// Independent FLV framing implementation; no Flutter or platform dependencies.
import 'dart:async';
import 'dart:typed_data';

/// Deliberately contains no upstream URL, response body, or request headers.
class LiveFlvException implements Exception {
  const LiveFlvException(this.code);
  final String code;
  @override
  String toString() => 'LiveFlvException($code)';
}

/// Hard limits apply even before a downstream player connects.
abstract final class LiveFlvLimits {
  static const maxTag = 2 * 1024 * 1024;
  static const maxPrefetch = 8 * 1024 * 1024;
  static const maxPrefetchTags = 1024;
  static const maxHistory = 2 * 1024 * 1024;
  static const connectTimeout = Duration(seconds: 5);
  static const readTimeout = Duration(seconds: 5);
  static const prepareTimeout = Duration(seconds: 8);
  static const renewTimeout = Duration(seconds: 8);
  static const idleTimeout = Duration(seconds: 15);
}

int _u24(List<int> b, int p) => (b[p] << 16) | (b[p + 1] << 8) | b[p + 2];
int _u32(List<int> b, int p) => (_u24(b, p) << 8) | b[p + 3];

bool flvBytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class LiveFlvTag {
  LiveFlvTag(this.type, this.timestamp, this.data, this.time);
  LiveFlvTag._owned(this.type, this.timestamp, Uint8List packet, this.time)
    : data = Uint8List.sublistView(packet, 11, packet.length - 4),
      _packet = packet;
  Uint8List? _packet;
  final int type;
  final int timestamp;
  final Uint8List data;
  // Unwrapped decode time, not AVC composition/presentation time.
  final int time;

  bool get videoConfig => type == 9 && data[1] == 0;
  bool get audioConfig => type == 8 && data[1] == 0;
  bool get media => (type == 8 || type == 9) && data[1] == 1;
  bool get keyframe => type == 9 && data[1] == 1 && data[0] >> 4 == 1;

  /// 中继只发送一次：转移 reader 自有缓冲区，仅改头部时间戳，不再复制 payload。
  /// 再次调用仍返回独立字节；历史索引只引用不可修改的 payload 区域。
  Uint8List takePacket(int outputTime) {
    final packet = _packet;
    if (packet == null) return encode(outputTime);
    _packet = null;
    final stamp = outputTime & 0xffffffff;
    packet[4] = stamp >> 16;
    packet[5] = stamp >> 8;
    packet[6] = stamp;
    packet[7] = stamp >> 24;
    return packet;
  }

  Uint8List encode(int outputTime) {
    final bytes = Uint8List(15 + data.length);
    final stamp = outputTime & 0xffffffff;
    bytes[0] = type;
    bytes[1] = data.length >> 16;
    bytes[2] = data.length >> 8;
    bytes[3] = data.length;
    bytes[4] = stamp >> 16;
    bytes[5] = stamp >> 8;
    bytes[6] = stamp;
    bytes[7] = stamp >> 24;
    bytes.setRange(11, 11 + data.length, data);
    ByteData.sublistView(bytes).setUint32(11 + data.length, 11 + data.length);
    return bytes;
  }
}

/// Pull-based framing: the subscription is paused between reads. There is no
/// unbounded producer queue; at most one source chunk and one tag are retained.
class LiveFlvReader {
  LiveFlvReader(Stream<List<int>> stream, {required this.abort})
    : _input = StreamIterator<List<int>>(stream);
  final void Function() abort;
  final StreamIterator<List<int>> _input;
  Uint8List header = Uint8List(0);
  Uint8List? videoConfiguration;
  Uint8List? audioConfiguration;
  List<int> _chunk = const [];
  int _position = 0;
  int _highTime = 0;
  int _nalLength = 0;
  final List<Uint8List> _parameterSets = [];
  bool _closed = false;
  Future<void>? _cancelling;

  bool get hasAudio => header[4] & 4 != 0;

  /// 只有完整下一包已在当前网络块中才延后 flush，不能为了凑批等待网络。
  bool get hasCompleteTagBuffered {
    final left = _chunk.length - _position;
    return left >= 11 && left >= 15 + _u24(_chunk, _position + 1);
  }

  Future<T> _timed<T>(Future<T> operation) async {
    try {
      return await operation.timeout(LiveFlvLimits.readTimeout);
    } on TimeoutException {
      unawaited(cancel());
      throw const LiveFlvException('read-timeout');
    }
  }

  Future<Uint8List> _read(int size) async {
    final result = Uint8List(size);
    await _readInto(result, 0, size);
    return result;
  }

  Future<void> _readInto(Uint8List result, int start, int size) async {
    var written = 0;
    while (written < size) {
      if (_closed) throw const LiveFlvException('closed');
      if (_position == _chunk.length) {
        if (!await _input.moveNext()) {
          throw const LiveFlvException('unexpected-eof');
        }
        _chunk = _input.current;
        _position = 0;
        // HttpClient yields bounded network chunks; reject hostile custom
        // streams too, rather than retaining an arbitrary-size source buffer.
        if (_chunk.length > LiveFlvLimits.maxTag + 15) {
          throw const LiveFlvException('chunk-limit');
        }
        continue;
      }
      final available = _chunk.length - _position;
      final take = available < size - written ? available : size - written;
      result.setRange(
        start + written,
        start + written + take,
        _chunk,
        _position,
      );
      written += take;
      _position += take;
    }
  }

  Future<void> readHeader() => _timed(_readHeader());
  Future<void> _readHeader() async {
    final first = await _read(9);
    if (first[0] != 70 ||
        first[1] != 76 ||
        first[2] != 86 ||
        first[3] != 1 ||
        first[4] & ~5 != 0 ||
        first[4] & 1 == 0) {
      throw const LiveFlvException('unsupported-header');
    }
    final offset = _u32(first, 5);
    if (offset < 9 || offset > 4096) {
      throw const LiveFlvException('header-limit');
    }
    final rest = await _read(offset - 9 + 4);
    if (_u32(rest, rest.length - 4) != 0) {
      throw const LiveFlvException('previous-tag-size');
    }
    header = Uint8List.fromList([...first, ...rest]);
  }

  Future<LiveFlvTag> next() =>
      hasCompleteTagBuffered ? _next() : _timed(_next());
  Future<LiveFlvTag> _next() async {
    final h = await _read(11);
    final type = h[0];
    final size = _u24(h, 1);
    if (type != 8 && type != 9 && type != 18 || _u24(h, 8) != 0) {
      throw const LiveFlvException('invalid-tag-header');
    }
    if (size == 0 || size > LiveFlvLimits.maxTag) {
      throw const LiveFlvException('tag-limit');
    }
    final packet = Uint8List(size + 15)..setRange(0, 11, h);
    await _readInto(packet, 11, size + 4);
    final data = Uint8List.sublistView(packet, 11, size + 11);
    if (_u32(packet, size + 11) != size + 11) {
      throw const LiveFlvException('previous-tag-size');
    }
    if (type == 9) _validateVideo(data);
    if (type == 8) _validateAudio(data);
    final stamp = _u24(h, 4) | h[7] << 24;
    var time = (_highTime & ~0xffffffff) + stamp;
    // Nearest epoch also handles interleaved audio around the 32-bit wrap.
    if (time < _highTime - 0x80000000) time += 0x100000000;
    if (time > _highTime + 0x80000000 && time >= 0x100000000) {
      time -= 0x100000000;
    }
    if ((type == 8 || type == 9) && data[1] == 1 && time > _highTime) {
      _highTime = time;
    }
    return LiveFlvTag._owned(type, stamp, packet, time);
  }

  void _validateAudio(Uint8List data) {
    if (!hasAudio || data.length < 3 || data[0] >> 4 != 10 || data[1] > 1) {
      throw const LiveFlvException('unsupported-audio');
    }
    if (data[1] == 0) {
      if (data.length < 4 || data[2] >> 3 == 0 || data[2] >> 3 == 31) {
        throw const LiveFlvException('invalid-aac-config');
      }
      audioConfiguration = data;
    } else if (audioConfiguration == null) {
      throw const LiveFlvException('missing-aac-config');
    }
  }

  void _validateVideo(Uint8List data) {
    if (data.length < 6 ||
        data[0] & 15 != 7 ||
        (data[0] >> 4 != 1 && data[0] >> 4 != 2) ||
        data[1] > 1) {
      throw const LiveFlvException('unsupported-video');
    }
    if (data[1] == 0) {
      // AVCDecoderConfigurationRecord: require bounded SPS/PPS and a legal
      // length prefix before accepting any subsequent NAL units.
      if (data.length < 12 || data[5] != 1 || data[9] & 3 == 2) {
        throw const LiveFlvException('invalid-avc-config');
      }
      _nalLength = (data[9] & 3) + 1;
      var p = 11;
      final sps = data[10] & 31;
      if (sps == 0) throw const LiveFlvException('invalid-avc-config');
      _parameterSets.clear();
      void parameterSets(int count, int nalType) {
        if (count == 0) throw const LiveFlvException('invalid-avc-config');
        for (var i = 0; i < count; i++) {
          if (p + 2 > data.length) {
            throw const LiveFlvException('invalid-avc-config');
          }
          final length = (data[p] << 8) | data[p + 1];
          p += 2;
          if (length == 0 ||
              p + length > data.length ||
              data[p] & 31 != nalType) {
            throw const LiveFlvException('invalid-avc-config');
          }
          _parameterSets.add(Uint8List.sublistView(data, p, p + length));
          p += length;
        }
      }

      parameterSets(sps, 7);
      if (p >= data.length) throw const LiveFlvException('invalid-avc-config');
      final pps = data[p++];
      parameterSets(pps, 8);
      videoConfiguration = data;
    } else {
      if (_nalLength == 0) throw const LiveFlvException('missing-avc-config');
      var p = 5;
      var idr = false;
      while (p < data.length) {
        if (p + _nalLength > data.length) {
          throw const LiveFlvException('invalid-nal');
        }
        var length = 0;
        for (var i = 0; i < _nalLength; i++) {
          length = (length << 8) | data[p++];
        }
        if (length == 0 || p + length > data.length) {
          throw const LiveFlvException('invalid-nal');
        }
        if (data[p] & 31 == 5) idr = true;
        final nalType = data[p] & 31;
        if ((nalType == 7 || nalType == 8) &&
            !_parameterSets.any(
              (set) => flvBytesEqual(
                set,
                Uint8List.sublistView(data, p, p + length),
              ),
            )) {
          // Encoders may hide a resolution/profile change inside an IDR rather
          // than send another FLV sequence header. Never pass it off as seamless.
          throw const LiveFlvException('configuration-changed');
        }
        p += length;
      }
      if (data[0] >> 4 == 1 && !idr) {
        throw const LiveFlvException('missing-idr');
      }
    }
  }

  Future<void> cancel() {
    if (_cancelling != null) return _cancelling!;
    _closed = true;
    abort();
    _chunk = const [];
    _position = 0;
    return _cancelling = _input.cancel();
  }
}

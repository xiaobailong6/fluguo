// Original, standalone implementation for fluguo (not copied from pure_live).
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'live_flv_format.dart';
import 'live_models.dart';

/// One player, one private loopback endpoint, and at most two upstream readers.
/// Supports classic AVC + optional AAC FLV only. Unsupported or changed codec
/// configuration is reported through onFailure so the page can reopen normally.
class LiveFlvRelay {
  LiveFlvRelay._(this._current, this._renew, this._onRenewed, this._onFailure)
    : _client = HttpClient() {
    _client.connectionTimeout = LiveFlvLimits.connectTimeout;
    _client.idleTimeout = Duration.zero;
    _client.maxConnectionsPerHost = 2;
    _client.autoUncompress = false;
    _client.findProxy = (_) => 'DIRECT';
  }

  static bool appliesTo(LiveStream stream) =>
      stream.renewAfter != null && _validUri(stream.url) != null;

  static Uri? _validUri(String value) {
    try {
      final uri = Uri.parse(value);
      if ((uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          uri.port < 1 ||
          uri.port > 65535 ||
          !uri.path.toLowerCase().endsWith('.flv')) {
        return null;
      }
      return uri;
    } catch (_) {
      return null;
    }
  }

  static Future<LiveFlvRelay> start(
    LiveStream initial, {
    required Future<LiveStream> Function(LiveStream current) renew,
    void Function(LiveStream stream)? onRenewed,
    void Function(Object error)? onFailure,
    Future<void>? cancelled,
  }) async {
    if (!appliesTo(initial)) throw const LiveFlvException('invalid-stream');
    final relay = LiveFlvRelay._(initial, renew, onRenewed, onFailure);
    try {
      relay._server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      relay._server!.idleTimeout = LiveFlvLimits.idleTimeout;
      final random = Random.secure();
      relay._path =
          '/${List.generate(24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}.flv';
      relay._url = 'http://127.0.0.1:${relay._server!.port}${relay._path}';
      relay._server!.listen(
        relay._accept,
        onError: (_) {
          if (!relay._closed) {
            relay._fatal(const LiveFlvException('local-server'));
          }
        },
      );
      // 页面退出可能早于 start 返回；绑定成功后挂取消信号，确保服务器
      // 与正在等待的初始 header/关键帧一起关闭，而不是等读取超时。
      if (cancelled != null) {
        unawaited(
          cancelled.then((_) => relay.close(), onError: (_) => relay.close()),
        );
      }
      relay._active = await relay._prepare(initial, initial: true);
      relay._videoConfig = relay._active!.reader.videoConfiguration!;
      relay._audioConfig = relay._active!.reader.audioConfiguration;
      relay._idle = Timer(
        LiveFlvLimits.idleTimeout,
        () => unawaited(relay.close()),
      );
      relay._schedule(initial.renewAfter, elapsed: relay._active!.age.elapsed);
      return relay;
    } catch (error) {
      await relay.close();
      throw relay._safe(error);
    }
  }

  final HttpClient _client;
  final Future<LiveStream> Function(LiveStream) _renew;
  final void Function(LiveStream)? _onRenewed;
  final void Function(Object)? _onFailure;
  LiveStream _current;
  HttpServer? _server;
  String _path = '';
  String _url = '';
  String get url => _url;
  Socket? _output;
  bool _claimed = false;
  bool _closed = false;
  bool _renewing = false;
  bool _reported = false;
  int _attempts = 0;
  Timer? _timer;
  Timer? _idle;
  Future<void>? _closing;
  Completer<void>? _wake;
  final Set<void Function()> _cancellers = {};
  final Set<LiveFlvReader> _readers = {};
  final Set<HttpClientRequest> _requests = {};
  _Prepared? _active;
  _Prepared? _ready;
  Uint8List _videoConfig = Uint8List(0);
  Uint8List? _audioConfig;
  int _lastOutput = -1;
  int _floor = -1;
  final Queue<_History> _history = Queue();
  int _historyBytes = 0;
  final _historyIndex = <int, Set<_History>>{};
  int _pendingOutputBytes = 0;
  int _pendingOutputTags = 0;
  final _batchClock = Stopwatch()..start();

  LiveFlvException _safe(Object error) => error is LiveFlvException
      ? error
      : const LiveFlvException('upstream-failure');

  /// A cancellable deadline also covers a resolver that never completes. Its
  /// future cannot be forcibly cancelled, but a late value/error is consumed
  /// and cannot open sockets, publish callbacks, or resurrect this relay.
  Future<T> _bounded<T>(Future<T> work, Duration timeout) {
    final result = Completer<T>();
    Timer? timer;
    late void Function() cancel;
    void finish(void Function() complete) {
      if (result.isCompleted) return;
      timer?.cancel();
      _cancellers.remove(cancel);
      complete();
    }

    cancel = () =>
        finish(() => result.completeError(const LiveFlvException('closed')));
    if (_closed) {
      cancel();
    } else {
      _cancellers.add(cancel);
      timer = Timer(
        timeout,
        () => finish(
          () =>
              result.completeError(const LiveFlvException('operation-timeout')),
        ),
      );
    }
    work.then(
      (value) => finish(() => result.complete(value)),
      onError: (Object error, StackTrace stack) {
        finish(() => result.completeError(_safe(error), stack));
      },
    );
    return result.future;
  }

  Future<LiveFlvReader> _open(LiveStream stream) async {
    final uri = _validUri(stream.url);
    if (uri == null) throw const LiveFlvException('invalid-stream');
    if (_closed) throw const LiveFlvException('closed');
    var abandoned = false;
    HttpClientRequest? request;
    try {
      final owned = await _bounded<HttpClientRequest>(
        _client.getUrl(uri).then((value) {
          if (abandoned || _closed) {
            value.abort();
            throw const LiveFlvException('closed');
          }
          _requests.add(value);
          return value;
        }),
        LiveFlvLimits.connectTimeout,
      );
      request = owned;
      // Never forward credentials across redirects. Each renewal supplies a
      // complete fresh header set; no global client or cookie jar is shared.
      owned.followRedirects = false;
      owned.persistentConnection = false;
      for (final entry in stream.headers.entries) {
        owned.headers.set(entry.key, entry.value);
      }
      final response = await _bounded(
        owned.close().then((value) async {
          if (abandoned || _closed) {
            await value.listen((_) {}).cancel();
            throw const LiveFlvException('closed');
          }
          return value;
        }),
        LiveFlvLimits.connectTimeout,
      );
      if (_closed) {
        await response.listen((_) {}).cancel();
        throw const LiveFlvException('closed');
      }
      if (response.statusCode != HttpStatus.ok) {
        // abort() alone is a no-op after headers have arrived. Cancelling the
        // response subscription releases even an endless HTTP error body.
        await response.listen((_) {}).cancel();
        throw const LiveFlvException('http-status');
      }
      final reader = LiveFlvReader(
        response,
        abort: () {
          owned.abort();
          _requests.remove(owned);
        },
      );
      _readers.add(reader);
      return reader;
    } catch (_) {
      abandoned = true;
      request?.abort();
      _requests.remove(request);
      rethrow;
    }
  }

  Future<void> _discard(LiveFlvReader reader) async {
    await reader.cancel();
    _readers.remove(reader);
  }

  Future<_Prepared> _prepare(LiveStream stream, {bool initial = false}) async {
    final age = Stopwatch()..start();
    final reader = await _open(stream);
    try {
      final prepared = await _bounded(
        _collect(reader, stream, initial),
        LiveFlvLimits.prepareTimeout,
      );
      prepared.age = age;
      return prepared;
    } catch (_) {
      await _discard(reader);
      rethrow;
    }
  }

  void _compatible(LiveFlvReader reader) {
    if (reader.header[4] != _active!.reader.header[4] ||
        reader.videoConfiguration != null &&
            !flvBytesEqual(reader.videoConfiguration!, _videoConfig) ||
        reader.audioConfiguration != null &&
            (_audioConfig == null ||
                !flvBytesEqual(reader.audioConfiguration!, _audioConfig!))) {
      throw const LiveFlvException('configuration-changed');
    }
  }

  Future<_Prepared> _collect(
    LiveFlvReader reader,
    LiveStream stream,
    bool initial,
  ) async {
    await reader.readHeader();
    if (!initial) _compatible(reader);
    var bytes = reader.header.length;
    var count = 0;
    LiveFlvTag? video;
    LiveFlvTag? audio;
    LiveFlvTag? metadata;
    int? alignedOffset;
    int? previousMatchOffset;
    int? previousMatchTime;
    while (!_closed) {
      final tag = await reader.next();
      bytes += tag.data.length + 15;
      if (++count > LiveFlvLimits.maxPrefetchTags ||
          bytes > LiveFlvLimits.maxPrefetch) {
        throw const LiveFlvException('prefetch-limit');
      }
      if (!initial) _compatible(reader);
      if (tag.videoConfig) video = tag;
      if (tag.audioConfig) audio = tag;
      if (tag.type == 18 && initial) metadata = tag;
      final natural = initial ? tag.time : tag.time + _active!.offset;
      final nearbyForward =
          natural > _lastOutput && natural - _lastOutput <= 10000;
      var provisionalOverlap = false;
      if (!initial && tag.type == 9 && tag.media) {
        final matches =
            (_historyIndex[_frameKey(tag.data)] ?? const <_History>{})
                .where((old) => flvBytesEqual(old.data, tag.data))
                .take(2)
                .toList();
        // 重复静态帧不能证明时钟关系；只采纳连续两个唯一且偏移一致的对应。
        if (matches.length == 1) {
          final offset = matches.single.outputTime - tag.time;
          if (previousMatchOffset == offset &&
              previousMatchTime != null &&
              tag.time > previousMatchTime) {
            alignedOffset = offset;
          }
          previousMatchOffset = offset;
          previousMatchTime = tag.time;
          provisionalOverlap = alignedOffset == null && !nearbyForward;
        } else {
          previousMatchOffset = null;
          previousMatchTime = null;
        }
      }
      if (!tag.keyframe || video == null || reader.hasAudio && audio == null) {
        continue;
      }
      // With no overlapping payload, preserve a nearby forward decode clock;
      // a reset or large discontinuity starts immediately after the output tail.
      // Exact overlap above remains authoritative, including rebased CDN clocks.
      if (provisionalOverlap) continue;
      final offset = initial
          ? 0
          : alignedOffset ??
                (nearbyForward ? _active!.offset : _lastOutput + 1 - tag.time);
      // An overlapping GOP cannot be replayed after the already emitted tail.
      // Keep the old connection playing while waiting for a newer IDR instead.
      if (!initial &&
          alignedOffset != null &&
          tag.time + offset <= _lastOutput) {
        continue;
      }
      return _Prepared(
        reader,
        stream,
        offset,
        Queue.of([?metadata, video, ?audio, tag]),
      );
    }
    throw const LiveFlvException('closed');
  }

  void _accept(HttpRequest request) {
    final uri = request.uri;
    final expectedHost = '127.0.0.1:${_server!.port}';
    if (_closed ||
        uri.path != _path ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.hasScheme ||
        request.headers.value(HttpHeaders.hostHeader) != expectedHost) {
      request.response.statusCode = HttpStatus.notFound;
      unawaited(request.response.close().catchError((_) {}));
      return;
    }
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      request.response.headers.set(HttpHeaders.allowHeader, 'GET');
      unawaited(request.response.close().catchError((_) {}));
      return;
    }
    if (_claimed) {
      request.response.statusCode = HttpStatus.conflict;
      unawaited(request.response.close().catchError((_) {}));
      return;
    }
    _claimed = true;
    _idle?.cancel();
    unawaited(_attachPlayer(request));
  }

  Future<void> _attachPlayer(HttpRequest request) async {
    try {
      // HttpResponse.done alone does not observe an idle peer disconnect on
      // every OS. Own the socket read side explicitly; use close-delimited
      // HTTP so raw FLV bytes require no second chunk-framing queue.
      request.response
        ..bufferOutput = false
        ..persistentConnection = false
        ..headers.chunkedTransferEncoding = false
        ..headers.contentType = ContentType('video', 'x-flv')
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..headers.set('X-Content-Type-Options', 'nosniff');
      final socket = await request.response.detachSocket();
      if (_closed) {
        socket.destroy();
        return;
      }
      _output = socket;
      socket.listen(
        (_) => unawaited(close()),
        onDone: () => unawaited(close()),
        onError: (_) => unawaited(close()),
      );
      unawaited(socket.done.then((_) => close(), onError: (_) => close()));
      await _pump();
    } catch (_) {
      if (!_closed) unawaited(close());
    }
  }

  Future<void> _write(List<int> bytes) async {
    if (_closed) throw const LiveFlvException('closed');
    _output!.add(bytes);
    await _flush();
  }

  Future<void> _flush() async {
    await _bounded(_output!.flush(), LiveFlvLimits.readTimeout);
    _pendingOutputBytes = _pendingOutputTags = 0;
    _batchClock.reset();
  }

  Future<void> _pump() async {
    Future<_Read>? pending;
    try {
      await _write(_active!.reader.header);
      while (!_closed) {
        if (_ready != null) {
          if (_pendingOutputBytes > 0) await _flush();
          final old = _active!;
          final next = _ready!;
          // Re-check at the actual handoff: an old tag may have been flushing
          // while the candidate became ready. Never discard the candidate IDR.
          if (next.queue.last.time + next.offset <= _lastOutput) {
            _ready = null;
            await _discard(next.reader);
            if (++_attempts >= 3) {
              _report(const LiveFlvException('handoff-overtaken'));
            } else {
              _schedule(const Duration(milliseconds: 400));
            }
            continue;
          }
          _ready = null;
          _active = next;
          _floor = _lastOutput;
          pending = null; // Its error is already consumed by _Read.capture.
          await _discard(old.reader);
          if (_closed) break;
          _current = next.stream;
          _attempts = 0;
          _schedule(_current.renewAfter, elapsed: next.age.elapsed);
          try {
            _onRenewed?.call(_current);
          } catch (_) {
            /* Observer only. */
          }
        }
        final active = _active!;
        LiveFlvTag tag;
        if (active.queue.isNotEmpty) {
          tag = active.queue.removeFirst();
        } else if (pending == null && active.reader.hasCompleteTagBuffered) {
          tag = await active.reader.next();
        } else {
          if (_pendingOutputBytes > 0) await _flush();
          pending ??= _Read.capture(active.reader.next());
          final wake = Completer<void>();
          _wake = wake;
          final value = await _bounded(
            Future.any<_Read?>([
              pending,
              wake.future.then<_Read?>((_) => null),
            ]),
            LiveFlvLimits.readTimeout + const Duration(seconds: 1),
          );
          _wake = null;
          if (_closed) break;
          if (_ready != null) continue;
          if (value == null) continue;
          pending = null;
          if (value.error != null) throw value.error!;
          tag = value.tag!;
        }
        if (tag.videoConfig && !flvBytesEqual(tag.data, _videoConfig) ||
            tag.audioConfig &&
                (_audioConfig == null ||
                    !flvBytesEqual(tag.data, _audioConfig!))) {
          throw const LiveFlvException('configuration-changed');
        }
        var outputTime = tag.media
            ? tag.time + active.offset
            : max(0, _lastOutput);
        if (tag.media && outputTime <= _floor) continue;
        if (tag.media && outputTime < _lastOutput - 1000) {
          throw const LiveFlvException('timeline-regression');
        }
        outputTime = max(outputTime, max(0, _lastOutput));
        if (tag.media) {
          _lastOutput = outputTime;
          if (tag.type == 9) {
            final entry = _History(tag.data, outputTime);
            _history.add(entry);
            (_historyIndex[entry.key] ??= {}).add(entry);
            _historyBytes += tag.data.length;
            while (_historyBytes > LiveFlvLimits.maxHistory ||
                _history.length > 256) {
              final removed = _history.removeFirst();
              _historyBytes -= removed.data.length;
              final bucket = _historyIndex[removed.key]!;
              bucket.remove(removed);
              if (bucket.isEmpty) _historyIndex.remove(removed.key);
            }
          }
        }
        final packet = tag.takePacket(outputTime);
        if (_closed) break;
        _output!.add(packet);
        _pendingOutputBytes += packet.length;
        _pendingOutputTags++;
        if (_pendingOutputBytes >= 64 * 1024 ||
            _pendingOutputTags >= 32 ||
            _batchClock.elapsedMicroseconds >= 4000 ||
            (active.queue.isEmpty && !active.reader.hasCompleteTagBuffered)) {
          await _flush();
          // 即便 socket 已可写，热数据循环也要让出事件队列给绘制/取消/续期。
          await Future<void>.delayed(Duration.zero);
        }
      }
    } catch (error) {
      if (!_closed) _fatal(error);
    }
  }

  void _schedule(Duration? duration, {Duration elapsed = Duration.zero}) {
    _timer?.cancel();
    if (_closed || duration == null || _reported) return;
    // Begin slightly before expiry, with a floor against zero-duration storms.
    final micros = duration.inMicroseconds;
    final lead = min(
      const Duration(seconds: 2).inMicroseconds,
      max(0, micros ~/ 5),
    );
    final delay = Duration(
      microseconds: max(100000, micros - lead - elapsed.inMicroseconds),
    );
    _timer = Timer(delay, () => unawaited(_renewOnce()));
  }

  Future<void> _renewOnce() async {
    if (_closed || _renewing || _ready != null || _reported) return;
    _renewing = true;
    try {
      final stream = await _bounded(
        Future.sync(() => _renew(_current)).onError(
          (Object _, StackTrace _) =>
              throw const LiveFlvException('renew-failure'),
        ),
        LiveFlvLimits.renewTimeout,
      );
      if (_closed) return;
      final prepared = await _prepare(stream);
      if (_closed) {
        await _discard(prepared.reader);
        return;
      }
      _ready = prepared;
      _wake?.complete();
    } catch (error) {
      if (!_closed) {
        _attempts++;
        final safe = _safe(error);
        if (safe.code == 'configuration-changed' ||
            safe.code == 'operation-timeout' ||
            _attempts >= 3) {
          _report(safe);
        } else {
          // Failed candidates have been cancelled before retrying. The old
          // reader is untouched, and there are at most three attempts/expiry.
          _timer = Timer(
            Duration(milliseconds: 250 * _attempts),
            () => unawaited(_renewOnce()),
          );
        }
      }
    } finally {
      _renewing = false;
    }
  }

  void _report(Object error) {
    if (_reported || _closed) return;
    _reported = true;
    _timer?.cancel();
    try {
      _onFailure?.call(_safe(error));
    } catch (_) {
      /* Observer only. */
    }
  }

  void _fatal(Object error) {
    _report(error);
    unawaited(close());
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _timer?.cancel();
    _idle?.cancel();
    for (final cancel in _cancellers.toList()) {
      cancel();
    }
    if (_wake != null && !_wake!.isCompleted) _wake!.complete();
    _wake = null;
    for (final request in _requests.toList()) {
      request.abort();
    }
    _requests.clear();
    _client.close(force: true);
    _output?.destroy();
    return _closing = _release();
  }

  Future<void> _release() async {
    final closingServer = _server?.close(force: true);
    await Future.wait(
      _readers.toList().map((reader) async {
        try {
          await reader.cancel();
        } catch (_) {
          /* Socket already gone. */
        }
      }),
    );
    _readers.clear();
    _active?.queue.clear();
    _ready?.queue.clear();
    _history.clear();
    _historyIndex.clear();
    _batchClock.stop();
    _active = null;
    _ready = null;
    _output = null;
    if (closingServer != null) await closingServer;
  }
}

class _Prepared {
  _Prepared(this.reader, this.stream, this.offset, this.queue);
  Stopwatch age = Stopwatch()..start();
  final LiveFlvReader reader;
  final LiveStream stream;
  final int offset;
  final Queue<LiveFlvTag> queue;
}

// 常量成本采样仅用于缩小桶；碰撞仍逐字节确认，不能影响交接正确性。
int _frameKey(Uint8List data) {
  var key = data.length;
  for (var i = 0; i < 16 && i < data.length; i++) {
    key = ((key * 31) ^ data[i * (data.length - 1) ~/ 15]) & 0x3fffffff;
  }
  return key;
}

class _History {
  _History(this.data, this.outputTime) : key = _frameKey(data);
  final int key;
  final Uint8List data;
  final int outputTime;
}

class _Read {
  _Read(this.tag, this.error);
  final LiveFlvTag? tag;
  final Object? error;
  static Future<_Read> capture(Future<LiveFlvTag> read) => read.then(
    (tag) => _Read(tag, null),
    onError: (Object error) => _Read(null, error),
  );
}

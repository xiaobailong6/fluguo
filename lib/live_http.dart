import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const liveUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

Map<String, String> liveHeaders(String origin) => {
  'User-Agent': liveUserAgent,
  'Referer': '$origin/',
  'Origin': origin,
};

class LiveHttp {
  /// 复用同一个客户端：取流阶段会连续请求多个接口（斗鱼单次解析最多 4 次、
  /// 虎牙并发 4 路），每次新建客户端都要重付一次 TCP + TLS 握手。
  /// 保持少量空闲长连接比反复握手便宜得多。
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12);

  static Future<String> text(
    String url, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    Map<String, String>? form,
  }) async {
    final uri = Uri.parse(
      url,
    ).replace(queryParameters: query.isEmpty ? null : query);
    if (!uri.hasAuthority || uri.scheme != 'https') {
      throw StateError('直播接口地址无效');
    }
    final result = await requestLiveResponse(
      () => _client.openUrl(form == null ? 'GET' : 'POST', uri),
      configure: (request) {
        request.headers.set(HttpHeaders.userAgentHeader, liveUserAgent);
        headers.forEach((key, value) => request.headers.set(key, value));
        if (form != null) {
          request.headers.contentType = ContentType(
            'application', 'x-www-form-urlencoded', charset: 'utf-8',
          );
          request.write(Uri(queryParameters: form).query);
        }
      },
    );
    if (result.status != 200) {
      throw StateError('直播平台接口 HTTP ${result.status}，请稍后重试');
    }
    return utf8.decode(result.bytes);
  }

  static Future<Map<String, dynamic>> json(
    String url, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    Map<String, String>? form,
  }) async {
    dynamic data = jsonDecode(
      await text(url, query: query, headers: headers, form: form),
    );
    // 部分虎牙接口外层是 JSON 字符串，而不是对象。
    if (data is String) data = jsonDecode(data);
    if (data is! Map) throw StateError('直播接口返回格式异常');
    return Map<String, dynamic>.from(data);
  }
}

const liveResponseMaxBytes = 8 * 1024 * 1024;
const liveErrorMaxBytes = 64 * 1024;
const liveRequestTimeout = Duration(seconds: 30);

/// 一个绝对时限覆盖获取 request、响应头、响应体；晚到的 request 也要中断。
Future<({int status, HttpHeaders headers, Uint8List bytes})> requestLiveResponse(
  Future<HttpClientRequest> Function() open, {
  void Function(HttpClientRequest)? configure,
  Duration timeout = liveRequestTimeout,
}) async {
  final clock = Stopwatch()..start();
  var expired = false;
  HttpClientRequest? request;
  Duration remaining() {
    final left = timeout - clock.elapsed;
    if (left <= Duration.zero) throw TimeoutException('直播接口响应超时');
    return left;
  }

  try {
    // timeout 不取消 Future；这个回调在超时之后仍负责释放晚到的连接。
    final openingBudget = remaining();
    void observeCompletion(HttpClientRequest value) {
      // abort 在 close 之前也会使 done 失败，必须消费该 Future 的错误。
      unawaited(value.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    }
    final active = await open().then((value) {
      observeCompletion(value);
      if (expired) value.abort();
      return value;
    }).timeout(openingBudget);
    request = active;
    configure?.call(active);
    final headerBudget = remaining();
    final response = await active.close().timeout(headerBudget);
    final success = response.statusCode == HttpStatus.ok;
    Uint8List bytes;
    try {
      bytes = await readLiveResponse(
        response,
        abort: () => active.abort(),
        timeout: remaining(),
        maxBytes: success ? liveResponseMaxBytes : liveErrorMaxBytes,
      );
    } catch (_) {
      if (success) rethrow;
      // 错误页无论超限、超时或损坏，调用者仍得到原始 HTTP 状态。
      active.abort();
      bytes = Uint8List(0);
    }
    return (status: response.statusCode, headers: response.headers, bytes: bytes);
  } catch (_) {
    expired = true;
    request?.abort();
    rethrow;
  } finally {
    clock.stop();
  }
}

/// 按原始字节计数，先检查再保存；滴流不能延长总时限。
Future<Uint8List> readLiveResponse(
  Stream<List<int>> response, {
  required void Function() abort,
  Duration timeout = liveRequestTimeout,
  int maxBytes = liveResponseMaxBytes,
}) {
  final done = Completer<Uint8List>();
  final bytes = BytesBuilder(copy: false);
  StreamSubscription<List<int>>? subscription;
  Timer? timer;
  var finished = false;

  void cancel() {
    unawaited(subscription?.cancel().catchError((Object _) {}));
  }

  void fail(Object error, [StackTrace? stack]) {
    if (finished) return;
    finished = true;
    timer?.cancel();
    cancel();
    abort();
    done.completeError(error, stack);
  }

  timer = Timer(timeout, () => fail(TimeoutException('直播接口响应超时')));
  try {
    subscription = response.listen(
      (chunk) {
        if (finished) return;
        if (chunk.length > maxBytes - bytes.length) {
          fail(StateError('直播接口数据超过大小限制'));
        } else {
          bytes.add(chunk);
        }
      },
      onError: (Object error, StackTrace stack) => fail(error, stack),
      onDone: () {
        if (finished) return;
        finished = true;
        timer?.cancel();
        done.complete(bytes.takeBytes());
      },
    );
    if (finished) cancel();
  } catch (error, stack) {
    fail(error, stack);
  }
  return done.future;
}

/// 错误页的读取失败不覆盖上层 HTTP 状态。
Future<void> drainLiveErrorResponse(
  Stream<List<int>> response, {
  required void Function() abort,
  Duration timeout = const Duration(seconds: 5),
  int maxBytes = liveErrorMaxBytes,
}) async {
  try {
    await readLiveResponse(response, abort: abort, timeout: timeout, maxBytes: maxBytes);
  } catch (_) {}
}

int liveInt(Object? value) => int.tryParse('$value') ?? 0;
String liveImage(Object? value) {
  final text = '${value ?? ''}';
  if (text.startsWith('//')) return 'https:$text';
  return text.startsWith('http://')
      ? text.replaceFirst('http://', 'https://')
      : text;
}

String livePopularity(Object? value) {
  final count = liveInt(value);
  if (count <= 0) return '';
  if (count < 10000) return '$count';
  return '${(count / 10000).toStringAsFixed(count < 1000000 ? 1 : 0)}万';
}

/// 从网页指定位置取完整 JSON 对象；引号内的大括号不参与计数。
Map<String, dynamic> livePageObject(String page, String marker) {
  final match = RegExp(marker).firstMatch(page);
  if (match == null) throw StateError('直播间未开播或平台页面结构已变更');
  final start = page.indexOf('{', match.end);
  var depth = 0;
  var quoted = false;
  var escaped = false;
  // 逐字符 page[i] 会为每个位置新建一个 String，页面动辄数百 KB；
  // 直接遍历 UTF-16 代码单元即可，引号、大括号、反斜杠都在 ASCII 内。
  const quote = 0x22;
  const openBrace = 0x7b;
  const closeBrace = 0x7d;
  const backslash = 0x5c;
  final units = page.codeUnits;
  for (var i = start; i >= 0 && i < units.length; i++) {
    final c = units[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (c == backslash) {
        escaped = true;
      } else if (c == quote) {
        quoted = false;
      }
      continue;
    }
    if (c == quote) {
      quoted = true;
    } else if (c == openBrace) {
      depth++;
    } else if (c == closeBrace && --depth == 0) {
      return Map<String, dynamic>.from(
        jsonDecode(page.substring(start, i + 1)) as Map,
      );
    }
  }
  throw StateError('直播间流信息不完整');
}

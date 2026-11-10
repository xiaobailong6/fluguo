import 'dart:convert';
import 'dart:io';

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
    if (!uri.hasAuthority || uri.scheme != 'https')
      throw StateError('直播接口地址无效');
    final client = _client;
    final request = await client
        .openUrl(form == null ? 'GET' : 'POST', uri)
        .timeout(const Duration(seconds: 15));
    request.headers.set(HttpHeaders.userAgentHeader, liveUserAgent);
    headers.forEach((key, value) => request.headers.set(key, value));
    if (form != null) {
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.write(Uri(queryParameters: form).query);
    }
    final response = await request.close().timeout(
      const Duration(seconds: 20),
    );
    if (response.statusCode != 200) {
      // 读取完错误响应再抛出，连接才能回到复用池，而不是被强制断开。
      await response.drain<void>().timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      throw StateError('直播平台接口 HTTP ${response.statusCode}，请稍后重试');
    }
    // 直接拼接字节，避免接近 8MB 上限时反复扩容并整份拷贝。
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      bytes.add(chunk);
      if (bytes.length > 8 * 1024 * 1024) {
        // 中断读取会让客户端丢弃这条连接，不会把半截响应放回复用池。
        throw StateError('直播接口数据超过大小限制');
      }
    }
    return utf8.decode(bytes.takeBytes());
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

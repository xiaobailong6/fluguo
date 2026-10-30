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
  static Future<String> text(
    String url, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    Map<String, String>? form,
  }) async {
    final uri = Uri.parse(url)
        .replace(queryParameters: query.isEmpty ? null : query);
    if (!uri.hasAuthority || uri.scheme != 'https')
      throw StateError('直播接口地址无效');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
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
      if (response.statusCode != 200)
        throw StateError('直播平台接口 HTTP ${response.statusCode}，请稍后重试');
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 8 * 1024 * 1024) throw StateError('直播接口数据超过大小限制');
      }
      return utf8.decode(bytes);
    } finally {
      client.close(force: true);
    }
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
  for (var i = start; i >= 0 && i < page.length; i++) {
    final c = page[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        quoted = false;
      }
      continue;
    }
    if (c == '"') {
      quoted = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}' && --depth == 0) {
      return Map<String, dynamic>.from(
        jsonDecode(page.substring(start, i + 1)) as Map,
      );
    }
  }
  throw StateError('直播间流信息不完整');
}

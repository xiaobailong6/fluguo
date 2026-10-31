import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'live_douyin_sign.dart';

const douyinUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const douyinOrigin = 'https://live.douyin.com';

typedef DouyinRequest =
    Future<DouyinResponse> Function(Uri uri, Map<String, String> headers);

class DouyinResponse {
  const DouyinResponse(this.body, {this.status = 200, this.cookies = const {}});
  final String body;
  final int status;
  final Map<String, String> cookies;
}

/// 匿名会话只保存在内存，不使用用户账号 Cookie，也不写入收藏/历史/备份。
class DouyinClient {
  DouyinClient({DouyinRequest? request, DateTime Function()? clock})
    : _request = request ?? _network,
      _clock = clock ?? DateTime.now;
  final DouyinRequest _request;
  final DateTime Function() _clock;
  final _cookies = <String, String>{};
  final _random = Random.secure();
  DateTime? _expires;
  DateTime? _homeExpires;
  String? _homeBody;
  Future<String>? _pendingHome;

  Map<String, String> get headers => {
    'User-Agent': douyinUserAgent,
    'Referer': '$douyinOrigin/',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    if (_cookies.isNotEmpty)
      'Cookie': _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
  };

  Future<String> home() {
    if (_expires != null && !_clock().isBefore(_expires!)) {
      _cookies.clear();
      _homeBody = null;
    }
    if (_homeBody != null && _clock().isBefore(_homeExpires!)) {
      return Future.value(_homeBody);
    }
    final pending = _pendingHome;
    if (pending != null) return pending;
    final task = _get(Uri.parse('$douyinOrigin/?from_nav=1')).then((body) {
      if (body.trim().isEmpty) throw StateError('抖音分类页面返回空响应，请稍后重试');
      _homeBody = body;
      _homeExpires = _clock().add(const Duration(minutes: 5));
      _expires = _clock().add(const Duration(minutes: 30));
      return body;
    });
    _pendingHome = task;
    // 成功和失败都清理，避免失败 Future 永久阻止重试。
    unawaited(
      task.then<void>(
        (_) => _pendingHome = null,
        onError: (Object _, StackTrace _) {
          _pendingHome = null;
        },
      ),
    );
    return task;
  }

  Future<String> page(String roomId) async {
    await home();
    return _get(Uri.parse('$douyinOrigin/${Uri.encodeComponent(roomId)}'));
  }

  Future<Map<String, dynamic>> json(
    String path,
    Map<String, String> query, {
    String origin = douyinOrigin,
  }) async {
    await home();
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=';
    final parameters = <String, String>{
      'aid': '6383',
      'app_name': 'douyin_web',
      'live_id': '1',
      'device_platform': 'web',
      'language': 'zh-CN',
      'browser_language': 'zh-CN',
      'browser_platform': 'Win32',
      'browser_name': 'Edge',
      'browser_version': '125.0.0.0',
      'cookie_enabled': 'true',
      'compress': 'gzip',
      'msToken': List.generate(
        184,
        (_) => alphabet[_random.nextInt(alphabet.length)],
      ).join(),
      ...query,
    };
    final encoded = Uri(queryParameters: parameters).query;
    final signed = signDouyinQuery(encoded, userAgent: douyinUserAgent);
    // 签名针对完整原始 query，不能再用 queryParameters 重新排序或二次编码。
    final body = await _get(Uri.parse('$origin$path?$signed'));
    if (body.trim().isEmpty) {
      throw StateError('抖音接口返回空响应，可能受到平台风控，请稍后重试');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw StateError('抖音接口返回验证页面或无效数据，请稍后重试');
    }
    if (decoded is! Map) throw StateError('抖音接口格式已变更');
    final status = int.tryParse('${decoded['status_code'] ?? ''}');
    if (status != null && status != 0) {
      throw StateError('抖音接口暂不可用（平台代码 $status），请稍后重试');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<String> _get(Uri uri) async {
    if (uri.scheme != 'https' ||
        !const {
          'live.douyin.com',
          'www.douyin.com',
          'webcast.amemv.com',
        }.contains(uri.host)) {
      throw StateError('抖音接口地址无效');
    }
    final DouyinResponse response;
    try {
      response = await _request(
        uri,
        headers,
      ).timeout(const Duration(seconds: 30));
    } catch (_) {
      // 不把带签名 URL 或 Cookie 带入 UI/日志。
      throw StateError('抖音网络请求失败或超时，请稍后重试');
    }
    if (response.status != 200) {
      throw StateError('抖音接口 HTTP ${response.status}，请稍后重试');
    }
    if (utf8.encode(response.body).length > 8 * 1024 * 1024) {
      throw StateError('抖音接口数据超过大小限制');
    }
    for (final cookie in response.cookies.entries) {
      if (const {
            'ttwid',
            'UIFID_TEMP',
            '__ac_nonce',
            'msToken',
          }.contains(cookie.key) &&
          !cookie.value.contains(RegExp(r'[;\r\n]'))) {
        _cookies[cookie.key] = cookie.value;
      }
    }
    return response.body;
  }

  /// 部分响应含 `Secure=...`，内置 Cookie 解析会抛异常；只取首个键值。
  static Map<String, String> responseCookies(Iterable<String> values) {
    final result = <String, String>{};
    for (final raw in values) {
      final pair = raw.split(';').first.trim();
      final equal = pair.indexOf('=');
      if (equal > 0) {
        result[pair.substring(0, equal)] = pair.substring(equal + 1);
      }
    }
    return result;
  }

  static Future<DouyinResponse> _network(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 8 * 1024 * 1024) {
          throw StateError('response too large');
        }
      }
      return DouyinResponse(
        utf8.decode(bytes),
        status: response.statusCode,
        cookies: responseCookies(
          response.headers[HttpHeaders.setCookieHeader] ?? const [],
        ),
      );
    } finally {
      client.close(force: true);
    }
  }
}

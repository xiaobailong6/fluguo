import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'live_http.dart';
import 'live_models.dart';

/// 参考 pure_live 的平台协议，保留本应用自己的数据和播放栈。
class DouyuLive extends LivePlatform {
  const DouyuLive();
  @override
  String get id => 'douyu';
  @override
  String get name => '斗鱼';
  static const origin = 'https://www.douyu.com';
  static final _device = List.generate(
    16,
    (_) => Random.secure().nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static Map<String, String> get headers => {
    ...liveHeaders(origin),
    'Cookie': 'dy_did=$_device',
  };

  @override
  Future<List<LiveCategory>> categories() async => parseCategories(
    await LiveHttp.json('https://m.douyu.com/api/cate/list', headers: headers),
  );

  static List<LiveCategory> parseCategories(Map<String, dynamic> json) {
    final data = json['data'];
    if (json['code'] != 0 ||
        data is! Map ||
        data['cate1Info'] is! List ||
        data['cate2Info'] is! List) {
      throw StateError('斗鱼分类暂时不可用');
    }
    final children = data['cate2Info'] as List;
    return [
      const LiveCategory.hot(),
      for (final parent in data['cate1Info'] as List)
        if (parent is Map)
          LiveCategory(
            name: '${parent['cate1Name'] ?? ''}',
            parentId: '${parent['cate1Id']}',
            children: [
              for (final child in children)
                if (child is Map &&
                    '${child['cate1Id']}' == '${parent['cate1Id']}')
                  LiveCategory(
                    name: '${child['cate2Name'] ?? ''}',
                    parentId: '${parent['cate1Id']}',
                    areaId: '${child['cate2Id']}',
                    picture: liveImage(
                      child['icon'] ?? child['smallIcon'] ?? child['pic'],
                    ),
                  ),
            ],
          ),
    ];
  }

  @override
  Future<List<LiveRoom>> rooms(LiveCategory category, {int page = 1}) async {
    final json = await LiveHttp.json(
      category.hot
          ? '$origin/japi/weblist/apinc/allpage/6/$page'
          : '$origin/gapi/rkc/directory/mixList/2_${category.areaId}/$page',
      headers: headers,
    );
    final data = json['data'];
    if (data is! Map || data['rl'] is! List) throw StateError('斗鱼直播列表暂时不可用');
    return parseRooms(data['rl'] as List);
  }

  static List<LiveRoom> parseRooms(List rows) => [
    for (final item in rows)
      if (item is Map &&
          liveInt(item['rid']) > 0 &&
          liveInt(item['type'] ?? 1) == 1)
        LiveRoom(
          roomId: '${item['rid']}',
          title: '${item['rn'] ?? ''}',
          anchor: '${item['nn'] ?? ''}',
          cover: liveImage(item['rs16'] ?? item['rs1']),
          area: '${item['c2name'] ?? ''}',
          online: livePopularity(item['ol']),
        ),
  ];

  @override
  Future<List<LiveRoom>> search(String keyword, {int page = 1}) async {
    final json = await LiveHttp.json(
      '$origin/japi/search/api/searchShow',
      query: {'kw': keyword.trim(), 'page': '$page', 'pageSize': '30'},
      headers: headers,
    );
    if (json['error'] != 0) throw StateError('斗鱼搜索暂时不可用，请稍后重试');
    final data = json['data'];
    final rows = data is Map ? data['relateShow'] : null;
    return [
      for (final item in rows is List ? rows : const [])
        if (item is Map &&
            liveInt(item['rid']) > 0 &&
            liveInt(item['isLive']) == 1 &&
            liveInt(item['roomType']) == 0)
          LiveRoom(
            roomId: '${item['rid']}',
            title: '${item['roomName'] ?? ''}',
            anchor: '${item['nickName'] ?? ''}',
            cover: liveImage(item['roomSrc']),
            area: '${item['cateName'] ?? ''}',
            online: livePopularity(item['hot']),
          ),
    ];
  }

  /// 签名只使用平台下发的描述符，不嵌入账号 Cookie 或第三方解析服务。
  static Map<String, String> sign(
    Map<String, dynamic> key,
    String roomId, {
    required int seconds,
    required String device,
    int rate = -1,
  }) {
    final times = liveInt(key['enc_time']);
    if (times < 1 ||
        times > 16 ||
        liveInt(key['expire_at']) <= seconds ||
        [
          'key',
          'rand_str',
          'enc_data',
        ].any((field) => '${key[field] ?? ''}'.isEmpty)) {
      throw StateError('斗鱼签名已过期或数据不完整');
    }
    var secret = '${key['rand_str']}';
    for (var i = 0; i < times; i++) {
      secret = md5.convert(utf8.encode('$secret${key['key']}')).toString();
    }
    final salt = liveInt(key['is_special']) == 1 ? '' : '$roomId$seconds';
    return {
      'enc_data': '${key['enc_data']}',
      'tt': '$seconds',
      'did': device,
      'auth': md5.convert(utf8.encode('$secret${key['key']}$salt')).toString(),
      'cdn': '',
      'rate': '$rate',
      'hevc': '0',
      'fa': '0',
      'ive': '0',
      'ver': 'Douyu_new',
      'iar': '0',
    };
  }

  Future<Map<String, dynamic>> _play(String roomId, int rate) async {
    final descriptor = await LiveHttp.json(
      '$origin/wgapi/livenc/liveweb/websec/getEncryption',
      query: {'did': _device},
      headers: headers,
    );
    if (descriptor['data'] is! Map) throw StateError('斗鱼取流签名暂时不可用');
    final form = sign(
      Map<String, dynamic>.from(descriptor['data'] as Map),
      roomId,
      seconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      device: _device,
      rate: rate,
    );
    final response = await LiveHttp.json(
      '$origin/lapi/live/getH5PlayV1/$roomId',
      headers: {...headers, 'Referer': '$origin/$roomId'},
      form: form,
    );
    if (response['error'] != 0 || response['data'] is! Map) {
      throw StateError('斗鱼直播未开播、线路受限或取流失败（${response['error']}）');
    }
    return Map<String, dynamic>.from(response['data'] as Map);
  }

  static List<({int rate, LiveQuality quality})> rates(
    Map<String, dynamic> data,
  ) {
    final rows = data['multirates'];
    final result = <({int rate, LiveQuality quality})>[];
    final ids = <int>{};
    for (final raw in rows is List ? rows : const []) {
      if (raw is! Map) continue;
      final rate = int.tryParse('${raw['rate']}');
      final label = '${raw['name'] ?? ''}';
      if (rate == null || rate < 0 || label.isEmpty) continue;
      final code = liveQualityCode(label, source: rate == 0);
      if (ids.add(code))
        result.add((rate: rate, quality: LiveQuality(id: code, label: label)));
    }
    return result;
  }

  @override
  Future<LiveStream> resolve(LiveRoom room, {int quality = 0}) async {
    var data = await _play(room.roomId, -1);
    var options = rates(data);
    final selected = options
        .where((entry) => entry.quality.id == quality)
        .firstOrNull;
    final best = selected ?? options.firstOrNull;
    if (best != null && liveInt(data['rate']) != best.rate) {
      data = await _play(room.roomId, best.rate);
    }
    if (options.isEmpty) options = rates(data);
    final actualRate = int.tryParse('${data['rate']}');
    final applied = options
        .where((entry) => entry.rate == actualRate)
        .firstOrNull;
    final base = '${data['rtmp_url'] ?? ''}'.replaceAll(RegExp(r'/$'), '');
    final live = '${data['rtmp_live'] ?? ''}';
    final url = live.startsWith('https://') || live.startsWith('http://')
        ? live
        : '$base/$live';
    final uri = Uri.tryParse(url);
    if (live.isEmpty ||
        uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        !uri.hasAuthority) {
      throw StateError('斗鱼没有返回可播放线路');
    }
    return LiveStream(
      url: url,
      quality: applied?.quality.label ?? '平台默认',
      qualityId: applied?.quality.id ?? 0,
      qualities: options.map((entry) => entry.quality).toList(),
      headers: liveHeaders(origin),
      renewAfter: const Duration(minutes: 4),
    );
  }
}

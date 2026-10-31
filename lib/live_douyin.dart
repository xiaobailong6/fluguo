import 'dart:convert';

import 'live_douyin_http.dart';
import 'live_http.dart';
import 'live_models.dart';

/// 抖音 Web 匿名目录与直播流；不依赖账号、弹幕或 Pure Live 的 UI 栈。
class DouyinLive extends LivePlatform {
  const DouyinLive({this.client});
  final DouyinClient? client;
  static final _defaultClient = DouyinClient();
  DouyinClient get _http => client ?? _defaultClient;
  @override
  String get id => 'douyin';
  @override
  String get name => '抖音';
  @override
  int get pageSize => 15;

  @override
  Future<List<LiveCategory>> categories() async =>
      parseCategories(await _http.home());

  /// Next.js Flight 的 JSON 字符串先完整解码，再读取分类数组，避免用正则截断嵌套对象。
  static Iterable<String> _pageTexts(String page) sync* {
    yield page;
    for (final match in RegExp(
      r'self\.__(?:next|pace)_f\.push\((.*?)\);?\s*</script>',
      dotAll: true,
    ).allMatches(page)) {
      try {
        final decoded = jsonDecode(match.group(1)!);
        if (decoded is List && decoded.length > 1 && decoded[1] is String) {
          yield decoded[1] as String;
        }
      } catch (_) {
        /* 忽略非数据脚本，不执行网页 JavaScript。 */
      }
    }
    for (final match in RegExp(
      r'<script[^>]*id=["\x27]RENDER_DATA["\x27][^>]*>(.*?)</script>',
      dotAll: true,
    ).allMatches(page)) {
      try {
        yield Uri.decodeComponent(match.group(1)!);
      } catch (_) {}
    }
  }

  static dynamic _after(String text, String key) {
    final marker = RegExp('"${RegExp.escape(key)}"\\s*:').firstMatch(text);
    if (marker == null) return null;
    var start = marker.end;
    while (start < text.length && text[start].trim().isEmpty) {
      start++;
    }
    if (start >= text.length || !'{['.contains(text[start])) return null;
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final c = text[i];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          quoted = false;
        }
      } else if (c == '"') {
        quoted = true;
      } else if (c == '{' || c == '[') {
        depth++;
      } else if ((c == '}' || c == ']') && --depth == 0) {
        try {
          return jsonDecode(text.substring(start, i + 1));
        } catch (_) {
          return null;
        }
      }
    }
    return null;
  }

  static List<LiveCategory> parseCategories(String page) {
    dynamic rows;
    for (final text in _pageTexts(page)) {
      rows = _after(text, 'categoryData');
      if (rows is List) break;
    }
    if (rows is! List) {
      throw StateError('抖音分类暂不可用，页面可能需要验证或结构已变更');
    }
    final result = <LiveCategory>[];
    final seen = <String>{};
    String identity(Map item) {
      final key = '${item['id_str'] ?? item['id'] ?? ''},${item['type'] ?? ''}';
      return RegExp(r'^\d+,\d+$').hasMatch(key) ? key : '';
    }

    for (final row in rows.whereType<Map>()) {
      final partition = _map(row['partition']);
      final parent = identity(partition);
      final title = _text(partition['title']);
      if (parent.isEmpty || title.isEmpty || !seen.add(parent)) continue;
      final children = <LiveCategory>[
        LiveCategory(name: '全部$title', parentId: parent, areaId: parent),
      ];
      final childIds = <String>{parent};
      for (final child
          in (row['sub_partition'] is List
                  ? row['sub_partition'] as List
                  : const [])
              .whereType<Map>()) {
        final part = _map(child['partition']);
        final area = identity(part);
        final name = _text(part['title']);
        if (area.isNotEmpty && name.isNotEmpty && childIds.add(area)) {
          children.add(
            LiveCategory(
              name: name,
              parentId: parent,
              areaId: area,
              picture: _image(part['cover'] ?? part['icon']),
            ),
          );
        }
      }
      result.add(
        LiveCategory(name: title, parentId: parent, children: children),
      );
    }
    if (result.isEmpty) throw StateError('抖音没有返回有效分类，请稍后重试');
    return [const LiveCategory.hot(), ...result];
  }

  @override
  Future<List<LiveRoom>> rooms(LiveCategory category, {int page = 1}) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    if (category.hot) {
      return parseRooms(
        await _http.json('/webcast/feed/', {
          'need_map': '1',
          'is_draw': '1',
          'inner_from_drawer': '0',
          'enter_source': 'web_homepage_hot_web_live_card',
          'source_key': 'web_homepage_hot_web_live_card',
          'count': '$pageSize',
          'offset': '${(page - 1) * pageSize}',
        }),
      );
    }
    final key = category.areaId == '0' ? category.parentId : category.areaId;
    if (!RegExp(r'^\d+,\d+$').hasMatch(key)) throw StateError('抖音分区标识无效');
    final parts = key.split(',');
    return parseRooms(
      await _http.json('/webcast/web/partition/detail/room/v2/', {
        'partition': parts[0],
        'partition_type': parts[1],
        'count': '$pageSize',
        'offset': '${(page - 1) * pageSize}',
        'req_from': '2',
        'enter_from': 'link_share',
        'screen_width': '1920',
        'screen_height': '1080',
        'browser_online': 'true',
      }),
      area: category.name,
    );
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String && value.trimLeft().startsWith('{')) {
      try {
        return _map(jsonDecode(value));
      } catch (_) {}
    }
    return {};
  }

  static String _text(Object? value) =>
      value is String || value is num ? '$value'.trim() : '';
  static String _image(Object? value) {
    final map = _map(value);
    final list = map['url_list'];
    if (list is List) {
      for (final url in list) {
        if (_playable(_text(url))) return liveImage(url);
      }
    }
    final direct = _text(value);
    return _playable(direct) ? liveImage(direct) : '';
  }

  static bool _playable(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.host.isNotEmpty &&
        const {'http', 'https'}.contains(uri.scheme);
  }

  static void _checkStatus(Map<String, dynamic> json) {
    final status = int.tryParse('${json['status_code'] ?? ''}');
    if (status != null && status != 0) {
      throw StateError('抖音接口暂不可用（平台代码 $status），请稍后重试');
    }
  }

  static List<LiveRoom> parseRooms(
    Map<String, dynamic> json, {
    String area = '',
  }) {
    _checkStatus(json);
    dynamic rows = json['data'];
    if (rows is Map) rows = rows['data'];
    if (rows is! List) throw StateError('抖音房间列表格式已变更，请稍后重试');
    final result = <LiveRoom>[];
    final seen = <String>{};
    for (final raw in rows.whereType<Map>()) {
      final envelope = _map(raw);
      var room = _map(envelope['room']);
      if (room.isEmpty) room = _map(envelope['data']);
      if (room.isEmpty) room = envelope;
      final status = int.tryParse('${room['status'] ?? ''}');
      if (status != null && status != 0 && status != 2) continue;
      final owner = _map(room['owner']);
      final webId = [
        envelope['web_rid'],
        room['web_rid'],
        owner['web_rid'],
        room['id_str'],
        room['id'],
      ].map(_text).where((s) => RegExp(r'^\d{1,24}$').hasMatch(s)).firstOrNull;
      if (webId == null || !seen.add(webId)) continue;
      final popularity = _text(room['user_count_str']).isNotEmpty
          ? _text(room['user_count_str'])
          : livePopularity(room['user_count']);
      result.add(
        LiveRoom(
          roomId: webId,
          title: _text(room['title']),
          anchor: _text(owner['nickname']),
          cover: _image(room['cover']),
          area: _text(envelope['tag_name']).isNotEmpty
              ? _text(envelope['tag_name'])
              : area,
          online: popularity,
        ),
      );
    }
    return result;
  }

  @override
  Future<List<LiveRoom>> search(String keyword, {int page = 1}) async {
    final query = keyword.trim();
    if (query.isEmpty) return [];
    if (page < 1) throw ArgumentError.value(page, 'page');
    return parseSearch(
      await _http.json('/aweme/v1/web/live/search/', {
        'device_platform': 'webapp',
        'channel': 'channel_pc_web',
        'search_channel': 'aweme_live',
        'search_source': 'switch_tab',
        'query_correct_type': '1',
        'need_filter_settings': '1',
        'list_type': 'single',
        'keyword': query,
        'offset': '${(page - 1) * pageSize}',
        'count': '$pageSize',
        'os_version': '10',
      }, origin: 'https://www.douyin.com'),
    );
  }

  static List<LiveRoom> parseSearch(Map<String, dynamic> json) {
    _checkStatus(json);
    final rows = json['data'];
    if (rows is! List) throw StateError('抖音搜索暂不可用，平台可能需要验证');
    final normalized = <Map<String, dynamic>>[];
    for (final raw in rows.whereType<Map>()) {
      final item = _map(raw);
      var live = _map(item['lives']);
      if (live.isEmpty) live = _map(item['live_info']);
      var room = _map(live['rawdata'] ?? live['raw_data'] ?? item['rawdata']);
      if (room.isEmpty) room = live;
      if (room['room'] is Map) room = _map(room['room']);
      if (room.isNotEmpty) normalized.add({'room': room});
    }
    return parseRooms({'data': normalized});
  }

  @override
  Future<LiveStream> resolve(LiveRoom room, {int quality = 0}) async {
    if (!RegExp(r'^\d{1,24}$').hasMatch(room.roomId)) {
      throw StateError('抖音房间号无效');
    }
    Map<String, dynamic> detail;
    try {
      if (room.roomId.length > 16) {
        final json = await _http.json('/webcast/room/reflow/info/', {
          'type_id': '0',
          'room_id': room.roomId,
          'sec_user_id': '',
          'version_code': '99.99.99',
          'app_id': '6383',
        }, origin: 'https://webcast.amemv.com');
        detail = _map(_map(json['data'])['room']);
      } else {
        detail = roomDetail(
          await _http.json('/webcast/room/web/enter/', {
            'enter_from': 'web_live',
            'web_rid': room.roomId,
            'is_need_double_stream': 'false',
          }),
        );
      }
    } catch (_) {
      // 仅回退当前房间网页；不得复用列表中的旧签名或切到其他主播。
      detail = roomFromPage(await _http.page(room.roomId));
    }
    final status = int.tryParse('${detail['status'] ?? ''}');
    if (status != 2) throw StateError('抖音主播未开播或当前房间不可用');
    return parseStream(_map(detail['stream_url']), quality: quality);
  }

  static Map<String, dynamic> roomDetail(Map<String, dynamic> json) {
    _checkStatus(json);
    final data = _map(json['data']);
    final rooms = data['data'];
    if (rooms is! List || rooms.isEmpty || rooms.first is! Map) {
      throw StateError('抖音房间详情暂不可用');
    }
    return _map(rooms.first);
  }

  static Map<String, dynamic> roomFromPage(String page) {
    for (final text in _pageTexts(page)) {
      final store = _map(_after(text, 'roomStore'));
      final room = _map(_map(store['roomInfo'])['room']);
      if (room.isNotEmpty) return room;
    }
    throw StateError('抖音直播页面暂不可用，可能需要平台验证');
  }

  static LiveStream parseStream(
    Map<String, dynamic> stream, {
    int quality = 0,
  }) {
    final pull = _map(_map(stream['live_core_sdk_data'])['pull_data']);
    final modern = _map(_map(pull['stream_data'])['data']);
    final flv = _map(stream['flv_pull_url']);
    final hls = _map(stream['hls_pull_url_map']);
    final names = _map(stream['resolution_name']);
    final descriptors = <String, Map<String, dynamic>>{};
    final options = _map(pull['options'])['qualities'];
    if (options is List) {
      for (final item in options.whereType<Map>()) {
        final key = _text(item['sdk_key']).toLowerCase();
        if (key.isNotEmpty) descriptors[key] = _map(item);
      }
    }
    for (final key in {...modern.keys, ...flv.keys, ...hls.keys}) {
      descriptors.putIfAbsent(key.toLowerCase(), () => {'sdk_key': key});
    }
    Object? lookup(Map map, String key) => map.entries
        .where((e) => '${e.key}'.toLowerCase() == key)
        .firstOrNull
        ?.value;
    final variants =
        <({int rank, LiveQuality quality, List<LiveLine> lines})>[];
    final seenUrls = <String>{};
    for (final descriptor in descriptors.entries) {
      final key = descriptor.key;
      if (const {'ao', 'audio', 'audio_only', 'audioonly'}.contains(key)) {
        continue;
      }
      final main = _map(_map(lookup(modern, key))['main']);
      final urls = <String>{};
      for (final raw in [
        main['flv'],
        main['hls'],
        lookup(flv, key),
        lookup(hls, key),
      ]) {
        final url = _text(raw);
        if (_playable(url) &&
            !const {
              '1',
              'true',
            }.contains(Uri.parse(url).queryParameters['only_audio'])) {
          urls.add(url);
        }
      }
      urls.removeWhere(seenUrls.contains);
      if (urls.isEmpty) continue;
      seenUrls.addAll(urls);
      final rank = switch (key) {
        'origin' || 'origion' => 600,
        'uhd' || 'full_hd1' => 500,
        'hd' || 'hd1' => 400,
        'sd' || 'sd2' => 300,
        'ld' || 'sd1' => 200,
        'md' => 100,
        _ => liveInt(descriptor.value['level']),
      };
      final fallback = switch (rank) {
        600 => '原画',
        500 => '蓝光',
        400 => '超清',
        300 => '高清',
        200 || 100 => '流畅',
        _ => '平台画质',
      };
      final configured = _text(descriptor.value['name']);
      final label = configured.isNotEmpty
          ? configured
          : _text(lookup(names, key));
      final actualLabel = label.isEmpty ? fallback : label;
      final code = rank == 600
          ? 10000
          : liveQualityCode(actualLabel, source: false);
      if (variants.any((v) => v.quality.id == code)) continue;
      variants.add((
        rank: rank,
        quality: LiveQuality(id: code, label: actualLabel),
        lines: [
          for (final (i, url) in urls.indexed)
            LiveLine(
              id: '${key}_${Uri.parse(url).path.toLowerCase().contains('.m3u8') ? 'hls' : 'flv'}_$i',
              label:
                  '${Uri.parse(url).path.toLowerCase().contains('.m3u8') ? 'HLS' : 'FLV'} ${i + 1}',
              url: url,
            ),
        ],
      ));
    }
    variants.sort((a, b) => b.rank.compareTo(a.rank));
    if (variants.isEmpty) throw StateError('抖音没有返回可播放的视频线路');
    var selected = variants.where((v) => v.quality.id == quality).firstOrNull;
    selected ??= quality == 0
        ? variants.where((v) => v.quality.id != 10000).firstOrNull ??
              variants.first
        : variants.first;
    return LiveStream(
      url: selected.lines.first.url,
      quality: selected.quality.label,
      qualityId: selected.quality.id,
      qualities: [for (final v in variants) v.quality],
      headers: const {
        'User-Agent': douyinUserAgent,
        'Referer': '$douyinOrigin/',
      },
      lines: selected.lines,
      lineId: selected.lines.first.id,
      renewAfter: const Duration(minutes: 5),
    );
  }
}

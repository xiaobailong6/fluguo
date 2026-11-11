import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'live_http.dart';
import 'live_models.dart';

class HuyaLive extends LivePlatform {
  const HuyaLive();
  @override
  String get id => 'huya';
  @override
  String get name => '虎牙';
  static const origin = 'https://www.huya.com';
  static final _viewer = 1000000000 + Random.secure().nextInt(1000000000);
  static Map<String, String> get headers => liveHeaders(origin);

  @override
  Future<List<LiveCategory>> categories() async {
    const groups = {'1': '网游', '2': '单机', '8': '娱乐', '3': '手游'};
    final categories = await Future.wait(
      groups.entries.map((group) async {
        final json = await LiveHttp.json(
          'https://live.cdn.huya.com/liveconfig/game/bussLive',
          query: {'bussType': group.key},
          headers: headers,
        );
        return LiveCategory(
          name: group.value,
          parentId: group.key,
          children: parseAreas(json, group.key),
        );
      }),
    );
    return [const LiveCategory.hot(), ...categories];
  }

  static List<LiveCategory> parseAreas(
    Map<String, dynamic> json,
    String parentId,
  ) {
    if (json['data'] is! List) throw StateError('虎牙分区数据暂时不可用');
    final result = <LiveCategory>[];
    for (final raw in json['data'] as List) {
      if (raw is! Map) continue;
      final gid = raw['gid'];
      final id = gid is Map
          ? '${gid['value']}'.split(',').first
          : gid is num
          ? '${gid.toInt()}'
          : '${gid ?? ''}';
      if ((int.tryParse(id) ?? 0) <= 0) continue;
      result.add(
        LiveCategory(
          name: '${raw['gameFullName'] ?? ''}',
          parentId: parentId,
          areaId: id,
          picture: 'https://huyaimg.msstatic.com/cdnimage/game/$id-MS.jpg',
        ),
      );
    }
    return result;
  }

  @override
  Future<List<LiveRoom>> rooms(LiveCategory category, {int page = 1}) async {
    final json = await LiveHttp.json(
      '$origin/cache.php',
      query: {
        'm': 'LiveList',
        'do': 'getLiveListByPage',
        'tagAll': '0',
        'page': '$page',
        if (!category.hot) 'gameId': category.areaId,
      },
      headers: headers,
    );
    final data = json['data'];
    if (data is! Map || data['datas'] is! List) throw StateError('虎牙直播列表暂时不可用');
    return parseRooms(data['datas'] as List);
  }

  static List<LiveRoom> parseRooms(List rows) => [
    for (final item in rows)
      if (item is Map && '${item['profileRoom'] ?? ''}'.isNotEmpty)
        LiveRoom(
          roomId: '${item['profileRoom']}',
          title: '${item['introduction'] ?? item['roomName'] ?? ''}',
          anchor: '${item['nick'] ?? ''}',
          cover: liveImage(item['screenshot']),
          area: '${item['gameFullName'] ?? ''}',
          online: livePopularity(item['totalCount']),
        ),
  ];

  @override
  Future<List<LiveRoom>> search(String keyword, {int page = 1}) async {
    final json = await LiveHttp.json(
      'https://search.cdn.huya.com/',
      query: {
        'm': 'Search',
        'do': 'getSearchContent',
        'q': keyword.trim(),
        'uid': '0',
        'v': '4',
        'typ': '-5',
        'livestate': '0',
        'rows': '30',
        'start': '${(page - 1) * 30}',
      },
      headers: headers,
    );
    final response = json['response'];
    final bucket = response is Map ? response['3'] : null;
    final docs = bucket is Map ? bucket['docs'] : null;
    if (docs != null && docs is! List) throw StateError('虎牙搜索返回格式异常');
    return [
      for (final item in docs is List ? docs : const [])
        if (item is Map && '${item['room_id'] ?? ''}'.isNotEmpty)
          LiveRoom(
            roomId: '${item['room_id']}',
            title:
                '${item['game_introduction'] ?? item['game_roomName'] ?? ''}',
            anchor: '${item['game_nick'] ?? ''}',
            cover: liveImage(item['game_screenshot']),
            area: '${item['gameName'] ?? ''}',
            online: livePopularity(item['game_total_count']),
          ),
    ];
  }

  /// 按平台 fm 模板计算签名，严格保留 wsTime，不能把过期令牌延长后继续使用。
  static String signAntiCode(
    String stream,
    String antiCode, {
    required int viewer,
    required DateTime now,
  }) {
    final fields = Map<String, String>.from(
      Uri.splitQueryString(antiCode.replaceAll('&amp;', '&')),
    );
    final fm = fields['fm'];
    if (fm == null || fm.isEmpty) return antiCode;
    final expires = int.tryParse(fields['wsTime'] ?? '', radix: 16);
    if (expires == null || expires <= now.millisecondsSinceEpoch ~/ 1000) {
      throw StateError('虎牙线路已过期，请重新打开直播');
    }
    final ctype = fields['ctype'] ?? 'huya_webh5';
    final t = fields['t'] ?? '100';
    final seq = viewer + now.millisecondsSinceEpoch;
    final rotated =
        ((viewer & 0xffffffff) << 8 | (viewer & 0xffffffff) >> 24) & 0xffffffff;
    final hash = md5.convert(utf8.encode('$seq|$ctype|$t')).toString();
    final template = utf8.decode(base64.decode(base64.normalize(fm)));
    if (![r'$0', r'$1', r'$2', r'$3'].every(template.contains)) {
      throw StateError('虎牙线路签名模板无效');
    }
    final secret = template
        .replaceAll(r'$0', '${t == '103' ? viewer : rotated}')
        .replaceAll(r'$1', stream)
        .replaceAll(r'$2', hash)
        .replaceAll(r'$3', fields['wsTime']!);
    fields.remove('fm');
    fields.remove('uid');
    fields.remove('u');
    fields.remove('uuid');
    fields.addAll({
      'wsSecret': md5.convert(utf8.encode(secret)).toString(),
      'seqid': '$seq',
      'ctype': ctype,
      't': t,
      'ver': '1',
      'codec': '264',
    });
    fields[t == '103' ? 'uid' : 'u'] = '${t == '103' ? viewer : rotated}';
    if (t == '103') {
      fields['uuid'] = '${now.millisecondsSinceEpoch & 0xffffffff}';
    }
    return Uri(queryParameters: fields).query;
  }

  @override
  Future<LiveStream> resolve(LiveRoom room, {int quality = 0}) async {
    final page = await LiveHttp.text(
      '$origin/${Uri.encodeComponent(room.roomId)}',
      headers: headers,
    );
    final stream = livePageObject(page, r'\bstream\s*:');
    return parseStream(stream, quality: quality, viewer: _viewer);
  }

  static LiveStream parseStream(
    Map<String, dynamic> stream, {
    int quality = 0,
    int viewer = 1,
    DateTime? at,
  }) {
    final data = stream['data'];
    final detail = data is List && data.isNotEmpty ? data.first : null;
    final lines = detail is Map ? detail['gameStreamInfoList'] : null;
    if (lines is! List || lines.isEmpty) throw StateError('虎牙主播未开播或当前直播暂不可用');
    final options = <({int bitRate, LiveQuality quality})>[];
    final ids = <int>{};
    for (final rate in (stream['vMultiStreamInfo'] as List?) ?? const []) {
      if (rate is! Map || liveInt(rate['iCodecType']) != 0) continue;
      final label = '${rate['sDisplayName'] ?? ''}';
      if (label.contains('HDR') || label.isEmpty) continue;
      final bitRate = liveInt(rate['iBitRate']);
      final code = liveQualityCode(label, source: bitRate == 0);
      if (ids.add(code)) {
        options.add((
          bitRate: bitRate,
          quality: LiveQuality(id: code, label: label),
        ));
      }
    }
    if (options.isEmpty) {
      options.add((
        bitRate: 0,
        quality: const LiveQuality(id: 10000, label: '原画'),
      ));
    }
    final selected =
        options.where((entry) => entry.quality.id == quality).firstOrNull ??
        options.where((entry) => entry.bitRate == 0).firstOrNull ??
        options.first;
    final now = at ?? DateTime.now();
    final available = <LiveLine>[];
    var renewSeconds = 240;
    for (final raw in lines) {
      if (raw is! Map || '${raw['sFlvUrl'] ?? ''}'.isEmpty) continue;
      final name = '${raw['sStreamName'] ?? ''}';
      if (name.isEmpty) continue;
      try {
        final anti = signAntiCode(
          name,
          '${raw['sFlvAntiCode'] ?? ''}',
          viewer: viewer,
          now: now,
        );
        final fields = Uri.splitQueryString(anti)..remove('ratio');
        if (selected.bitRate > 0) fields['ratio'] = '${selected.bitRate}';
        fields['codec'] = '264';
        final base = liveImage(raw['sFlvUrl']).replaceAll(RegExp(r'/$'), '');
        final extension = '${raw['sFlvUrlSuffix'] ?? 'flv'}';
        final uri = Uri.parse(
          '$base/$name.$extension',
        ).replace(queryParameters: fields);
        if (uri.scheme != 'https' || !uri.hasAuthority) continue;
        final expires = int.tryParse(fields['wsTime'] ?? '', radix: 16);
        final seconds = expires == null
            ? 240
            : (expires - now.millisecondsSinceEpoch ~/ 1000 - 30).clamp(
                10,
                240,
              );
        renewSeconds = seconds < renewSeconds ? seconds : renewSeconds;
        final id = '${raw['sCdnType'] ?? uri.host}';
        if (!available.any((entry) => entry.id == id)) {
          available.add(
            LiveLine(
              id: id,
              label: '线路 ${available.length + 1} · $id',
              url: '$uri',
            ),
          );
        }
      } on FormatException {
        continue;
      } on StateError {
        continue;
      }
    }
    if (available.isEmpty) throw StateError('虎牙没有返回可播放线路');
    return LiveStream(
      url: available.first.url,
      quality: selected.quality.label,
      qualityId: selected.quality.id,
      qualities: options.map((entry) => entry.quality).toList(),
      headers: headers,
      lines: available,
      lineId: available.first.id,
      renewAfter: Duration(seconds: renewSeconds),
    );
  }
}

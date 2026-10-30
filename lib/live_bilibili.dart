import 'dart:convert';
import 'dart:io';

/// 直播平台适配。
///
/// 目前只接了哔哩哔哩，页面只认这个抽象：以后再接站源只加一个实现，
/// 分类条、房间网格和播放页都不用改。
abstract class LivePlatform {
  const LivePlatform();

  /// 稳定标识。
  String get id;

  /// 下拉里显示的名字。
  String get name;

  /// 一级分区（含首位的「热门」）。
  Future<List<LiveCategory>> categories();

  /// 某个分区里的直播间，从第 1 页开始。
  Future<List<LiveRoom>> rooms(LiveCategory category, {int page = 1});

  /// 取这个直播间当前可播的线路。
  Future<LiveStream> resolve(LiveRoom room, {int quality = 10000});
}

/// 可选的直播平台清单，左上角下拉直接读这里。
const livePlatforms = <LivePlatform>[BilibiliLive()];

class LiveCategory {
  const LiveCategory({
    required this.name,
    required this.parentId,
    this.areaId = '0',
    this.children = const [],
  });

  /// 「热门」没有分区 id，走 `parent_area_id=0`。
  const LiveCategory.hot()
    : name = '热门',
      parentId = '0',
      areaId = '0',
      children = const [];

  final String name;

  /// 一级分区 id：房间列表接口按它就能查出该区全部直播。
  final String parentId;

  /// 二级分区编号，0 只用于一级分区和热门入口。
  final String areaId;
  final List<LiveCategory> children;

  bool get hot => parentId == '0';

  @override
  bool operator ==(Object other) =>
      other is LiveCategory &&
      other.parentId == parentId &&
      other.areaId == areaId;

  @override
  int get hashCode => Object.hash(parentId, areaId);

  @override
  String toString() => 'LiveCategory($name, $parentId/$areaId)';
}

class LiveRoom {
  const LiveRoom({
    required this.roomId,
    required this.title,
    required this.anchor,
    required this.cover,
    required this.area,
    required this.online,
  });

  final String roomId;
  final String title;
  final String anchor;
  final String cover;

  /// 二级分区名，例如「英雄联盟」。
  final String area;

  /// 人气值，已经格式化成「1.2万」这种文本。
  final String online;
}

class LiveQuality {
  const LiveQuality({required this.id, required this.label});
  final int id;
  final String label;
}

class LiveStream {
  const LiveStream({
    required this.url,
    required this.quality,
    required this.headers,
    this.qualityId = 0,
    this.qualities = const [],
  });

  final String url;
  final String quality;
  final int qualityId;
  final List<LiveQuality> qualities;

  /// 播放器要带的请求头：哔哩哔哩的 CDN 校验 Referer，缺了会 403。
  final Map<String, String> headers;
}

/// 哔哩哔哩直播。
///
/// 三个接口，全部匿名可用，不需要签名和 Cookie（实测 2026-10）：
/// - 分区：`room/v1/Area/getList`
/// - 房间：`room/v1/Area/getRoomList`（`parent_area_id` 生效，`0` 是全站热门）
/// - 线路：`xlive/web-room/v2/index/getRoomPlayInfo`
///
/// pure_live 的房间列表走的是需要 WBI 签名的 `second/getList`，匿名调用
/// 会回 -352（风控），所以这里改用上面那个老的 `getRoomList`：同样按一级
/// 分区排序，还省掉了签名、access_id 抓页面和 buvid cookie 三套逻辑。
class BilibiliLive extends LivePlatform {
  const BilibiliLive();

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const _referer = 'https://live.bilibili.com/';

  /// 清晰度代码 → 文案。接口里的 g_qn_desc 不一定全，这里兜一层。
  static const _qualityLabels = <int, String>{
    30000: '杜比',
    20000: '4K',
    10000: '原画',
    401: '蓝光',
    400: '蓝光',
    250: '超清',
    150: '高清',
    80: '流畅',
  };

  static final _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12);

  @override
  String get id => 'bilibili';

  @override
  String get name => '哔哩哔哩';

  @override
  Future<List<LiveCategory>> categories() async {
    final json = await _json(
      'https://api.live.bilibili.com/room/v1/Area/getList',
      const {'need_entrance': '1', 'parent_id': '0'},
    );
    return [const LiveCategory.hot(), ...parseCategories(json)];
  }

  @override
  Future<List<LiveRoom>> rooms(LiveCategory category, {int page = 1}) async {
    final json = await _json(
      'https://api.live.bilibili.com/room/v1/Area/getRoomList',
      {
        'platform': 'web',
        'parent_area_id': category.parentId,
        // 0 = 整个一级分区；只要二级分区时才填具体 id。
        'area_id': category.areaId,
        'sort_type': 'online',
        'page': '$page',
        'page_size': '30',
      },
    );
    return parseRooms(json);
  }

  @override
  Future<LiveStream> resolve(LiveRoom room, {int quality = 10000}) async {
    final json = await _json(
      'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo',
      {
        'room_id': room.roomId,
        'protocol': '0,1',
        'format': '0,1,2',
        // codec 只留 avc：mpv 对 FLV 里的 HEVC 支持不稳，选了反而容易黑屏。
        'codec': '0',
        'qn': '$quality',
        'platform': 'web',
        'ptype': '8',
        'dolby': '5',
        'panorama': '1',
        'mask': '0',
        'no_playurl': '0',
      },
    );
    final stream = parsePlayStream(json, requestedQuality: quality);
    return LiveStream(
      url: stream.url,
      quality: stream.quality,
      qualityId: stream.qualityId,
      qualities: parseQualities(json),
      headers: const {
        'User-Agent': _userAgent,
        'Referer': _referer,
        'Origin': 'https://live.bilibili.com',
      },
    );
  }

  // ------------------------------------------------------- 解析（纯函数，便于单测）

  /// 解析 `room/v1/Area/getList` 的一级分区。
  static List<LiveCategory> parseCategories(Map<String, dynamic> json) {
    if (json['code'] != 0) {
      throw StateError('哔哩哔哩分区接口返回 ${json['code']}');
    }
    final data = json['data'];
    if (data is! List) throw StateError('哔哩哔哩分区数据为空');
    return [
      for (final raw in data)
        if (raw is Map && raw['name'] != null && '${raw['id'] ?? ''}' != '')
          LiveCategory(
            name: raw['name'].toString(),
            parentId: '${raw['id']}',
            children: [
              for (final child in (raw['list'] as List?) ?? const [])
                if (child is Map && '${child['id'] ?? ''}' != '')
                  LiveCategory(
                    name: '${child['name'] ?? ''}',
                    parentId: '${raw['id']}',
                    areaId: '${child['id']}',
                  ),
            ],
          ),
    ];
  }

  /// 解析 `getRoomList` 的房间数组。
  static List<LiveRoom> parseRooms(Map<String, dynamic> json) {
    if (json['code'] != 0) {
      throw StateError('哔哩哔哩房间列表返回 ${json['code']}');
    }
    final data = json['data'];
    if (data is! List) return const [];
    return [
      for (final item in data)
        if (item is Map && (int.tryParse('${item['roomid']}') ?? 0) > 0)
          LiveRoom(
            roomId: '${item['roomid']}',
            title: (item['title'] ?? '').toString(),
            anchor: (item['uname'] ?? '').toString(),
            cover: (item['cover'] ?? item['user_cover'] ?? '').toString(),
            area: (item['area_name'] ?? '').toString(),
            online: formatOnline(item['online']),
          ),
    ];
  }

  /// 人气值：超过 1 万换成「万」，省得卡片上一长串数字。
  static String formatOnline(Object? value) {
    final count = int.tryParse('$value') ?? 0;
    if (count <= 0) return '';
    if (count < 10000) return '$count';
    final wan = count / 10000;
    return '${wan.toStringAsFixed(wan >= 100 ? 0 : 1)}万';
  }

  /// 只展示实际 codec 声明支持的档位，不把描述表里所有会员档位都当成可选项。
  static List<LiveQuality> parseQualities(Map<String, dynamic> json) {
    final data = json['data'];
    final info = data is Map ? data['playurl_info'] : null;
    final play = info is Map ? info['playurl'] : null;
    if (play is! Map) return const [];
    final names = <int, String>{..._qualityLabels};
    for (final raw in (play['g_qn_desc'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final id = int.tryParse('${raw['qn']}');
      if (id != null && '${raw['desc'] ?? ''}'.trim().isNotEmpty) {
        names[id] = '${raw['desc']}';
      }
    }
    final ids = <int>{};
    for (final stream in (play['stream'] as List?) ?? const []) {
      if (stream is! Map) continue;
      for (final format in (stream['format'] as List?) ?? const []) {
        if (format is! Map) continue;
        for (final codec in (format['codec'] as List?) ?? const []) {
          if (codec is! Map) continue;
          for (final raw in [
            codec['current_qn'],
            ...(codec['accept_qn'] as List?) ?? const [],
          ]) {
            final id = int.tryParse('$raw');
            if (id != null && id > 0) ids.add(id);
          }
        }
      }
    }
    final ordered = ids.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final id in ordered) LiveQuality(id: id, label: names[id] ?? '$id'),
    ];
  }

  /// 从 `getRoomPlayInfo` 里挑一条线路。
  ///
  /// 清晰度最高的优先；同清晰度里 FLV（http_stream）优先，其次 HLS。
  /// mcdn 域经常缺签名，排在同清晰度的最后。
  static ({String url, String quality, int qualityId}) parsePlayStream(
    Map<String, dynamic> json, {
    int? requestedQuality,
  }) {
    if (json['code'] != 0) {
      throw StateError('哔哩哔哩播放地址返回 ${json['code']}');
    }
    final data = json['data'];
    final info = data is Map ? data['playurl_info'] : null;
    final playurl = info is Map ? info['playurl'] : null;
    final streams = playurl is Map ? playurl['stream'] : null;
    if (playurl is! Map || streams is! List) {
      throw StateError('这个直播间暂时没有可播放的线路');
    }
    final labels = <int, String>{};
    for (final raw in (playurl['g_qn_desc'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final qn = int.tryParse('${raw['qn']}');
      if (qn == null) continue;
      final desc = (raw['desc'] ?? '').toString().trim();
      if (desc.isNotEmpty) labels[qn] = desc;
    }

    final candidates = <_Candidate>[];
    for (final rawStream in streams) {
      if (rawStream is! Map) continue;
      final protocol = (rawStream['protocol_name'] ?? '').toString();
      for (final rawFormat in (rawStream['format'] as List?) ?? const []) {
        if (rawFormat is! Map) continue;
        final format = (rawFormat['format_name'] ?? '').toString();
        for (final rawCodec in (rawFormat['codec'] as List?) ?? const []) {
          if (rawCodec is! Map) continue;
          final base = (rawCodec['base_url'] ?? '').toString();
          if (base.isEmpty) continue;
          final qn = int.tryParse('${rawCodec['current_qn']}') ?? 0;
          for (final rawUrl in (rawCodec['url_info'] as List?) ?? const []) {
            if (rawUrl is! Map) continue;
            final url = '${rawUrl['host'] ?? ''}$base${rawUrl['extra'] ?? ''}';
            final uri = Uri.tryParse(url);
            if (uri == null ||
                !uri.hasAuthority ||
                (uri.scheme != 'https' && uri.scheme != 'http'))
              continue;
            candidates.add(
              _Candidate(
                url: url,
                qn: qn,
                protocol: protocol,
                format: format,
                mcdn: url.contains('mcdn'),
              ),
            );
          }
        }
      }
    }
    if (candidates.isEmpty) {
      throw StateError('这个直播间暂时没有可播放的线路');
    }
    candidates.sort((a, b) {
      if (requestedQuality != null) {
        final requested = (b.qn == requestedQuality ? 1 : 0).compareTo(
          a.qn == requestedQuality ? 1 : 0,
        );
        if (requested != 0) return requested;
      }
      if (a.qn != b.qn) return b.qn.compareTo(a.qn);
      final formatOrder = a.formatRank.compareTo(b.formatRank);
      if (formatOrder != 0) return formatOrder;
      if (a.mcdn != b.mcdn) return a.mcdn ? 1 : -1;
      return a.url.compareTo(b.url);
    });
    final best = candidates.first;
    return (
      url: best.url,
      quality: labels[best.qn] ?? _qualityLabels[best.qn] ?? '',
      qualityId: best.qn,
    );
  }

  // --------------------------------------------------------------- 请求

  static Future<Map<String, dynamic>> _json(
    String url,
    Map<String, String> query,
  ) async {
    final uri = Uri.parse(url).replace(queryParameters: query);
    final request = await _http.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    request.headers.set(HttpHeaders.refererHeader, _referer);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, text/plain, */*',
    );
    final response = await request.close().timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        request.abort();
        throw StateError('哔哩哔哩接口请求超时，请重试');
      },
    );
    final body = await response
        .timeout(const Duration(seconds: 20))
        .transform(utf8.decoder)
        .join();
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('哔哩哔哩接口 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('哔哩哔哩接口返回格式异常');
    }
    return decoded;
  }
}

class _Candidate {
  const _Candidate({
    required this.url,
    required this.qn,
    required this.protocol,
    required this.format,
    required this.mcdn,
  });

  final String url;
  final int qn;
  final String protocol;
  final String format;
  final bool mcdn;

  int get formatRank => switch (format) {
    'flv' => protocol == 'http_stream' ? 0 : 1,
    'ts' => 2,
    'fmp4' => 3,
    _ => 4,
  };
}

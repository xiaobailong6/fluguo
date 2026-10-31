/// 各直播平台共享的数据契约，不依赖页面或播放器。
abstract class LivePlatform {
  const LivePlatform();
  String get id;
  String get name;

  /// 分类列表每页大小；各平台可覆盖，避免短页被误判为已经到底。
  int get pageSize => 30;
  Future<List<LiveCategory>> categories();
  Future<List<LiveRoom>> rooms(LiveCategory category, {int page = 1});
  Future<List<LiveRoom>> search(String keyword, {int page = 1}) async {
    throw UnsupportedError('当前平台暂不支持直播搜索');
  }

  Future<LiveStream> resolve(LiveRoom room, {int quality = 0});

  /// 线路标识由平台声明；不支持多线路的平台保持原解析行为。
  Future<LiveStream> resolveLine(
    LiveRoom room, {
    int quality = 0,
    String line = '',
  }) async => (await resolve(room, quality: quality)).selectLine(line);
}

class LiveCategory {
  const LiveCategory({
    required this.name,
    required this.parentId,
    this.areaId = '0',
    this.children = const [],
    this.picture = '',
  });
  const LiveCategory.hot()
    : name = '热门',
      parentId = '0',
      areaId = '0',
      children = const [],
      picture = '';
  final String name;
  final String parentId;
  final String areaId;
  final List<LiveCategory> children;
  final String picture;
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
  final String area;
  final String online;

  Map<String, dynamic> toJson() => {
    'roomId': roomId,
    'title': title,
    'anchor': anchor,
    'cover': cover,
    'area': area,
    'online': online,
  };
  factory LiveRoom.fromJson(Map<String, dynamic> json) {
    for (final key in [
      'roomId',
      'title',
      'anchor',
      'cover',
      'area',
      'online',
    ]) {
      if (json[key] is! String || (json[key] as String).length > 2048) {
        throw const FormatException('直播收藏数据无效');
      }
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(json['roomId'] as String)) {
      throw const FormatException('直播房间号无效');
    }
    return LiveRoom(
      roomId: json['roomId'] as String,
      title: json['title'] as String,
      anchor: json['anchor'] as String,
      cover: json['cover'] as String,
      area: json['area'] as String,
      online: json['online'] as String,
    );
  }
}

class LiveQuality {
  const LiveQuality({required this.id, required this.label});
  final int id;
  final String label;
}

class LiveLine {
  const LiveLine({required this.id, required this.label, this.url = ''});
  final String id;
  final String label;
  final String url;
}

class LiveStream {
  const LiveStream({
    required this.url,
    required this.quality,
    required this.headers,
    this.qualityId = 0,
    this.qualities = const [],
    this.renewAfter,
    this.lines = const [],
    this.lineId = '',
  });
  final String url;
  final String quality;
  final int qualityId;
  final List<LiveQuality> qualities;
  final Map<String, String> headers;
  final List<LiveLine> lines;
  final String lineId;

  LiveStream selectLine(String requested) {
    final selected = lines
        .where((entry) => entry.id == requested && entry.url.isNotEmpty)
        .firstOrNull;
    if (selected == null) return this;
    return LiveStream(
      url: selected.url,
      quality: quality,
      headers: headers,
      qualityId: qualityId,
      qualities: qualities,
      renewAfter: renewAfter,
      lines: lines,
      lineId: selected.id,
    );
  }

  /// 短有效期平台在过期前重新解析，不 seek 或修改服务端过期时间。
  final Duration? renewAfter;
}

/// 不同平台用同一组语义画质选项；平台的实际码率/rate 由适配器映射。
int liveQualityCode(String label, {required bool source}) {
  if (source || label.contains('原画') || label.contains('原始')) return 10000;
  if (label.contains('蓝光') || label.contains('4K')) return 400;
  if (label.contains('超清')) return 250;
  if (label.contains('高清')) return 150;
  if (label.contains('流畅') || label.contains('标清')) return 80;
  return 250;
}

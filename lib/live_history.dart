import 'live_favorites.dart';
import 'live_models.dart';

/// 房间身份与展示快照，不持久化解析结果、请求头或登录凭据。
class LiveHistoryEntry {
  const LiveHistoryEntry({
    required this.platformId,
    required this.room,
    required this.updatedAt,
  });
  static const limit = 300;
  final String platformId;
  final LiveRoom room;
  final DateTime updatedAt;
  String get key => '$platformId:${room.roomId}';

  Map<String, dynamic> toJson() => {
    'platform': platformId,
    'room': room.toJson(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory LiveHistoryEntry.fromJson(Map<String, dynamic> json) {
    final identity = LiveFavorite.fromJson(json);
    if (json.keys.any(
          (key) => !{'platform', 'room', 'updatedAt'}.contains(key),
        ) ||
        (json['room'] is Map &&
            (json['room'] as Map).keys.any(
              (key) => !{
                'roomId',
                'title',
                'anchor',
                'cover',
                'area',
                'online',
              }.contains(key),
            ))) {
      throw const FormatException('直播历史包含非展示字段');
    }
    final time = json['updatedAt'];
    if (time is! String || DateTime.tryParse(time) == null) {
      throw const FormatException('直播观看时间无效');
    }
    return LiveHistoryEntry(
      platformId: identity.platformId,
      room: identity.room,
      updatedAt: DateTime.parse(time),
    );
  }

  static void validateList(Object? value) {
    if (value == null) return; // 旧备份没有此类别。
    if (value is! List || value.length > limit) {
      throw const FormatException('直播历史数量无效');
    }
    final keys = <String>{};
    for (final row in value) {
      if (row is! Map) throw const FormatException('直播历史数据无效');
      final entry = LiveHistoryEntry.fromJson(Map<String, dynamic>.from(row));
      if (!keys.add(entry.key)) throw const FormatException('直播历史存在重复房间');
    }
  }
}

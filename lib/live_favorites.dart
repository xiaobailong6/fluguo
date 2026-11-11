import 'live_models.dart';

/// 只持久化主播展示信息和房间身份；临时 URL、签名、Cookie 不进入收藏。
class LiveFavorite {
  const LiveFavorite({required this.platformId, required this.room});
  final String platformId;
  final LiveRoom room;
  String get key => '$platformId:${room.roomId}';
  Map<String, dynamic> toJson() => {
    'platform': platformId,
    'room': room.toJson(),
  };

  factory LiveFavorite.fromJson(Map<String, dynamic> json) {
    final platform = json['platform'];
    if (platform is! String ||
        !RegExp(r'^[a-z][a-z0-9_]{0,31}$').hasMatch(platform) ||
        json['room'] is! Map) {
      throw const FormatException('直播收藏身份无效');
    }
    return LiveFavorite(
      platformId: platform,
      room: LiveRoom.fromJson(Map<String, dynamic>.from(json['room'] as Map)),
    );
  }

  static void validateList(Object? value) {
    if (value == null) return; // 旧备份没有直播收藏。
    if (value is! List || value.length > 1000) {
      throw const FormatException('直播收藏数量无效');
    }
    final keys = <String>{};
    for (final row in value) {
      if (row is! Map) throw const FormatException('直播收藏数据无效');
      final favorite = LiveFavorite.fromJson(Map<String, dynamic>.from(row));
      if (!keys.add(favorite.key)) throw const FormatException('直播收藏存在重复房间');
    }
  }
}

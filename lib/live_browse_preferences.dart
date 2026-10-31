/// 用户级直播浏览偏好，仅保留平台与一级分类的稳定标识。
class LiveBrowsePreferences {
  const LiveBrowsePreferences({
    this.platformId = '',
    this.categoryIds = const {},
  });

  final String platformId;
  final Map<String, String> categoryIds;

  factory LiveBrowsePreferences.fromJson(Map<String, dynamic> json) {
    final platform = json['platformId'];
    final categories = json['categoryIds'];
    if ((platform != null && platform is! String) ||
        (categories != null && categories is! Map)) {
      throw const FormatException('直播浏览偏好无效');
    }
    final ids = <String, String>{};
    if (categories is Map) {
      for (final entry in categories.entries) {
        if (entry.key is! String || entry.value is! String) {
          throw const FormatException('直播分类标识无效');
        }
        ids[entry.key as String] = entry.value as String;
      }
    }
    return LiveBrowsePreferences(
      platformId: platform as String? ?? '',
      categoryIds: Map.unmodifiable(ids),
    );
  }

  Map<String, dynamic> toJson() => {
    'platformId': platformId,
    'categoryIds': categoryIds,
  };
}

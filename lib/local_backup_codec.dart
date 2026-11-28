import 'dart:convert';

import 'download_preferences.dart';
import 'follow_state.dart';
import 'live_favorites.dart';
import 'live_history.dart';
import 'local_profiles.dart';
import 'models.dart';
import 'navigation_order.dart';
import 'playback_preferences.dart';
import 'theme_color.dart';

/// 备份的数据契约，不持有存储、用户状态或写队列。权限、刷盘与恢复身份
/// 仍由 LocalStore 管理，避免校验或组装字段时触发任何写入。
abstract final class LocalBackupCodec {
  static Map<String, dynamic> validate(
    String content, {
    required List<LocalProfile> Function(dynamic records) readProfiles,
  }) {
    if (utf8.encode(content).length > 8 * 1024 * 1024) {
      throw const FormatException('备份文件过大');
    }
    final data = jsonDecode(content) as Map<String, dynamic>;
    if (data['schema'] != 1 || data['app'] != 'zhenguojian') {
      throw const FormatException('不支持的备份格式');
    }
    final profiles = readProfiles(data['profiles']);
    if (data.containsKey('themeMode') &&
        !{'light', 'dark', 'system'}.contains(data['themeMode'])) {
      throw const FormatException('备份主题设置无效');
    }
    if (data.containsKey('followSystemColor') &&
            data['followSystemColor'] is! bool ||
        data.containsKey('themeColor') &&
            ThemeColor.byName(data['themeColor']) == null) {
      throw const FormatException('备份主题色设置无效');
    }
    if (data.containsKey('glassEffects') && data['glassEffects'] is! bool) {
      throw const FormatException('备份外观设置无效');
    }
    if (data.containsKey('forceLogin') && data['forceLogin'] is! bool) {
      throw const FormatException('备份登录设置无效');
    }
    if (data.containsKey('exploreBanner') && data['exploreBanner'] is! bool) {
      throw const FormatException('备份横幅设置无效');
    }
    final libraries = data['libraries'] as Map;
    for (final profile in profiles) {
      final library = libraries[profile.id] as Map;
      final history = library['history'] as List,
          favorites = library['favorites'] as List;
      LiveFavorite.validateList(library['liveFavorites']);
      LiveHistoryEntry.validateList(library['liveHistory']);
      final media = library['mediaHistory'] as Map? ?? {};
      if (media.length > 300 ||
          history.length > 300 ||
          favorites.length > 20000) {
        throw const FormatException('备份记录过多');
      }
      for (final row in [...history, ...media.values]) {
        WatchEntry.fromJson(Map<String, dynamic>.from(row as Map));
      }
      for (final row in favorites) {
        Drama.fromJson(Map<String, dynamic>.from(row as Map));
      }
      final states = library['followStates'] as Map? ?? {};
      final seriesCandidates = library['seriesCandidates'] as List? ?? [];
      final favoriteIds = favorites.map((row) => (row as Map)['id']).toSet();
      if (states.length > 20000 ||
          states.keys.any((id) => id is! String || !favoriteIds.contains(id))) {
        throw const FormatException('备份追剧状态无效');
      }
      for (final row in states.values) {
        FollowState.fromJson(Map<String, dynamic>.from(row as Map));
      }
      if (seriesCandidates.length > 2000) {
        throw const FormatException('备份系列候选过多');
      }
      for (final row in seriesCandidates) {
        Drama.fromJson(Map<String, dynamic>.from(row as Map));
      }
      if (library['hideVip'] is! bool || library['source'] is! String) {
        throw const FormatException('备份设置无效');
      }
      PlaybackPreferences.fromJson(
        Map<String, dynamic>.from(library['playback'] as Map? ?? {}),
      );
      DownloadPreferences.fromJson(
        Map<String, dynamic>.from(library['downloadPreferences'] as Map? ?? {}),
      );
      final searches = library['recentSearches'] as List? ?? [];
      if (searches.length > 20 ||
          searches.any(
            (value) => value is! String || value.runes.length > 80,
          )) {
        throw const FormatException('备份搜索记录无效');
      }
    }
    return data;
  }

  /// 只组装原快照字段；外观独立键、旧系列候选迁移仍在原提交之后处理。
  static Map<String, Object> snapshotValues(
    Map<String, dynamic> data, {
    required List<LocalProfile> profiles,
    required String fallbackThemeMode,
    required bool fileBacked,
    required String Function(String category, String profileId) keyFor,
  }) {
    final values = <String, Object>{
      'profiles': jsonEncode(
        profiles.map((profile) => profile.toJson()).toList(),
      ),
      'activeProfile': profiles.firstWhere((profile) => profile.admin).id,
      'displayMode':
          {
            'auto',
            'television',
            'phone',
            'pad',
            'window',
          }.contains(data['displayMode'])
          ? data['displayMode'] as String
          : 'auto',
      'themeMode': data['themeMode'] as String? ?? fallbackThemeMode,
      'navigationOrder': jsonEncode(
        normalizeNavigationOrder(
          data['navigationOrder'] is List
              ? data['navigationOrder'] as List
              : const [],
        ),
      ),
      'navigationVisible': jsonEncode(
        normalizeNavigationVisible(
          data['navigationVisible'] is List
              ? data['navigationVisible'] as List
              : const [],
        ),
      ),
      'autoExport': data['autoExport'] == true,
      'exploreBanner': data['exploreBanner'] as bool? ?? true,
      'exportPosters': data['exportPosters'] == true,
      'forceLogin': data['forceLogin'] is bool
          ? data['forceLogin'] as bool
          : profiles.firstWhere((profile) => profile.admin).protected,
    };
    final libraries = data['libraries'] as Map;
    for (final profile in profiles) {
      final library = libraries[profile.id] as Map;
      values.addAll({
        keyFor('history', profile.id): library['history'] as List,
        keyFor('favorites', profile.id): library['favorites'] as List,
        keyFor('liveFavorites', profile.id):
            library['liveFavorites'] as List? ?? [],
        keyFor('liveHistory', profile.id):
            library['liveHistory'] as List? ?? [],
        keyFor('followStates', profile.id):
            library['followStates'] as Map? ?? {},
        keyFor('mediaHistory', profile.id):
            library['mediaHistory'] as Map? ?? {},
        keyFor('source', profile.id): library['source'] as String,
        keyFor('hideVip', profile.id): library['hideVip'] as bool,
        keyFor('playback', profile.id): jsonEncode(library['playback'] ?? {}),
        keyFor('downloadPreferences', profile.id): jsonEncode(
          library['downloadPreferences'] ?? {},
        ),
        if (fileBacked)
          keyFor('seriesCandidates', profile.id):
              library['seriesCandidates'] as List? ?? [],
        keyFor('recentSearches', profile.id): jsonEncode(
          library['recentSearches'] ?? [],
        ),
      });
    }
    return values;
  }
}

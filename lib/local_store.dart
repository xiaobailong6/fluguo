import 'dart:convert';
import 'dart:io';
import 'local_file_store.dart';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_profiles.dart';
import 'local_snapshot.dart';
import 'models.dart';
import 'playback_preferences.dart';
import 'live_browse_preferences.dart';
import 'download_preferences.dart';
import 'catalog_sort.dart';
import 'follow_state.dart';
import 'hongguo_series.dart';
import 'theme_color.dart';
import 'live_favorites.dart';
import 'live_models.dart';
import 'live_history.dart';
import 'navigation_order.dart';
import 'history_retention.dart';

class LocalStore extends ChangeNotifier {
  LocalStore(
    this.preferences, {
    this.fileStore,
    bool migrateAuxiliary = true,
    Future<String> Function(String, String)? pinHasher,
    DateTime Function()? clock,
  }) : _migrateAuxiliary = migrateAuxiliary,
       _pinHasher = pinHasher ?? hashProfilePin,
       _clock = clock ?? DateTime.now {
    _initialize();
  }

  final SharedPreferences preferences;
  final LocalFileStore? fileStore;
  final bool _migrateAuxiliary;
  final DateTime Function() _clock;
  DateTime? _historyCleanupDay;

  /// 只有分文件存储完整落盘后才清理旧快照；原权限与备份格式保持不变。
  static Future<LocalStore> open(
    SharedPreferences preferences,
    Directory directory,
  ) async {
    final files = LocalFileStore(
      directory,
      validateProfiles: (value) {
        _readProfiles(value);
      },
    );
    try {
      await files.load();
    } catch (error) {
      files.loadError = error;
    }
    if (!files.initialized && files.loadError == null) {
      final legacy = LocalStore(preferences, migrateAuxiliary: false);
      await legacy._writes;
      if (legacy.configurationError != null) return legacy;
      try {
        final values = legacy._snapshot!.values;
        for (final profile in legacy._profiles) {
          for (final category in ['seriesCandidates', 'followChecks']) {
            final old = preferences.getString('$category.${profile.id}');
            if (old != null) values[legacy._key(category, profile.id)] = old;
          }
        }
        values['profiles'] = jsonEncode(
          legacy._profiles.map((profile) => profile.toJson()).toList(),
        );
        values['activeProfile'] = legacy._current;
        if (preferences.getBool('autoExport') case final value?)
          values['autoExport'] = value;
        await files.commit(
          files.prepareMigration(LocalSnapshot.cleanValues(values)),
        );
      } finally {
        legacy.dispose();
      }
    }
    final store = LocalStore(preferences, fileStore: files);
    if (store.configurationError == null) {
      // 迁移后重启也会重试清理；无关键（窗口、诊断等）不删除。
      for (final key in preferences.getKeys().toList()) {
        if (LocalSnapshot.owns(key) ||
            key == LocalSnapshot.storageKey ||
            RegExp(
              r'^(seriesCandidates|followChecks)\.[a-zA-Z0-9_-]{1,64}$',
            ).hasMatch(key)) {
          try {
            await preferences.remove(key);
          } catch (_) {
            /* 下次启动重试清理，不影响已迁移数据。 */
          }
        }
      }
    }
    return store;
  }

  final Future<String> Function(String pin, String salt) _pinHasher;
  LocalSnapshot? _snapshot;
  final Map<String, WatchEntry> _history = {};
  final Map<String, Drama> _favorites = {};
  final Map<String, FollowState> _followStates = {};
  final Map<String, Drama> _seriesCandidates = {};
  Future<void> _writes = Future<void>.value();
  List<LocalProfile> _profiles = [];
  String _current = 'default';
  bool _locked = false;
  bool _disposed = false;
  String? _configurationError;
  int _epoch = 0;
  int _failures = 0;
  Map<String, bool> _sourceSwitches = {};
  DateTime _retryAfter = DateTime(2000);

  /// 静默保存的延迟落盘：播放中每 5 秒一次的进度只改内存，
  /// 攒够 [_watchFlushDelay] 才合并写一次，不再反复重排、重编码整份历史。
  /// 不用定时器：写盘时机由下一次保存判断，避免悬挂任务与切换用户后的残留。
  static const _watchFlushDelay = Duration(seconds: 15);
  bool _watchPending = false;
  bool _watchFollowPending = false;
  DateTime _watchSavedAt = DateTime(2000);

  /// 内存历史的修订号：排序快照据此判断是否需要重新读取，
  /// 让「只改了内存、还没落盘」的进度也能立刻出现在列表里。
  int _libraryRevision = 0;

  void _initialize() {
    try {
      _snapshot = LocalSnapshot(preferences, files: fileStore);
      final raw = _snapshot!.getString('profiles');
      if (raw == null &&
          (_snapshot!.getString('activeProfile') != null ||
              _snapshot!.values.keys.any(
                (key) => key.startsWith('profile.'),
              ))) {
        throw const FormatException('已有用户配置缺失');
      }
      _profiles = raw == null
          ? [const LocalProfile(id: 'default', name: '管理员', admin: true)]
          : _readProfiles(jsonDecode(raw));
      _current = _snapshot!.getString('activeProfile') ?? 'default';
      if (!_profiles.any((profile) => profile.id == _current)) {
        _current = _profiles.firstWhere((profile) => profile.admin).id;
      }
      _configurationError = null;
      _locked = forceLogin && profile.protected;
      _loadSourceSwitches();
      _loadLibrary();
      _loadSeriesCandidates();
      if (_migrateAuxiliary && fileStore == null)
        _queue(() => _moveSeriesCandidates().catchError((Object _) {}));
      pruneExpiredHistory(force: true).catchError((Object _) {});
    } catch (_) {
      _block('本地用户配置损坏，已锁定访问。原始记录已保留，请重新读取或从备份恢复。');
    }
  }

  static List<LocalProfile> _readProfiles(dynamic records) {
    final profiles = (records as List)
        .map(
          (row) => LocalProfile.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
    if (profiles.isEmpty ||
        profiles.length > 20 ||
        profiles.map((profile) => profile.id).toSet().length !=
            profiles.length ||
        profiles.where((profile) => profile.admin).length != 1 ||
        (profiles.length > 1 &&
            !profiles.firstWhere((profile) => profile.admin).protected)) {
      throw const FormatException('用户配置无效');
    }
    return profiles;
  }

  void _block(String message) {
    _configurationError = message;
    _locked = true;
    _profiles = [
      const LocalProfile(id: 'default', name: '配置待恢复', download: false),
    ];
    _current = 'default';
    _history.clear();
    _favorites.clear();
    _followStates.clear();
    _seriesCandidates.clear();
    _epoch++;
    // 损坏时的数据不能留到恢复之后：挂起的进度直接丢弃。
    _discardWatch();
    _libraryRevision++;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String? _string(String key) => _snapshot?.getString(key);
  bool? _bool(String key) => _snapshot?.getBool(key);
  String _key(String key, [String? id]) =>
      (id ?? _current) == 'default' ? key : 'profile.${id ?? _current}.$key';
  String? get configurationError => _configurationError;
  List<LocalProfile> get profiles => List.unmodifiable(_profiles);
  LocalProfile get profile =>
      _profiles.firstWhere((profile) => profile.id == _current);
  bool get locked => _locked || _configurationError != null;
  int get profileEpoch => _epoch;
  bool get forceLogin {
    if (_configurationError != null) return true;
    final admin = _profiles.firstWhere((profile) => profile.admin);
    return _bool('forceLogin') ?? admin.protected;
  }

  bool get canDownload => !locked && (profile.admin || profile.download);
  bool allowsSource(String source) =>
      !locked &&
      SourceSite.isAvailable(source) &&
      profile.allows(source) &&
      sourceEnabled(source);
  List<SourceSite> get sources =>
      SourceSite.values.where((site) => allowsSource(site.id)).toList();
  List<SourceSite> get permittedSources => [
    for (final site in SourceSite.values)
      if (!locked && profile.allows(site.id)) site,
  ];

  bool sourceEnabled(String source) =>
      _sourceSwitches[source] ?? !SourceSite.isRestricted(source);

  void _loadSourceSwitches() {
    try {
      final raw = _string('sourceSwitches');
      _sourceSwitches = raw == null
          ? {}
          : Map<String, bool>.from(jsonDecode(raw) as Map);
    } catch (_) {
      _sourceSwitches = {};
    }
  }

  Future<void> setSourceEnabled(String source, bool enabled) {
    if (!SourceSite.isAvailable(source)) {
      return Future.error(StateError('站源无效'));
    }
    final epoch = _epoch;
    return _queue(() async {
      _requireAdmin();
      if (epoch != _epoch) throw StateError('当前用户已变更，请重试');
      final switches = {..._sourceSwitches, source: enabled};
      await _commit({'sourceSwitches': jsonEncode(switches)});
      _sourceSwitches = switches;
      _notify();
    });
  }

  void _loadLibrary() {
    _history.clear();
    _favorites.clear();
    _followStates.clear();
    if (_configurationError != null) return;
    for (final row in readJsonList(_string(_key('history')))) {
      try {
        final entry = WatchEntry.fromJson(row);
        _history[entry.drama.id] = entry;
      } catch (_) {}
    }
    for (final row in readJsonList(_string(_key('favorites')))) {
      try {
        final drama = Drama.fromJson(row);
        _favorites[drama.id] = drama;
      } catch (_) {}
    }
    Map<String, dynamic> states = {};
    try {
      states = Map<String, dynamic>.from(
        jsonDecode(_string(_key('followStates')) ?? '{}') as Map,
      );
    } catch (_) {}
    for (final drama in _favorites.values) {
      try {
        _followStates[drama.id] = FollowState.fromJson(
          Map<String, dynamic>.from(states[drama.id] as Map),
        );
      } catch (_) {
        _followStates[drama.id] = FollowState.initial(drama);
      }
    }
  }

  String _seriesKey([String? id]) => 'seriesCandidates.${id ?? _current}';
  String _followChecksKey([String? id]) => 'followChecks.${id ?? _current}';

  String? _userAux(String category, [String? id]) => fileStore != null
      ? _string(_key(category, id))
      : preferences.getString('$category.${id ?? _current}') ??
            _string(_key(category, id));

  Future<void> _saveUserAux(String category, String value, [String? id]) async {
    if (fileStore != null) {
      await _commit({_key(category, id): value});
    } else {
      await preferences.setString('$category.${id ?? _current}', value);
    }
  }

  Map<String, FollowCheck> get followChecks {
    try {
      final data = jsonDecode(_userAux('followChecks') ?? '{}') as Map;
      return {
        for (final entry in data.entries)
          entry.key as String: FollowCheck.fromJson(entry.value),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> saveFollowChecks(
    Map<String, FollowCheck> checks, {
    required int epoch,
  }) => _queue(() async {
    if (locked || epoch != _epoch) return;
    await _saveUserAux(
      'followChecks',
      jsonEncode({
        for (final entry in checks.entries)
          if (_favorites.containsKey(entry.key))
            entry.key: entry.value.toJson(),
      }),
    );
  });

  void _loadSeriesCandidates() {
    _seriesCandidates.clear();
    if (_configurationError != null) return;
    for (final row in readJsonList(_userAux('seriesCandidates'))) {
      try {
        final drama = Drama.fromJson(row);
        if (drama.source == SourceSite.hongguo.id) {
          _seriesCandidates[drama.id] = drama;
        }
      } catch (_) {}
    }
  }

  Future<void> _moveSeriesCandidates() async {
    if (fileStore != null) return;
    if (_configurationError != null) return;
    final legacy = {
      for (final profile in _profiles)
        profile.id: ?_string(_key('seriesCandidates', profile.id)),
    };
    if (legacy.isEmpty) return;
    for (final entry in legacy.entries) {
      if (preferences.getString(_seriesKey(entry.key)) == null) {
        await preferences.setString(_seriesKey(entry.key), entry.value);
      }
    }
    await _commit(
      {},
      remove: legacy.keys.map((id) => _key('seriesCandidates', id)),
    );
  }

  /// 原始记录仅作为缓存身份，不对外解析或复制整份历史；时钟沿用保留规则。
  ({Object contents, DateTime now}) recentHistoryState() => (
    contents: (
      _epoch,
      locked,
      sources.map((source) => source.id).join(','),
      locked ? null : _string(_key('history')),
      locked ? null : _string(_key('liveHistory')),
      _libraryRevision,
    ),
    now: _clock(),
  );

  List<WatchEntry> get history =>
      _history.values
          .where(
            (entry) =>
                allowsSource(entry.drama.source) &&
                retainedWatchTime(entry.updatedAt, _clock()),
          )
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  List<Drama> get favorites => _favorites.values
      .where((drama) => allowsSource(drama.source))
      .toList()
      .reversed
      .toList();

  /// 某个站源最近一条观看记录。
  ///
  /// 等价于 [history] 里该站源的第一条，但只扫一遍内存映射，
  /// 不排序、不生成整份列表，可以放心在 build 里反复调用。
  WatchEntry? latestWatchFor(String source) {
    if (!allowsSource(source)) return null;
    final now = _clock();
    WatchEntry? latest;
    for (final entry in _history.values) {
      if (entry.drama.source != source) continue;
      if (!retainedWatchTime(entry.updatedAt, now)) continue;
      if (latest == null || entry.updatedAt.isAfter(latest.updatedAt)) {
        latest = entry;
      }
    }
    return latest;
  }
  WatchEntry? watched(String id) {
    final entry = _history[id];
    return entry != null &&
            allowsSource(entry.drama.source) &&
            retainedWatchTime(entry.updatedAt, _clock())
        ? entry
        : null;
  }

  bool isFavorite(String id) =>
      _favorites[id] != null && allowsSource(_favorites[id]!.source);
  FollowState? following(String id) =>
      isFavorite(id) ? _followStates[id] : null;
  List<Drama> seriesDramasFor(Drama anchor) {
    if (!allowsSource(SourceSite.hongguo.id) ||
        anchor.source != SourceSite.hongguo.id) {
      return const [];
    }
    final items = <String, Drama>{};
    for (final drama in _seriesCandidates.values) {
      if (allowsSource(drama.source)) items[drama.id] = drama;
    }
    for (final drama in _favorites.values) {
      if (allowsSource(drama.source)) items[drama.id] = drama;
    }
    for (final entry in _history.values) {
      if (allowsSource(entry.drama.source)) items[entry.drama.id] = entry.drama;
    }
    final notices = <SeriesSeasonNotice>[
      ...?_followStates[anchor.id]?.seriesSeasons.values,
      for (final state in _followStates.values)
        if (state.seriesSeasons.containsKey(anchor.id))
          state.seriesSeasons[anchor.id]!,
    ];
    for (final notice in notices) {
      items.putIfAbsent(
        notice.id,
        () => Drama(
          id: notice.id,
          source: SourceSite.hongguo.id,
          sourceId: notice.id.substring(SourceSite.hongguo.id.length + 1),
          title: notice.title,
        ),
      );
    }
    final current = items.remove(anchor.id) ?? anchor;
    // 每项只算一次排序键：放进比较器会把归一化与正则折叠变成 O(n log n) 次。
    final rest = [
      for (final drama in items.values)
        (drama: drama, key: naturalTitleKey(drama.title)),
    ]..sort((a, b) => naturalTitleKeyCompare(a.key, b.key));
    return [current, ...rest.map((entry) => entry.drama)];
  }

  bool get hideVip =>
      _configurationError == null ? _bool(_key('hideVip')) ?? true : true;
  String get displayMode {
    final value = _configurationError == null ? _string('displayMode') : null;
    return {'auto', 'television', 'phone', 'pad', 'window'}.contains(value)
        ? value!
        : 'auto';
  }

  String get themeMode {
    final value = _configurationError == null ? _string('themeMode') : null;
    return {'light', 'dark', 'system'}.contains(value) ? value! : 'system';
  }

  bool get followSystemColor =>
      preferences.getBool('followSystemColor') ?? true;
  ThemeColor get themeColor =>
      ThemeColor.byName(preferences.getString('themeColor')) ??
      ThemeColor.orange;
  bool get sideBarExpanded => preferences.getBool('sideBarExpanded') ?? true;

  String? _navigationOrderRaw;
  List<String> _navigationOrderCache = const [];

  /// 顶栏顺序在每次 build 里都会被读到，按原始字符串缓存解析结果。
  List<String> get navigationOrder {
    final raw = _string('navigationOrder');
    if (raw != _navigationOrderRaw) {
      _navigationOrderRaw = raw;
      _navigationOrderCache = _parseNavigationOrder(raw);
    }
    return _navigationOrderCache;
  }

  static List<String> _parseNavigationOrder(String? raw) {
    try {
      final decoded = raw == null ? null : jsonDecode(raw);
      return normalizeNavigationOrder(decoded is List ? decoded : const []);
    } catch (_) {
      return normalizeNavigationOrder(const []);
    }
  }

  Future<void> setNavigationOrder(Iterable<Object?> values) =>
      _setting('navigationOrder', jsonEncode(normalizeNavigationOrder(values)));

  String? _navigationVisibleRaw;
  List<String> _navigationVisibleCache = const [];

  /// 与 [navigationOrder] 同理：按原始字符串缓存解析结果。
  List<String> get navigationVisible {
    final raw = _string('navigationVisible');
    if (raw != _navigationVisibleRaw) {
      _navigationVisibleRaw = raw;
      _navigationVisibleCache = _parseNavigationVisible(raw);
    }
    return _navigationVisibleCache;
  }

  static List<String> _parseNavigationVisible(String? raw) {
    try {
      final decoded = raw == null ? null : jsonDecode(raw);
      return normalizeNavigationVisible(decoded is List ? decoded : const []);
    } catch (_) {
      return normalizeNavigationVisible(const []);
    }
  }

  /// 在写队列内读取最新值，连续操作也不能关掉最后一个功能。
  Future<void> setNavigationVisible(String name, bool visible) {
    final epoch = _epoch;
    return _queue(() async {
      if (locked || epoch != _epoch) throw StateError('当前用户已变更，请重试');
      if (!defaultNavigationOrder.contains(name)) return;
      final next = navigationVisible.toSet();
      if (visible) {
        next.add(name);
      } else {
        if (next.length == 1 && next.contains(name)) return;
        next.remove(name);
      }
      await _commit({'navigationVisible': jsonEncode(next.toList())});
      _notify();
    });
  }

  Future<void> resetNavigation() {
    final epoch = _epoch;
    return _queue(() async {
      if (locked || epoch != _epoch) throw StateError('当前用户已变更，请重试');
      await _commit({
        'navigationOrder': jsonEncode(defaultNavigationOrder),
        'navigationVisible': jsonEncode(defaultNavigationOrder),
      });
      _notify();
    });
  }

  bool get showDramaDetails => preferences.getBool('showDramaDetails') ?? true;
  Future<void> setShowDramaDetails(bool value) => _queue(() async {
    if (locked) throw StateError('请先解锁');
    await preferences.setBool('showDramaDetails', value);
    _notify();
  });

  /// 每个本地自然日检查全部用户，锁定仅限制访问，不阻止过期数据维护。
  Future<void> pruneExpiredHistory({bool force = false}) => _queue(() async {
    if (_disposed || _configurationError != null || _snapshot == null) return;
    final now = _clock();
    final day = DateTime(now.year, now.month, now.day);
    if (!force && _historyCleanupDay == day) return;
    final previous = _snapshot!.values;
    final next = Map<String, Object>.of(previous);
    pruneWatchHistoryValues(next, now);
    final changes = <String, Object>{
      for (final entry in next.entries)
        if (previous[entry.key] != entry.value) entry.key: entry.value,
    };
    if (changes.isNotEmpty) {
      await _commit(changes);
      _loadLibrary();
      _notify();
    }
    _historyCleanupDay = day;
  });

  /// 液态玻璃外观开关。默认开启；关闭后所有玻璃件退化为不透明容器。
  bool get glassEffects => preferences.getBool('glassEffects') ?? true;
  bool get playerWide => preferences.getBool('playerWide') ?? false;
  double get playerVolume => preferences.getDouble('playerVolume') ?? 100;
  ({double left, double top, double extent})? get miniWindow {
    final values = preferences
        .getString('miniWindow')
        ?.split(',')
        .map(double.tryParse)
        .toList();
    if (values == null || values.length != 3 || values.contains(null)) {
      return null;
    }
    return (left: values[0]!, top: values[1]!, extent: values[2]!);
  }

  bool get televisionKeyboard =>
      preferences.getBool('televisionKeyboard') ?? false;
  bool get autoExport => _bool('autoExport') ?? false;
  bool get deleteAfterAutoExport =>
      preferences.getBool('deleteAfterAutoExport') ?? false;
  bool get deleteAfterManualExport =>
      preferences.getBool('deleteAfterManualExport') ?? false;
  String get ignoredUpdate => preferences.getString('ignoredUpdate') ?? '';

  String get source {
    if (locked) return '';
    final value = _string(_key('source')) ?? '';
    return sources.any((site) => site.id == value)
        ? value
        : sources.firstOrNull?.id ?? '';
  }

  final _downloadPreferences = _ParsedField<DownloadPreferences>();

  DownloadPreferences get downloadPreferences {
    if (locked) return const DownloadPreferences();
    return _downloadPreferences.read(
      _string(_key('downloadPreferences')),
      _parseDownloadPreferences,
    );
  }

  static DownloadPreferences _parseDownloadPreferences(String? raw) {
    try {
      return DownloadPreferences.fromJson(
        jsonDecode(raw ?? '{}') as Map<String, dynamic>,
      );
    } catch (_) {
      return const DownloadPreferences();
    }
  }

  List<LiveHistoryEntry> get liveHistory {
    if (locked) return const [];
    final entries = <String, LiveHistoryEntry>{};
    for (final row in readJsonList(_string(_key('liveHistory')))) {
      try {
        final entry = LiveHistoryEntry.fromJson(row);
        if (!retainedWatchTime(entry.updatedAt, _clock())) continue;
        final old = entries[entry.key];
        if (old == null || entry.updatedAt.isAfter(old.updatedAt)) {
          entries[entry.key] = entry;
        }
      } catch (_) {}
    }
    final sorted = entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(sorted.take(LiveHistoryEntry.limit));
  }

  /// 调用者须先确认视频输出；代次校验防止异步首帧写入另一用户。
  Future<void> recordLiveWatch(
    String platform,
    LiveRoom room, {
    required int profileEpoch,
  }) => _queue(() async {
    if (locked || profileEpoch != _epoch) return;
    final entry = LiveHistoryEntry.fromJson(
      LiveHistoryEntry(
        platformId: platform,
        room: room,
        updatedAt: _clock(),
      ).toJson(),
    );
    final next = [
      entry,
      ...liveHistory.where((item) => item.key != entry.key),
    ].take(LiveHistoryEntry.limit);
    await _commit({
      _key('liveHistory'): jsonEncode(next.map((e) => e.toJson()).toList()),
    });
    _notify();
  });

  /// 混合历史使用带类型的键，在同一事务内删除，筛选不会影响另一类。
  Future<void> removeRecentHistory(
    Set<String> keys, {
    required int profileEpoch,
  }) {
    final selected = Set<String>.of(keys);
    return _queue(() async {
      if (locked || profileEpoch != _epoch) return;
      final dramas = _history.values.where(
        (entry) =>
            !allowsSource(entry.drama.source) ||
            !selected.contains('drama:${entry.drama.id}'),
      );
      final live = liveHistory.where(
        (entry) => !selected.contains('live:${entry.key}'),
      );
      await _commit({
        _key('history'): jsonEncode(dramas.map((e) => e.toJson()).toList()),
        _key('liveHistory'): jsonEncode(live.map((e) => e.toJson()).toList()),
      });
      _loadLibrary();
      _notify();
    });
  }

  String? _liveFavoritesRaw;
  List<LiveFavorite> _liveFavoritesCache = const [];

  List<LiveFavorite> get liveFavorites {
    if (locked) return const [];
    final raw = _string(_key('liveFavorites'));
    if (raw != _liveFavoritesRaw) {
      final result = <LiveFavorite>[];
      for (final row in readJsonList(raw)) {
        try {
          result.add(LiveFavorite.fromJson(row));
        } catch (_) {}
      }
      _liveFavoritesRaw = raw;
      _liveFavoritesCache = List.unmodifiable(result);
    }
    return _liveFavoritesCache;
  }

  bool isLiveFavorite(String platform, String roomId) => liveFavorites.any(
    (entry) => entry.platformId == platform && entry.room.roomId == roomId,
  );

  Future<void> toggleLiveFavorite(String platform, LiveRoom room) {
    final epoch = _epoch;
    return _queue(() async {
      if (locked || epoch != _epoch) throw StateError('当前用户已变更，请重试');
      final entry = LiveFavorite.fromJson(
        LiveFavorite(platformId: platform, room: room).toJson(),
      );
      final next = liveFavorites.toList();
      final index = next.indexWhere((item) => item.key == entry.key);
      if (index >= 0) {
        next.removeAt(index);
      } else {
        if (next.length >= 1000) throw StateError('直播收藏已达 1000 个，请先整理收藏');
        next.insert(0, entry);
      }
      await _commit({
        _key('liveFavorites'): jsonEncode(
          next.map((item) => item.toJson()).toList(),
        ),
      });
      _notify();
    });
  }

  /// 一个事务移除一批收藏；锁定用户代次，不能操作切换后的用户。
  Future<void> removeLiveFavorites(Set<String> keys) {
    final selected = Set<String>.of(keys);
    final epoch = _epoch;
    return _queue(() async {
      if (locked || epoch != _epoch) throw StateError('当前用户已变更，请重试');
      final next = liveFavorites
          .where((entry) => !selected.contains(entry.key))
          .toList();
      await _commit({
        _key('liveFavorites'): jsonEncode(
          next.map((entry) => entry.toJson()).toList(),
        ),
      });
      _notify();
    });
  }

  final _liveBrowsePreferences = _ParsedField<LiveBrowsePreferences>();

  /// 独立用户偏好不进入旧快照白名单，缺失时保持原来的默认行为。
  LiveBrowsePreferences get liveBrowsePreferences {
    if (locked) return const LiveBrowsePreferences();
    return _liveBrowsePreferences.read(
      preferences.getString('liveBrowsePreferences.$_current'),
      _parseLiveBrowsePreferences,
    );
  }

  static LiveBrowsePreferences _parseLiveBrowsePreferences(String? raw) {
    try {
      return LiveBrowsePreferences.fromJson(
        jsonDecode(raw ?? '{}') as Map<String, dynamic>,
      );
    } catch (_) {
      return const LiveBrowsePreferences();
    }
  }

  Future<void> rememberLiveBrowse(
    String platformId,
    String? categoryId, {
    required int profileEpoch,
  }) {
    return _queue(() async {
      // 在队列执行时检查用户，防止迟到的分类响应写入另一用户。
      if (locked || profileEpoch != _epoch) return;
      final previous = liveBrowsePreferences;
      final next = LiveBrowsePreferences(
        platformId: platformId,
        categoryIds: {...previous.categoryIds, platformId: ?categoryId},
      );
      // 浏览偏好不是资料快照的一部分，保存失败不锁定整个资料库。
      final saved = await preferences.setString(
        'liveBrowsePreferences.$_current',
        jsonEncode(next.toJson()),
      );
      if (!saved) throw StateError('直播浏览偏好保存失败');
      _notify();
    });
  }

  /// 分类偏好独立于旧快照；站源本身沿用已有用户级 source 持久化。
  String? catalogCategory(String sourceId) {
    if (locked) return null;
    try {
      final value = jsonDecode(
        preferences.getString('catalogCategories.$_current') ?? '{}',
      );
      return value is Map && value[sourceId] is String
          ? value[sourceId] as String
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> rememberCatalogCategory(
    String sourceId,
    String categoryId, {
    required int profileEpoch,
  }) => _queue(() async {
    if (locked || profileEpoch != _epoch || !allowsSource(sourceId)) return;
    final key = 'catalogCategories.$_current';
    final categories = <String, String>{};
    try {
      final raw = jsonDecode(preferences.getString(key) ?? '{}');
      if (raw is Map) {
        for (final entry in raw.entries) {
          if (entry.key is String && entry.value is String) {
            categories[entry.key as String] = entry.value as String;
          }
        }
      }
    } catch (_) {}
    if (categories[sourceId] == categoryId) return;
    categories[sourceId] = categoryId;
    if (!await preferences.setString(key, jsonEncode(categories))) {
      throw StateError('短剧分类偏好保存失败');
    }
  });

  final _playbackPreferences = _ParsedField<PlaybackPreferences>();

  PlaybackPreferences get playbackPreferences {
    if (locked) return const PlaybackPreferences();
    return _playbackPreferences.read(
      _string(_key('playback')),
      _parsePlaybackPreferences,
    );
  }

  static PlaybackPreferences _parsePlaybackPreferences(String? raw) {
    try {
      return PlaybackPreferences.fromJson(
        jsonDecode(raw ?? '{}') as Map<String, dynamic>,
      );
    } catch (_) {
      return const PlaybackPreferences();
    }
  }

  final _recentSearches = _ParsedField<List<String>>();

  List<String> get recentSearches {
    if (locked) return const [];
    return _recentSearches.read(
      _string(_key('recentSearches')),
      _parseRecentSearches,
    );
  }

  static List<String> _parseRecentSearches(String? raw) {
    try {
      return List.unmodifiable(
        (jsonDecode(raw ?? '[]') as List).whereType<String>().take(20),
      );
    } catch (_) {
      return const [];
    }
  }

  Future<void> setCatalogSource(String source) {
    final epoch = _epoch;
    return _queue(() async {
      if (!allowsSource(source) || epoch != _epoch) {
        throw StateError('当前用户没有此站源权限');
      }
      await _commit({_key('source'): source});
      _notify();
    });
  }

  Future<void> rememberSearch(String text) {
    final query = text.trim();
    if (query.isEmpty || query.runes.length > 80) return Future.value();
    final epoch = _epoch;
    return _queue(() async {
      if (locked || epoch != _epoch) return;
      final entries = [
        query,
        ...recentSearches.where(
          (entry) => normalizedSearchText(entry) != normalizedSearchText(query),
        ),
      ].take(20).toList();
      await _commit({_key('recentSearches'): jsonEncode(entries)});
      _notify();
    });
  }

  Future<void> clearRecentSearches() => _setting(_key('recentSearches'), '[]');

  /// 删除单条最近搜索（长按搜索记录），其余条目顺序不变。
  Future<void> forgetSearch(String query) => _setting(
    _key('recentSearches'),
    jsonEncode([
      for (final entry in recentSearches)
        if (entry != query) entry,
    ]),
  );

  Future<void> _commit(
    Map<String, Object> changes, {
    Iterable<String> remove = const [],
    bool replace = false,
  }) async {
    final snapshot = _snapshot;
    if (snapshot == null) throw StateError('请先恢复本地配置');
    final values = replace ? <String, Object>{} : snapshot.values;
    for (final key in remove) {
      values.remove(key);
    }
    // 整体替换（恢复备份）以传入内容为准，挂起的静默进度直接丢弃。
    if (replace) _discardWatch();
    // 挂起的静默进度先落成字段；显式改动优先，因为它读的是最新的内存状态。
    final pending = replace ? const <String, Object>{} : _takeWatchChanges();
    final incoming = Map<String, Object>.of(changes);
    pruneWatchHistoryValues(incoming, _clock());
    values.addAll(pending);
    values.addAll(incoming);
    values.putIfAbsent(
      'profiles',
      () => jsonEncode(_profiles.map((profile) => profile.toJson()).toList()),
    );
    values.putIfAbsent('activeProfile', () => _current);
    try {
      await snapshot.commit(values);
    } on SnapshotRecoveryRequired catch (error) {
      _block(error.toString());
      _notify();
      rethrow;
    }
  }

  Future<void> _setting(String key, Object value, {bool admin = false}) {
    final epoch = _epoch;
    return _queue(() async {
      if (admin) _requireAdmin();
      if (locked || epoch != _epoch) throw StateError('当前用户已变更，请重试');
      await _commit({key: value});
      _notify();
    });
  }

  Future<void> setForceLogin(bool value) =>
      _setting('forceLogin', value, admin: true);
  Future<void> setHideVip(bool value) => _setting(_key('hideVip'), value);
  Future<void> setSource(String value) {
    if (!allowsSource(value)) return Future.error(StateError('当前用户没有此站源权限'));
    return _setting(_key('source'), value);
  }

  Future<void> setDisplayMode(String value) =>
      {'auto', 'television', 'phone', 'pad', 'window'}.contains(value)
      ? _setting('displayMode', value)
      : Future.value();
  Future<void> setThemeMode(String value) =>
      {'light', 'dark', 'system'}.contains(value)
      ? _setting('themeMode', value)
      : Future.value();
  Future<void> setFollowSystemColor(bool value) => _queue(() async {
    await preferences.setBool('followSystemColor', value);
    _notify();
  });
  Future<void> setThemeColor(ThemeColor value) => _queue(() async {
    await preferences.setString('themeColor', value.name);
    _notify();
  });
  Future<void> setSideBarExpanded(bool value) => _queue(() async {
    await preferences.setBool('sideBarExpanded', value);
    _notify();
  });
  Future<void> setGlassEffects(bool value) => _queue(() async {
    await preferences.setBool('glassEffects', value);
    _notify();
  });
  Future<void> setPlayerWide(bool value) => _queue(() async {
    await preferences.setBool('playerWide', value);
    _notify();
  });
  Future<void> setPlayerVolume(double value) =>
      _queue(() => preferences.setDouble('playerVolume', value));
  Future<void> setMiniWindow(
    ({double left, double top, double extent}) value,
  ) => _queue(
    () => preferences.setString(
      'miniWindow',
      '${value.left},${value.top},${value.extent}',
    ),
  );
  Future<void> setTelevisionKeyboard(bool value) => _queue(() async {
    await preferences.setBool('televisionKeyboard', value);
    _notify();
  });
  Future<void> setAutoExport(bool value) => _queue(() async {
    await _commit({'autoExport': value});
    _notify();
  });
  Future<void> setDeleteAfterAutoExport(bool value) => _queue(() async {
    await preferences.setBool('deleteAfterAutoExport', value);
    _notify();
  });
  Future<void> setDeleteAfterManualExport(bool value) => _queue(() async {
    await preferences.setBool('deleteAfterManualExport', value);
    _notify();
  });
  Future<void> setIgnoredUpdate(String version) =>
      _queue(() => preferences.setString('ignoredUpdate', version));
  Future<void> setPlaybackPreferences(PlaybackPreferences value) {
    PlaybackPreferences.fromJson(value.toJson());
    return _setting(_key('playback'), jsonEncode(value.toJson()));
  }

  Future<void> setDownloadPreferences(DownloadPreferences value) {
    DownloadPreferences.fromJson(value.toJson());
    return _setting(_key('downloadPreferences'), jsonEncode(value.toJson()));
  }

  Future<void> toggleFavorite(Drama drama) {
    final epoch = _epoch;
    return _queue(() async {
      if (!allowsSource(drama.source) || epoch != _epoch) return;
      final entries = Map.of(_favorites);
      final states = Map.of(_followStates);
      if (entries.containsKey(drama.id)) {
        entries.remove(drama.id);
        states.remove(drama.id);
      } else {
        if (entries.length >= 20000) throw StateError('追剧数量已达上限，请先整理追剧');
        entries[drama.id] = drama;
        states[drama.id] = FollowState.initial(drama);
      }
      await _commit({
        _key('favorites'): jsonEncode(
          entries.values.map((entry) => entry.toJson()).toList(),
        ),
        _key('followStates'): _encodeFollowStates(states),
      });
      _loadLibrary();
      _notify();
    });
  }

  String _encodeFollowStates(Map<String, FollowState> states) => jsonEncode({
    for (final entry in states.entries) entry.key: entry.value.toJson(),
  });

  Future<void> removeFavorites(Set<String> ids) {
    final epoch = _epoch;
    return _queue(() async {
      if (epoch != _epoch) return;
      final removed = {
        for (final id in ids)
          if (_favorites[id] case final drama? when allowsSource(drama.source))
            id,
      };
      if (removed.isEmpty) return;
      final entries = Map.of(_favorites)
        ..removeWhere((id, _) => removed.contains(id));
      final states = Map.of(_followStates)
        ..removeWhere((id, _) => removed.contains(id));
      await _commit({
        _key('favorites'): jsonEncode(
          entries.values.map((entry) => entry.toJson()).toList(),
        ),
        _key('followStates'): _encodeFollowStates(states),
      });
      _loadLibrary();
      _notify();
    });
  }

  Future<void> markUpdatesRead(String id) {
    final epoch = _epoch;
    return _queue(() async {
      if (!isFavorite(id) || epoch != _epoch) return;
      final states = Map.of(_followStates)
        ..[id] = _followStates[id]!.markRead();
      await _commit({_key('followStates'): _encodeFollowStates(states)});
      _loadLibrary();
      _notify();
    });
  }

  Future<void> markSeriesSeasonRead(String id, String seasonId) {
    final epoch = _epoch;
    return _queue(() async {
      if (!isFavorite(id) || epoch != _epoch) return;
      final current = _followStates[id]!;
      final updated = current.markSeriesSeasonRead(seasonId);
      if (identical(current, updated)) return;
      final states = Map.of(_followStates)..[id] = updated;
      await _commit({_key('followStates'): _encodeFollowStates(states)});
      _loadLibrary();
      _notify();
    });
  }

  /// 把挂起的观看进度转成待写入的字段，并按落盘规则把内存历史裁到同一份。
  ///
  /// 只有真正写盘时才排序、编码，所以每 5 秒一次的静默保存不再触碰磁盘格式，
  /// 也不必再整份反序列化重建 library。
  Map<String, Object> _takeWatchChanges() {
    if (!_watchPending) return const {};
    _watchPending = false;
    final follow = _watchFollowPending;
    _watchFollowPending = false;
    final now = _clock();
    _watchSavedAt = now;
    final sorted = _history.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final kept = <WatchEntry>[];
    for (final entry in sorted) {
      if (kept.length >= 300) break;
      if (!retainedWatchTime(entry.updatedAt, now)) continue;
      kept.add(entry);
    }
    // 内存与写入内容保持一致：等价于过去保存后重新解析一次磁盘。
    _history.clear();
    for (final entry in kept) {
      _history[entry.drama.id] = entry;
    }
    final changes = <String, Object>{
      _key('history'): jsonEncode(kept.map((entry) => entry.toJson()).toList()),
    };
    if (follow) {
      changes[_key('followStates')] = _encodeFollowStates(_followStates);
      changes[_key('favorites')] = jsonEncode(
        _favorites.values.map((entry) => entry.toJson()).toList(),
      );
    }
    return changes;
  }

  Future<void> _flushWatch() async {
    if (!_watchPending) return;
    await _commit(const {});
  }

  /// 切换用户、恢复备份或配置损坏时，挂起的进度不能落到别人的数据上。
  void _discardWatch() {
    _watchPending = false;
    _watchFollowPending = false;
  }

  /// 保存观看进度。
  ///
  /// [quiet] 用于播放中每 5 秒一次的定时保存：只改内存里的那一条历史，攒够
  /// [_watchFlushDelay] 才合并写一次，不再每次都重排、重编码整份历史；
  /// 顶部条目的可见内容没有变化时也不通知监听者，避免被遮挡的页面跟着重绘。
  Future<void> saveWatch(WatchEntry entry, {bool quiet = false}) {
    final epoch = _epoch;
    return _queue(() async {
      if (!allowsSource(entry.drama.source) || epoch != _epoch) return;
      final previous = _history[entry.drama.id]?.drama;
      final current = previous == null
          ? entry
          : WatchEntry(
              drama: previous.merge(entry.drama),
              episode: entry.episode,
              position: entry.position,
              duration: entry.duration,
              updatedAt: entry.updatedAt,
            );
      // 改动前先抓住「最新一条历史」和追剧状态：静默保存据此判断是否要通知。
      WatchEntry? latest;
      for (final item in _history.values) {
        if (latest == null || item.updatedAt.isAfter(latest.updatedAt)) {
          latest = item;
        }
      }
      final beforeState = _followStates[entry.drama.id];
      final beforeFavorite = _favorites[entry.drama.id];
      FollowState? state;
      Drama? favorite;
      // 只替换这一条；其余条目保持原对象，不必重建整份 library。
      _history[entry.drama.id] = current;
      _libraryRevision++;
      if (beforeState != null) {
        final observed = beforeState.observe(current.drama);
        final merged = beforeFavorite!.merge(current.drama);
        state = observed;
        favorite = merged;
        _followStates[entry.drama.id] = observed;
        _favorites[entry.drama.id] = merged;
        _watchFollowPending = true;
      }
      _watchPending = true;
      if (!quiet || _clock().difference(_watchSavedAt) >= _watchFlushDelay) {
        await _flushWatch();
      }
      var changed =
          !quiet ||
          latest == null ||
          latest.drama.id != entry.drama.id ||
          latest.episode != current.episode ||
          jsonEncode(latest.drama) != jsonEncode(current.drama);
      if (state != null) {
        if (jsonEncode(state) != jsonEncode(beforeState)) changed = true;
        if (jsonEncode(favorite) != jsonEncode(beforeFavorite)) changed = true;
      }
      if (changed) _notify();
    });
  }

  WatchEntry? mediaWatched(String id) {
    if (!canDownload) return null;
    try {
      final data = jsonDecode(_string(_key('mediaHistory')) ?? '{}') as Map;
      final entry = data[id] == null
          ? null
          : WatchEntry.fromJson(Map<String, dynamic>.from(data[id] as Map));
      return entry != null && allowsSource(entry.drama.source) ? entry : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveMediaWatch(String id, WatchEntry entry) {
    final epoch = _epoch;
    return _queue(() async {
      if (!canDownload ||
          !allowsSource(entry.drama.source) ||
          epoch != _epoch) {
        return;
      }
      final data = jsonDecode(_string(_key('mediaHistory')) ?? '{}') as Map;
      data.remove(id);
      data[id] = entry.toJson();
      while (data.length > 300) {
        data.remove(data.keys.first);
      }
      await _commit({_key('mediaHistory'): jsonEncode(data)});
    });
  }

  Future<void> clearHistory() {
    final epoch = _epoch;
    return _queue(() async {
      if (locked || epoch != _epoch) return;
      await _commit({}, remove: [_key('history')]);
      _loadLibrary();
      _notify();
    });
  }

  Future<void> removeHistory(Set<String> ids) {
    final epoch = _epoch;
    return _queue(() async {
      if (epoch != _epoch) return;
      final removed = {
        for (final id in ids)
          if (_history[id] case final entry?
              when allowsSource(entry.drama.source))
            id,
      };
      if (removed.isEmpty) return;
      final entries = Map.of(_history)
        ..removeWhere((id, _) => removed.contains(id));
      await _commit({
        _key('history'): jsonEncode(
          entries.values.map((entry) => entry.toJson()).toList(),
        ),
      });
      _loadLibrary();
      _notify();
    });
  }

  Future<void> refreshDrama(Drama drama) =>
      _refreshDramas([drama], cacheSeriesCandidates: false);

  Future<void> refreshDramas(Iterable<Drama> dramas) =>
      _refreshDramas(dramas, cacheSeriesCandidates: true);

  Future<void> _refreshDramas(
    Iterable<Drama> dramas, {
    required bool cacheSeriesCandidates,
  }) {
    final epoch = _epoch;
    final updates = dramas.toList();
    return _queue(() async {
      if (locked || epoch != _epoch) return;
      final changes = <String, Object>{};
      final favorites = Map.of(_favorites);
      final history = Map.of(_history);
      final states = Map.of(_followStates);
      final seriesCandidates = Map.of(_seriesCandidates);
      for (final drama in updates) {
        if (!allowsSource(drama.source)) continue;
        if (cacheSeriesCandidates && drama.source == SourceSite.hongguo.id) {
          seriesCandidates[drama.id] = (seriesCandidates[drama.id] ?? drama)
              .merge(drama);
        }
        final favorite = favorites[drama.id];
        if (favorite != null) {
          favorites[drama.id] = favorite.merge(drama);
          states[drama.id] = states[drama.id]!.observe(favorites[drama.id]!);
        }
        final watched = history[drama.id];
        if (watched != null) {
          history[drama.id] = WatchEntry(
            drama: watched.drama.merge(drama),
            episode: watched.episode,
            position: watched.position,
            duration: watched.duration,
            updatedAt: watched.updatedAt,
          );
        }
      }
      final candidates = <String, Drama>{
        for (final entry in history.values) entry.drama.id: entry.drama,
        ...favorites,
        for (final drama in updates)
          if (allowsSource(drama.source)) drama.id: drama,
      };
      for (final state in states.values) {
        for (final notice in state.seriesSeasons.values) {
          candidates.putIfAbsent(
            notice.id,
            () => Drama(
              id: notice.id,
              source: SourceSite.hongguo.id,
              sourceId: notice.id.substring(SourceSite.hongguo.id.length + 1),
              title: notice.title,
            ),
          );
        }
      }
      final favoriteIds = favorites.keys.toSet();
      for (final favorite in favorites.values) {
        if (favorite.source != SourceSite.hongguo.id ||
            states[favorite.id] == null) {
          continue;
        }
        states[favorite.id] = observeHongguoSeriesSeasons(
          anchor: favorite,
          state: states[favorite.id]!,
          candidates: candidates.values,
          favoriteIds: favoriteIds,
        );
      }
      final favoriteJson = jsonEncode(
        favorites.values.map((entry) => entry.toJson()).toList(),
      );
      final historyJson = jsonEncode(
        history.values.map((entry) => entry.toJson()).toList(),
      );
      final statesJson = _encodeFollowStates(states);
      final cachedCandidates = cacheSeriesCandidates
          ? (seriesCandidates.values.toList()
                  ..sort((a, b) => a.id.compareTo(b.id)))
                .take(2000)
                .toList()
          : null;
      final seriesCandidateJson = cachedCandidates == null
          ? null
          : jsonEncode(
              cachedCandidates.map((entry) => entry.toJson()).toList(),
            );
      if (favoriteJson !=
          jsonEncode(
            _favorites.values.map((entry) => entry.toJson()).toList(),
          )) {
        changes[_key('favorites')] = favoriteJson;
      }
      if (historyJson !=
          jsonEncode(_history.values.map((entry) => entry.toJson()).toList())) {
        changes[_key('history')] = historyJson;
      }
      if (statesJson != _encodeFollowStates(_followStates)) {
        changes[_key('followStates')] = statesJson;
      }
      final seriesChanged =
          seriesCandidateJson != null &&
          seriesCandidateJson != _userAux('seriesCandidates');
      if (seriesChanged) {
        await _saveUserAux('seriesCandidates', seriesCandidateJson);
        _seriesCandidates
          ..clear()
          ..addEntries(
            cachedCandidates!.map((drama) => MapEntry(drama.id, drama)),
          );
      }
      if (changes.isEmpty) {
        if (seriesChanged) _notify();
        return;
      }
      await _commit(changes);
      _loadLibrary();
      _notify();
    });
  }

  void _requireAdmin() {
    if (locked || !profile.admin) throw StateError('仅管理员可以修改此设置');
  }

  Future<void> _checkPin(LocalProfile target, String pin) async {
    if (DateTime.now().isBefore(_retryAfter)) {
      throw StateError('密码输入过于频繁，请稍后再试');
    }
    if (!await checkProfilePin(target, pin)) {
      _failures++;
      if (_failures >= 3) {
        _retryAfter = DateTime.now().add(
          Duration(seconds: (_failures * 2).clamp(0, 30)),
        );
      }
      throw StateError('密码不正确');
    }
    _failures = 0;
  }

  Future<void> switchProfile(String id, {String pin = ''}) => _queue(() async {
    if (_configurationError != null) throw StateError('本地用户配置损坏，请先恢复');
    final target = _profiles.firstWhere((profile) => profile.id == id);
    await _checkPin(target, pin);
    await _commit({'activeProfile': id});
    _current = id;
    _locked = false;
    _loadLibrary();
    _loadSeriesCandidates();
    _epoch++;
    _notify();
  });
  void lock() {
    if (!profile.protected) return;
    _locked = true;
    _epoch++;
    _notify();
  }

  Future<void> saveProfile({
    String? id,
    required String name,
    required List<String> sources,
    required bool download,
    String? pin,
  }) => _queue(() async {
    _requireAdmin();
    final old = _profiles.where((profile) => profile.id == id).firstOrNull;
    final targetId = old?.id ?? randomProfileToken();
    final cleanName = name.trim();
    if (cleanName.isEmpty || cleanName.length > 40) {
      throw StateError('用户名需要 1 至 40 个字符');
    }
    if (sources.any((source) => !SourceSite.isKnown(source))) {
      throw StateError('站源无效');
    }
    if (targetId != 'default' &&
        !_profiles.firstWhere((profile) => profile.admin).protected) {
      throw StateError('请先为管理员设置密码，再创建或修改其他用户');
    }
    if (old == null && _profiles.length >= 20) {
      throw StateError('最多支持 20 个本地用户');
    }
    var salt = old?.salt ?? '', hash = old?.pinHash ?? '';
    if (pin != null) {
      if (pin.isEmpty) {
        if (targetId == 'default' && _profiles.length > 1) {
          throw StateError('存在其他用户时不能取消管理员密码');
        }
        salt = '';
        hash = '';
      } else {
        if (pin.length < 6 || pin.length > 128) {
          throw StateError('密码需要 6 至 128 个字符');
        }
        salt = randomProfileToken();
        hash = await _pinHasher(pin, salt);
      }
    }
    _requireAdmin();
    final updated = LocalProfile(
      id: targetId,
      name: cleanName,
      admin: targetId == 'default',
      sources: sources.toSet().toList(),
      download: download,
      salt: salt,
      pinHash: hash,
    );
    final profiles =
        [
          for (final profile in _profiles)
            if (profile.id != targetId) profile,
          updated,
        ]..sort(
          (a, b) => a.admin
              ? -1
              : b.admin
              ? 1
              : a.name.compareTo(b.name),
        );
    await _commit({
      'profiles': jsonEncode(
        profiles.map((profile) => profile.toJson()).toList(),
      ),
    });
    _profiles = profiles;
    _notify();
  });
  Future<void> deleteProfile(String id) => _queue(() async {
    _requireAdmin();
    if (id == 'default') throw StateError('不能删除管理员');
    final profiles = _profiles.where((profile) => profile.id != id).toList();
    await _commit({
      'profiles': jsonEncode(
        profiles.map((profile) => profile.toJson()).toList(),
      ),
    }, remove: LocalSnapshot.libraryKeys.map((key) => _key(key, id)));
    await preferences.remove(_seriesKey(id));
    await preferences.remove(_followChecksKey(id));
    _profiles = profiles;
    _notify();
  });

  Future<String> exportBackup() async {
    await _writes.catchError((Object _) {});
    // 导出前先把挂起的观看进度写下去：备份里不能少掉最后一集。
    await _queue(_flushWatch).catchError((Object _) {});
    _requireAdmin();
    final content = jsonEncode({
      'schema': 1,
      'app': 'zhenguojian',
      'profiles': _profiles.map((profile) => profile.toJson()).toList(),
      'displayMode': displayMode,
      'themeMode': themeMode,
      'navigationOrder': navigationOrder,
      'navigationVisible': navigationVisible,
      'followSystemColor': followSystemColor,
      'glassEffects': glassEffects,
      'themeColor': themeColor.name,
      'autoExport': _bool('autoExport') ?? false,
      'exportPosters': _bool('exportPosters') ?? false,
      'forceLogin': forceLogin,
      'libraries': {
        for (final profile in _profiles)
          profile.id: {
            'history': readJsonList(_string(_key('history', profile.id))),
            'favorites': readJsonList(_string(_key('favorites', profile.id))),
            'liveFavorites': readJsonList(
              _string(_key('liveFavorites', profile.id)),
            ),
            'liveHistory': readJsonList(
              _string(_key('liveHistory', profile.id)),
            ),
            'followStates': jsonDecode(
              _string(_key('followStates', profile.id)) ?? '{}',
            ),
            'seriesCandidates': readJsonList(
              _userAux('seriesCandidates', profile.id) ?? '[]',
            ),
            'mediaHistory': jsonDecode(
              _string(_key('mediaHistory', profile.id)) ?? '{}',
            ),
            'source': _string(_key('source', profile.id)) ?? '',
            'hideVip': _bool(_key('hideVip', profile.id)) ?? true,
            'playback': jsonDecode(
              _string(_key('playback', profile.id)) ?? '{}',
            ),
            'downloadPreferences': jsonDecode(
              _string(_key('downloadPreferences', profile.id)) ?? '{}',
            ),
            'recentSearches': jsonDecode(
              _string(_key('recentSearches', profile.id)) ?? '[]',
            ),
          },
      },
    });
    if (utf8.encode(content).length > 8 * 1024 * 1024) {
      throw StateError('备份超过 8 MiB 保存上限，请先整理记录；尚未写出备份文件');
    }
    validateBackup(content);
    return content;
  }

  Map<String, dynamic> validateBackup(String content) {
    if (utf8.encode(content).length > 8 * 1024 * 1024) {
      throw const FormatException('备份文件过大');
    }
    final data = jsonDecode(content) as Map<String, dynamic>;
    if (data['schema'] != 1 || data['app'] != 'zhenguojian') {
      throw const FormatException('不支持的备份格式');
    }
    final profiles = _readProfiles(data['profiles']);
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

  Future<void> _installBackup(Map<String, dynamic> data) async {
    final profiles = _readProfiles(data['profiles']);
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
      'themeMode': data['themeMode'] as String? ?? themeMode,
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
      'exportPosters': data['exportPosters'] == true,
      'forceLogin': data['forceLogin'] is bool
          ? data['forceLogin'] as bool
          : profiles.firstWhere((profile) => profile.admin).protected,
    };
    final libraries = data['libraries'] as Map;
    for (final profile in profiles) {
      final library = libraries[profile.id] as Map;
      values.addAll({
        _key('history', profile.id): jsonEncode(library['history']),
        _key('favorites', profile.id): jsonEncode(library['favorites']),
        _key('liveFavorites', profile.id): jsonEncode(
          library['liveFavorites'] ?? [],
        ),
        _key('liveHistory', profile.id): jsonEncode(
          library['liveHistory'] ?? [],
        ),
        _key('followStates', profile.id): jsonEncode(
          library['followStates'] ?? {},
        ),
        _key('mediaHistory', profile.id): jsonEncode(
          library['mediaHistory'] ?? {},
        ),
        _key('source', profile.id): library['source'] as String,
        _key('hideVip', profile.id): library['hideVip'] as bool,
        _key('playback', profile.id): jsonEncode(library['playback'] ?? {}),
        _key('downloadPreferences', profile.id): jsonEncode(
          library['downloadPreferences'] ?? {},
        ),
        if (fileStore != null)
          _key('seriesCandidates', profile.id): jsonEncode(
            library['seriesCandidates'] ?? [],
          ),
        _key('recentSearches', profile.id): jsonEncode(
          library['recentSearches'] ?? [],
        ),
      });
    }
    await _commit(values, replace: true);
    if (data['followSystemColor'] case final bool follow) {
      await preferences.setBool('followSystemColor', follow);
    }
    if (data['glassEffects'] case final bool glass) {
      await preferences.setBool('glassEffects', glass);
    }
    if (ThemeColor.byName(data['themeColor']) case final color?) {
      await preferences.setString('themeColor', color.name);
    }
    for (final key in preferences.getKeys().toList()) {
      if (key.startsWith('seriesCandidates.')) await preferences.remove(key);
    }
    for (final profile
        in fileStore == null ? profiles : const <LocalProfile>[]) {
      await _saveUserAux(
        'seriesCandidates',
        jsonEncode((libraries[profile.id] as Map)['seriesCandidates'] ?? []),
        profile.id,
      );
    }
    _profiles = profiles;
    _current = profiles.firstWhere((profile) => profile.admin).id;
    _configurationError = null;
    _locked = forceLogin && profile.protected;
    _loadSourceSwitches();
    _loadLibrary();
    _loadSeriesCandidates();
    _epoch++;
    _notify();
  }

  Future<void> importBackup(String content) => _queue(() async {
    _requireAdmin();
    await _installBackup(validateBackup(content));
  });

  Future<void> recoverBackup(String content, {required String pin}) =>
      _queue(() async {
        if (_configurationError == null) throw StateError('请从设置中恢复备份');
        final data = validateBackup(content);
        LocalProfile? originalAdmin;
        try {
          final identity = await fileStore?.readIdentity();
          final raw = preferences.getString(LocalSnapshot.storageKey);
          final values = raw == null
              ? null
              : (jsonDecode(raw) as Map)['values'] as Map;
          final records =
              jsonDecode(
                    (identity?['profiles'] as String?) ??
                        (values?['profiles'] as String?) ??
                        preferences.getString('profiles') ??
                        '[]',
                  )
                  as List;
          for (final row in records) {
            if (row is Map && row['admin'] == true) {
              originalAdmin = LocalProfile.fromJson(
                Map<String, dynamic>.from(row),
              );
            }
          }
        } catch (_) {}
        final backupAdmin = _readProfiles(
          data['profiles'],
        ).firstWhere((profile) => profile.admin);
        final verifier = originalAdmin?.protected == true
            ? originalAdmin!
            : backupAdmin;
        if (!verifier.protected) throw StateError('无法验证管理员身份，请使用包含管理员密码的备份恢复');
        await _checkPin(verifier, pin);
        _snapshot ??= LocalSnapshot.empty(preferences, files: fileStore);
        await _installBackup(data);
      });

  String exportRecoveryData() {
    if (_configurationError == null) throw StateError('请从设置中导出备份');
    return jsonEncode({
      'app': 'zhenguojian',
      'recovery': true,
      'values': {
        for (final key in preferences.getKeys())
          if (LocalSnapshot.owns(key) || key == LocalSnapshot.storageKey)
            key: preferences.get(key),
      },
      if (fileStore != null) 'files': fileStore!.recoveryFiles(),
    });
  }

  Future<void> reload() => _queue(() async {
    // 先把手上的进度写下去，再重新读取磁盘，避免挂起内容被丢掉。
    await _flushWatch().catchError((Object _) {});
    final previousProfiles = _configurationError == null
        ? _string('profiles')
        : null;
    final previousId = _current;
    final previousLocked = locked;
    await preferences.reload();
    try {
      await fileStore?.load();
      fileStore?.loadError = null;
    } catch (error) {
      fileStore?.loadError = error;
    }
    _initialize();
    if (_configurationError == null &&
        previousProfiles == _string('profiles') &&
        previousId == _current) {
      _locked = previousLocked;
    } else {
      _epoch++;
    }
    _notify();
  });

  Future<void> _queue(Future<void> Function() action) {
    _writes = _writes.catchError((Object _) {}).then((_) => action());
    return _writes;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 单个字段的解析记忆化：原始字符串没变就不再 jsonDecode。
///
/// 这些偏好与列表会在 build、筛选与每轮轮询里被反复读取，每次都重新解析一份
/// JSON 只是白费 CPU。保存过字段或换了用户，原始字符串必然变化，缓存随之失效。
class _ParsedField<T> {
  String? _raw;
  T? _value;
  bool _filled = false;

  T read(String? raw, T Function(String? raw) parse) {
    if (!_filled || raw != _raw) {
      _raw = raw;
      _value = parse(raw);
      _filled = true;
    }
    return _value as T;
  }
}

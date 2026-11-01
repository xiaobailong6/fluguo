import 'history_retention.dart';
import 'live_history.dart';
import 'local_store.dart';
import 'models.dart';
import 'catalog_sort.dart';

enum HistoryKind { all, drama, live }

/// 混合列表身份带类型前缀，绝不把直播房间当作短剧存储或续播。
class RecentEntry {
  const RecentEntry.drama(WatchEntry entry) : watch = entry, live = null;
  const RecentEntry.live(LiveHistoryEntry entry) : live = entry, watch = null;
  final WatchEntry? watch;
  final LiveHistoryEntry? live;
  String get key =>
      live == null ? 'drama:${watch!.drama.id}' : 'live:${live!.key}';
  String get title => live?.room.title ?? watch!.drama.title;
  DateTime get updatedAt => live?.updatedAt ?? watch!.updatedAt;
  String get sourceKey => live == null
      ? 'drama:${watch!.drama.source}'
      : 'live:${live!.platformId}';
  bool matches(String query) =>
      matchesTitle(title, query) ||
      (live != null && matchesTitle(live!.room.anchor, query));
}

final _historyCaches = Expando<RecentHistoryCache>();

/// 只缓存排序结果；仍由 Store 判定权限和滚动保留期限，避免另造时钟。
class RecentHistoryCache {
  WeakReference<LocalStore>? _store;
  Object? _contents;
  DateTime? _readAt;
  DateTime? _validUntil;
  List<RecentEntry> _sorted = const [];

  List<RecentEntry> read(LocalStore store) {
    final state = store.recentHistoryState();
    if (identical(_store?.target, store) &&
        _contents == state.contents &&
        _readAt != null &&
        !state.now.isBefore(_readAt!) &&
        (_validUntil == null || !state.now.isAfter(_validUntil!))) {
      return _sorted;
    }
    final entries = <RecentEntry>[
      ...store.history.map(RecentEntry.drama),
      ...store.liveHistory.map(RecentEntry.live),
    ];
    _store = WeakReference(store);
    _contents = state.contents;
    _readAt = state.now;
    _validUntil = null;
    for (final entry in entries) {
      final expiry = entry.updatedAt.add(watchHistoryRetention);
      if (_validUntil == null || expiry.isBefore(_validUntil!)) {
        _validUntil = expiry;
      }
    }
    entries.sort((a, b) {
      final time = b.updatedAt.compareTo(a.updatedAt);
      return time == 0 ? a.key.compareTo(b.key) : time;
    });
    return _sorted = List.unmodifiable(entries);
  }
}

List<RecentEntry> recentHistory(
  LocalStore store, {
  HistoryKind kind = HistoryKind.all,
}) {
  final cache = _historyCaches[store] ??= RecentHistoryCache();
  final entries = cache.read(store);
  return kind == HistoryKind.all
      ? entries
      : entries.where((entry) => matchesHistoryKind(entry, kind)).toList();
}

bool matchesHistoryKind(RecentEntry entry, HistoryKind kind) => switch (kind) {
  HistoryKind.all => true,
  HistoryKind.drama => entry.watch != null,
  HistoryKind.live => entry.live != null,
};

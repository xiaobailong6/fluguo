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

List<RecentEntry> recentHistory(
  LocalStore store, {
  HistoryKind kind = HistoryKind.all,
}) {
  final entries = <RecentEntry>[
    if (kind != HistoryKind.live) ...store.history.map(RecentEntry.drama),
    if (kind != HistoryKind.drama) ...store.liveHistory.map(RecentEntry.live),
  ];
  entries.sort((a, b) {
    final time = b.updatedAt.compareTo(a.updatedAt);
    return time == 0 ? a.key.compareTo(b.key) : time;
  });
  return entries;
}

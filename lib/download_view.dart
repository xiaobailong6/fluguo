import 'package:flutter/foundation.dart';

import 'download_collections.dart';
import 'download_snapshot.dart';
import 'merge_queue.dart';
import 'models.dart';

typedef DownloadView = ({
  List<DownloadJob> pending,
  List<DownloadedDrama> downloaded,
  List<MergedVideo> merged,
  List<MergeTask> tasks,
  Set<String> selectable,
  List<SourceSite> sources,
  String source,
  Set<String>? selection,
});

String mergeTaskSelectionKey(MergeTask task) => 'task:${task.id}';

/// 仅派生活跃页签。jobs 为不可变快照；权限和可变 MergeTask 每次读取，
/// 不以回调或 tasks 列表身份推断它们没有变化。
class DownloadViewProjection {
  List<DownloadJob>? _jobs;
  List<DownloadJob>? _pending;
  List<DownloadJob>? _completed;
  List<DownloadedDrama> _downloaded = const [];
  List<DownloadJob>? _archive;
  Map<String, int> _pendingCounts = const {};
  bool _archiveChecked = false;
  int pendingCount = 0, downloadedCount = 0;

  @visibleForTesting
  int pendingComputations = 0, archiveComputations = 0, projections = 0;

  List<DownloadJob> get pending {
    if (_pending == null) {
      pendingComputations++;
      _pending = pendingDownloads(_jobs ?? const []);
    }
    return _pending!;
  }

  List<DownloadJob> get completed => _completed ??= [
    for (final job in _jobs ?? const <DownloadJob>[])
      if (job.completed) job,
  ];

  List<DownloadedDrama> get downloaded {
    if (_archiveChecked) return _downloaded;
    _archiveChecked = true;
    final counts = <String, int>{};
    for (final job in _jobs ?? const <DownloadJob>[]) {
      if (!job.completed && job.state != 'removing') {
        counts.update(job.drama.id, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final archive = completed;
    // 下载活动（包括新的2秒快照）不改变归档时，复用整个分组与排序结果。
    final previous = _archive;
    final same =
        previous != null &&
        previous.length == archive.length &&
        Iterable<int>.generate(
          archive.length,
        ).every((i) => sameDownload(previous[i], archive[i]));
    if (!same) {
      archiveComputations++;
      _downloaded = downloadedDramas(_jobs ?? const []);
    } else if (!mapEquals(counts, _pendingCounts)) {
      // 仅未完成数量变化时不重排已归档分集，未受影响的海报数据也复用。
      _downloaded = [
        for (final item in _downloaded)
          if (item.pending == (counts[item.drama.id] ?? 0))
            item
          else
            DownloadedDrama(
              item.drama,
              item.episodes,
              counts[item.drama.id] ?? 0,
            ),
      ];
    }
    _archive = archive;
    _pendingCounts = counts;
    return _downloaded;
  }

  void invalidate() {
    _jobs = null;
    _archive = null;
    _pending = null;
    _completed = null;
    _archiveChecked = false;
  }

  void _accept(List<DownloadJob> jobs) {
    if (identical(_jobs, jobs)) return;
    _jobs = jobs;
    _pending = null;
    _completed = null;
    _archiveChecked = false;
    pendingCount = 0;
    final dramas = <String>{};
    for (final job in jobs) {
      if (job.completed) {
        dramas.add(job.drama.id);
      } else if (job.state != 'removing' || job.error.isNotEmpty) {
        pendingCount++;
      }
    }
    downloadedCount = dramas.length;
  }

  /// 兼容需要全部派生结果的调用；页面 project 不走这条急切路径。
  void derive(List<DownloadJob> jobs) {
    _accept(jobs);
    pending;
    downloaded;
    completed;
  }

  DownloadView project({
    required List<DownloadJob> jobs,
    required List<MergedVideo> videos,
    required List<MergeTask> tasks,
    required bool canDownload,
    required bool Function(String source) allowsSource,
    required int tab,
    required String selectedSource,
    required Set<String>? selection,
  }) {
    projections++;
    _accept(jobs);
    bool allowed(Drama drama) => canDownload && allowsSource(drama.source);
    var shownPending = const <DownloadJob>[];
    var shownDownloaded = const <DownloadedDrama>[];
    var shownMerged = const <MergedVideo>[];
    var shownTasks = const <MergeTask>[];
    final siteIds = <String>{};
    switch (tab) {
      case 0:
        shownPending = [
          for (final job in pending)
            if (allowed(job.drama)) job,
        ];
        siteIds.addAll(shownPending.map((job) => job.drama.source));
      case 1:
        shownDownloaded = [
          for (final item in downloaded)
            if (allowed(item.drama)) item,
        ];
        siteIds.addAll(shownDownloaded.map((item) => item.drama.source));
      default:
        shownMerged = [
          for (final video in videos)
            if (allowed(video.drama)) video,
        ];
        shownTasks = [
          for (final task in tasks.reversed)
            if (task.state != MergeState.done && allowed(task.drama)) task,
        ];
        siteIds.addAll(shownMerged.map((video) => video.drama.source));
        siteIds.addAll(shownTasks.map((task) => task.drama.source));
    }
    final sources = [
      for (final site in SourceSite.values)
        if (siteIds.contains(site.id)) site,
    ];
    final source = sources.any((site) => site.id == selectedSource)
        ? selectedSource
        : '';
    if (source.isNotEmpty) {
      shownPending = shownPending
          .where((job) => job.drama.source == source)
          .toList();
      shownDownloaded = shownDownloaded
          .where((item) => item.drama.source == source)
          .toList();
      shownMerged = shownMerged
          .where((video) => video.drama.source == source)
          .toList();
      shownTasks = shownTasks
          .where((task) => task.drama.source == source)
          .toList();
    }
    final selectable = switch (tab) {
      0 => {for (final job in shownPending) job.id},
      1 => {for (final item in shownDownloaded) item.drama.id},
      _ => {
        for (final task in shownTasks) mergeTaskSelectionKey(task),
        for (final video in shownMerged) video.id,
      },
    };
    return (
      pending: shownPending,
      downloaded: shownDownloaded,
      merged: shownMerged,
      tasks: shownTasks,
      selectable: selectable,
      sources: sources,
      source: source,
      selection: selection?.intersection(selectable),
    );
  }
}

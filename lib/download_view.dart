import 'download_collections.dart';
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

/// 下载页的数据投影，不负责监听、导航或执行删除。权限从每次调用传入，
/// 只有 jobs 的纯派生按列表身份缓存，不能缓存用户权限或可变合并任务状态。
class DownloadViewProjection {
  List<DownloadJob>? _jobs;
  List<DownloadJob> pending = const [];
  List<DownloadedDrama> downloaded = const [];
  List<DownloadJob> completed = const [];

  void invalidate() => _jobs = null;

  void derive(List<DownloadJob> jobs) {
    if (identical(_jobs, jobs)) return;
    _jobs = jobs;
    pending = pendingDownloads(jobs);
    downloaded = downloadedDramas(jobs);
    completed = [
      for (final job in jobs)
        if (job.completed) job,
    ];
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
    derive(jobs);
    final merged = canDownload
        ? videos.where((video) => allowsSource(video.drama.source)).toList()
        : <MergedVideo>[];
    final sources = tab == 2
        ? _mergedSources(merged, tasks, canDownload, allowsSource)
        : downloadSources(tab == 0 ? pending : completed);
    final source = sources.any((site) => site.id == selectedSource)
        ? selectedSource
        : '';
    bool shown(Drama drama) => source.isEmpty || drama.source == source;
    final shownPending = [
      for (final job in pending)
        if (shown(job.drama)) job,
    ];
    final shownDownloaded = [
      for (final item in downloaded)
        if (shown(item.drama)) item,
    ];
    final shownMerged = [
      for (final video in merged)
        if (shown(video.drama)) video,
    ];
    final shownTasks = tab == 2
        ? tasks.reversed
              .where(
                (task) =>
                    task.state != MergeState.done &&
                    allowsSource(task.drama.source) &&
                    shown(task.drama),
              )
              .toList()
        : const <MergeTask>[];
    // 三页签分别使用分集、剧集和合并任务/成品身份，保持原全选与删除契约。
    final taskKeys = {
      for (final task in shownTasks) mergeTaskSelectionKey(task),
    };
    final selectable = switch (tab) {
      0 => {for (final job in shownPending) job.id},
      1 => {for (final item in shownDownloaded) item.drama.id},
      _ => {...taskKeys, for (final video in shownMerged) video.id},
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

  List<SourceSite> _mergedSources(
    List<MergedVideo> merged,
    List<MergeTask> tasks,
    bool canDownload,
    bool Function(String) allowsSource,
  ) {
    final siteIds = <String>{
      for (final video in merged) video.drama.source,
      if (canDownload)
        for (final task in tasks)
          if (task.state != MergeState.done && allowsSource(task.drama.source))
            task.drama.source,
    };
    return [
      for (final site in SourceSite.values)
        if (siteIds.contains(site.id)) site,
    ];
  }
}

import 'package:flutter/material.dart';
import '../app_motion.dart';

import '../../download_collections.dart';
import '../../download_converter.dart';
import '../../download_overview.dart';
import '../../download_view.dart';
import '../../download_ui_signals.dart';
import '../../local_store.dart';
import '../../merge_queue.dart';
import '../../merged_playback.dart';
import '../../merged_export.dart';
import '../../download_merge.dart' show episodeRanges;
import '../../models.dart';
import '../app_scope.dart';
import '../shell/app_shell.dart';
import '../widgets/cover_image.dart';
import '../widgets/drama_grid.dart';
import '../widgets/drama_tile.dart';
import '../widgets/focus_ring.dart';
import '../widgets/follow_pager.dart';
import '../widgets/status_view.dart';
import '../widgets/glass/glass_surface.dart';
import '../theme/glass_style.dart';
import '../widgets/app_notice.dart';
import '../widgets/glass/glass_dialog.dart';
import '../widgets/poster_menu.dart';
import '../player/playback_handle.dart';
import '../player/playback_page.dart';
import 'merge_actions.dart';
import 'download_actions.dart';
import 'downloaded_drama_page.dart';

typedef _View = DownloadView;

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({
    super.key,
    required this.store,
    required this.downloads,
    required this.converter,
    required this.merges,
  });
  final LocalStore store;
  final DownloadOverview downloads;
  final DownloadConverter converter;
  final MergeQueue merges;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage>
    with TickerProviderStateMixin {
  late TabController _tabs = TabController(length: 3, vsync: this)
    ..addListener(_tabChanged);
  int _lastTabIndex = 0;
  final _sources = ['', '', ''];
  final _scrolls = List.generate(3, (_) => ScrollController());
  Set<String>? _selection;
  bool _busy = false;
  bool _playing = false;

  /// 正在导出的成品 ID：导出期间不允许删除，避免删掉正在读取的源文件。
  final _exporting = <String>{};
  late int _profileEpoch;

  final _projection = DownloadViewProjection();

  /// 合并监听只建一次。每次重建都新建会让 ListenableBuilder 在
  /// didUpdateWidget 里把整组监听器摘下再挂上，而下载总览每 2 秒就通知一次，
  /// 这个开销会持续发生。父级换了实例时在 didUpdateWidget 里重建。
  late Listenable _merged = _mergeSources();

  Listenable _mergeSources() => Listenable.merge([
    widget.store,
    widget.downloads.ui.structure,
    widget.converter.autoExporter,
    widget.merges.ui.structure,
    _tabs,
  ]);

  bool get _pendingTab => _tabs.index == 0;

  @override
  void initState() {
    super.initState();
    _profileEpoch = widget.store.profileEpoch;
    widget.downloads.refresh();
    widget.merges.ui.structure.addListener(_mergeChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = AppMotion.duration(context, AppMotion.enter);
    if (_tabs.animationDuration == duration) return;
    final previous = _tabs;
    previous.removeListener(_tabChanged);
    _tabs = TabController(
      length: 3,
      vsync: this,
      initialIndex: previous.index,
      animationDuration: duration,
    )..addListener(_tabChanged);
    _merged = _mergeSources();
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  @override
  void dispose() {
    _tabs.dispose();
    for (final scroll in _scrolls) {
      scroll.dispose();
    }
    widget.merges.ui.structure.removeListener(_mergeChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(DownloadsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final storeChanged = !identical(oldWidget.store, widget.store);
    if (!storeChanged &&
        identical(oldWidget.downloads, widget.downloads) &&
        identical(oldWidget.converter, widget.converter) &&
        identical(oldWidget.merges, widget.merges)) {
      return;
    }
    if (!identical(oldWidget.merges, widget.merges)) {
      oldWidget.merges.ui.structure.removeListener(_mergeChanged);
      widget.merges.ui.structure.addListener(_mergeChanged);
    }
    _merged = _mergeSources();
    // 新总览可能持有另一份列表：派生缓存按身份失效，否则会沿用旧结果。
    _projection.invalidate();
    if (storeChanged) {
      _profileEpoch = widget.store.profileEpoch;
      _selection = null;
    }
  }

  void _tabChanged() {
    // index 在切页开始时就已更新；动画结束的第二次通知不能清掉新页的选择。
    if (_tabs.index == _lastTabIndex) return;
    _lastTabIndex = _tabs.index;
    setState(() => _selection = null);
  }

  static String _taskKey(MergeTask task) => mergeTaskSelectionKey(task);

  /// 失败提示只发一次；网格由 build 里的 ListenableBuilder 负责重建，这里不重复 setState。
  final _announced = <int>{};
  void _mergeChanged() {
    if (!mounted) return;
    for (final task in widget.merges.tasks) {
      if (task.state != MergeState.failed || !_announced.add(task.id)) continue;
      if (widget.store.allowsSource(task.drama.source)) {
        showMessage(context, '合并失败，点击「已合并」中的海报查看原因或重试');
      }
    }
  }

  void _toggle(String id) => setState(() {
    final selection = {...?_selection};
    if (!selection.remove(id)) selection.add(id);
    _selection = selection;
  });

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      await widget.downloads.refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _control(DownloadJob job) => _run(() async {
    if (job.converting) {
      widget.converter.retry(job.id);
      return;
    }
    await AppScope.of(context).repository.controlDownloads(
      job.state == 'removing'
          ? 'remove'
          : job.active
          ? 'pause'
          : 'resume',
      id: job.id,
    );
  });

  void _controlAll(String command, List<DownloadJob> jobs) => _run(() async {
    final repository = AppScope.of(context).repository;
    final result = await controlDownloadJobs(repository, command, [
      for (final job in jobs) job.id,
    ]);
    if (result.failures.isNotEmpty && mounted) {
      showMessage(
        context,
        '${result.failures.length} 集未能处理：${result.failures.values.first}',
      );
    }
  });

  Future<void> _cancel(Set<String> ids) async {
    if (ids.isEmpty ||
        !await confirmRemoval(
          context,
          title: '取消下载 ${ids.length} 集？',
          message: '已下载的部分会一起删除。',
          action: '取消下载',
        ) ||
        !mounted) {
      return;
    }
    await _run(() => removeDownloads(context, ids.toList(), done: '已取消下载'));
    if (mounted) setState(() => _selection = null);
  }

  _View _viewFor(int index) => _projection.project(
    jobs: widget.downloads.structureJobs,
    videos: widget.merges.library.videos,
    tasks: widget.merges.tasks,
    canDownload: widget.store.canDownload,
    allowsSource: widget.store.allowsSource,
    tab: index,
    selectedSource: _sources[index],
    selection: index == _tabs.index ? _selection : null,
  );

  Widget _page(BuildContext context, int index, _View view) {
    final content = switch (index) {
      0 => _pendingList(context, view),
      1 => _downloadedGrid(context, view),
      _ => _mergeList(context, view),
    };
    final exportError = widget.store.autoExport && widget.store.canDownload
        ? widget.converter.autoExporter.error
        : null;
    if (index != 1 || exportError == null) return content;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('自动导出未完成，App 内分集已保留'),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => showGlassDialog<void>(
                      context,
                      builder: (context) => GlassDialogBody(
                        title: '自动导出未完成',
                        content: SelectableText(exportError),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('查看原因'),
                  ),
                  TextButton(
                    onPressed: widget.converter.autoExporter.exporting
                        ? null
                        : widget.converter.autoExporter.retry,
                    child: const Text('重试自动导出'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(child: content),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _merged,
    builder: (context, _) {
      trackDownloadBuild('page');
      if (_profileEpoch != widget.store.profileEpoch) {
        _profileEpoch = widget.store.profileEpoch;
        _selection = null;
      }
      final index = _tabs.index;
      final view = _viewFor(index);
      final form = AppScope.formFactorOf(context);
      final touch = form == FormFactor.phone || form == FormFactor.pad;
      final body = !widget.downloads.available
          ? const StatusView(
              title: '当前用户没有下载权限',
              icon: Icons.lock_outline_rounded,
            )
          : touch
          ? TabBarView(
              key: ValueKey(widget.store.profileEpoch),
              controller: _tabs,
              physics: _selection == null && !_busy
                  ? null
                  : const NeverScrollableScrollPhysics(),
              children: [
                for (var page = 0; page < _tabs.length; page++)
                  PagerScrollScope(
                    key: ValueKey(('download-page', page)),
                    active: page == index,
                    child: _page(
                      context,
                      page,
                      page == index ? view : _viewFor(page),
                    ),
                  ),
              ],
            )
          : _page(context, index, view);
      return PopScope(
        canPop: _selection == null && !_busy,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !_busy) setState(() => _selection = null);
        },
        child: AppScope.formFactorOf(context) == FormFactor.phone
            ? _phone(context, view, body)
            : _wide(context, view, body),
      );
    },
  );

  Widget _textButton(String label, VoidCallback? onPressed, {IconData? icon}) =>
      FocusRing(
        radius: 20,
        child: icon == null
            ? TextButton(onPressed: onPressed, child: Text(label))
            : TextButton.icon(
                onPressed: onPressed,
                icon: Icon(icon, size: 18),
                label: Text(label),
              ),
      );

  Widget _pauseAll(_View view, {bool icon = true}) {
    final active = [
      for (final job in view.pending)
        if (job.active) job,
    ];
    return _textButton(
      '全部暂停',
      active.isEmpty || _busy ? null : () => _controlAll('pause', active),
      icon: icon ? Icons.pause_rounded : null,
    );
  }

  Widget _resumeAll(_View view, {bool icon = true}) {
    final paused = [
      for (final job in view.pending)
        if (job.resumable) job,
    ];
    return _textButton(
      '全部继续',
      paused.isEmpty || _busy ? null : () => _controlAll('resume', paused),
      icon: icon ? Icons.play_arrow_rounded : null,
    );
  }

  Widget _editButton(_View view, {bool icon = true}) => _textButton(
    '编辑',
    view.selectable.isEmpty || _busy
        ? null
        : () => setState(() => _selection = {}),
    icon: icon ? Icons.check_box_outlined : null,
  );

  Widget _selectAll(_View view) {
    final all = view.selectable;
    final everything = all.isNotEmpty && all.every(view.selection!.contains);
    return _textButton(
      everything ? '取消全选' : '全选',
      all.isEmpty || _busy
          ? null
          : () => setState(() => _selection = everything ? {} : {...all}),
    );
  }

  Widget _cancelButton(_View view) {
    final colors = Theme.of(context).colorScheme;
    final selection = view.selection!;
    return FocusRing(
      radius: 20,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: colors.error,
          foregroundColor: colors.onError,
        ),
        onPressed: selection.isEmpty || _busy
            ? null
            : () => _pendingTab ? _cancel(selection) : _deleteSelected(view),
        icon: Icon(
          _pendingTab ? Icons.close_rounded : Icons.delete_outline_rounded,
          size: 18,
        ),
        label: Text(_pendingTab ? '取消下载' : '删除 ${selection.length} 部'),
      ),
    );
  }

  Widget _tabBar(double inset) {
    final pending = _projection.pendingCount;
    final downloaded = _projection.downloadedCount;
    final merged = widget.store.canDownload
        ? widget.merges.library.videos
              .where((video) => widget.store.allowsSource(video.drama.source))
              .length
        : 0;
    final failed = widget.store.canDownload
        ? widget.merges.tasks
              .where(
                (task) =>
                    task.state == MergeState.failed &&
                    widget.store.allowsSource(task.drama.source),
              )
              .length
        : 0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: IgnorePointer(
        ignoring: _busy,
        child: ExcludeFocus(
          excluding: _busy,
          child: TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
            tabs: [
              Tab(text: pending == 0 ? '下载中' : '下载中 $pending'),
              Tab(text: downloaded == 0 ? '已下载' : '已下载 $downloaded'),
              Tab(
                text:
                    '${merged == 0 ? '已合并' : '已合并 $merged'}'
                    '${failed == 0 ? '' : ' · 失败 $failed'}',
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _allowed(int epoch, String source) =>
      mounted &&
      widget.store.profileEpoch == epoch &&
      widget.store.canDownload &&
      widget.store.allowsSource(source);

  Future<void> _showDownloadedMenu(
    DownloadedDrama item,
    Offset anchor,
    _View view,
  ) async {
    if (_busy || _selection != null) return;
    final epoch = widget.store.profileEpoch;
    final action = await showPosterMenu(context, anchor, const [
      PosterMenuItem('merge', '合并剧集', Icons.merge_rounded),
      PosterMenuItem('delete', '删除剧集', Icons.delete_outline_rounded),
    ]);
    if (!mounted || !_allowed(epoch, item.drama.source)) return;
    if (action == 'delete') {
      await _deleteSelected(view, only: {item.drama.id});
      return;
    }
    if (action != 'merge') return;
    // 弹层打开期间任务可能变化，重新取快照；不使用旧列表误合并半成品。
    _projection.derive(widget.downloads.jobs);
    final current = _projection.downloaded
        .where((value) => value.drama.id == item.drama.id)
        .firstOrNull;
    if (current == null) {
      if (!mounted) return;
      showMessage(context, '没有可合并的已下载分集');
      return;
    }
    await _run(() async {
      await enqueueMerges(context, widget.merges, [current.episodes]);
    });
  }

  /// 删除前的阻塞原因：成品在导出、或分集正被合并任务占用。
  ///
  /// 两个检查点（确认前、确认后）共用同一条判定，避免以后只改一处而分叉；
  /// 合并提示按阶段区分措辞——确认前是"正在合并"，确认后是"已开始合并"。
  /// 返回 null 表示可以继续。
  String? _deleteBlocker({
    required bool mergedTab,
    required Set<String> videoIds,
    required List<DownloadJob> selectedJobs,
    required bool afterConfirm,
  }) {
    if (mergedTab && videoIds.any(_exporting.contains)) {
      return '所选成品仍在导出，请等待完成后再删除';
    }
    if (!mergedTab &&
        selectedJobs.any((job) => widget.merges.usesDownload(job.id))) {
      return afterConfirm ? '所选分集已开始合并，请先取消任务再删除' : '所选分集正在合并，请等待完成或先取消合并任务';
    }
    return null;
  }

  Future<void> _deleteSelected(_View view, {Set<String>? only}) async {
    final chosen = only ?? view.selection;
    if (_busy || chosen == null || chosen.isEmpty) return;
    final mergedTab = _tabs.index == 2;
    final ids = <String>{...chosen};
    // 合并任务用 task: 前缀，成品用自身 ID；两者分开处理。
    final taskIds = {
      for (final id in ids)
        if (id.startsWith('task:')) id,
    };
    final videoIds = ids.difference(taskIds);
    final epoch = widget.store.profileEpoch;
    final repository = AppScope.of(context).repository;
    final selectedJobs = [
      for (final item in view.downloaded)
        if (ids.contains(item.drama.id)) ...item.episodes,
    ];
    setState(() => _busy = true);
    try {
      final blocker = _deleteBlocker(
        mergedTab: mergedTab,
        videoIds: videoIds,
        selectedJobs: selectedJobs,
        afterConfirm: false,
      );
      if (blocker != null) {
        showMessage(context, blocker);
        return;
      }
      final confirmed = await confirmRemoval(
        context,
        title: mergedTab
            ? (videoIds.isEmpty
                  ? '取消 ${taskIds.length} 个合并任务？'
                  : '删除 ${ids.length} 项？')
            : '删除 ${ids.length} 部已下载剧集？',
        message: mergedTab
            ? (videoIds.isEmpty
                  ? '正在合并的任务会被中断，已完成的成品保留。'
                  : '取消所选合并任务；成品只删 App 内文件，原分集和已导出副本保留。')
            : '删除所选剧的已完成分集。下载中/处理中的分集、合并视频和已导出副本保留。',
        action: '删除',
      );
      if (!confirmed ||
          !mounted ||
          widget.store.profileEpoch != epoch ||
          !widget.store.canDownload) {
        return;
      }
      final recheck = _deleteBlocker(
        mergedTab: mergedTab,
        videoIds: videoIds,
        selectedJobs: selectedJobs,
        afterConfirm: true,
      );
      if (recheck != null) {
        showMessage(context, recheck);
        return;
      }
      final failed = <String>{};
      if (mergedTab) {
        final allowedIds = {
          for (final video in view.merged)
            if (videoIds.contains(video.id) &&
                widget.store.allowsSource(video.drama.source))
              video.id,
        };
        for (final task in view.tasks) {
          if (taskIds.contains(_taskKey(task))) widget.merges.forget(task);
        }
        // 仅隐藏任务时无需等待成品库，原生退出期间由 usesDownload 保护分集。
        final errors = allowedIds.isEmpty
            ? <String, String>{}
            : await widget.merges.library.remove(allowedIds);
        failed.addAll(errors.keys);
        if (mounted) {
          showMessage(
            context,
            errors.isNotEmpty
                ? '${errors.length} 部未能删除：${errors.values.first}'
                : videoIds.isEmpty
                ? '已取消合并任务'
                : taskIds.isEmpty
                ? '已删除合并视频'
                : '已取消合并任务并删除成品',
          );
        }
      } else {
        final latest = {
          for (final job in widget.downloads.jobs)
            if (job.completed) job.id,
        };
        final safe = selectedJobs
            .where(
              (job) =>
                  latest.contains(job.id) &&
                  widget.store.allowsSource(job.drama.source),
            )
            .toList();
        final result = await controlDownloadJobs(repository, 'remove', [
          for (final job in safe) job.id,
        ]);
        failed.addAll(
          safe
              .where((job) => result.failures.containsKey(job.id))
              .map((job) => job.drama.id),
        );
        await widget.downloads.refresh();
        if (mounted) {
          showMessage(
            context,
            result.failures.isEmpty
                ? '已删除所选已下载分集'
                : '${result.failures.length} 集未能删除：${result.failures.values.first}',
          );
        }
      }
      if (mounted && widget.store.profileEpoch == epoch) {
        setState(() => _selection = failed.isEmpty ? null : failed);
      }
    } catch (error) {
      if (mounted) showMessage(context, '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 已合并海报的三点菜单：导出（仅 Android）与删除成品；合并不再自动导出。
  Future<void> _showMergedMenu(
    MergedVideo video,
    Offset anchor,
    _View view,
  ) async {
    if (_busy || _selection != null || _exporting.contains(video.id)) return;
    final epoch = widget.store.profileEpoch;
    final action = await showPosterMenu(context, anchor, [
      if (mergedExportSupported)
        const PosterMenuItem(
          'export',
          '导出到 Movies',
          Icons.drive_folder_upload_outlined,
        ),
      const PosterMenuItem('delete', '删除', Icons.delete_outline_rounded),
    ]);
    if (!mounted || !_allowed(epoch, video.drama.source)) return;
    if (action == 'delete') {
      await _deleteSelected(view, only: {video.id});
      return;
    }
    if (action != 'export') return;
    final notice = AppNotice.of(context);
    setState(() => _exporting.add(video.id));
    try {
      notice.show(
        await exportMergedVideo(
          widget.merges.library,
          video,
          checkAccess: () {
            if (!_allowed(epoch, video.drama.source)) {
              throw StateError('用户或权限已变更，已停止导出');
            }
          },
        ),
      );
    } catch (error) {
      if (mounted) notice.show('$error');
    } finally {
      if (mounted) setState(() => _exporting.remove(video.id));
    }
  }

  Future<void> _playMerged(MergedVideo video) async {
    if (_playing || _busy || !widget.store.canDownload) return;
    final epoch = widget.store.profileEpoch;
    _playing = true;
    try {
      final original = AppScope.of(context).repository;
      await widget.merges.library.fileFor(video);
      if (!_allowed(epoch, video.drama.source)) return;
      final repository = MergedPlaybackRepository(
        widget.merges.library,
        video,
        widget.store,
        original,
      );
      final historyId = 'merged:${video.id}';
      final watch = widget.store.mediaWatched(historyId);
      final position = watch != null && !watch.finished ? watch.position : 0.0;
      final handle = PlaybackHandle(
        repository: repository,
        store: widget.store,
        detail: repository.playbackDetail(),
        index: 0,
        position: position,
        preopen: false,
        mediaHistoryId: historyId,
      );
      if (!mounted) return;
      final scope = AppScope.of(context);
      await openPage<void>(
        context,
        (_) => AppScope(
          repository: repository,
          formFactor: scope.formFactor,
          systemColorAvailable: scope.systemColorAvailable,
          glass: scope.glass,
          version: scope.version,
          child: PlaybackPage(store: widget.store, handle: handle),
        ),
        debugName: 'playback',
      );
    } catch (error) {
      if (mounted) showMessage(context, '$error');
    } finally {
      _playing = false;
    }
  }

  Widget _mergeList(BuildContext context, _View view) {
    final tasks = view.tasks;

    final error = widget.merges.library.error;
    if (tasks.isEmpty && view.merged.isEmpty) {
      return StatusView(
        title: error == null ? '还没有合并视频' : '无法读取合并视频',
        message: error == null ? '在「已下载」海报菜单选择合并；原分集会保留。' : '$error',
        icon: Icons.merge_rounded,
      );
    }
    final inset = AppScope.formFactorOf(context) == FormFactor.phone
        ? 16.0
        : 24.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - inset * 2;
        final (columns, gap, runGap) = _grid(context, width);
        final tile = (width - gap * (columns - 1)) / columns;
        final total = tasks.length + view.merged.length;
        return CustomScrollView(
          key: PageStorageKey(('merged', widget.store.profileEpoch)),
          controller: _scrolls[2],
          slivers: [
            if (error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(inset),
                  child: Text('$error'),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 8, inset, 32),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: gap,
                  mainAxisSpacing: runGap,
                  mainAxisExtent: ProgressPoster.extentFor(context, tile),
                ),
                itemCount: total,
                itemBuilder: (context, index) {
                  final task = index < tasks.length ? tasks[index] : null;
                  final video = task == null
                      ? view.merged[index - tasks.length]
                      : null;
                  return Focus(
                    key: ValueKey(
                      task != null ? 'merge-${task.id}' : 'merged-${video!.id}',
                    ),
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: (_, event) =>
                        wrapGridRow(index, columns, total, event),
                    child: task != null
                        ? ListenableBuilder(
                            listenable: widget.merges.ui.row(task.id),
                            builder: (_, _) => _taskPoster(task, view, tile),
                          )
                        : _videoPoster(video!, view, tile),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _taskPoster(MergeTask task, _View view, double tile) {
    trackDownloadBuild('merge:${task.id}');
    final failed = task.state == MergeState.failed;
    final selecting = view.selection != null;
    final menuEnabled = failed && !selecting && !_busy;
    final site = SourceSite.byId(task.drama.source).name;
    final status = task.cancelling || task.cleaning
        ? '取消中'
        : switch (task.state) {
            MergeState.queued => '等待合并',
            MergeState.running => '合并中',
            MergeState.failed => '合并失败',
            _ => '已取消',
          };
    return ProgressPoster(
      drama: task.drama,
      width: tile,
      progress: task.state == MergeState.running ? task.progress : null,
      inlineStatus: false,
      progressLabel: task.state == MergeState.running
          ? '${((task.progress ?? 0).clamp(0.0, .99) * 100).floor()}%'
          : null,
      caption:
          '第 ${episodeRanges([for (final job in task.jobs) job.episode.number])} 集',
      tag: site.isEmpty ? task.drama.source : site,
      status: status,
      statusError: failed,
      selected: selecting ? view.selection!.contains(_taskKey(task)) : null,
      showMenuButton: menuEnabled,
      menuTooltip: '失败任务菜单',
      onMore: menuEnabled
          ? (anchor) => _showFailedMergeMenu(task, anchor)
          : null,
      onLongPress: _busy || selecting
          ? null
          : () => setState(() => _selection = {}),
      onTap: _busy
          ? () {}
          : selecting
          ? () => _toggle(_taskKey(task))
          : () => _showTaskDetails(task),
    );
  }

  Future<void> _showFailedMergeMenu(MergeTask task, Offset anchor) async {
    if (_busy || _selection != null || task.state != MergeState.failed) return;
    final epoch = widget.store.profileEpoch;
    final action = await showPosterMenu(context, anchor, const [
      PosterMenuItem('delete', '删除', Icons.delete_outline_rounded),
    ]);
    if (!mounted ||
        action != 'delete' ||
        !_allowed(epoch, task.drama.source) ||
        !widget.merges.tasks.contains(task)) {
      return;
    }
    final confirmed = await confirmRemoval(
      context,
      title: '删除失败的合并任务？',
      message: '仅移除这次失败的合并任务，已下载的原分集和其他合并成品保留。',
      action: '删除',
    );
    if (!confirmed ||
        !_allowed(epoch, task.drama.source) ||
        task.state != MergeState.failed) {
      return;
    }
    widget.merges.forget(task);
  }

  Future<void> _showTaskDetails(MergeTask task) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => ListenableBuilder(
        listenable: widget.merges.ui.row(task.id),
        builder: (context, _) {
          final stopping = task.cancelling || task.cleaning;
          final running =
              task.state == MergeState.running ||
              task.state == MergeState.queued;
          final heading = stopping
              ? '取消中'
              : switch (task.state) {
                  MergeState.running => '正在合并',
                  MergeState.queued => '等待合并',
                  MergeState.done => '合并完成',
                  MergeState.failed => '合并失败',
                  MergeState.cancelled => '已取消合并',
                };
          return GlassSurface(
            role: GlassRole.panel,
            radius: GlassRadius.sheet,
            style: GlassStyleResolver.preset(context, GlassPreset.panel),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .8,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 12,
                    children: [
                      Text(
                        '$heading · ${task.drama.title}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '第 ${episodeRanges([for (final job in task.jobs) job.episode.number])} 集',
                      ),
                      if (running) ...[
                        Text(
                          task.state == MergeState.queued
                              ? '等待前面的任务完成'
                              : task.status,
                        ),
                        if (task.state == MergeState.running) ...[
                          // 只展示当前阶段，转换完成后才切换到合并进度。
                          _mergeStep(
                            context,
                            switch (task.phase) {
                              'checking' => '检查',
                              'converting' =>
                                '1 转换异常分集（${task.conversionCompleted}/${task.conversionTotal}）',
                              'saving' => '保存视频',
                              _ => task.needsConversion ? '2 合并视频' : '合并视频',
                            },
                            switch (task.phase) {
                              'checking' || 'saving' => null,
                              'converting' => task.conversionProgress,
                              _ => task.mergeProgress,
                            },
                          ),
                          const Text('查看进度或关闭面板不会取消任务。'),
                        ],
                      ] else
                        SelectableText(
                          task.message.isEmpty ? heading : task.message,
                        ),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        alignment: WrapAlignment.end,
                        children: [
                          if (running || stopping)
                            OutlinedButton(
                              onPressed: stopping
                                  ? null
                                  : () async {
                                      if (!mounted) return;
                                      final confirmed = await confirmRemoval(
                                        context,
                                        title: '取消合并任务？',
                                        message: '原分集会保留，重新合并需从头处理。',
                                        action: '取消合并',
                                      );
                                      if (!confirmed || !mounted) return;
                                      if (!task.finished &&
                                          !task.cancelling &&
                                          !task.cleaning) {
                                        widget.merges.cancel(task);
                                      }
                                    },
                              child: Text(
                                task.cleaning
                                    ? '清理中'
                                    : task.cancelling
                                    ? '正在取消'
                                    : '取消合并',
                              ),
                            ),
                          if (!stopping &&
                              (task.state == MergeState.failed ||
                                  task.state == MergeState.cancelled))
                            FilledButton(
                              onPressed: () {
                                Navigator.pop(sheetContext);
                                widget.merges.retry(task);
                              },
                              child: const Text('重新合并'),
                            ),
                          TextButton(
                            onPressed: () => Navigator.pop(sheetContext),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _mergeStep(BuildContext context, String title, double? progress) {
    final value = progress?.clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Text(title),
        if (value != null)
          Text(
            '${(value * 100).floor()}%',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        LinearProgressIndicator(value: value, semanticsLabel: title),
      ],
    );
  }

  Widget _videoPoster(MergedVideo video, _View view, double tile) {
    final idle = view.selection == null && !_busy;
    return ProgressPoster(
      drama: video.drama,
      width: tile,
      progress: null,
      caption:
          '第 ${episodeRanges(video.episodes)} 集 · ${formatBytes(video.bytes)}',
      tag: SourceSite.byId(video.drama.source).name,
      badge: '已合并',
      inlineStatus: false,
      menuTooltip: '成品菜单',
      showMenuButton: idle,
      selected: view.selection?.contains(video.id),
      onMore: idle ? (anchor) => _showMergedMenu(video, anchor, view) : null,
      onLongPress: _busy || view.selection != null
          ? null
          : () => setState(() => _selection = {}),
      onTap: _busy
          ? () {}
          : view.selection == null
          ? () => _playMerged(video)
          : () => _toggle(video.id),
    );
  }

  Widget _phone(BuildContext context, _View view, Widget body) {
    final selection = view.selection;
    return Scaffold(
      appBar: selection == null
          ? AppBar(
              title: const Text('下载'),
              actions: [
                if (_pendingTab && view.pending.isNotEmpty) ...[
                  IconButton(
                    tooltip: '全部暂停',
                    onPressed: view.pending.any((job) => job.active) && !_busy
                        ? () => _controlAll('pause', [
                            for (final job in view.pending)
                              if (job.active) job,
                          ])
                        : null,
                    icon: const Icon(Icons.pause_rounded),
                  ),
                  IconButton(
                    tooltip: '全部继续',
                    onPressed:
                        view.pending.any((job) => job.resumable) && !_busy
                        ? () => _controlAll('resume', [
                            for (final job in view.pending)
                              if (job.resumable) job,
                          ])
                        : null,
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
                  _editButton(view, icon: false),
                ] else if (!_pendingTab && view.selectable.isNotEmpty)
                  _editButton(view, icon: false),
                const SizedBox(width: 8),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: _tabBar(4),
              ),
            )
          : AppBar(
              leading: IconButton(
                tooltip: '退出编辑',
                onPressed: _busy
                    ? null
                    : () => setState(() => _selection = null),
                icon: const Icon(Icons.close_rounded),
              ),
              title: Text('已选择 ${selection.length} ${_pendingTab ? '集' : '部'}'),
              actions: [_selectAll(view), const SizedBox(width: 8)],
            ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?_sourceChips(view, inset: 16, scroll: true),
            Expanded(child: body),
          ],
        ),
      ),
      bottomNavigationBar: selection == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(height: 48, child: _cancelButton(view)),
              ),
            ),
    );
  }

  Widget _wide(BuildContext context, _View view, Widget body) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 24, 8),
            child: SizedBox(
              height: 48,
              child: Row(
                spacing: 8,
                children: [
                  if (view.selection == null)
                    const BackButton()
                  else
                    IconButton(
                      tooltip: '退出编辑',
                      onPressed: _busy
                          ? null
                          : () => setState(() => _selection = null),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        view.selection == null
                            ? '下载'
                            : '已选择 ${view.selection!.length} ${_pendingTab ? '集' : '部'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  if (view.selection != null) ...[
                    _selectAll(view),
                    _cancelButton(view),
                    _textButton(
                      '完成',
                      _busy ? null : () => setState(() => _selection = null),
                    ),
                  ] else if (_pendingTab && view.pending.isNotEmpty) ...[
                    _pauseAll(view),
                    _resumeAll(view),
                    _editButton(view),
                  ] else if (!_pendingTab && view.selectable.isNotEmpty) ...[
                    _editButton(view),
                  ],
                ],
              ),
            ),
          ),
          _tabBar(24),
          const SizedBox(height: 8),
          ?_sourceChips(view, inset: 24),
          Expanded(child: body),
        ],
      ),
    ),
  );

  Widget? _sourceChips(
    _View view, {
    required double inset,
    bool scroll = false,
  }) {
    if (view.sources.length < 2) return null;
    Widget chip(String id, String label) => FocusRing(
      radius: 8,
      child: ChoiceChip(
        key: ValueKey('download-source-$id'),
        label: Text(label),
        showCheckmark: false,
        selected: view.source == id,
        onSelected: _busy
            ? null
            : (_) => setState(() {
                _sources[_tabs.index] = id;
                if (_selection != null) _selection = {};
              }),
      ),
    );
    final chips = [
      chip('', '全部'),
      for (final site in view.sources) chip(site.id, site.name),
    ];
    if (scroll) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(inset, 8, inset, 4),
        child: Row(spacing: 8, children: chips),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 8, inset, 4),
      child: Wrap(spacing: 8, runSpacing: 8, children: chips),
    );
  }

  Widget _pendingList(BuildContext context, _View view) {
    if (view.pending.isEmpty) {
      return const StatusView(title: '没有正在下载的剧集', icon: Icons.download_rounded);
    }
    final phone = AppScope.formFactorOf(context) == FormFactor.phone;
    final inset = phone ? 16.0 : 24.0;
    final counts = <String, int>{};
    for (final job in view.pending) {
      counts[job.state] = (counts[job.state] ?? 0) + 1;
    }
    final summary = [
      for (final (state, label) in const [
        ('downloading', '下载中'),
        ('converting', '处理中'),
        ('queued', '等待'),
        ('paused', '已暂停'),
        ('failed', '失败'),
        ('removing', '删除失败'),
      ])
        if (counts[state] case final count?) '$label $count',
    ].join(' · ');
    return ListView.separated(
      key: PageStorageKey(('pending', widget.store.profileEpoch)),
      controller: _scrolls[0],
      padding: EdgeInsets.fromLTRB(inset, 8, inset, 32),
      itemCount: view.pending.length + 1,
      separatorBuilder: (_, index) => SizedBox(height: index == 0 ? 4 : 8),
      itemBuilder: (context, index) => index == 0
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                summary,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : ListenableBuilder(
              key: ValueKey(view.pending[index - 1].id),
              listenable: Listenable.merge([
                widget.downloads.ui.row(view.pending[index - 1].id),
                widget.converter.ui.row(view.pending[index - 1].id),
              ]),
              builder: (context, _) {
                final id = view.pending[index - 1].id;
                final job = widget.downloads.jobById(id);
                if (job == null) return const SizedBox.shrink();
                return _JobRow(
                  job: job,
                  conversion: widget.converter.progressOf(id),
                  conversionError: widget.converter.errorOf(id),
                  selected: view.selection?.contains(id),
                  busy: _busy,
                  onToggle: () => _toggle(id),
                  onSelect: () => setState(() => _selection = {id}),
                  onControl: () => _control(job),
                );
              },
            ),
    );
  }

  (int, double, double) _grid(BuildContext context, double width) {
    if (AppScope.formFactorOf(context) == FormFactor.phone) return (3, 10, 20);
    final desktop = AppScope.formFactorOf(context) == FormFactor.window;
    final minimum = desktop ? 140.0 : 120.0;
    final gap = desktop ? 18.0 : 16.0;
    final columns = ((width + gap) / (minimum + gap)).floor().clamp(1, 99);
    return (columns, gap, desktop ? 22 : 20);
  }

  Widget _downloadedGrid(BuildContext context, _View view) {
    if (view.downloaded.isEmpty) {
      return const StatusView(
        title: '没有下载完成的剧集',
        icon: Icons.download_done_rounded,
      );
    }
    final inset = AppScope.formFactorOf(context) == FormFactor.phone
        ? 16.0
        : 24.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - inset * 2;
        final (columns, gap, runGap) = _grid(context, width);
        final tile = (width - gap * (columns - 1)) / columns;
        return GridView.builder(
          key: PageStorageKey(('downloaded', widget.store.profileEpoch)),
          controller: _scrolls[1],
          padding: EdgeInsets.fromLTRB(inset, 12, inset, 32),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: gap,
            mainAxisSpacing: runGap,
            mainAxisExtent: ProgressPoster.extentFor(context, tile),
          ),
          itemCount: view.downloaded.length,
          itemBuilder: (context, index) {
            final item = view.downloaded[index];
            trackDownloadBuild('archive:${item.drama.id}');
            return Focus(
              key: ValueKey(item.drama.id),
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (_, event) =>
                  wrapGridRow(index, columns, view.downloaded.length, event),
              child: ProgressPoster(
                drama: item.drama,
                width: tile,
                progress: null,
                caption:
                    '${item.episodes.length} 集 · ${formatBytes(item.bytes)}',
                tag: SourceSite.byId(item.drama.source).name,
                badge: item.pending > 0 ? '${item.pending} 集未完成' : null,
                inlineStatus: true,
                selected: view.selection?.contains(item.drama.id),
                onLongPress: _busy || view.selection != null
                    ? null
                    : () => setState(() => _selection = {}),
                onTap: _busy
                    ? () {}
                    : view.selection != null
                    ? () => _toggle(item.drama.id)
                    : () => openPage<void>(
                        context,
                        (_) => DownloadedDramaPage(
                          store: widget.store,
                          downloads: widget.downloads,
                          drama: item.drama,
                          merges: widget.merges,
                        ),
                      ),
                showMenuButton:
                    view.selection == null && item.pending == 0 && !_busy,
                menuTooltip: '剧集菜单',
                onMore: view.selection == null && item.pending == 0 && !_busy
                    ? (anchor) => _showDownloadedMenu(item, anchor, view)
                    : null,
              ),
            );
          },
        );
      },
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({
    required this.job,
    required this.conversion,
    required this.conversionError,
    required this.selected,
    required this.busy,
    required this.onToggle,
    required this.onSelect,
    required this.onControl,
  });
  final DownloadJob job;
  final double? conversion;
  final String? conversionError;
  final bool? selected;
  final bool busy;
  final VoidCallback onToggle;
  final VoidCallback onSelect;
  final VoidCallback onControl;

  @override
  Widget build(BuildContext context) {
    trackDownloadBuild('job:${job.id}');
    final colors = Theme.of(context).colorScheme;
    final downloading = job.state == 'downloading';
    final removalFailed = job.state == 'removing' && job.error.isNotEmpty;
    final failed =
        job.state == 'failed' || removalFailed || conversionError != null;
    final converted = (conversion ?? 0) > 0 ? conversion : null;
    final state = removalFailed
        ? '删除失败'
        : conversionError != null
        ? '处理已暂停'
        : downloading
        ? '${(job.progress.clamp(0.0, .99) * 100).floor()}%'
        : converted != null
        ? '${job.stateLabel} ${(converted.clamp(0.0, .99) * 100).floor()}%'
        : job.stateLabel;
    final detail =
        conversionError ??
        switch (job.state) {
          'failed' || 'removing' => job.error,
          'queued' || 'converting' => '',
          _ when job.total > 0 =>
            '${formatBytes(job.bytes)} / ${formatBytes(job.total)}',
          _ when job.bytes > 0 => formatBytes(job.bytes),
          _ => '',
        };
    final secondary = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    final title = '${job.drama.title} 第 ${job.episode.number} 集';
    return Semantics(
      label: '$title，$state${detail.isEmpty ? '' : '，$detail'}',
      checked: selected,
      child: FocusRing(
        radius: 16,
        child: Material(
          color: colors.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: selected == true
                ? BorderSide(color: colors.primary, width: 2)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: selected == null ? null : onToggle,
            onLongPress: selected == null ? onSelect : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                spacing: 16,
                children: [
                  if (selected case final selected?)
                    Checkbox(value: selected, onChanged: (_) => onToggle()),
                  SizedBox(
                    width: 48,
                    height: 72,
                    child: DramaCover(
                      drama: job.drama,
                      radius: 8,
                      details: false,
                    ),
                  ),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 6,
                        children: [
                          Text(
                            job.drama.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                '第 ${job.episode.number} 集',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                              SourceTag(job.drama.source),
                            ],
                          ),
                          LinearProgressIndicator(
                            value: conversionError != null
                                ? 0
                                : job.converting
                                ? converted?.clamp(0.0, .99)
                                : job.progress.clamp(0.0, .99),
                            minHeight: 4,
                            borderRadius: BorderRadius.circular(2),
                            color: downloading || job.converting
                                ? null
                                : colors.outline,
                          ),
                          Row(
                            spacing: 12,
                            children: [
                              Flexible(
                                child: Text(
                                  state,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: secondary.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: failed
                                        ? colors.error
                                        : downloading || job.converting
                                        ? colors.primary
                                        : null,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  detail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: secondary,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (selected == null &&
                      (!job.converting || conversionError != null) &&
                      (job.state != 'removing' || removalFailed))
                    FocusRing(
                      radius: 20,
                      child: IconButton.filledTonal(
                        tooltip: removalFailed
                            ? '重试删除'
                            : failed
                            ? '重试'
                            : job.active
                            ? '暂停'
                            : '继续',
                        onPressed: busy ? null : onControl,
                        icon: Icon(
                          removalFailed
                              ? Icons.delete_outline_rounded
                              : failed
                              ? Icons.refresh_rounded
                              : job.active
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

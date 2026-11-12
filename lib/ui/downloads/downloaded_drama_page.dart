import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../widgets/app_notice.dart';

import '../../app_device.dart';
import '../../core_bridge.dart';
import '../../download_collections.dart';
import '../../download_export.dart';
import '../../download_merge.dart';
import '../../merge_queue.dart';
import '../../download_overview.dart';
import '../app_motion.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../player/playback_handle.dart';
import '../player/playback_page.dart';
import '../widgets/cover_image.dart';
import '../widgets/focus_ring.dart';
import '../widgets/glass/glass_dialog.dart';
import '../widgets/status_view.dart';
import 'download_actions.dart';
import 'merge_actions.dart';

class DownloadedDramaPage extends StatefulWidget {
  const DownloadedDramaPage({
    super.key,
    required this.store,
    required this.downloads,
    required this.drama,
    required this.merges,
  });
  final LocalStore store;
  final DownloadOverview downloads;
  final Drama drama;
  final MergeQueue merges;

  @override
  State<DownloadedDramaPage> createState() => _DownloadedDramaPageState();
}

class _DownloadedDramaPageState extends State<DownloadedDramaPage> {
  DownloadCollectionUpdater? _updater;
  Set<String>? _selection;
  bool _busy = false;
  bool _playing = false;

  /// 合并监听只建一次，父级换 store/downloads 时在 didUpdateWidget 重建。
  late Listenable _merged = Listenable.merge([
    widget.store,
    widget.downloads,
    if (_updater case final updater?) updater,
  ]);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updater ??= DownloadCollectionUpdater(
      AppScope.of(context).repository,
      widget.store,
    );
  }

  @override
  void dispose() {
    _updater?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(DownloadedDramaPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.store, widget.store) &&
        identical(oldWidget.downloads, widget.downloads)) {
      return;
    }
    _merged = Listenable.merge([
      widget.store,
      widget.downloads,
      if (_updater case final updater?) updater,
    ]);
    if (!identical(oldWidget.store, widget.store)) _selection = null;
  }

  Future<void> _fill(Drama drama) async {
    final updater = _updater!;
    final inspection = updater.inspect(drama, widget.downloads.jobs)..ignore();
    final plan = await showDialog<DownloadFill>(
      context: context,
      builder: (context) => _FillDialog(inspection: inspection),
    );
    if (plan == null || !mounted) return;
    await updater.fill(plan);
    if (!mounted) return;
    showMessage(context, updater.error ?? updater.status);
    await widget.downloads.refresh();
  }

  Future<void> _remove(DownloadedDrama item, Set<String> ids) async {
    if (_busy) return;
    final epoch = widget.store.profileEpoch;
    bool merging() => ids.any(widget.merges.usesDownload);
    if (merging()) {
      showMessage(context, '所选分集正在合并，请等待完成或先取消合并任务');
      return;
    }
    if (ids.isEmpty ||
        !await confirmRemoval(
          context,
          title: '删除 ${ids.length} 集？',
          message: '视频文件会一起删除。',
          action: '删除',
        ) ||
        !mounted) {
      return;
    }
    if (widget.store.profileEpoch != epoch ||
        !widget.store.canDownload ||
        !widget.store.allowsSource(item.drama.source)) {
      return;
    }
    if (merging()) {
      showMessage(context, '所选分集已开始合并，请先取消任务再删除');
      return;
    }
    setState(() => _busy = true);
    final removed = await removeDownloads(context, ids.toList(), done: '已删除');
    await widget.downloads.refresh();
    if (!mounted) return;
    if (removed && ids.length == item.episodes.length) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _selection = null;
      });
    }
  }

  Future<void> _merge(DownloadedDrama item, Set<String> ids) async {
    setState(() => _busy = true);
    await enqueueMerges(context, widget.merges, [
      [
        for (final job in item.episodes)
          if (ids.contains(job.id)) job,
      ],
    ]);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _export(DownloadedDrama item, Set<String> ids) async {
    if (_busy) return;
    final epoch = widget.store.profileEpoch;
    void checkAccess() {
      if (!mounted ||
          widget.store.profileEpoch != epoch ||
          !widget.store.canDownload ||
          !widget.store.allowsSource(item.drama.source)) {
        throw AppFailure('当前用户或权限已变更，已停止导出');
      }
    }

    final repository = AppScope.of(context).repository;
    final notice = AppNotice.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final jobs = [
      for (final job in item.episodes)
        if (ids.contains(job.id)) job,
    ];
    if (jobs.isEmpty) return;
    try {
      if (!await AppDevice.requestVideoExport()) {
        throw AppFailure('未获得存储权限，无法导出');
      }
    } catch (error) {
      notice.show('$error');
      return;
    }
    if (!mounted || _busy) return;
    try {
      checkAccess();
    } catch (error) {
      notice.show('$error');
      return;
    }
    final delete = widget.store.deleteAfterManualExport;
    final exported = ValueNotifier(0);
    setState(() => _busy = true);
    // 进度面板同样用玻璃对话框；路由仍由这里手动管理，才能保证导出结束
    // 时只收起自己这一层（原 DialogRoute 的 isActive/isCurrent 语义不变）。
    Route<void>? dialogRoute;
    final shown = showGlassDialog<void>(
      context,
      // 导出中不能被遮罩或返回键关掉；这一层仍由这里手动收起。
      dismissible: false,
      builder: (context) {
        dialogRoute = ModalRoute.of<void>(context);
        return GlassDialogBody(
          title: '导出到 Movies',
          content: ValueListenableBuilder(
            valueListenable: exported,
            builder: (context, count, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                Text('已处理 $count / ${jobs.length} 集'),
                LinearProgressIndicator(value: count / jobs.length),
              ],
            ),
          ),
        );
      },
    );
    final failures = <String>[];
    final cleanup = <String>[];
    var copied = 0;
    for (final job in jobs) {
      try {
        checkAccess();
        await exportDownload(
          repository,
          job,
          delete: delete,
          checkAccess: checkAccess,
          beforeDelete: () {
            checkAccess();
            if (widget.merges.usesDownload(job.id)) {
              throw AppFailure('该分集正在合并，请稍后手动删除');
            }
          },
        );
        copied++;
      } catch (error) {
        if (error is DownloadCleanupFailure) {
          copied++;
          cleanup.add('$error');
        } else {
          failures.add('$error');
        }
      }
      exported.value++;
    }
    // 页面被销毁时，根 Navigator 也可能已不可用，不能等待永远不会完成的退出动画。
    if (!navigator.mounted) {
      exported.dispose();
      return;
    }
    final route = dialogRoute;
    if (route != null && route.isActive) {
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    }
    await shown;
    exported.dispose();
    if (!mounted) return;
    await widget.downloads.refresh();
    notice.show(
      failures.isEmpty && cleanup.isEmpty
          ? '已导出到 Movies/${safeFileName(item.drama.title)}'
          : '已导出 $copied/${jobs.length} 集；'
                '${failures.isNotEmpty ? '导出失败：${failures.first}' : cleanup.first}',
    );
    if (!mounted) return;
    final remaining = widget.downloads.jobs.any(
      (job) => job.completed && job.drama.id == item.drama.id,
    );
    if (delete && !remaining) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _selection = null;
      });
    }
  }

  Future<void> _play(DownloadedDrama item, int index) async {
    if (_playing) return;
    _playing = true;
    final episode = item.episodes[index].episode;
    final watch = widget.store.watched(item.drama.id);
    final position = watch?.episode == episode.number && !watch!.finished
        ? watch.position
        : 0.0;
    final handle = PlaybackHandle(
      repository: AppScope.of(context).repository,
      store: widget.store,
      detail: DramaDetail(item.drama, [
        for (final job in item.episodes) job.episode,
      ]),
      index: index,
      position: position,
      preopen: widget.store.playbackPreferences.preopens(
        television: AppScope.of(context).television,
      ),
    );
    handle.session.start(index, position: position);
    await Navigator.of(context, rootNavigator: true).push(
      AppMotion.page<void>(
        context,
        (_) => PlaybackPage(store: widget.store, handle: handle),
      ),
    );
    _playing = false;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _merged,
    builder: (context, _) {
      final item = downloadedDramas(
        widget.downloads.jobs,
      ).where((entry) => entry.drama.id == widget.drama.id).firstOrNull;
      final selection = item == null
          ? null
          : _selection?.intersection({for (final job in item.episodes) job.id});
      final phone = AppScope.formFactorOf(context) == FormFactor.phone;
      return PopScope(
        canPop: _selection == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => _selection = null);
        },
        child: phone
            ? _phone(context, item, selection)
            : _wide(context, item, selection),
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

  Widget _fillButton(Drama drama, {bool icon = true}) => _textButton(
    '补齐缺集',
    _updater!.busy || _busy ? null : () => _fill(drama),
    icon: icon ? Icons.refresh_rounded : null,
  );

  Widget _editButton(DownloadedDrama? item, {bool icon = true}) => _textButton(
    '编辑',
    item == null ? null : () => setState(() => _selection = {}),
    icon: icon ? Icons.check_box_outlined : null,
  );

  Widget _selectAll(DownloadedDrama item, Set<String> selection) {
    final all = {for (final job in item.episodes) job.id};
    final everything = selection.length == all.length;
    return _textButton(
      everything ? '取消全选' : '全选',
      () => setState(() => _selection = everything ? {} : all),
    );
  }

  Widget _mergeButton(DownloadedDrama item, Set<String> selection) => FocusRing(
    radius: 20,
    child: FilledButton.tonalIcon(
      onPressed: selection.length < 2 || _busy
          ? null
          : () => _merge(item, selection),
      icon: const Icon(Icons.merge_rounded, size: 18),
      label: const Text('合并'),
    ),
  );

  Widget _exportButton(DownloadedDrama item, Set<String> selection) =>
      FocusRing(
        radius: 20,
        child: FilledButton.tonalIcon(
          onPressed: selection.isEmpty || _busy
              ? null
              : () => _export(item, selection),
          icon: const Icon(Icons.drive_folder_upload_outlined, size: 18),
          label: const Text('导出'),
        ),
      );

  Widget _deleteButton(DownloadedDrama item, Set<String> selection) {
    final colors = Theme.of(context).colorScheme;
    return FocusRing(
      radius: 20,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: colors.error,
          foregroundColor: colors.onError,
        ),
        onPressed: selection.isEmpty || _busy
            ? null
            : () => _remove(item, selection),
        icon: const Icon(Icons.delete_outline_rounded, size: 18),
        label: const Text('删除'),
      ),
    );
  }

  Widget _phone(
    BuildContext context,
    DownloadedDrama? item,
    Set<String>? selection,
  ) {
    final drama = item?.drama ?? widget.drama;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 21;
    return Scaffold(
      appBar: selection == null || item == null
          ? AppBar(
              toolbarHeight: max(56.0, MediaQuery.textScalerOf(context).scale(22) * 1.3 + 16),
              title: Text(
                drama.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                if (largeText) ...[
                  IconButton(
                    tooltip: '补齐缺集',
                    onPressed: _updater!.busy || _busy
                        ? null
                        : () => _fill(drama),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    tooltip: '编辑',
                    onPressed: item == null
                        ? null
                        : () => setState(() => _selection = {}),
                    icon: const Icon(Icons.check_box_outlined),
                  ),
                ] else ...[
                  _fillButton(drama, icon: false),
                  _editButton(item, icon: false),
                ],
                const SizedBox(width: 8),
              ],
            )
          : AppBar(
              toolbarHeight: max(56.0, MediaQuery.textScalerOf(context).scale(22) * 1.3 + 16),
              leading: IconButton(
                tooltip: '退出编辑',
                onPressed: () => setState(() => _selection = null),
                icon: const Icon(Icons.close_rounded),
              ),
              title: Text(
                '已选择 ${selection.length} 集',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [_selectAll(item, selection), const SizedBox(width: 8)],
            ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: _content(context, item, selection, inset: 16),
      ),
      bottomNavigationBar: selection == null || item == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: largeText
                    ? Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          _mergeButton(item, selection),
                          if (Platform.isAndroid) _exportButton(item, selection),
                          _deleteButton(item, selection),
                        ],
                      )
                    : SizedBox(
                        height: 48,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 12,
                          children: [
                            Expanded(child: _mergeButton(item, selection)),
                            if (Platform.isAndroid)
                              Expanded(child: _exportButton(item, selection)),
                            Expanded(child: _deleteButton(item, selection)),
                          ],
                        ),
                      ),
              ),
            ),
    );
  }

  Widget _wide(
    BuildContext context,
    DownloadedDrama? item,
    Set<String>? selection,
  ) {
    final drama = item?.drama ?? widget.drama;
    final editing = selection != null && item != null;
    return Scaffold(
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
                    if (editing)
                      IconButton(
                        tooltip: '退出编辑',
                        onPressed: () => setState(() => _selection = null),
                        icon: const Icon(Icons.close_rounded),
                      )
                    else
                      const BackButton(),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          editing ? '已选择 ${selection.length} 集' : drama.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    if (editing) ...[
                      _selectAll(item, selection),
                      _mergeButton(item, selection),
                      if (Platform.isAndroid) _exportButton(item, selection),
                      _deleteButton(item, selection),
                      _textButton(
                        '完成',
                        () => setState(() => _selection = null),
                      ),
                    ] else ...[
                      _fillButton(drama),
                      _editButton(item),
                    ],
                  ],
                ),
              ),
            ),
            Expanded(
              child: _content(context, item, selection, inset: 24, lead: 68),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    DownloadedDrama? item,
    Set<String>? selection, {
    required double inset,
    double? lead,
  }) {
    final colors = Theme.of(context).colorScheme;
    final updater = _updater!;
    final header = <Widget>[
      if (item != null)
        Padding(
          padding: EdgeInsets.fromLTRB(lead ?? inset, 4, inset, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SourceTag(item.drama.source),
              Text(
                '已下载 ${item.episodes.length} 集 · ${formatBytes(item.bytes)}'
                '${item.pending > 0 ? ' · 另有 ${item.pending} 集未完成' : ''}',
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      if (updater.busy)
        Padding(
          padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
          child: Material(
            color: colors.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                spacing: 12,
                children: [
                  Expanded(
                    child: Text(
                      updater.status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                  ),
                  _textButton('停止', updater.cancel),
                ],
              ),
            ),
          ),
        ),
    ];
    if (item == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...header,
          const Expanded(
            child: StatusView(
              title: '没有已下载的剧集',
              icon: Icons.download_done_rounded,
            ),
          ),
        ],
      );
    }
    return _EpisodeList(
      header: header,
      episodes: item.episodes,
      watched: widget.store.watched(item.drama.id)?.episode,
      selection: selection,
      inset: inset,
      touch: AppScope.formFactorOf(context) != FormFactor.window,
      onSelect: (selection) => setState(() => _selection = selection),
      onPlay: (index) => _play(item, index),
    );
  }
}

const _cardGap = 12.0;
const _gridTop = 12.0;

class _EpisodeList extends StatefulWidget {
  const _EpisodeList({
    required this.header,
    required this.episodes,
    required this.watched,
    required this.selection,
    required this.inset,
    required this.touch,
    required this.onSelect,
    required this.onPlay,
  });
  final List<Widget> header;
  final List<DownloadJob> episodes;
  final int? watched;
  final Set<String>? selection;
  final double inset;
  final bool touch;
  final ValueChanged<Set<String>> onSelect;
  final ValueChanged<int> onPlay;

  @override
  State<_EpisodeList> createState() => _EpisodeListState();
}

class _EpisodeListState extends State<_EpisodeList>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  final _headerKey = GlobalKey();
  bool? _dragAdds;
  bool _marked = false;
  bool _swallowTap = false;
  int _dragAnchor = 0;
  Set<String> _dragBase = const {};
  Offset? _dragPoint;
  /// 拖到边缘时的自动滚动：用 vsync Ticker 取代独立 16ms 定时器，
  /// 每帧最多推进一次，且按真实经过时间换算位移，速度与原步进一致。
  /// Ticker 由 [SingleTickerProviderStateMixin] 托管，离屏时随 TickerMode 静默。
  late final Ticker _autoTicker = createTicker(_autoScrollTick);
  Duration? _autoTickAt;
  double _width = 0;
  double _height = 0;
  int _columns = 1;
  double _cardHeight = 64;
  double get _rowExtent => _cardHeight + _cardGap;

  List<DownloadJob> get _episodes => widget.episodes;

  @override
  void didUpdateWidget(_EpisodeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selection == null) _dragEnd();
  }

  @override
  void dispose() {
    // 拖选中被销毁时 Ticker 仍可能活动，mixin 会在 dispose 断言失败，先停。
    _stopAutoScroll();
    _scroll.dispose();
    super.dispose();
  }

  double get _top => (_headerKey.currentContext?.size?.height ?? 0) + _gridTop;

  double get _cardWidth =>
      (_width - widget.inset * 2 - _cardGap * (_columns - 1)) / _columns;

  int? _hit(Offset point, {bool exact = false}) {
    if (_episodes.isEmpty || !_scroll.hasClients) return null;
    final pitch = _cardWidth + _cardGap;
    final x = point.dx - widget.inset;
    final y = point.dy + _scroll.offset - _top;
    if (exact &&
        (x < 0 ||
            y < 0 ||
            x >= pitch * _columns ||
            x % pitch > _cardWidth ||
            y % _rowExtent > _cardHeight)) {
      return null;
    }
    final rows = (_episodes.length / _columns).ceil();
    final column = (x / pitch).floor().clamp(0, _columns - 1);
    final row = (y / _rowExtent).floor().clamp(0, rows - 1);
    final index = row * _columns + column;
    if (index < _episodes.length) return index;
    return exact ? null : _episodes.length - 1;
  }

  void _mark(int index) {
    final adds = _dragAdds;
    if (adds == null) return;
    _marked = true;
    final range = {
      for (
        var item = min(index, _dragAnchor);
        item <= max(index, _dragAnchor);
        item++
      )
        _episodes[item].id,
    };
    widget.onSelect(
      adds ? _dragBase.union(range) : _dragBase.difference(range),
    );
  }

  void _toggle(int index) {
    if (_swallowTap) return;
    final selection = {...?widget.selection};
    final id = _episodes[index].id;
    if (!selection.remove(id)) selection.add(id);
    widget.onSelect(selection);
  }

  void _dragStart(Offset point) {
    final selection = widget.selection;
    final index = _hit(point, exact: true);
    if (selection == null || index == null) return;
    _dragAdds = !selection.contains(_episodes[index].id);
    _dragAnchor = index;
    _dragBase = selection;
    _dragPoint = point;
    if (widget.touch) _mark(index);
  }

  void _dragMove(Offset point) {
    if (_dragAdds == null) return;
    _dragPoint = point;
    final index = _hit(point);
    if (index != null && (_marked || index != _dragAnchor)) _mark(index);
    if (_marked && _edgeSpeed(point.dy) != 0) _startAutoScroll();
  }

  void _pointerUp() {
    _swallowTap = _marked;
    scheduleMicrotask(() => _swallowTap = false);
    _dragEnd();
  }

  void _dragEnd() {
    _dragAdds = null;
    _dragPoint = null;
    _marked = false;
    _stopAutoScroll();
  }

  double _edgeSpeed(double y) {
    final zone = min(_height / 3, max(64.0, _cardHeight));
    if (zone <= 0) return 0;
    final depth = y < zone
        ? y - zone
        : y > _height - zone
        ? y - (_height - zone)
        : 0.0;
    if (depth == 0) return 0;
    final t = (depth.abs() / zone).clamp(0.0, 2.0) / 2;
    return depth.sign * (120 + 1700 * t * t) * (_rowExtent / 76);
  }

  void _startAutoScroll() {
    _autoTickAt = null;
    if (!_autoTicker.isActive) _autoTicker.start();
  }

  void _stopAutoScroll() {
    if (_autoTicker.isActive) _autoTicker.stop();
    _autoTickAt = null;
  }

  void _autoScrollTick(Duration elapsed) {
    final point = _dragPoint;
    final speed = point == null ? 0.0 : _edgeSpeed(point.dy);
    if (speed == 0 || !_scroll.hasClients) {
      _stopAutoScroll();
      return;
    }
    final previous = _autoTickAt;
    _autoTickAt = elapsed;
    // 第一帧只记时间基准；之后按真实间隔推进，每秒位移与原来相同。
    if (previous == null) return;
    final dt = (elapsed - previous).inMicroseconds / 1000000;
    if (dt <= 0) return;
    final position = _scroll.position;
    final next = (position.pixels + speed * dt).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) return;
    _scroll.jumpTo(next);
    final index = _hit(point!);
    if (index != null) _mark(index);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _width = constraints.maxWidth;
      _height = constraints.maxHeight;
      final scaler = MediaQuery.textScalerOf(context);
      // 固定两行的文字与 VIP 徽标共用高度，网格、命中和自动滚动使用同一行距。
      _cardHeight = max(
        64.0,
        16 +
            max(
              (scaler.scale(15) * 1.3).ceilToDouble(),
              (scaler.scale(11) * 1.2).ceilToDouble() + 6,
            ) +
            2 +
            (scaler.scale(12) * 1.3).ceilToDouble(),
      );
      _columns =
          ((_width - widget.inset * 2 + _cardGap) /
                  ((widget.inset == 16 ? 160 : 220) + _cardGap))
              .floor()
              .clamp(1, 99);
      final selection = widget.selection;
      final selecting = selection != null;
      final list = CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: KeyedSubtree(
              key: _headerKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.header,
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              widget.inset,
              _gridTop,
              widget.inset,
              32,
            ),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columns,
                crossAxisSpacing: _cardGap,
                mainAxisSpacing: _cardGap,
                mainAxisExtent: _cardHeight,
              ),
              itemCount: _episodes.length,
              itemBuilder: (context, index) {
                final job = _episodes[index];
                return _EpisodeCard(
                  key: ValueKey(job.id),
                  job: job,
                  watching: !selecting && job.episode.number == widget.watched,
                  selected: selection?.contains(job.id),
                  onTap: selecting
                      ? () => _toggle(index)
                      : () => widget.onPlay(index),
                  onLongPress: selecting
                      ? null
                      : () => widget.onSelect({job.id}),
                );
              },
            ),
          ),
        ],
      );
      if (widget.touch) {
        return GestureDetector(
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart: selecting
              ? (details) => _dragStart(details.localPosition)
              : null,
          onHorizontalDragUpdate: selecting
              ? (details) => _dragMove(details.localPosition)
              : null,
          onHorizontalDragEnd: selecting ? (_) => _dragEnd() : null,
          onHorizontalDragCancel: selecting ? _dragEnd : null,
          child: list,
        );
      }
      return Listener(
        onPointerDown: selecting
            ? (event) => _dragStart(event.localPosition)
            : null,
        onPointerMove: selecting
            ? (event) => _dragMove(event.localPosition)
            : null,
        onPointerUp: (_) => _pointerUp(),
        onPointerCancel: (_) => _dragEnd(),
        child: list,
      );
    },
  );
}

class _FillDialog extends StatelessWidget {
  const _FillDialog({required this.inspection});
  final Future<DownloadFill> inspection;

  Widget _button(
    BuildContext context,
    String label, {
    DownloadFill? result,
    bool primary = false,
  }) => FocusRing(
    radius: 20,
    child: primary
        ? FilledButton(
            onPressed: () => Navigator.pop(context, result),
            child: Text(label),
          )
        : TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, result),
            child: Text(label),
          ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<DownloadFill>(
    future: inspection,
    builder: (context, snapshot) {
      final plan = snapshot.data;
      final Widget content;
      final List<Widget> actions;
      if (snapshot.hasError) {
        content = Text('${snapshot.error}');
        actions = [_button(context, '关闭')];
      } else if (plan == null) {
        content = const Row(
          spacing: 16,
          children: [
            SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            Text('正在读取最新分集…'),
          ],
        );
        actions = [_button(context, '取消')];
      } else {
        final vip = plan.skippedVip > 0
            ? '\n另有 ${plan.skippedVip} 集 VIP，下载设置里没有包含 VIP 集，不会加入。'
            : '';
        content = Text(
          plan.missing == 0
              ? '本剧已全部下载，没有需要补齐的集。$vip'
              : '本剧还有 ${plan.missing} 集没有下载，确认后加入下载。$vip',
        );
        actions = plan.missing == 0
            ? [_button(context, '知道了')]
            : [
                _button(context, '取消'),
                _button(
                  context,
                  '补齐 ${plan.missing} 集',
                  result: plan,
                  primary: true,
                ),
              ];
      }
      return AlertDialog(
        title: const Text('补齐缺集'),
        content: content,
        actions: actions,
      );
    },
  );
}

class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({
    super.key,
    required this.job,
    required this.watching,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });
  final DownloadJob job;
  final bool watching;
  final bool? selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final episode = job.episode;
    final meta = job.actualQuality > 0
        ? '${job.actualQuality}P · ${formatBytes(job.bytes)}'
        : formatBytes(job.bytes);
    return Semantics(
      button: true,
      checked: selected,
      label:
          '第 ${episode.number} 集${episode.vip ? '，VIP' : ''}'
          '${watching ? '，看到这里' : ''}，$meta',
      excludeSemantics: true,
      child: FocusRing(
        radius: 14,
        child: Material(
          color: colors.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: selected == true
                ? BorderSide(color: colors.primary, width: 2)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: EdgeInsets.fromLTRB(selected == null ? 16 : 8, 8, 12, 8),
              child: Row(
                spacing: 8,
                children: [
                  if (selected case final selected?)
                    Checkbox(value: selected, onChanged: (_) => onTap()),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Row(
                          spacing: 6,
                          children: [
                            Flexible(
                              child: Text(
                                '第 ${episode.number} 集',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 15,
                                  height: 1.3,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (episode.vip) const VipBadge(),
                            if (watching)
                              Flexible(
                                child: Text(
                                  '看到这里',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: colors.primary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected == null)
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: 20,
                        color: colors.onSurface,
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

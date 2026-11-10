import 'dart:async';

import 'package:flutter/material.dart';

import '../../download_collections.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../player/episode_grid.dart';
import '../widgets/focus_ring.dart';
import '../widgets/status_view.dart';
import 'download_actions.dart';

class DownloadPickerPage extends StatefulWidget {
  const DownloadPickerPage({
    super.key,
    required this.store,
    this.detail,
    this.drama,
  }) : assert(detail != null || drama != null, '需要详情或短剧之一');

  final LocalStore store;

  /// 从剧集信息页进入时已经拿到详情，不再重复请求选集。
  final DramaDetail? detail;

  /// 从海报三点菜单直接进入时只有短剧，由本页自行读取选集。
  final Drama? drama;

  @override
  State<DownloadPickerPage> createState() => _DownloadPickerPageState();
}

class _DownloadPickerPageState extends State<DownloadPickerPage> {
  final _selected = <int>{};
  Set<int> _downloaded = const {};
  Set<int> _downloading = const {};
  bool _marked = false;
  bool _submitting = false;
  DramaDetail? _detail;
  String? _error;

  List<Episode> get _episodes => _detail?.episodes ?? const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_marked) return;
    _marked = true;
    final detail = widget.detail;
    if (detail != null) {
      // 从剧集信息页进入：详情已经有了，不再重复请求。
      _detail = detail;
      unawaited(_loadMarks());
    } else {
      unawaited(_load());
    }
  }

  /// 只有短剧时先取选集；失败保留重试入口，不落到空选集页面。
  ///
  /// 这里不在开头 setState：首次加载由 didChangeDependencies 触发，
  /// 此时仍在构建阶段，同步改状态会触发框架断言。
  Future<void> _load() async {
    try {
      final detail = await AppScope.of(context).repository.detail(widget.drama!);
      if (!mounted) return;
      if (detail.episodes.isEmpty) throw StateError('没有可下载的选集');
      setState(() => _detail = detail);
      await _loadMarks();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  /// 重试：先回到加载态，再重新读取选集。
  void _retry() {
    setState(() => _error = null);
    unawaited(_load());
  }

  Future<void> _loadMarks() async {
    try {
      final jobs = await AppScope.of(context).repository.downloads();
      if (!mounted) return;
      final marks = downloadMarks(jobs, _detail!.drama.id);
      Set<int> indexes(Set<int> numbers) => {
        for (final (index, episode) in _episodes.indexed)
          if (numbers.contains(episode.number)) index,
      };
      setState(() {
        _downloaded = indexes(marks.downloaded);
        _downloading = indexes(marks.downloading);
        _selected.removeWhere(
          (index) =>
              _downloaded.contains(index) || _downloading.contains(index),
        );
      });
    } catch (_) {}
  }

  List<int> get _selectable {
    final includeVip = widget.store.downloadPreferences.includeVip;
    return [
      for (final (index, episode) in _episodes.indexed)
        if (!_downloaded.contains(index) &&
            !_downloading.contains(index) &&
            (includeVip || !episode.vip))
          index,
    ];
  }

  bool get _all {
    final selectable = _selectable;
    return selectable.isNotEmpty && selectable.every(_selected.contains);
  }

  void _toggleAll() => setState(() {
    if (_all) {
      _selected.clear();
    } else {
      _selected.addAll(_selectable);
    }
  });

  Future<void> _submit() async {
    if (_selected.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    final indexes = _selected.toList()..sort();
    final added = await downloadEpisodes(context, widget.store, _detail!, [
      for (final index in indexes) _episodes[index],
    ]);
    if (!mounted) return;
    if (added) {
      Navigator.pop(context);
    } else {
      setState(() => _submitting = false);
    }
  }

  Widget _selectAllButton() => FocusRing(
    radius: 20,
    child: TextButton(
      onPressed: _submitting ? null : _toggleAll,
      child: Text(_all ? '取消全选' : '全选'),
    ),
  );

  Widget _submitButton() => FocusRing(
    radius: 20,
    child: FilledButton.icon(
      onPressed: _selected.isEmpty || _submitting ? null : _submit,
      icon: _submitting
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download_rounded, size: 18),
      label: Text(_selected.isEmpty ? '下载' : '下载 ${_selected.length} 集'),
    ),
  );

  Widget _legend(double inset) {
    final colors = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    Widget mark(IconData icon, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        Icon(icon, size: 14, color: colors.onSurfaceVariant),
        Text(label, style: style),
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 4, inset, 0),
      child: Wrap(
        spacing: 16,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          mark(Icons.check_rounded, '已下载'),
          mark(Icons.arrow_downward_rounded, '下载中'),
          if (_episodes.any((episode) => episode.vip))
            Text(
              'VIP 集可能只包含试看内容',
              style: style.copyWith(color: colors.tertiary),
            ),
        ],
      ),
    );
  }

  Widget _grid({
    required double inset,
    required double minCellWidth,
    required bool touch,
  }) => EpisodeGrid(
    episodes: _episodes,
    current: -1,
    selecting: !_submitting,
    selected: _selected,
    downloaded: _downloaded,
    downloading: _downloading,
    minCellWidth: minCellWidth,
    inset: inset,
    touch: touch,
    header: _legend(inset),
    onSelectionChanged: () => setState(() {}),
    onPick: (_) {},
  );

  @override
  Widget build(BuildContext context) {
    if (_detail == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('下载选集')),
        body: _error == null
            ? const StatusView.loading(title: '正在读取选集')
            : StatusView(
                title: '无法读取选集',
                message: _error,
                icon: Icons.cloud_off_rounded,
                action: '重试',
                onAction: _retry,
              ),
      );
    }
    final form = AppScope.formFactorOf(context);
    if (form == FormFactor.phone) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('下载选集'),
          actions: [_selectAllButton(), const SizedBox(width: 8)],
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: _grid(inset: 16, minCellWidth: 60, touch: true),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(height: 48, child: _submitButton()),
          ),
        ),
      );
    }
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
                    const BackButton(),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: const Text(
                          '下载选集',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    _selectAllButton(),
                    _submitButton(),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _grid(
                inset: 24,
                minCellWidth: 76,
                touch: form != FormFactor.window,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

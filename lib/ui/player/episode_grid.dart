import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../models.dart';
import '../widgets/cover_image.dart';
import '../widgets/text_metrics.dart';

const _cellGap = 8.0;
const _listTop = 14.0;

class EpisodeGrid extends StatefulWidget {
  const EpisodeGrid({
    super.key,
    required this.episodes,
    required this.current,
    required this.selecting,
    required this.selected,
    required this.onSelectionChanged,
    required this.onPick,
    this.touch = false,
    this.header,
    this.downloaded = const {},
    this.downloading = const {},
    this.minCellWidth,
    this.inset = 16,
  });
  final List<Episode> episodes;
  final int current;
  final bool selecting;
  final Set<int> selected;
  final VoidCallback onSelectionChanged;
  final ValueChanged<int> onPick;
  final bool touch;
  final Widget? header;
  final Set<int> downloaded;
  final Set<int> downloading;
  final double? minCellWidth;
  final double inset;

  @override
  State<EpisodeGrid> createState() => _EpisodeGridState();
}

class _EpisodeGridState extends State<EpisodeGrid>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  final _headerKey = GlobalKey();
  bool? _dragAdds;
  int _dragAnchor = 0;
  Set<int> _dragBase = const {};
  Offset? _dragPoint;
  /// 拖到边缘时的自动滚动：用 vsync Ticker 取代独立 16ms 定时器，
  /// 每帧最多推进一次，且按真实经过时间换算位移，速度与原步进一致。
  /// Ticker 由 [SingleTickerProviderStateMixin] 托管，离屏时随 TickerMode 静默。
  late final Ticker _autoTicker = createTicker(_autoScrollTick);
  Duration? _autoTickAt;
  double _gridWidth = 0;
  double _gridHeight = 0;
  int _columns = 5;
  ({int current, int columns, double rowExtent, double width})? _revealed;
  List<Episode>? _layoutEpisodes;
  int _maxDigits = 1;
  bool _hasVip = false;
  double _labelTopInset = 0;
  double _cellHeight = 48;
  double get _rowExtent => _cellHeight + _cellGap;

  List<Episode> get _episodes => widget.episodes;
  Set<int> get _selected => widget.selected;
  bool _locked(int index) =>
      widget.downloaded.contains(index) || widget.downloading.contains(index);

  @override
  void didUpdateWidget(EpisodeGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.selecting) _dragEnd();
  }

  @override
  void dispose() {
    // 拖选中被销毁时 Ticker 仍可能活动，mixin 会在 dispose 断言失败，先停。
    _stopAutoScroll();
    _scroll.dispose();
    super.dispose();
  }

  double get _top => _listTop + (_headerKey.currentContext?.size?.height ?? 0);

  double get _cellWidth =>
      (_gridWidth - widget.inset * 2 - _cellGap * (_columns - 1)) / _columns;

  int? _hit(Offset point, {bool exact = false}) {
    if (_episodes.isEmpty || !_scroll.hasClients) return null;
    final pitch = _cellWidth + _cellGap;
    final x = point.dx - widget.inset;
    final y = point.dy + _scroll.offset - _top;
    if (exact &&
        (x < 0 ||
            y < 0 ||
            x >= pitch * _columns ||
            x % pitch > _cellWidth ||
            y % _rowExtent > _cellHeight)) {
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
    final first = index < _dragAnchor ? index : _dragAnchor;
    final last = index < _dragAnchor ? _dragAnchor : index;
    final range = [
      for (var item = first; item <= last; item++)
        if (!_locked(item)) item,
    ];
    _selected
      ..clear()
      ..addAll(_dragBase);
    adds ? _selected.addAll(range) : _selected.removeAll(range);
    widget.onSelectionChanged();
  }

  void _toggle(int index) {
    if (_locked(index)) return;
    if (!_selected.remove(index)) _selected.add(index);
    widget.onSelectionChanged();
  }

  void _dragStart(Offset point) {
    final index = _hit(point, exact: true);
    if (index == null) return;
    _dragAdds = !_selected.contains(index);
    _dragAnchor = index;
    _dragBase = Set.of(_selected);
    _dragPoint = point;
    _mark(index);
  }

  void _dragMove(Offset point) {
    if (_dragAdds == null) return;
    _dragPoint = point;
    final index = _hit(point);
    if (index != null) _mark(index);
    if (_edgeSpeed(point.dy) != 0) _startAutoScroll();
  }

  void _dragEnd() {
    _dragAdds = null;
    _dragPoint = null;
    _stopAutoScroll();
  }

  double _edgeSpeed(double y) {
    const zone = 64.0;
    final depth = y < zone
        ? y - zone
        : y > _gridHeight - zone
        ? y - (_gridHeight - zone)
        : 0.0;
    if (depth == 0) return 0;
    final t = (depth.abs() / zone).clamp(0.0, 2.0) / 2;
    return depth.sign * (120 + 1700 * t * t);
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

  void _reveal({required bool animate}) {
    if (!mounted || !_scroll.hasClients || widget.current < 0) return;
    final top = _top + widget.current ~/ _columns * _rowExtent;
    final position = _scroll.position;
    final view = position.viewportDimension;
    if (top >= position.pixels && top + _cellHeight <= position.pixels + view) {
      return;
    }
    final target = (top - (view - _cellHeight) / 3).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (animate) {
      unawaited(
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        ),
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _gridWidth = constraints.maxWidth;
      _gridHeight = constraints.maxHeight;
      if (!identical(_layoutEpisodes, _episodes)) {
        _layoutEpisodes = _episodes;
        _maxDigits = 1;
        _hasVip = false;
        for (final episode in _episodes) {
          _maxDigits = max(_maxDigits, episode.number.toString().length);
          _hasVip = _hasVip || episode.vip;
        }
      }
      // 测量完整集号并给当前播放图标留白；大字体不能继续硬塞进五列。
      // 测量结果按 (集号位数, 样式, 缩放器) 记忆化：LayoutBuilder 每次重跑都要用。
      final labelMetrics = measureTextLine(
        text: '8' * _maxDigits,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        scaler: MediaQuery.textScalerOf(context),
        direction: Directionality.of(context),
      );
      final minimum = max(
        widget.minCellWidth ?? 48,
        labelMetrics.width.ceilToDouble() + 34,
      );
      // VIP/下载角标独占顶部空间，放大字号后也不能盖住集号。
      _labelTopInset = max(
        _hasVip ? MediaQuery.textScalerOf(context).scale(9) * 12 / 9 + 2 : 0.0,
        widget.downloaded.isNotEmpty || widget.downloading.isNotEmpty
            ? 19.0
            : 0.0,
      );
      _cellHeight = max(
        48,
        labelMetrics.height.ceilToDouble() + max(20, _labelTopInset + 12),
      );
      final fitted = max(
        1,
        ((_gridWidth - widget.inset * 2 + _cellGap) / (minimum + _cellGap))
            .floor(),
      );
      _columns = widget.minCellWidth == null ? min(5, fitted) : fitted;
      final layout = (
        current: widget.current,
        columns: _columns,
        rowExtent: _rowExtent,
        width: _gridWidth,
      );
      // 旋转/字号变化后行位置也会变，不能只在切集时校正当前项。
      if (_revealed != layout) {
        final animate =
            _revealed != null && _revealed!.current != widget.current;
        _revealed = layout;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _reveal(animate: animate),
        );
      }
      final selecting = widget.selecting;
      final rows = SliverFixedExtentList(
        itemExtent: _rowExtent,
        delegate: SliverChildBuilderDelegate(
          childCount: (_episodes.length / _columns).ceil(),
          (context, row) => Padding(
            padding: const EdgeInsets.only(bottom: _cellGap),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: _cellGap,
              children: [
                for (
                  var index = row * _columns;
                  index < (row + 1) * _columns;
                  index++
                )
                  Expanded(
                    child: index < _episodes.length
                        ? _EpisodeCell(
                            episode: _episodes[index],
                            labelTopInset: _labelTopInset,
                            current: index == widget.current,
                            watched: index < widget.current,
                            selected: selecting
                                ? _selected.contains(index)
                                : null,
                            marker: widget.downloaded.contains(index)
                                ? Icons.check_rounded
                                : widget.downloading.contains(index)
                                ? Icons.arrow_downward_rounded
                                : null,
                            onPressed: _locked(index)
                                ? null
                                : !selecting
                                ? () => widget.onPick(index)
                                : widget.touch
                                ? () => _toggle(index)
                                : null,
                          )
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        ),
      );
      final list = CustomScrollView(
        controller: _scroll,
        slivers: [
          if (widget.header case final header?)
            SliverToBoxAdapter(
              child: KeyedSubtree(key: _headerKey, child: header),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              widget.inset,
              _listTop,
              widget.inset,
              8,
            ),
            sliver: rows,
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
        onPointerUp: (_) => _dragEnd(),
        onPointerCancel: (_) => _dragEnd(),
        child: list,
      );
    },
  );
}

class _EpisodeCell extends StatelessWidget {
  const _EpisodeCell({
    required this.episode,
    required this.current,
    required this.watched,
    required this.selected,
    required this.onPressed,
    required this.labelTopInset,
    this.marker,
  });
  final Episode episode;
  final bool current;
  final bool watched;
  final bool? selected;
  final VoidCallback? onPressed;
  final IconData? marker;
  final double labelTopInset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = current
        ? colors.onPrimaryContainer
        : watched || marker != null
        ? colors.onSurfaceVariant
        : colors.onSurface;
    final radius = BorderRadius.circular(12);
    return Semantics(
      button: true,
      selected: selected ?? current,
      label:
          '第 ${episode.number} 集${episode.vip ? '，VIP' : ''}'
          '${marker == null
              ? ''
              : marker == Icons.check_rounded
              ? '，已下载'
              : '，下载中'}',
      excludeSemantics: true,
      child: Material(
        color: current
            ? colors.primaryContainer
            : marker != null
            ? colors.surfaceContainer
            : theme.brightness == Brightness.dark
            ? colors.surfaceContainerHigh
            : colors.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: selected == true
              ? BorderSide(color: colors.primary, width: 2)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: EdgeInsets.only(top: labelTopInset),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: 4,
                  children: [
                    if (current)
                      Icon(
                        Icons.equalizer_rounded,
                        size: 14,
                        color: foreground,
                      ),
                    Text(
                      '${episode.number}',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                        color: foreground,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              if (marker case final marker?)
                Positioned(
                  left: 6,
                  top: 6,
                  child: Icon(marker, size: 13, color: foreground),
                ),
              if (episode.vip)
                const Positioned(
                  right: 0,
                  top: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: vipGold,
                      borderRadius: BorderRadius.only(
                        topRight: Radius.circular(12),
                        bottomLeft: Radius.circular(6),
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      child: Text(
                        'VIP',
                        style: TextStyle(
                          fontSize: 9,
                          height: 12 / 9,
                          fontWeight: FontWeight.w800,
                          color: onVipGold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

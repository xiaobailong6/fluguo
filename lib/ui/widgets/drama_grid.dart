import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../drama_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import 'drama_tile.dart';
import 'focus_ring.dart';

(int, double, double) _gridLayout(BuildContext context, double width) =>
    switch (AppScope.formFactorOf(context)) {
      FormFactor.phone => (3, 10.0, 22.0),
      FormFactor.television => (
        ((width + 20) / 120).floor().clamp(3, 8),
        20.0,
        24.0,
      ),
      FormFactor.window => (
        math.max(2, ((width + 18) / 178).floor()),
        18.0,
        24.0,
      ),
      FormFactor.pad => ((width / 180).floor().clamp(4, 9), 18.0, 22.0),
    };

double dramaTileWidth(BuildContext context, double width) {
  final (columns, spacing, _) = _gridLayout(context, width);
  return (width - (columns - 1) * spacing) / columns;
}

SliverGridDelegate dramaGridDelegate(BuildContext context, double width) {
  // 同一份布局算一次即可：原来 tile 又走一遍 _gridLayout（含 formFactor 查询）。
  final (columns, spacing, runSpacing) = _gridLayout(context, width);
  final tile = (width - (columns - 1) * spacing) / columns;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: spacing,
    mainAxisSpacing: runSpacing,
    mainAxisExtent: DramaTile.extentFor(context, tile),
  );
}

KeyEventResult wrapGridRow(int index, int columns, int count, KeyEvent event) {
  if (event is KeyUpEvent) return KeyEventResult.ignored;
  final primary = FocusManager.instance.primaryFocus;
  final last = count - 1;
  switch (event.logicalKey) {
    case LogicalKeyboardKey.arrowRight
        when index % columns == columns - 1 || index == last:
      if (index < last) primary?.nextFocus();
      return KeyEventResult.handled;
    case LogicalKeyboardKey.arrowLeft when index % columns == 0 && index > 0:
      primary?.previousFocus();
      return KeyEventResult.handled;
    default:
      return KeyEventResult.ignored;
  }
}

class DramaSliverGrid extends StatelessWidget {
  const DramaSliverGrid({
    super.key,
    required this.width,
    required this.items,
    required this.onOpen,
    this.onMore,
    this.rankOf,
    this.autofocus = false,
    this.store,
  });
  final LocalStore? store;
  final double width;
  final List<Drama> items;
  final ValueChanged<Drama> onOpen;

  final ValueChanged<(Drama, Offset)>? onMore;
  final int? Function(Drama drama)? rankOf;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final (columns, _, _) = _gridLayout(context, width);
    return SliverGrid.builder(
      gridDelegate: dramaGridDelegate(context, width),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final drama = items[index];
        return Focus(
          key: ValueKey(drama.id),
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) =>
              wrapGridRow(index, columns, items.length, event),
          child: ListenableBuilder(
            // 只重建可见海报，追剧切换后不必刷新整个短剧 feed。
            listenable: store ?? const AlwaysStoppedAnimation<bool>(false),
            builder: (context, _) => DramaTile(
              drama: drama,
              followed: store?.isFavorite(drama.id) ?? false,
              rank: rankOf?.call(drama),
              autofocus: autofocus && index == 0,
              onTap: () => onOpen(drama),
              onMore: onMore == null ? null : (point) => onMore!((drama, point)),
            ),
          ),
        );
      },
    );
  }
}

class AutoLoadMore extends StatefulWidget {
  const AutoLoadMore({super.key, required this.feed, required this.child});
  final DramaFeed feed;
  final Widget child;

  @override
  State<AutoLoadMore> createState() => _AutoLoadMoreState();
}

class _AutoLoadMoreState extends State<AutoLoadMore> {
  BuildContext? _scrollable;
  /// 是否已经排了一个帧末的加载回调，避免滚动期间重复排队。
  bool _queued = false;

  @override
  void initState() {
    super.initState();
    widget.feed.addListener(_feedChanged);
  }

  @override
  void didUpdateWidget(covariant AutoLoadMore oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.feed == widget.feed) return;
    oldWidget.feed.removeListener(_feedChanged);
    widget.feed.addListener(_feedChanged);
  }

  @override
  void dispose() {
    widget.feed.removeListener(_feedChanged);
    super.dispose();
  }

  void _feedChanged() {
    if (!widget.feed.canLoadMore) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final scrollable = _scrollable;
      if (!mounted || scrollable == null || !scrollable.mounted) return;
      final state = scrollable.findAncestorStateOfType<ScrollableState>();
      if (state?.position case final position?
          when position.hasContentDimensions) {
        _check(position, 0, scrollable);
      }
    });
  }

  bool _check(ScrollMetrics metrics, int depth, BuildContext? context) {
    if (depth != 0 || metrics.axis != Axis.vertical) return false;
    _scrollable = context;
    final feed = widget.feed;
    // 触底判定每一帧都会被滚动通知调到：同一时刻只排一个帧末回调，
    // 否则滚动期间会不停堆积（`loadMore` 自身另有并发保护）。
    if (_queued || !feed.canLoadMore || metrics.extentAfter >= 600) {
      return false;
    }
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      feed.loadMore();
    });
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) => _check(
          notification.metrics,
          notification.depth,
          notification.context,
        ),
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: (notification) => _check(
            notification.metrics,
            notification.depth,
            notification.context,
          ),
          child: widget.child,
        ),
      );
}

class FeedFooter extends StatelessWidget {
  const FeedFooter({super.key, required this.feed});
  final DramaFeed feed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SizedBox(
      height: 72,
      child: Center(
        child: feed.loadingMore
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              )
            : feed.error.isNotEmpty
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      feed.error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: caption,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FocusRing(
                    radius: 999,
                    child: TextButton(
                      onPressed: feed.retry,
                      child: const Text('重试'),
                    ),
                  ),
                ],
              )
            : feed.hasMore
            ? null
            : Text('已经到底了', style: caption),
      ),
    );
  }
}

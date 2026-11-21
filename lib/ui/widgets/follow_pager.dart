import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../app_motion.dart';

/// 标记横向分页中的当前列表，允许外壳识别多一层viewport的纵向通知。
class PagerScrollScope extends InheritedWidget {
  const PagerScrollScope({
    super.key,
    required this.active,
    required super.child,
  });
  final bool active;

  @override
  bool updateShouldNotify(PagerScrollScope oldWidget) =>
      active != oldWidget.active;
}

/// 受控分页：点击目标优先，拖动只在落定后提交；构建过程不派发业务事件。
/// [pageHeight] 用于外层已经负责纵向滚动的选集区，按实际页位置插值高度。
class FollowPager extends StatefulWidget {
  const FollowPager({
    super.key,
    required this.index,
    required this.count,
    required this.onSelected,
    required this.itemBuilder,
    this.controller,
    this.enabled = true,
    this.pageHeight,
  });

  final int index;
  final int count;
  final ValueChanged<int> onSelected;
  final IndexedWidgetBuilder itemBuilder;
  final PageController? controller;
  final bool enabled;
  final double Function(int index)? pageHeight;

  @override
  State<FollowPager> createState() => _FollowPagerState();
}

class _FollowPagerState extends State<FollowPager> {
  late final PageController _owned = PageController(initialPage: _index());
  bool _dragging = false;
  int _revision = 0;

  PageController get _pager => widget.controller ?? _owned;
  int _index() =>
      widget.count == 0 ? 0 : widget.index.clamp(0, widget.count - 1);

  @override
  void didUpdateWidget(FollowPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index ||
        oldWidget.count != widget.count ||
        oldWidget.controller != widget.controller) {
      _dragging = false;
      final revision = ++_revision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && revision == _revision) _follow();
      });
    }
  }

  void _follow() {
    if (!_pager.hasClients || widget.count == 0) return;
    final target = _index();
    final page = _pager.page ?? target.toDouble();
    if ((page - target).abs() < .001) return;
    final duration = AppMotion.duration(context, AppMotion.enter);
    // 远距离跳转不经过所有中间页，快速点击也不会回放过期目标。
    if (duration == Duration.zero) {
      _pager.jumpToPage(target);
    } else {
      if ((page - target).abs() > 1) {
        _pager.jumpToPage(target > page ? target - 1 : target + 1);
      }
      unawaited(
        _pager.animateToPage(
          target,
          duration: duration,
          curve: AppMotion.curve,
        ),
      );
    }
  }

  bool _scrolled(ScrollNotification event) {
    if (event.depth != 0 || event.metrics.axis != Axis.horizontal) return false;
    if (event is ScrollStartNotification && event.dragDetails != null) {
      _dragging = true;
      _revision++;
    } else if (event is ScrollEndNotification && _dragging) {
      _dragging = false;
      final revision = ++_revision;
      final page = (_pager.page ?? _index().toDouble()).round();
      // ScrollNotification 来自布局，帧末提交，避免在布局期间 setState。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            revision != _revision ||
            page < 0 ||
            page >= widget.count) {
          return;
        }
        if (page != widget.index) widget.onSelected(page);
      });
    }
    return false;
  }

  @override
  void dispose() {
    _owned.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.count == 0) return const SizedBox.shrink();
    final pages = NotificationListener<ScrollNotification>(
      onNotification: _scrolled,
      child: PageView.builder(
        controller: _pager,
        physics: widget.enabled ? null : const NeverScrollableScrollPhysics(),
        itemCount: widget.count,
        itemBuilder: (context, index) {
          final child = PagerScrollScope(
            active: index == _index(),
            child: widget.itemBuilder(context, index),
          );
          return ExcludeFocus(
            excluding: index != _index(),
            child: widget.pageHeight == null
                ? child
                : OverflowBox(
                    alignment: Alignment.topCenter,
                    minHeight: 0,
                    maxHeight: double.infinity,
                    child: child,
                  ),
          );
        },
      ),
    );
    final height = widget.pageHeight;
    if (height == null) return pages;
    return AnimatedBuilder(
      animation: _pager,
      child: pages,
      builder: (context, child) {
        final page =
            (_pager.hasClients && _pager.position.hasContentDimensions
                    ? _pager.page ?? _index().toDouble()
                    : _index().toDouble())
                .clamp(0.0, (widget.count - 1).toDouble());
        final low = page.floor();
        final high = (low + 1).clamp(0, widget.count - 1);
        return SizedBox(
          height: lerpDouble(height(low), height(high), page - low),
          child: child,
        );
      },
    );
  }
}

/// 每个懒构建页独占纵向控制器，不复用 PrimaryScrollController。
class PagerScrollPage extends StatefulWidget {
  const PagerScrollPage({super.key, required this.builder, this.onScroll});
  final Widget Function(BuildContext, ScrollController) builder;
  final ValueChanged<ScrollController>? onScroll;

  @override
  State<PagerScrollPage> createState() => PagerScrollPageState();
}

class PagerScrollPageState extends State<PagerScrollPage> {
  final scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    scroll.addListener(_changed);
  }

  void _changed() => widget.onScroll?.call(scroll);

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, scroll);
}

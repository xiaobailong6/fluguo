import 'package:flutter/material.dart';

import '../app_motion.dart';
import '../app_scope.dart';

/// 仅淡入当前 sliver，不保留退出树，也不改变滚动布局或浮动顶栏的几何。
/// 加载态保持可读；连续切换时只为最新就绪内容重启入场。
class SliverContentTransition extends StatefulWidget {
  const SliverContentTransition({
    super.key,
    required this.identity,
    required this.ready,
    required this.child,
  });

  final Object identity;
  final bool ready;
  final Widget child;

  @override
  State<SliverContentTransition> createState() =>
      _SliverContentTransitionState();
}

class _SliverContentTransitionState extends State<SliverContentTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    value: 1,
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: .55,
    end: 1,
  ).animate(_motion.drive(CurveTween(curve: AppMotion.navigationCurve)));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.dependOnInheritedWidgetOfExactType<AppScope>();
    _motion.duration = AppMotion.of(context, AppMotion.state);
    // 隐藏或减少动态效果时直接结束，恢复显示也不补播旧切换。
    if (AppMotion.reduced(context) || !TickerMode.valuesOf(context).enabled) {
      _motion.stop();
      _motion.value = 1;
    }
  }

  @override
  void didUpdateWidget(SliverContentTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity == widget.identity &&
        oldWidget.ready == widget.ready) {
      return;
    }
    _motion.stop();
    if (!widget.ready ||
        AppMotion.reduced(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _motion.value = 1;
    } else {
      _motion.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SliverFadeTransition(opacity: _opacity, sliver: widget.child);
}

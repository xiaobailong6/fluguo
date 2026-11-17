import 'package:flutter/material.dart';

import '../app_motion.dart';
import '../app_scope.dart';

/// 只动画同一棵内容树，避免退出页与进入页共用滚动控制器、焦点或媒体实例。
/// 加载时显示现有加载态；最新内容就绪后轻移淡入，连续切换只保留最新意图。
class LocalContentTransition extends StatefulWidget {
  const LocalContentTransition({
    super.key,
    required this.identity,
    required this.child,
    this.index = 0,
    this.ready = true,
    this.animateOnMount = false,
    this.travel = const Offset(18, 0),
  });

  final Object identity;
  final int index;
  final bool ready;
  final bool animateOnMount;
  final Offset travel;
  final Widget child;

  @override
  State<LocalContentTransition> createState() => _LocalContentTransitionState();
}

class _LocalContentTransitionState extends State<LocalContentTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    value: 1,
  );
  int _direction = 1;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.dependOnInheritedWidgetOfExactType<AppScope>();
    _motion.duration = AppMotion.of(context, AppMotion.state);
    if (AppMotion.reduced(context) || !TickerMode.valuesOf(context).enabled) {
      _motion.stop();
      _motion.value = 1;
    } else if (!_initialized && widget.animateOnMount && widget.ready) {
      _motion.forward(from: 0);
    }
    _initialized = true;
  }

  @override
  void didUpdateWidget(LocalContentTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = oldWidget.identity != widget.identity;
    if (widget.index != oldWidget.index) {
      _direction = widget.index < oldWidget.index ? -1 : 1;
    }
    if (changed || oldWidget.ready != widget.ready) {
      _motion.stop();
      if (!widget.ready ||
          AppMotion.reduced(context) ||
          !TickerMode.valuesOf(context).enabled) {
        _motion.value = 1;
      } else {
        _motion.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    return AnimatedBuilder(
      animation: _motion,
      child: widget.child,
      builder: (context, child) {
        final value = AppMotion.reduced(context)
            ? 1.0
            : AppMotion.navigationCurve.transform(_motion.value);
        return Opacity(
          opacity: .55 + .45 * value,
          child: Transform.translate(
            offset:
                Offset(widget.travel.dx * _direction * rtl, widget.travel.dy) *
                (1 - value),
            child: child,
          ),
        );
      },
    );
  }
}

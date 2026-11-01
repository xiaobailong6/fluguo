import 'package:flutter/material.dart';

import '../app_motion.dart';

/// 不搬动 Navigator，只动画当前页；离开页的媒体/焦点仍由外壳立即停用。
class TabPageTransition extends StatefulWidget {
  const TabPageTransition({
    super.key,
    required this.active,
    required this.direction,
    required this.child,
  });
  final bool active;
  final double direction;
  final Widget child;

  @override
  State<TabPageTransition> createState() => _TabPageTransitionState();
}

class _TabPageTransitionState extends State<TabPageTransition>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: AppMotion.navigation,
  );

  @override
  void initState() {
    super.initState();
    _motion.value = widget.active ? 1 : 0;
  }

  @override
  void didUpdateWidget(TabPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) {
      _motion.stop();
      _motion.value = 0;
    } else if (!oldWidget.active) {
      if (AppMotion.reduced(context)) {
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
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _motion,
    child: widget.child,
    builder: (context, child) {
      final value = AppMotion.reduced(context)
          ? 1.0
          : AppMotion.navigationCurve.transform(_motion.value);
      return Opacity(
        opacity: .72 + .28 * value,
        child: Transform.translate(
          offset: Offset(widget.direction * 18 * (1 - value), 0),
          child: child,
        ),
      );
    },
  );
}

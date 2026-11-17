import 'package:flutter/material.dart';

import '../app_motion.dart';
import '../app_scope.dart';

/// 借鉴上游 ToggleIconSwitcher 的轻缩放反馈，但只保留当前图标。
/// 按钮、焦点和语义立即反映最新状态，快速切换不会积累退出图标。
class StateIcon extends StatefulWidget {
  const StateIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });
  final IconData icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  State<StateIcon> createState() => _StateIconState();
}

class _StateIconState extends State<StateIcon>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, value: 1);

  bool get _still =>
      AppMotion.reduced(context) || !TickerMode.valuesOf(context).enabled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.dependOnInheritedWidgetOfExactType<AppScope>();
    _controller.duration = AppMotion.of(context, AppMotion.press);
    if (_still) _controller.value = 1;
  }

  @override
  void didUpdateWidget(StateIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.icon != widget.icon) {
      if (_still) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: Icon(
      widget.icon,
      size: widget.size,
      color: widget.color,
      semanticLabel: widget.semanticLabel,
    ),
    builder: (context, child) {
      final value = _still
          ? 1.0
          : AppMotion.navigationCurve.transform(_controller.value);
      return Opacity(
        opacity: .6 + .4 * value,
        child: Transform.scale(scale: .82 + .18 * value, child: child),
      );
    },
  );
}

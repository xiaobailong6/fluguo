import 'package:flutter/material.dart';

import '../app_motion.dart';
import '../app_scope.dart';

/// 控件立即退出交互，画面允许短暂淡出；不保留另一份内容或改变布局尺寸。
class ControlPresence extends StatefulWidget {
  const ControlPresence({
    super.key,
    required this.visible,
    required this.child,
  });
  final bool visible;
  final Widget child;

  @override
  State<ControlPresence> createState() => _ControlPresenceState();
}

class _ControlPresenceState extends State<ControlPresence>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );
  bool get _still =>
      AppMotion.reduced(context) || !TickerMode.valuesOf(context).enabled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.dependOnInheritedWidgetOfExactType<AppScope>();
    _controller.duration = AppMotion.of(context, AppMotion.state);
    if (_still) _controller.value = widget.visible ? 1 : 0;
  }

  @override
  void didUpdateWidget(ControlPresence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    if (_still) {
      _controller.value = widget.visible ? 1 : 0;
    } else {
      _controller.animateTo(widget.visible ? 1 : 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !widget.visible,
    child: ExcludeFocus(
      excluding: !widget.visible,
      child: ExcludeSemantics(
        excluding: !widget.visible,
        child: AnimatedBuilder(
          animation: _controller,
          child: widget.child,
          builder: (context, child) {
            final value = _still
                ? (widget.visible ? 1.0 : 0.0)
                : _controller.value;
            return Offstage(
              offstage: !widget.visible && value == 0,
              child: Opacity(
                opacity: AppMotion.navigationCurve.transform(value),
                child: child,
              ),
            );
          },
        ),
      ),
    ),
  );
}

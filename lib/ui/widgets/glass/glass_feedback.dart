import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_motion.dart';

/// 仅提供反馈，不注册点击/拖动识别器，保留子按钮的手势、焦点和语义。
class GlassFeedback extends StatefulWidget {
  const GlassFeedback({
    super.key,
    required this.child,
    this.radius = 20,
    this.enabled = true,
    this.scaleOnPress = true,
  });
  final Widget child;
  final double radius;
  final bool enabled;
  final bool scaleOnPress;

  @override
  State<GlassFeedback> createState() => _GlassFeedbackState();
}

class _GlassFeedbackState extends State<GlassFeedback> {
  bool _hovered = false;
  bool _pressed = false;
  int? _pointer;
  Offset? _origin;

  void _release() {
    _pointer = null;
    _origin = null;
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  void didUpdateWidget(GlassFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _pressed = false;
      _hovered = false;
      _pointer = null;
      _origin = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final pressed = widget.enabled && _pressed;
    final target = pressed
        ? 1.0
        : widget.enabled && _hovered
        ? .5
        : 0.0;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (!focused) _release();
      },
      onKeyEvent: (_, event) {
        if (widget.enabled &&
            const [
              LogicalKeyboardKey.enter,
              LogicalKeyboardKey.space,
              LogicalKeyboardKey.select,
            ].contains(event.logicalKey)) {
          if (event is KeyDownEvent) setState(() => _pressed = true);
          if (event is KeyUpEvent) _release();
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        onEnter: (_) {
          if (widget.enabled) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (_hovered) setState(() => _hovered = false);
          _release();
        },
        child: Listener(
          onPointerDown: (event) {
            if (!widget.enabled || _pointer != null) return;
            _pointer = event.pointer;
            _origin = event.position;
            setState(() => _pressed = true);
          },
          onPointerMove: (event) {
            // 进入滚动后立即取消压感，不能让一整段滑动一直保持按下。
            if (event.pointer == _pointer &&
                _origin != null &&
                (event.position - _origin!).distance > 12) {
              _release();
            }
          },
          onPointerUp: (event) {
            if (event.pointer == _pointer) _release();
          },
          onPointerCancel: (event) {
            if (event.pointer == _pointer) _release();
          },
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: target),
            duration: AppMotion.duration(
              context,
              pressed ? AppMotion.press : AppMotion.state,
            ),
            curve: AppMotion.curve,
            builder: (context, value, child) => AnimatedScale(
              scale: reduced || !widget.scaleOnPress || !pressed ? 1 : .96,
              duration: AppMotion.duration(
                context,
                pressed ? AppMotion.press : AppMotion.state,
              ),
              curve: AppMotion.curve,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.radius),
                  boxShadow: [
                    if (value > 0)
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .10 * value),
                        blurRadius: 6,
                        offset: Offset(0, 2 - value),
                      ),
                  ],
                ),
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    child!,
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(widget.radius),
                            border: Border.all(
                              color: Colors.white.withValues(
                                alpha: .22 * value,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            child: RepaintBoundary(child: widget.child),
          ),
        ),
      ),
    );
  }
}

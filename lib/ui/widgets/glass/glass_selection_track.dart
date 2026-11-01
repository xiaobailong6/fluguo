import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_motion.dart';

/// 单个选中胶囊跨项目连续移动；ImplicitlyAnimatedWidget 自动从当前位置转向新目标。
class GlassSelectionTrack extends ImplicitlyAnimatedWidget {
  GlassSelectionTrack({
    super.key,
    required BuildContext context,
    required this.selectedIndex,
    required this.children,
    required this.height,
  }) : super(
         duration: AppMotion.duration(context, AppMotion.navigation),
         curve: AppMotion.curve,
       );

  final int selectedIndex;
  final List<Widget> children;
  final double height;

  @override
  AnimatedWidgetBaseState<GlassSelectionTrack> createState() =>
      _GlassSelectionTrackState();
}

class _GlassSelectionTrackState
    extends AnimatedWidgetBaseState<GlassSelectionTrack> {
  Tween<double>? _position;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _position =
        visitor(
              _position,
              widget.selectedIndex.toDouble(),
              (value) => Tween<double>(begin: value as double),
            )
            as Tween<double>?;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = widget.children.length;
        final width = constraints.maxWidth / count;
        final position = _position!.evaluate(animation).clamp(0.0, count - 1.0);
        final logical = Directionality.of(context) == TextDirection.rtl
            ? count - 1 - position
            : position;
        // 仅移动途中微伸展，落位后恢复原宽；不会改变按钮布局或点击区域。
        final stretch = AppMotion.reduced(context) || !controller.isAnimating
            ? 0.0
            : math.sin(math.pi * controller.value) * math.min(6, width * .06);
        final indicatorWidth = math.min(
          constraints.maxWidth,
          width + stretch * 2,
        );
        final left = (logical * width - stretch).clamp(
          0.0,
          constraints.maxWidth - indicatorWidth,
        );
        return SizedBox(
          height: widget.height,
          child: Stack(
            children: [
              Positioned(
                left: left,
                top: 0,
                width: indicatorWidth,
                height: widget.height,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: DecoratedBox(
                      key: const ValueKey('liquid-nav-indicator'),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(widget.height / 2),
                        color: colors.secondaryContainer,
                        border: Border.all(
                          color: colors.onSecondaryContainer.withValues(
                            alpha: .08,
                          ),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color.alphaBlend(
                              Colors.white.withValues(alpha: .08),
                              colors.secondaryContainer,
                            ),
                            colors.secondaryContainer,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final child in widget.children) Expanded(child: child),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

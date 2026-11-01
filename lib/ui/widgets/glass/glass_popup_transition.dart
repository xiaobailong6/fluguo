import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_motion.dart';
import '../../app_scope.dart';

/// 路由只管理时序；面板自己选择变换原点，避免把整屏当成触发器。
class GlassPopupRoute<T> extends PopupRoute<T> {
  GlassPopupRoute({
    required BuildContext context,
    required this.builder,
    this.barrierColor = Colors.black26,
  }) : reduced = AppMotion.reduced(context),
       barrierLabel = MaterialLocalizations.of(
         context,
       ).modalBarrierDismissLabel,
       themes = InheritedTheme.capture(
         from: context,
         to: Navigator.of(context, rootNavigator: true).context,
       ),
       scope = context.dependOnInheritedWidgetOfExactType<AppScope>();

  final Widget Function(BuildContext, Animation<double>) builder;
  final bool reduced;
  final CapturedThemes themes;
  final AppScope? scope;
  @override
  final Color? barrierColor;
  @override
  final String barrierLabel;
  @override
  bool get barrierDismissible => true;
  @override
  Duration get transitionDuration => reduced ? Duration.zero : AppMotion.enter;
  @override
  Duration get reverseTransitionDuration =>
      reduced ? Duration.zero : AppMotion.exit;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    Widget child = Builder(builder: (context) => builder(context, animation));
    // AppScope 不是 InheritedTheme，跨根导航时显式保留用户的玻璃和形态设置。
    if (scope case final scope?) {
      child = AppScope(
        repository: scope.repository,
        formFactor: scope.formFactor,
        systemColorAvailable: scope.systemColorAvailable,
        glass: scope.glass,
        version: scope.version,
        child: child,
      );
    }
    return themes.wrap(child);
  }
}

class GlassPopupTransition extends StatelessWidget {
  const GlassPopupTransition({
    super.key,
    required this.animation,
    required this.child,
    this.alignment = Alignment.center,
    this.offset = const Offset(0, 4),
  });
  final Animation<double> animation;
  final Widget child;
  final Alignment alignment;
  final Offset offset;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return child;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        // 正反向用同一映射，途中关闭/重开不会因换曲线产生跳帧。
        final value = AppMotion.curve.transform(animation.value);
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: offset * (1 - value),
            child: Transform.scale(
              scale: .96 + .04 * value,
              alignment: alignment,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// 锚点和布局都使用目标 Overlay 坐标，底部空间不足时向上展开。
class GlassAnchoredPopup extends StatelessWidget {
  const GlassAnchoredPopup({
    super.key,
    required this.anchor,
    required this.width,
    required this.animation,
    required this.child,
    this.maxHeight = double.infinity,
  });
  final Rect anchor;
  final double width;
  final double maxHeight;
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final safe = Rect.fromLTRB(
        math.max(16, media.padding.left),
        math.max(8, media.padding.top),
        constraints.maxWidth - math.max(16, media.padding.right),
        constraints.maxHeight -
            math.max(
              8,
              math.max(media.padding.bottom, media.viewInsets.bottom),
            ),
      );
      final menuWidth = math.min(width, math.max(0.0, safe.width));
      final below = math.max(0.0, safe.bottom - anchor.bottom - 6);
      final above = math.max(0.0, anchor.top - safe.top - 6);
      final useBelow = below >= math.min(maxHeight, 144) || below >= above;
      final height = math.min(maxHeight, useBelow ? below : above);
      final rtl = Directionality.of(context) == TextDirection.rtl;
      final left = (rtl ? anchor.left : anchor.right - menuWidth)
          .clamp(safe.left, math.max(safe.left, safe.right - menuWidth))
          .toDouble();
      final originX = menuWidth == 0
          ? 0.0
          : ((anchor.center.dx - left) / menuWidth * 2 - 1).clamp(-1.0, 1.0);
      return Stack(
        children: [
          Positioned(
            left: left,
            width: menuWidth,
            top: useBelow ? math.max(safe.top, anchor.bottom + 6) : null,
            bottom: useBelow
                ? null
                : math.max(
                    constraints.maxHeight - safe.bottom,
                    constraints.maxHeight - anchor.top + 6,
                  ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: height),
              child: GlassPopupTransition(
                animation: animation,
                alignment: Alignment(originX, useBelow ? -1 : 1),
                offset: Offset(0, useBelow ? 4 : -4),
                child: child,
              ),
            ),
          ),
        ],
      );
    },
  );
}

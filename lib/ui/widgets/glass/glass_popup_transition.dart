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
    this.dismissible = true,
  }) : _enter = AppMotion.of(context, AppMotion.enter),
       _exit = AppMotion.of(context, AppMotion.exit),
       barrierLabel = MaterialLocalizations.of(
         context,
       ).modalBarrierDismissLabel,
       themes = InheritedTheme.capture(
         from: context,
         to: Navigator.of(context, rootNavigator: true).context,
       ),
     // 只读取当前值、不登记 AppScope 依赖：路由构造发生在手势回调里，
     // `depend` 会把依赖永久挂在锚点元素上，AppScope 一变就白重建一次。
     // 注意 `_enter/_exit` 走 `AppMotion.of` 时会读 MediaQuery（减少动画），
     // 锚点元素因此仍会登记一次 MediaQuery 依赖，这是判定动效档位所需。
     scope = context.getInheritedWidgetOfExactType<AppScope>();

  final Widget Function(BuildContext, Animation<double>) builder;
  final CapturedThemes themes;
  final AppScope? scope;
  @override
  final Color? barrierColor;
  @override
  final String barrierLabel;

  /// 是否允许点遮罩/返回键关闭。
  ///
  /// 进度类弹窗要传 false：此时 `maybePop` 返回 doNotPop，遮罩和返回键都不会
  /// 把面板关掉，与 Material 的 `barrierDismissible: false` 语义一致。
  final bool dismissible;

  @override
  bool get barrierDismissible => dismissible;

  /// 构造时算好：`AppMotion.of` 已处理减少动画（归零）与电视端压缩。
  final Duration _enter;
  final Duration _exit;

  @override
  Duration get transitionDuration => _enter;
  @override
  Duration get reverseTransitionDuration => _exit;

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
    this.offset = const Offset(0, 10),
  });
  final Animation<double> animation;
  final Widget child;

  /// 只做位移，不做缩放：缩放会让玻璃的模糊层在过渡中重采样，
  /// 和背后正在滚动的内容互相闪烁。锚点方向由调用方换算成 [offset]。
  final Offset offset;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return child;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        // 正反向用同一映射，途中关闭/重开不会因换曲线产生跳帧。
        // 淡入淡出叠加一段小位移：纯淡入容易显得"啪"地出现，
        // 位移给面板一个 settle 的方向感；不做缩放，缩放会让玻璃
        // 模糊层在过渡中重采样，出现与底栏等背景内容的闪烁。
        final value = AppMotion.curve.transform(animation.value);
        return Opacity(
          opacity: value.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: offset * (1 - value),
            child: child,
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
      // 只订阅用到的内边距：整份 MediaQuery 会让键盘开合、文本缩放也触发重排。
      final padding = MediaQuery.paddingOf(context);
      final insets = MediaQuery.viewInsetsOf(context);
      final safe = Rect.fromLTRB(
        math.max(12, padding.left),
        math.max(8, padding.top),
        constraints.maxWidth - math.max(12, padding.right),
        constraints.maxHeight -
            math.max(8, math.max(padding.bottom, insets.bottom)),
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
      // 位移方向由「向上开还是向下开」决定，锚点水平位置只影响 left，
      // 不再参与过渡：这一段以前算过缩放原点，改成纯位移后就没人读了。
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
                offset: Offset(0, useBelow ? 12 : -12),
                child: child,
              ),
            ),
          ),
        ],
      );
    },
  );
}

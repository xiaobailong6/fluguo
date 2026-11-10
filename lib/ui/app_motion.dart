import 'package:flutter/material.dart';

/// 同类交互共用节奏；辅助导航和减少动态效果均不运行位移/缩放动画。
abstract final class AppMotion {
  static const press = Duration(milliseconds: 100);
  static const state = Duration(milliseconds: 160);
  static const enter = Duration(milliseconds: 320);
  static const exit = Duration(milliseconds: 220);
  static const navigation = Duration(milliseconds: 340);
  static const chrome = Duration(milliseconds: 400);
  static const heroEnter = Duration(milliseconds: 400);
  static const heroExit = Duration(milliseconds: 260);
  static const curve = Curves.easeOutCubic;
  static const navigationCurve = Curves.easeInOutCubic;

  static bool reduced(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    return media?.disableAnimations == true ||
        media?.accessibleNavigation == true;
  }

  static Duration duration(BuildContext context, Duration normal) =>
      reduced(context) ? Duration.zero : normal;

  static AnimationStyle sheet(BuildContext context) => AnimationStyle(
    duration: duration(context, enter),
    reverseDuration: duration(context, exit),
  );

  /// 播放页等全屏页面的淡入淡出过渡：进入时旧页面保持可见，
  /// 播放器首帧前的空档不会露出白色底色，比默认滑动更平缓。
  static PageRouteBuilder<T> page<T>(
    BuildContext context,
    WidgetBuilder builder, {
    bool allowSnapshotting = true,
    String? name,
  }) {
    final isReduced = reduced(context);
    return PageRouteBuilder<T>(
      settings: name == null ? null : RouteSettings(name: name),
      pageBuilder: (_, _, _) => Builder(builder: builder),
      transitionDuration: duration(context, enter),
      reverseTransitionDuration: duration(context, exit),
      allowSnapshotting: allowSnapshotting,
      transitionsBuilder: isReduced
          ? (_, _, _, child) => child
          : (_, animation, _, child) => FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: curve,
                reverseCurve: curve,
              ),
              child: child,
            ),
    );
  }
}

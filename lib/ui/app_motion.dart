import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'back_gesture.dart';

/// 同类交互共用节奏；辅助导航和减少动态效果均不运行位移/缩放动画。
///
/// 曲线取 Material 3 标准缓动的数值，直接写成 [Cubic]：
/// - 进入用 `emphasizedDecelerate`，起步快、中后段有长尾，收得稳；
/// - 退出用 `emphasizedAccelerate`，离开时先缓后快，不拖沓；
/// - 对称场景（Tab 互换、焦点移动）用 `standard`。
///
/// 之前全项目统一 `easeOutCubic`：它在前 20% 时间就走完约一半位移，
/// 160ms 的淡入前 32ms 就变完一半，视觉上等于「没有动画」。
abstract final class AppMotion {
  static const press = Duration(milliseconds: 120);
  static const state = Duration(milliseconds: 200);
  static const enter = Duration(milliseconds: 340);
  static const exit = Duration(milliseconds: 260);
  static const navigation = Duration(milliseconds: 360);
  static const chrome = Duration(milliseconds: 400);
  static const heroEnter = Duration(milliseconds: 400);
  static const heroExit = Duration(milliseconds: 260);

  /// 出现 / 展开（M3 emphasizedDecelerate）。
  static const curve = Cubic(0.05, 0.7, 0.1, 1);

  /// 消失 / 收起（M3 emphasizedAccelerate）。
  ///
  /// 只用于有明确正反两向、可以分别指定曲线的动画（路由反向、切页退出）。
  /// `AnimatedOpacity` 这类隐式动画只有一个 `curve`，正反同向，继续用 [curve]。
  static const exitCurve = Cubic(0.3, 0, 0.8, 0.15);

  /// 对称过渡（M3 standard）：Tab 之间互换、焦点框移动。
  static const navigationCurve = Cubic(0.2, 0, 0, 1);

  /// 电视端上限：遥控器连按时，等待感比动效完整性更重要。
  static const televisionMax = Duration(milliseconds: 200);

  static bool reduced(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    return media?.disableAnimations == true ||
        media?.accessibleNavigation == true;
  }

  /// 取实际时长：减少动画时归零，电视形态压到 [televisionMax] 以内。
  ///
  /// 只读 [AppScope] 而不登记依赖：这个函数也会在 `initState` /
  /// `didChangeDependencies` 里给 `AnimationController` 设时长，用
  /// `dependOnInheritedWidgetOfExactType` 会在那些阶段抛错。
  static Duration of(BuildContext context, Duration normal) {
    if (reduced(context)) return Duration.zero;
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    if ((scope?.television ?? false) && normal > televisionMax) {
      return televisionMax;
    }
    return normal;
  }

  static Duration duration(BuildContext context, Duration normal) =>
      of(context, normal);

  static AnimationStyle sheet(BuildContext context) => AnimationStyle(
    duration: duration(context, enter),
    reverseDuration: duration(context, exit),
  );

  /// 播放页等全屏页面的过渡：淡入 + 轻微放大。
  ///
  /// 只做透明度时，340ms 的纯淡入在快曲线上几乎感知不到变化；补一段
  /// 0.96→1 的缩放让页面「落」下来。进入时旧页面保持可见，播放器首帧前的
  /// 空档不会露出白色底色。
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
          : (routeContext, animation, _, child) {
              final curved = CurvedAnimation(
                parent: animation,
                curve: curve,
                reverseCurve: exitCurve,
              );
              final content = FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  scale: Tween(begin: .96, end: 1.0).animate(curved),
                  child: child,
                ),
              );
              // Android 13+ 的预测式返回：页面跟手缩小。系统不下发事件时
              // BackGesture 完全不介入，其它平台也保持原有转场。
              final route = ModalRoute.of(routeContext);
              if (route is! PageRoute) return content;
              return BackGesture(
                route: route,
                duration: duration(routeContext, state),
                curve: navigationCurve,
                child: content,
              );
            },
    );
  }
}

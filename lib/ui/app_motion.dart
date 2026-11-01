import 'package:flutter/material.dart';

/// 同类交互共用节奏；辅助导航和减少动态效果均不运行位移/缩放动画。
abstract final class AppMotion {
  static const press = Duration(milliseconds: 100);
  static const state = Duration(milliseconds: 160);
  static const enter = Duration(milliseconds: 240);
  static const exit = Duration(milliseconds: 160);
  static const navigation = Duration(milliseconds: 260);
  static const curve = Curves.easeOutCubic;

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
}

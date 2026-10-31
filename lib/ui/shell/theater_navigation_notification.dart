import 'package:flutter/widgets.dart';

/// 兼容旧调用方保留的失效通知。
/// Shell 不再监听此通知；剧场中央点击不能唤出手机导航。
/// 离开剧场应调用 TheaterPage 的显式 onExit 回调。
class TheaterNavigationToggleNotification extends Notification {
  const TheaterNavigationToggleNotification();
}

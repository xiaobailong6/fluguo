import 'package:flutter/widgets.dart';

/// 剧场中央单击时从 TheaterPage 内部 context 派发：
/// `const TheaterNavigationToggleNotification().dispatch(context);`
/// 仅表示一次用户主动切换，不应在翻页、滚动或播放状态变化时派发。
/// Shell 仅在手机、当前为剧场且没有覆盖路由时消费；桌面/TV 忽略。
class TheaterNavigationToggleNotification extends Notification {
  const TheaterNavigationToggleNotification();
}

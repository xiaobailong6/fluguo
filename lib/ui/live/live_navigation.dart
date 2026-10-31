import 'package:flutter/material.dart';

import '../../live_models.dart';
import '../../local_store.dart';
import 'live_player_page.dart';

/// 在入口所在的导航栈打开子页，返回时保留来源；不切换 Tab 或清空历史页。
Future<T?> pushLivePage<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool allowSnapshotting = true,
}) => Navigator.of(context).push<T>(
  MaterialPageRoute<T>(builder: builder, allowSnapshotting: allowSnapshotting),
);

Future<void> openLivePlayer(
  BuildContext context,
  LocalStore store,
  LivePlatform platform,
  LiveRoom room,
) => pushLivePage<void>(
  context,
  (_) => LivePlayerPage(
    platform: platform,
    room: room,
    store: store,
    defaultQuality: store.playbackPreferences.liveQuality,
  ),
  // 视频纹理不能可靠地进入路由截图，过渡期间始终绘制真实播放页面。
  allowSnapshotting: false,
);

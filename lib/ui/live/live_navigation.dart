import 'package:flutter/material.dart';

import '../../live_models.dart';
import '../../local_store.dart';
import 'live_player_page.dart';

/// 直播子页归属直播 Tab 的 Navigator，不能压入首页外层导致返回切到短剧。
Future<T?> pushLivePage<T>(BuildContext context, WidgetBuilder builder) =>
    Navigator.of(context).push<T>(MaterialPageRoute<T>(builder: builder));

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
);

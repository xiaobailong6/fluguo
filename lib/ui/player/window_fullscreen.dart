import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_device.dart';
import '../../desktop_window_state.dart';

Future<void> setWindowFullScreen(bool value) async {
  final previous = DesktopWindowState.instance.fullScreenRequested(value);
  try {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await AppDevice.channel.invokeMethod<void>('setFullScreen', {
        'enabled': value,
      });
    } else {
      await windowManager.setFullScreen(value);
    }
  } catch (_) {
    DesktopWindowState.instance.fullScreenRequested(previous);
  }
}

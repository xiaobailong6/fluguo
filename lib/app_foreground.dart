import 'package:flutter/widgets.dart';

/// 应用是否在用户眼前：前台运行，或窗口仍可见但已失焦（inactive）。
///
/// 定时轮询与直播续期据此让路：看不见的时候不做没人会看到的事情；
/// 回到前台后最多一个轮询周期内补回，界面显示内容与原来一致。
bool get appForeground {
  try {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  } catch (_) {
    // 没有绑定实例（纯 Dart 测试等）时按前台处理，保持原有行为。
    return true;
  }
}

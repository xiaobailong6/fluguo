import 'dart:async';

import 'package:flutter/foundation.dart';

/// 用 Zone 跨越会丢弃 Future 的 ValueChanged，不改变现有 onMore 接口。
class PosterMenuActivity extends ValueNotifier<bool> {
  PosterMenuActivity() : super(false);

  static final Object _zoneKey = Object();
  static PosterMenuActivity? get current =>
      Zone.current[_zoneKey] as PosterMenuActivity?;

  bool _disposed = false;
  bool _invoking = false;
  bool _holds = false;

  /// 菜单是否还占着这张海报（含退场动画期间）。用它拦重复点击：
  /// [release] 之后按钮已经回来了，但守卫要留到 [end]。
  bool get busy => _disposed || _holds;

  void invoke(VoidCallback callback) {
    if (busy || _invoking) return;
    _invoking = true;
    try {
      runZoned(callback, zoneValues: {_zoneKey: this});
    } finally {
      // 非菜单回调无需等待，也不能把海报永久留在 busy 状态。
      _invoking = false;
    }
  }

  bool begin() {
    if (busy) return false;
    _holds = true;
    value = true;
    return true;
  }

  /// 退场一开始就把按钮放回来。
  ///
  /// 原来要等 `route.completed`（overlay 已移除）才回来：面板彻底没了以后
  /// 画面先空一下、按钮再出现，看起来就是「闪一下才显示」。现在按钮的回场
  /// 与面板的淡出交叉进行，同一个位置是连续变化的。
  void release() {
    if (!_disposed) value = false;
  }

  void end() {
    _holds = false;
    if (!_disposed) value = false;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

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

  void invoke(VoidCallback callback) {
    if (_disposed || value || _invoking) return;
    _invoking = true;
    try {
      runZoned(callback, zoneValues: {_zoneKey: this});
    } finally {
      // 非菜单回调无需等待，也不能把海报永久留在 busy 状态。
      _invoking = false;
    }
  }

  bool begin() {
    if (_disposed || value) return false;
    value = true;
    return true;
  }

  void end() {
    if (!_disposed) value = false;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

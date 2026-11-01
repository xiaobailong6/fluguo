import 'dart:async';

import 'package:flutter/foundation.dart';

/// 拖动只通知进度条和时间提示，不让高频手势重建视频及整页控件。
class PlaybackSeekController
    extends ValueNotifier<({bool dragging, double? milliseconds})> {
  PlaybackSeekController() : super((dragging: false, milliseconds: null));

  Timer? _timer;
  double? _target;

  void start(double milliseconds) {
    _timer?.cancel();
    _target = null;
    value = (dragging: true, milliseconds: milliseconds);
  }

  void update(double milliseconds) {
    if (!value.dragging) return;
    value = (dragging: true, milliseconds: milliseconds);
  }

  void finish(double milliseconds) {
    _timer?.cancel();
    _target = milliseconds;
    // 原生 seek 回报可能晚一拍，短暂保留松手位置，避免滑块先跳回旧进度。
    value = (dragging: false, milliseconds: milliseconds);
    _timer = Timer(const Duration(seconds: 2), reset);
  }

  void acceptPosition(Duration position) {
    final target = _target;
    if (target != null && (position.inMilliseconds - target).abs() < 1000) {
      reset();
    }
  }

  void reset() {
    _timer?.cancel();
    _timer = null;
    _target = null;
    value = (dragging: false, milliseconds: null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

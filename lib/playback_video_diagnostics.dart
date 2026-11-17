import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'diary_service.dart';

typedef VideoPropertyReader = Future<String> Function(String name);

/// 只观察当前播放器，不修改视频实例、解码偏好或显示比例。
class PlaybackVideoDiagnostics {
  StreamSubscription<VideoParams>? _subscription;
  int _binding = 0;
  int _sample = 0;
  bool _disposed = false;
  String? _last;

  void bind(Player player) {
    final platform = player.platform;
    observe(
      player.stream.videoParams,
      read: platform is NativePlayer ? platform.getProperty : null,
      initial: player.state.videoParams,
    );
  }

  /// 可注入属性读取器，离线测试无需加载 mpv。
  void observe(
    Stream<VideoParams> parameters, {
    VideoPropertyReader? read,
    VideoParams? initial,
  }) {
    if (_disposed) return;
    unawaited(_subscription?.cancel());
    final binding = ++_binding;
    _sample++;
    _last = null;
    _subscription = parameters.listen((value) {
      unawaited(_log(value, read, binding));
    }, onError: (Object _) {});
    if (initial != null) unawaited(_log(initial, read, binding));
  }

  Future<void> _log(
    VideoParams params,
    VideoPropertyReader? read,
    int binding,
  ) async {
    final sample = ++_sample;
    if (_disposed ||
        !DiaryService.traceEnabled ||
        read == null ||
        binding != _binding ||
        (params.w ?? 0) <= 0 ||
        (params.h ?? 0) <= 0) {
      return;
    }
    try {
      // 白名单属性不涉及地址、请求头或解密参数；关闭 trace 时连读取也不执行。
      final values = await Future.wait([
        for (final key in const [
          'hwdec-current',
          'current-vo',
          'video-codec',
          'container-fps',
        ])
          read(key),
      ]);
      if (_disposed ||
          !DiaryService.traceEnabled ||
          binding != _binding ||
          sample != _sample) {
        return;
      }
      final message =
          '[Video] hwdec=${_safe(values[0])} vo=${_safe(values[1])} '
          'codec=${_safe(values[2])} fps=${_safe(values[3])} '
          'pixel=${_safe(params.pixelformat ?? '')} '
          'size=${params.w}x${params.h} display=${params.dw ?? params.w}x${params.dh ?? params.h}';
      if (message == _last) return;
      _last = message;
      DiaryService.trace(() => message);
    } catch (_) {
      // 原生属性可能在切集/释放时不可用，诊断失败绝不进入播放恢复流程。
    }
  }

  static String _safe(String value) {
    final text = value.trim();
    return text.isEmpty
        ? 'unknown'
        : RegExp(r'^[a-zA-Z0-9_.+ -]{1,80}$').hasMatch(text)
        ? text
        : '[redacted]';
  }

  /// 同一 Player 换媒体也要使上一媒体尚未返回的属性查询失效。
  void reset() {
    _sample++;
    _last = null;
  }

  void dispose() {
    _disposed = true;
    _binding++;
    _sample++;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}

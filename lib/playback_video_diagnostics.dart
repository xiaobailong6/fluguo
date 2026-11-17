import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'diary_service.dart';

typedef VideoPropertyReader = Future<String> Function(String name);

/// 只观察当前播放器，不修改视频实例、解码偏好或显示比例。
class PlaybackVideoDiagnostics {
  StreamSubscription<VideoParams>? _subscription;
  StreamSubscription<Duration>? _positionSubscription;
  String? _boundSignature;
  int _binding = 0;
  int _sample = 0;
  bool _disposed = false;
  String? _last;

  void bind(Player player, {bool Function()? allowed}) {
    if (_disposed) return;
    final platform = player.platform;
    // 先关闭上一个绑定；播放恢复时不在 Surface/decoder 切换中读取属性。
    observe(const Stream<VideoParams>.empty());
    final binding = _binding;
    var reading = false;
    void probe(VideoParams params) {
      if (reading ||
          _disposed ||
          !DiaryService.traceEnabled ||
          platform is! NativePlayer ||
          allowed?.call() == false ||
          !player.state.playing ||
          player.state.buffering ||
          player.state.position < const Duration(seconds: 2)) {
        return;
      }
      final signature =
          '${params.w}/${params.h}/${params.dw}/${params.dh}/${params.pixelformat}';
      if (_boundSignature == signature) return;
      reading = true;
      unawaited(
        _log(
          params,
          platform.getProperty,
          binding,
          eligible: () =>
              allowed?.call() != false &&
              player.state.playing &&
              !player.state.buffering,
        ).then((accepted) {
          reading = false;
          if (accepted && !_disposed && binding == _binding) {
            _boundSignature = signature;
          }
        }),
      );
    }

    unawaited(_subscription?.cancel());
    _subscription = player.stream.videoParams.listen(
      probe,
      onError: (Object _) {},
    );
    _positionSubscription = player.stream.position.listen(
      (_) => probe(player.state.videoParams),
    );
    probe(player.state.videoParams);
  }

  /// 可注入属性读取器，离线测试无需加载 mpv。
  void observe(
    Stream<VideoParams> parameters, {
    VideoPropertyReader? read,
    VideoParams? initial,
  }) {
    if (_disposed) return;
    unawaited(_subscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = null;
    _boundSignature = null;
    final binding = ++_binding;
    _sample++;
    _last = null;
    _subscription = parameters.listen((value) {
      unawaited(_log(value, read, binding).then<void>((_) {}));
    }, onError: (Object _) {});
    if (initial != null) {
      unawaited(_log(initial, read, binding).then<void>((_) {}));
    }
  }

  Future<bool> _log(
    VideoParams params,
    VideoPropertyReader? read,
    int binding, {
    bool Function()? eligible,
  }) async {
    final sample = ++_sample;
    if (_disposed ||
        !DiaryService.traceEnabled ||
        read == null ||
        binding != _binding ||
        (params.w ?? 0) <= 0 ||
        (params.h ?? 0) <= 0) {
      return false;
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
          eligible?.call() == false ||
          sample != _sample) {
        return false;
      }
      final message =
          '[Video] hwdec=${_safe(values[0])} vo=${_safe(values[1])} '
          'codec=${_safe(values[2])} fps=${_safe(values[3])} '
          'pixel=${_safe(params.pixelformat ?? '')} '
          'size=${params.w}x${params.h} display=${params.dw ?? params.w}x${params.dh ?? params.h}';
      if (message == _last) return true;
      _last = message;
      DiaryService.trace(() => message);
      return true;
    } catch (_) {
      // 原生属性可能在切集/释放时不可用，诊断失败绝不进入播放恢复流程。
      return false;
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
    _boundSignature = null;
    _last = null;
  }

  void dispose() {
    _disposed = true;
    _binding++;
    _sample++;
    unawaited(_subscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = null;
    _subscription = null;
  }
}

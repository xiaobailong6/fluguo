import 'dart:async';

/// 直播恢复共用一份预算。用户暂停/隐藏会取消所有定时动作；只有持续推进
/// 的播放才恢复预算，不能凭 open 成功或一个 playing 事件无限重试。
class LiveRecovery {
  LiveRecovery({
    required this.onRetry,
    this.onExhausted,
    DateTime Function()? now,
    this.stallTimeout = const Duration(seconds: 20),
    this.stableDuration = const Duration(seconds: 30),
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
  }) : _now = now ?? DateTime.now;

  final void Function(int attempt) onRetry;
  final void Function()? onExhausted;
  final Duration stallTimeout;
  final Duration stableDuration;
  final List<Duration> retryDelays;
  final DateTime Function() _now;
  DateTime? _lastProgress;
  bool _active = false;
  bool _opening = false;
  bool _failedDuringOpen = false;
  bool _disposed = false;
  bool _exhaustedReported = false;
  bool _progressSinceOpen = false;
  int attempts = 0;
  Duration? _position;
  Timer? _retry;
  Timer? _watchdog;
  Timer? _stable;

  void setActive(bool active) {
    if (_disposed || active == _active) return;
    _active = active;
    _cancelTimers();
    _position = null;
    if (active && !_opening) _watch();
  }

  void beginOpen({bool manual = false}) {
    if (_disposed) return;
    _opening = true;
    _failedDuringOpen = false;
    _progressSinceOpen = false;
    _position = null;
    _cancelTimers();
    if (manual) {
      attempts = 0;
      _exhaustedReported = false;
    }
  }

  void endOpen({required bool success}) {
    if (_disposed) return;
    _opening = false;
    if (!success || _failedDuringOpen) {
      failure();
    } else if (_active) {
      _watch();
    }
  }

  void failure() {
    if (_disposed || !_active) return;
    _stable?.cancel();
    _stable = null;
    _watchdog?.cancel();
    _watchdog = null;
    if (_opening) {
      _failedDuringOpen = true;
      return;
    }
    if (_retry != null) return;
    if (attempts >= retryDelays.length) {
      if (!_exhaustedReported) {
        _exhaustedReported = true;
        onExhausted?.call();
      }
      return;
    }
    _retry = Timer(retryDelays[attempts], () {
      _retry = null;
      if (_disposed || !_active || _opening) return;
      onRetry(++attempts);
    });
  }

  void buffering() {
    // 缓冲期间的 position 可能仍有音频更新，不能将它计为稳定恢复。
    _stable?.cancel();
    _stable = null;
  }

  void progress(Duration position) {
    if (_disposed || !_active || _opening) return;
    final previous = _position;
    _position = position;
    if (previous != null && position <= previous) return;
    // 已确认故障的重试不会被残留 position 事件取消。
    if (_retry != null) return;
    if (position > Duration.zero) _progressSinceOpen = true;
    _watch();
    _stable ??= Timer(stableDuration, () {
      _stable = null;
      attempts = 0;
      _exhaustedReported = false;
    });
  }

  /// 短有效期不能用周期性 open 不断重置无进度检测。没有实际推进的
  /// 续期归入失败预算；已有待恢复任务/预算耗尽时也不能另起免费重试。
  bool allowRenewal() {
    if (_disposed ||
        !_active ||
        _opening ||
        _retry != null ||
        _exhaustedReported) {
      return false;
    }
    if (!_progressSinceOpen) {
      failure();
      return false;
    }
    return true;
  }

  void _watch() {
    _lastProgress = _now();
    _watchdog ??= Timer(stallTimeout, _checkProgress);
  }

  void _checkProgress() {
    _watchdog = null;
    if (_disposed || !_active || _opening) return;
    final elapsed = _now().difference(_lastProgress!);
    final remaining = stallTimeout - elapsed;
    if (remaining <= Duration.zero) {
      failure();
    } else {
      // 时钟回拨最多延后一轮，不能创建不受限的等待。
      _watchdog = Timer(
        remaining > stallTimeout ? stallTimeout : remaining,
        _checkProgress,
      );
    }
  }

  void _cancelTimers() {
    _retry?.cancel();
    _retry = null;
    _watchdog?.cancel();
    _watchdog = null;
    _stable?.cancel();
    _stable = null;
  }

  void dispose() {
    _disposed = true;
    _cancelTimers();
  }
}

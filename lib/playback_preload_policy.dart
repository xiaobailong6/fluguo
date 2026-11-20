import 'dart:math' as math;

/// 调度只读取快照，不持有播放器。所有阈值按实际观看时间计算。
class PlaybackPreloadPolicy {
  bool _prefetching = false;

  void reset() => _prefetching = false;

  ({bool prefetch, bool preopen, Duration remaining}) evaluate({
    required Duration position,
    required Duration duration,
    required Duration buffered,
    required double rate,
    required bool playing,
    required bool buffering,
    bool local = false,
    int skipIntroSeconds = 0,
    int skipOutroSeconds = 0,
  }) {
    final speed = rate.isFinite && rate > 0 ? rate : 1.0;
    final total = duration.inMilliseconds;
    final start = position.inMilliseconds;
    var end = total;
    // 与会话跳片尾的重叠保护一致，不能为无效片尾提前判定切集。
    final outroEnd = total - skipOutroSeconds * 1000;
    if (total > 2000 &&
        skipOutroSeconds > 0 &&
        outroEnd > skipIntroSeconds * 1000 + 1000) {
      end = outroEnd;
    }
    final remainingMs = math.max(0, end - start) / speed;
    final remaining = Duration(milliseconds: remainingMs.ceil());
    if (total <= 0 || start < 2000 || start >= end || !playing || buffering) {
      reset();
      return (prefetch: false, preopen: false, remaining: remaining);
    }
    final full =
        local ||
        buffered.inMilliseconds >= end - 500 && buffered.inMilliseconds > start;
    final ahead = math.max(0, buffered.inMilliseconds - start) / speed;
    // 完整缓冲不限播放百分比；长视频的有限缓存则在90秒窗口内准备。
    // 启动/停止阈值分开，避免缓冲在边界附近反复取消。
    _prefetching =
        full ||
        start >= 5000 &&
            remainingMs <= 90000 &&
            ahead >= (_prefetching ? 5000 : 15000);
    return (
      prefetch: _prefetching,
      preopen: _prefetching && remainingMs <= 30000,
      remaining: remaining,
    );
  }
}

import 'history_retention.dart';
import 'models.dart';

/// 近 30 天的观看摘要。
///
/// 数据来源只有 [WatchEntry]：每部剧只保留**最后一条**进度快照，所以
/// [watched] 是「各剧最后停留位置之和」的下界，不是真实累计播放时长，
/// 展示时必须写明这一点，不能当成精确统计对外说。
class WatchSummary {
  const WatchSummary({
    this.dramas = 0,
    this.finished = 0,
    this.watched = Duration.zero,
    this.activeDays = 0,
  });

  /// 保留期内有进度记录的短剧数。
  final int dramas;

  /// 其中进度已经到结尾的部数。
  final int finished;

  /// 按每部剧最后停留位置累加的时长下界。
  final Duration watched;

  /// 有观看记录的自然日数。
  final int activeDays;

  bool get isEmpty => dramas == 0;

  /// [history] 一般是 `store.history`；[now] 可注入，便于测试与复现。
  static WatchSummary of(List<WatchEntry> history, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final since = current.subtract(watchHistoryRetention);
    final days = <DateTime>{};
    var dramas = 0;
    var finished = 0;
    var micros = 0;
    for (final entry in history) {
      if (entry.updatedAt.isBefore(since)) continue;
      dramas++;
      if (entry.finished) finished++;
      final seconds = entry.duration > 0
          ? entry.position.clamp(0.0, entry.duration)
          : entry.position;
      micros += (seconds * Duration.microsecondsPerSecond).round();
      days.add(
        DateTime(
          entry.updatedAt.year,
          entry.updatedAt.month,
          entry.updatedAt.day,
        ),
      );
    }
    return WatchSummary(
      dramas: dramas,
      finished: finished,
      watched: Duration(microseconds: micros),
      activeDays: days.length,
    );
  }
}

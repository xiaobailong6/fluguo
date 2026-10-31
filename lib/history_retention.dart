import 'dart:convert';

const watchHistoryRetention = Duration(days: 30);

bool retainedWatchTime(DateTime updatedAt, DateTime now) =>
    !updatedAt.isBefore(now.subtract(watchHistoryRetention));

/// 只处理观看记录字段；不触碰追剧、收藏、下载或未知的旧配置。
/// 无法解析的原始数据留给现有恢复流程，不将损坏误当空记录覆盖。
void pruneWatchHistoryValues(Map<String, Object> values, DateTime now) {
  final cutoff = now.subtract(watchHistoryRetention);
  for (final key in values.keys.toList()) {
    if (!RegExp(
      r'^(?:profile\.[a-zA-Z0-9_-]{1,64}\.)?(?:history|liveHistory)$',
    ).hasMatch(key)) {
      continue;
    }
    final raw = values[key];
    if (raw is! String) continue;
    try {
      final rows = jsonDecode(raw);
      if (rows is! List) continue;
      final retained = rows.where((row) {
        if (row is! Map) return true;
        final updated = DateTime.tryParse('${row['updatedAt']}');
        return updated == null || !updated.isBefore(cutoff);
      }).toList();
      if (retained.length != rows.length) values[key] = jsonEncode(retained);
    } catch (_) {
      // 保留损坏的原始值，避免清理任务破坏恢复依据。
    }
  }
}

import 'package:flutter/material.dart';

import '../../watch_summary.dart';

/// 我的页的「近 30 天」摘要卡。
///
/// 视觉沿用同页下载卡：`surfaceContainer` + 20 圆角，不引入新的材质、
/// 阴影或配色，避免和既有卡片并列时显得突兀。
class WatchSummaryCard extends StatelessWidget {
  const WatchSummaryCard({super.key, required this.summary});

  final WatchSummary summary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: '近 30 天观看摘要',
      child: Material(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: [
              Row(
                children: [
                  _Stat(value: '${summary.dramas}', label: '看过'),
                  _Stat(value: '${summary.finished}', label: '看完'),
                  _Stat(value: _duration(summary.watched), label: '累计'),
                  _Stat(value: '${summary.activeDays}', label: '活跃天数'),
                ],
              ),
              Text(
                '只统计保留 30 天内的进度；累计时长按每部剧最后停留位置估算。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _duration(Duration value) {
    if (value.inMinutes < 1) return '0 分';
    if (value.inMinutes < 60) return '${value.inMinutes} 分';
    return '${(value.inMinutes / 60).toStringAsFixed(1)} 时';
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          Text(
            label,
            maxLines: 1,
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

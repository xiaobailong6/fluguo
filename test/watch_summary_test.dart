import 'package:duanju_app/models.dart';
import 'package:duanju_app/watch_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

WatchEntry _entry(
  String id,
  DateTime at, {
  double position = 12,
  double duration = 100,
}) => WatchEntry(
  drama: drama(id),
  episode: 1,
  position: position,
  duration: duration,
  updatedAt: at,
);

void main() {
  final now = DateTime(2026, 11, 12, 12);

  test('只统计保留期内的进度快照', () {
    final summary = WatchSummary.of([
      _entry('a', now.subtract(const Duration(days: 1))),
      _entry('b', now.subtract(const Duration(days: 29))),
      _entry('c', now.subtract(const Duration(days: 31))),
    ], now: now);
    expect(summary.dramas, 2);
    expect(summary.activeDays, 2);
  });

  test('看完判定与时长按每部剧最后位置累加', () {
    final summary = WatchSummary.of([
      _entry('a', now, position: 100, duration: 100),
      _entry('b', now, position: 20, duration: 0),
    ], now: now);
    expect(summary.finished, 1);
    expect(summary.watched, const Duration(seconds: 120));
  });

  test('同一天的多次记录只算一个活跃日', () {
    final summary = WatchSummary.of([
      _entry('a', DateTime(2026, 11, 12, 9)),
      _entry('b', DateTime(2026, 11, 12, 23)),
    ], now: now);
    expect(summary.activeDays, 1);
    expect(summary.isEmpty, isFalse);
  });

  test('空历史是空摘要', () {
    expect(WatchSummary.of(const [], now: now).isEmpty, isTrue);
  });
}

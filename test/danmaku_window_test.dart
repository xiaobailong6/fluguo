import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/ui/player/danmaku_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

DanmakuFlight _flight(String id, int timeMs) =>
    DanmakuFlight(DanmakuItem(id: id, text: id, timeMs: timeMs), id, 0, 40);

/// 旧实现的上屏判据：控制器位置落在 `[timeMs, timeMs + lifetime)` 就画。
bool _onScreen(DanmakuFlight flight, double ms) =>
    ms >= flight.item.timeMs &&
    ms < flight.item.timeMs + danmakuLifetimeMs;

void main() {
  test('窗口结果与逐条判据完全一致', () {
    final schedule = [
      for (var index = 0; index < 40; index++) _flight('d$index', index * 700),
    ];
    var cursor = 0;
    for (var ms = 0.0; ms < 32000; ms += 37) {
      final window = danmakuWindow(schedule, ms, cursor: cursor);
      final expected = schedule
          .where((flight) => _onScreen(flight, ms))
          .toList();
      expect(window.visible, expected, reason: 'ms=$ms');
      cursor = window.cursor;
    }
  });

  test('入屏与退场都是左闭右开', () {
    final flight = _flight('a', 1000);
    expect(danmakuWindow([flight], 999.9).visible, isEmpty);
    expect(danmakuWindow([flight], 1000).visible, [flight]);
    expect(
      danmakuWindow([flight], 1000 + danmakuLifetimeMs - 0.1).visible,
      [flight],
    );
    expect(
      danmakuWindow([flight], 1000.0 + danmakuLifetimeMs).visible,
      isEmpty,
    );
  });

  test('游标只前进，回拖时由调用方重置', () {
    final schedule = [
      for (var index = 0; index < 10; index++) _flight('d$index', index * 1000),
    ];
    final forward = danmakuWindow(schedule, 25000, cursor: 0);
    expect(forward.visible, isEmpty);
    expect(forward.cursor, schedule.length);
    final back = danmakuWindow(schedule, 12000, cursor: 0);
    expect(back.visible.map((flight) => flight.item.id), [
      'd5',
      'd6',
      'd7',
      'd8',
      'd9',
    ]);
  });
}

import 'package:duanju_app/live_recovery.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('高频进度只保留一个watchdog，到实际停滞截止时才恢复', () {
    fakeAsync((clock) {
      final calls = <int>[];
      final recovery = LiveRecovery(
        onRetry: calls.add,
        now: () => DateTime(2020).add(clock.elapsed),
      )..setActive(true);
      final watchdog = clock.pendingTimers.single;
      for (var i = 1; i <= 1000; i++) {
        recovery.progress(Duration(milliseconds: i));
      }
      expect(clock.pendingTimers.contains(watchdog), isTrue);
      expect(clock.pendingTimers.length, 2);
      clock.elapse(const Duration(seconds: 19));
      recovery.progress(const Duration(seconds: 19));
      clock.elapse(const Duration(seconds: 20));
      expect(calls, isEmpty);
      clock.elapse(const Duration(seconds: 1));
      expect(calls, [1]);
      recovery.dispose();
    });
  });
  test('错误与 EOF 合并，连续失败最多三次，手动重试重置预算', () {
    fakeAsync((clock) {
      final calls = <int>[];
      var exhausted = 0;
      final recovery = LiveRecovery(
        now: () => DateTime(2020).add(clock.elapsed),
        onRetry: calls.add,
        onExhausted: () => exhausted++,
      );
      recovery.setActive(true);
      for (var i = 0; i < 4; i++) {
        recovery.failure();
        recovery.failure();
        clock.elapse(const Duration(seconds: 5));
        recovery.beginOpen();
        recovery.endOpen(success: false);
      }
      expect(calls, [1, 2, 3]);
      expect(exhausted, 1);
      recovery.beginOpen(manual: true);
      recovery.endOpen(success: false);
      clock.elapse(const Duration(seconds: 1));
      expect(calls, [1, 2, 3, 1]);
      recovery.dispose();
    });
  });

  test('暂停、隐藏和销毁取消重试；open 内故障延后到完成', () {
    fakeAsync((clock) {
      final calls = <int>[];
      final recovery = LiveRecovery(
        onRetry: calls.add,
        now: () => DateTime(2020).add(clock.elapsed),
      )..setActive(true);
      recovery.beginOpen();
      recovery.failure();
      clock.elapse(const Duration(minutes: 1));
      expect(calls, isEmpty);
      recovery.endOpen(success: true);
      recovery.setActive(false);
      clock.elapse(const Duration(minutes: 1));
      expect(calls, isEmpty);
      recovery.setActive(true);
      recovery.failure();
      recovery.dispose();
      clock.elapse(const Duration(minutes: 1));
      expect(calls, isEmpty);
    });
  });

  test('持续卡缓冲触发恢复，只有连续推进足够久才恢复预算', () {
    fakeAsync((clock) {
      final calls = <int>[];
      final recovery = LiveRecovery(
        onRetry: calls.add,
        now: () => DateTime(2020).add(clock.elapsed),
      )..setActive(true);
      clock.elapse(const Duration(seconds: 21));
      expect(calls, [1]);
      recovery.beginOpen();
      recovery.endOpen(success: true);
      for (var i = 1; i <= 10; i++) {
        recovery.progress(Duration(seconds: i));
        clock.elapse(const Duration(seconds: 1));
      }
      recovery.buffering();
      clock.elapse(const Duration(seconds: 20));
      clock.elapse(const Duration(seconds: 2));
      expect(calls, [1, 2]);
      recovery.beginOpen();
      recovery.endOpen(success: true);
      for (var i = 1; i <= 32; i++) {
        recovery.progress(Duration(seconds: i));
        clock.elapse(const Duration(seconds: 1));
      }
      expect(recovery.attempts, 0);
      recovery.failure();
      clock.elapse(const Duration(seconds: 1));
      expect(calls, [1, 2, 1]);
      recovery.dispose();
    });
  });
}

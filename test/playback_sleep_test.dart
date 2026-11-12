import 'dart:async';

import 'package:duanju_app/diary_service.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/player/playback_sheets.dart';
import 'package:duanju_app/ui/player/sleep_timer_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Repository extends FakeRepository {
  @override
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0}) async =>
      PlaybackPlan(url: 'https://media.test/${episode.number}.mp4');
}

/// 只拦截用户设置的长计时器，其余异步调度仍使用测试运行器的时钟。
class _SleepClock {
  final timers = <_ManualTimer>[];

  T capture<T>(T Function() action) => runZoned(action,
    zoneSpecification: ZoneSpecification(createTimer: (self, parent, zone, delay, callback) {
      if (delay < const Duration(minutes: 15)) {
        return parent.createTimer(zone, delay, callback);
      }
      final timer = _ManualTimer(callback);
      timers.add(timer);
      return timer;
    }),
  );
}

class _ManualTimer implements Timer {
  _ManualTimer(this.callback);
  final void Function() callback;
  bool _active = true;
  int _tick = 0;
  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;
  void fire() {
    if (!_active) return;
    _active = false;
    _tick++;
    callback();
  }
}

class _HeldPlayer extends FakePlayer {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    await super.open(playable, play: play);
  }
}

void main() {
  Future<PlaybackSession> open({FakePlayer? player}) async {
    final store = await openStore();
    final session = PlaybackSession(
      repository: _Repository(), store: store,
      detail: dramaDetail(drama('sleep'), count: 3),
      player: player ?? FakePlayer(), index: 0,
    );
    return session;
  }

  test('到时暂停、保存位置和解除倍速锁，用户可继续播放', () async {
    final player = FakePlayer();
    final session = await open(player: player);
    await pumpEventQueue();
    final clock = _SleepClock();
    player.progress(const Duration(seconds: 20), duration: const Duration(seconds: 100));
    session.setBoostLocked(true);
    clock.capture(() => session.setSleepTimer(minutes: 15));
    expect(session.sleepMinutes, 15);
    expect(session.sleepAt, isNotNull);
    clock.timers.single.fire();
    await pumpEventQueue();
    expect(session.paused, isTrue);
    expect(player.state.playing, isFalse);
    expect(session.boostLocked, isFalse);
    expect(session.boosting, isFalse);
    expect(session.sleepAt, isNull);
    expect(session.store.watched(session.detail.drama.id)!.position, 20);
    player.finish();
    await pumpEventQueue();
    expect(session.index, 0);
    session.togglePlayback();
    await pumpEventQueue();
    expect(session.paused, isFalse);
    expect(player.state.playing, isTrue);
    session.dispose();
    await pumpEventQueue();
  });

  test('重设和关闭取消旧计时，切集保留截止时间', () async {
    final session = await open();
    await pumpEventQueue();
    final clock = _SleepClock();
    clock.capture(() => session.setSleepTimer(minutes: 15));
    clock.capture(() => session.setSleepTimer(minutes: 30));
    expect(clock.timers.first.isActive, isFalse);
    final at = session.sleepAt;
    await session.play(1);
    expect(session.sleepAt, at);
    expect(session.sleepMinutes, 30);
    session.setSleepTimer();
    expect(clock.timers.last.isActive, isFalse);
    clock.timers.last.fire();
    expect(session.sleepAt, isNull);
    expect(session.paused, isFalse);
    expect(() => session.setSleepTimer(minutes: -1), throwsArgumentError);
    session.dispose();
    await pumpEventQueue();
  });

  test('播完本集阻止连播，手动切集后仍在所选集结束时停止', () async {
    final player = FakePlayer();
    final session = await open(player: player);
    await pumpEventQueue();
    session.setSleepTimer(episodeEnd: true);
    await session.play(1);
    expect(session.sleepAtEpisodeEnd, isTrue);
    player.progress(const Duration(seconds: 99), duration: const Duration(seconds: 100));
    player.finish();
    await pumpEventQueue();
    expect(session.index, 1);
    expect(player.opened, hasLength(2));
    expect(session.paused, isTrue);
    expect(session.sleepAtEpisodeEnd, isFalse);
    session.dispose();
    await pumpEventQueue();
  });

  test('异步起播尚未完成时到期，起播完成后仍暂停', () async {
    final player = _HeldPlayer();
    final session = await open(player: player);
    await player.entered.future;
    final clock = _SleepClock();
    clock.capture(() => session.setSleepTimer(minutes: 15));
    clock.timers.single.fire();
    player.release.complete();
    await pumpEventQueue();
    expect(session.ready, isTrue);
    expect(session.paused, isTrue);
    expect(player.state.playing, isFalse);
    session.dispose();
    await pumpEventQueue();
  });

  test('交接与销毁清理计时，不暂停交接后的播放器', () async {
    final session = await open();
    await pumpEventQueue();
    final clock = _SleepClock();
    clock.capture(() => session.setSleepTimer(minutes: 60));
    final player = session.player;
    expect(session.takeOver(), isNotNull);
    expect(clock.timers.single.isActive, isFalse);
    clock.timers.single.fire();
    expect(player.state.playing, isTrue);
    session.dispose();
    await pumpEventQueue();
    await player.dispose();

    final other = await open();
    await pumpEventQueue();
    clock.capture(() => other.setSleepTimer(minutes: 90));
    other.dispose();
    expect(clock.timers.last.isActive, isFalse);
    await pumpEventQueue();
  });

  test('切换用户取消旧会话定时，不影响新用户', () async {
    final store = await openStore(viewerPreferences);
    final session = PlaybackSession(
      repository: _Repository(), store: store,
      detail: dramaDetail(drama('profile-sleep'), count: 3),
      player: FakePlayer(), index: 0,
    );
    await pumpEventQueue();
    final clock = _SleepClock();
    clock.capture(() => session.setSleepTimer(minutes: 15));
    await store.switchProfile('viewer');
    expect(clock.timers.single.isActive, isFalse);
    expect(session.sleepAt, isNull);
    clock.timers.single.fire();
    expect(session.paused, isTrue);
    session.dispose();
    await pumpEventQueue();
  });

  test('提前断流不当作本集播完，定时选择仍保留', () async {
    final player = FakePlayer();
    final session = await open(player: player);
    await pumpEventQueue();
    session.setSleepTimer(episodeEnd: true);
    player.finish(); // duration 为零，应走提前结束恢复而非定时停止。
    expect(session.sleepAtEpisodeEnd, isTrue);
    expect(session.paused, isFalse);
    session.dispose();
    await pumpEventQueue();
  });

  test('播放前后台诊断受调试日志开关控制，重复状态不重复写入', () async {
    final session = await open();
    await pumpEventQueue();
    await DiaryService.clear();
    DiaryService.traceEnabled = false;
    session.setForeground(false);
    session.setForeground(true);
    expect(DiaryService.entries, isEmpty);
    DiaryService.traceEnabled = true;
    session.setForeground(false);
    session.setForeground(false);
    session.setForeground(true);
    expect(DiaryService.entries.where((line) => line.contains('[Play]')), hasLength(2));
    DiaryService.traceEnabled = false;
    session.dispose();
    await pumpEventQueue();
  });

  testWidgets('现有播放设置可选择和关闭定时停止', (tester) async {
    late PlaybackSession session;
    await tester.runAsync(() async {
      session = await open();
      await pumpEventQueue();
    });
    final clock = _SleepClock();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(
      child: SizedBox(width: 340, height: 600, child: PlaybackSettings(
        session: session, onFailure: () => fail('不应保存长期偏好'),
      )),
    ))));
    await tester.ensureVisible(find.text('15 分钟'));
    clock.capture(() => tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '15 分钟'))
        .onSelected!(true));
    await tester.pump();
    expect(selectedSleepTimer(session), 15);
    expect(find.textContaining('切集不重置'), findsOneWidget);
    await tester.ensureVisible(find.text('播完本集'));
    await tester.tap(find.text('播完本集'));
    await tester.pump();
    expect(selectedSleepTimer(session), -1);
    await tester.tap(find.text('关闭定时'));
    await tester.pump();
    expect(selectedSleepTimer(session), 0);
    expect(sleepTimerOptions.map(sleepTimerOptionLabel),
      ['播完本集', '15 分钟', '30 分钟', '60 分钟', '90 分钟', '关闭定时']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      session.dispose();
      await pumpEventQueue();
    });
    expect(tester.takeException(), isNull);
  });
}

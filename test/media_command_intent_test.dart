import 'dart:async';

import 'package:duanju_app/media_controls.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Repository extends FakeRepository {
  final second = Completer<PlaybackPlan>();
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => episode.number == 2
      ? second.future
      : const PlaybackPlan(url: 'memory:first');
}

class _HeldPlayer extends FakePlayer {
  Completer<void>? gate;
  final entered = Completer<void>();
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final pending = gate;
    if (pending != null) {
      entered.complete();
      await pending.future;
    }
    await super.open(playable, play: play);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('duanju/media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final outbound = <MethodCall>[];
  setUp(() {
    outbound.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      outbound.add(call);
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> send(String command, {int? interruptionId}) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall('command', {
          'command': command,
          'interruptionId': ?interruptionId,
        }),
      ),
      (_) {},
    );
  }

  Future<PlaybackSession> open(FakePlayer player, _Repository repo) async {
    final store = await openStore();
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(backgroundPlayback: true),
    );
    final session = PlaybackSession(
      repository: repo,
      store: store,
      detail: dramaDetail(drama('media-intent'), count: 2),
      player: player,
      index: 0,
    );
    addTearDown(() async {
      session.dispose();
      await pumpEventQueue();
    });
    await pumpEventQueue();
    session.setForeground(false);
    return session;
  }

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    for (final lastPlay in [true, false]) {
      test('加载中以最后系统意图为准 $platform play=$lastPlay', () async {
        debugDefaultTargetPlatformOverride = platform;
        final player = FakePlayer();
        final repo = _Repository();
        final session = await open(player, repo);
        final loading = session.play(1);
        await pumpEventQueue();
        await send('pause');
        await send('play');
        if (!lastPlay) await send('pause');
        expect(player.state.playing, isFalse, reason: '新集未就绪，不能重新播放旧集');
        repo.second.complete(const PlaybackPlan(url: 'memory:second'));
        await loading;
        expect(session.ready, isTrue);
        expect(session.paused, !lastPlay);
        expect(player.state.playing, lastPlay);
        expect(player.opened.last.uri, 'memory:second');
      });
    }
  }

  for (final wanted in [true, false]) {
    test('原生open途中更新最后播放意图 wanted=$wanted', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final player = _HeldPlayer();
      final repo = _Repository();
      final session = await open(player, repo);
      player.gate = Completer<void>();
      final loading = session.play(1, playWhenReady: false);
      repo.second.complete(const PlaybackPlan(url: 'memory:second'));
      await player.entered.future;
      await send('play');
      if (!wanted) await send('pause');
      expect(player.state.playing, isFalse);
      player.gate!.complete();
      await loading;
      expect(session.ready, isTrue);
      expect(session.paused, !wanted);
      expect(player.state.playing, wanted);
    });
  }

  for (final action in [
    'none',
    'pause',
    'toggle-twice',
    'wrong-id',
    'new-load',
    'already-paused',
  ]) {
    test('中断恢复只接受仍有效的编号 $action', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final player = FakePlayer();
      final repo = _Repository();
      final session = await open(player, repo);
      if (action == 'already-paused') await send('pause');
      await send('pause', interruptionId: 10);
      expect(session.paused, isTrue);
      if (action == 'pause') await send('pause');
      if (action == 'toggle-twice') {
        session.togglePlayback();
        session.togglePlayback();
      }
      if (action == 'new-load') await session.play(0, playWhenReady: false);
      await send('play', interruptionId: action == 'wrong-id' ? 11 : 10);
      await pumpEventQueue();
      final resumes = action == 'none';
      expect(session.paused, !resumes);
      expect(player.state.playing, resumes);
      if (['pause', 'toggle-twice', 'new-load'].contains(action)) {
        expect(
          outbound
              .where((c) => c.method == 'cancelResume')
              .map((c) => c.arguments['interruptionId']),
          contains(10),
        );
      }
      if (action == 'wrong-id') {
        await send('play', interruptionId: 10);
        await pumpEventQueue();
        expect(player.state.playing, isTrue);
      }
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final action in [
      'background-disabled',
      'screen-lock',
      'profile-switch',
      'sleep',
    ]) {
      test('中断后撤销播放许可不能被旧恢复覆盖 $platform $action', () async {
        debugDefaultTargetPlatformOverride = platform;
        final player = FakePlayer();
        final session = await open(player, _Repository());
        await send('pause', interruptionId: 30);
        expect(session.paused, isTrue);
        switch (action) {
          case 'background-disabled':
            await session.store.setPlaybackPreferences(
              session.store.playbackPreferences.copyWith(
                backgroundPlayback: false,
              ),
            );
            await session.store.setPlaybackPreferences(
              session.store.playbackPreferences.copyWith(
                backgroundPlayback: true,
              ),
            );
            session.setForeground(true);
          case 'screen-lock':
            session.setLocked(true);
          case 'profile-switch':
            await session.store.switchProfile(session.store.profile.id);
          case 'sleep':
            // 只触发本次睡眠截止回调，不等待真实十五分钟；停止会取消原 Timer。
            late void Function() expire;
            runZoned(
              () => session.setSleepTimer(minutes: 15),
              zoneSpecification: ZoneSpecification(
                createTimer: (self, parent, zone, delay, callback) {
                  expect(delay, const Duration(minutes: 15));
                  expire = callback;
                  return parent.createTimer(zone, delay, callback);
                },
              ),
            );
            expire();
        }
        await send('play', interruptionId: 30);
        await pumpEventQueue();
        expect(session.paused, isTrue);
        expect(player.state.playing, isFalse);
        if (action == 'screen-lock') {
          // 锁定时消费恢复编号，解锁后重复回调也不能起播。
          session.setLocked(false);
          await send('play', interruptionId: 30);
          expect(session.paused, isTrue);
          expect(player.state.playing, isFalse);
        } else {
          expect(
            outbound
                .where((c) => c.method == 'cancelResume')
                .map((c) => c.arguments['interruptionId']),
            contains(30),
          );
        }
      });
    }
  }

  test('中断在加载期间恢复，完成后起播；清理后旧恢复不能影响新会话', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final player = FakePlayer();
    final repo = _Repository();
    final session = await open(player, repo);
    final loading = session.play(1);
    await pumpEventQueue();
    await send('pause', interruptionId: 20);
    await send('play', interruptionId: 20);
    repo.second.complete(const PlaybackPlan(url: 'memory:second'));
    await loading;
    expect(player.state.playing, isTrue);
    await send('pause', interruptionId: 21);
    MediaControls.instance.release(session);
    final other = await open(FakePlayer(), _Repository());
    await send('pause');
    await send('play', interruptionId: 21);
    expect(other.paused, isTrue);
  });
}

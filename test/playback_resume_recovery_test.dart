import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Repository extends FakeRepository {
  int resolves = 0;
  final released = <String>[];
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    resolves++;
    return PlaybackPlan(
      url: 'https://fixture.invalid/${episode.number}',
      session: 'p$resolves',
    );
  }

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async =>
      PlaybackPlan(url: 'https://fixture.invalid/next', session: 'next');
  @override
  Future<void> release(String session) async {
    released.add(session);
  }
}

class _Player extends FakePlayer {
  bool ignoreSeek = false;
  Completer<void>? heldOpen;
  String terminalOnReopen = '';
  @override
  Future<void> seek(Duration position) async {
    if (ignoreSeek) {
      seeks.add(position);
      return;
    }
    await super.seek(position);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final held = heldOpen;
    if (held != null) await held.future;
    await super.open(playable, play: play);
    if (opened.length == 2 && terminalOnReopen.isNotEmpty) {
      if (terminalOnReopen == 'error') {
        await pause();
        fail('synthetic native event failure');
      } else {
        finish();
      }
    }
  }
}

class _Timer implements Timer {
  _Timer(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  bool active = true;
  @override
  bool get isActive => active;
  @override
  int get tick => active ? 0 : 1;
  @override
  void cancel() {
    active = false;
  }

  void fire() {
    if (active) {
      active = false;
      callback();
    }
  }
}

class _Clock {
  final timers = <_Timer>[];
  T capture<T>(T Function() action) => runZoned(
    action,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, delay, callback) {
        if (!const [600, 2500, 5000, 60000].contains(delay.inMilliseconds)) {
          return parent.createTimer(zone, delay, callback);
        }
        final timer = _Timer(delay, zone.bindCallback(callback));
        timers.add(timer);
        return timer;
      },
    ),
  );
  void fire(int milliseconds) => timers
      .firstWhere((t) => t.active && t.delay.inMilliseconds == milliseconds)
      .fire();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<(PlaybackSession, _Player, _Repository)> open({
    FakePlayer? standby,
  }) async {
    final player = _Player();
    final repository = _Repository();
    final session = PlaybackSession(
      repository: repository,
      store: await openStore(),
      detail: dramaDetail(drama('resume'), count: 3),
      player: player,
      standby: standby,
      index: 0,
    );
    await pumpEventQueue();
    player.progress(
      const Duration(seconds: 20),
      duration: const Duration(seconds: 100),
    );
    return (session, player, repository);
  }

  for (final progresses in [false, true]) {
    test(
      'long pause recovery reopens only stalled current route (progress=$progresses)',
      () async {
        final (session, player, repository) = await open();
        addTearDown(session.dispose);
        final clock = _Clock();
        clock.capture(session.togglePlayback);
        clock.fire(5000);
        clock.capture(session.togglePlayback);
        await pumpEventQueue();
        if (progresses) player.progress(const Duration(seconds: 22));
        clock.fire(5000);
        await pumpEventQueue();
        expect(player.opened.length, progresses ? 1 : 2);
        expect(repository.resolves, 1);
        if (!progresses) {
          expect(player.opened.last.start, const Duration(seconds: 20));
          expect(player.state.playing, isTrue);
        }
      },
    );
  }

  for (final mode in [
    'pause',
    'background',
    'profile',
    'switch',
    'dispose',
    'sleep',
  ]) {
    test('$mode invalidates a scheduled resume recovery', () async {
      final (session, player, _) = await open();
      var disposed = false;
      addTearDown(() {
        if (!disposed) session.dispose();
      });
      final clock = _Clock();
      clock.capture(session.togglePlayback);
      clock.fire(5000);
      clock.capture(session.togglePlayback);
      await pumpEventQueue();
      final old = clock.timers.last;
      switch (mode) {
        case 'pause':
          session.togglePlayback();
        case 'background':
          session.setForeground(false);
        case 'profile':
          await session.store.switchProfile(session.store.profile.id);
        case 'switch':
          await session.play(1);
        case 'dispose':
          session.dispose();
          disposed = true;
        case 'sleep':
          session.setSleepTimer(episodeEnd: true);
          player.finish();
      }
      old.fire();
      await pumpEventQueue();
      expect(player.opened.length, mode == 'switch' ? 2 : 1);
    });
  }

  test(
    'seek watchdog reopens only a stuck seek and not normal progress',
    () async {
      final (session, player, repository) = await open();
      addTearDown(session.dispose);
      player.ignoreSeek = true;
      final clock = _Clock();
      await clock.capture(() => session.seekTo(const Duration(seconds: 60)));
      clock.fire(2500);
      clock.fire(2500);
      await pumpEventQueue();
      expect(player.opened.last.start, const Duration(seconds: 60));
      expect(repository.resolves, 1);
      await clock.capture(() => session.seekTo(const Duration(seconds: 80)));
      clock.fire(2500);
      player.progress(const Duration(seconds: 63));
      clock.fire(2500);
      await pumpEventQueue();
      expect(player.opened, hasLength(2));
    },
  );

  test(
    'pause while recovery open awaits cannot restore sound or hand back',
    () async {
      final (session, player, _) = await open();
      addTearDown(session.dispose);
      player.ignoreSeek = true;
      final clock = _Clock();
      await clock.capture(() => session.seekTo(const Duration(seconds: 60)));
      player.heldOpen = Completer<void>();
      clock.fire(2500);
      clock.fire(2500);
      await pumpEventQueue();
      expect(session.takeOver(), isNull);
      session.togglePlayback();
      player.heldOpen!.complete();
      await pumpEventQueue();
      expect(player.state.playing, isFalse);
      expect(session.paused, isTrue);
    },
  );

  test(
    'standby releases on background and cannot be resurrected by late open',
    () async {
      final standby = _Player()..heldOpen = Completer<void>();
      final (session, player, repository) = await open(standby: standby);
      addTearDown(session.dispose);
      player.state = player.state.copyWith(buffer: const Duration(seconds: 80));
      player.progress(const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await pumpEventQueue();
      session.setForeground(false);
      standby.heldOpen!.complete();
      await pumpEventQueue();
      expect(session.standby, isNull);
      expect(standby.stops, greaterThan(0));
      expect(repository.released, contains('next'));
    },
  );

  test(
    'one minute pause clears standby without buffer events reopening it',
    () async {
      final standby = _Player();
      final (session, player, _) = await open(standby: standby);
      addTearDown(session.dispose);
      final clock = _Clock();
      player.state = player.state.copyWith(buffer: const Duration(seconds: 80));
      player.progress(const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await pumpEventQueue();
      expect(session.standby, same(standby));
      clock.capture(session.togglePlayback);
      clock.fire(60000);
      await pumpEventQueue();
      player.progress(const Duration(seconds: 60));
      await pumpEventQueue();
      expect(session.standby, isNull);
      expect(standby.opened, hasLength(1));
    },
  );
  for (final terminal in ['error', 'completed', 'sleep']) {
    test(
      'reopen preserves native $terminal events even when open succeeds',
      () async {
        final (session, player, repository) = await open();
        addTearDown(session.dispose);
        player.ignoreSeek = true;
        player.terminalOnReopen = terminal;
        if (terminal == 'sleep') session.setSleepTimer(episodeEnd: true);
        final clock = _Clock();
        await clock.capture(() => session.seekTo(const Duration(seconds: 99)));
        clock.fire(2500);
        clock.fire(2500);
        await pumpEventQueue();
        if (terminal == 'error') {
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          await pumpEventQueue();
          expect(repository.resolves, 2);
        } else if (terminal == 'completed') {
          expect(session.index, 1);
          expect(repository.resolves, 2);
        } else {
          expect(session.index, 0);
          expect(session.paused, isTrue);
        }
      },
    );
  }
}

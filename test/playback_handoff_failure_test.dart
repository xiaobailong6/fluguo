import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'support/fake_player.dart';

class _Repository extends FakeRepository {
  final pending = Completer<PlaybackPlan?>();
  int resolved = 0;
  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) => pending.future;
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    resolved++;
    return const PlaybackPlan(
      url: 'https://fixture.invalid/new',
      session: 'new',
    );
  }
}

class _SlowSeek extends FakePlayer {
  Completer<void>? gate;
  @override
  Future<void> seek(Duration position) async {
    await gate?.future;
    await super.seek(position);
  }
}

class _FailingSeek extends FakePlayer {
  bool failSeek = true;

  @override
  Future<void> seek(Duration position) async {
    if (failSeek) {
      failSeek = false;
      throw StateError('rewind failed');
    }
    await super.seek(position);
  }
}

class _FailingOpen extends FakePlayer {
  bool failOpen = true;
  int attempts = 0;
  @override
  Future<void> open(dynamic media, {bool play = true}) async {
    attempts++;
    if (failOpen) throw StateError('media open failed');
    await super.open(media, play: play);
  }
}

class _SlowOpen extends FakePlayer {
  Completer<void>? gate;
  @override
  Future<void> open(dynamic media, {bool play = true}) async {
    await gate?.future;
    await super.open(media, play: play);
  }
}

class _SlowVolume extends FakePlayer {
  Completer<void>? gate;
  @override
  Future<void> setVolume(double value) async {
    if (value > 0) await gate?.future;
    await super.setVolume(value);
  }
}

void main() {
  testWidgets('真正open失败仍报错，修复网络后重试可以播放目标集', (tester) async {
    final repo = _Repository();
    final main = FakePlayer(), next = _FailingOpen();
    final session = PlaybackSession(
      repository: repo,
      store: await openStore(),
      detail: dramaDetail(drama('open-failure'), count: 2),
      player: main,
      standby: next,
      index: 0,
      adoptedPlan: const PlaybackPlan(url: 'https://fixture.invalid/current'),
      prepareVideo: (_) async {},
    );
    final switching = session.play(1);
    await tester.pump();
    await switching;
    expect(session.index, 0);
    expect(next.attempts, 2);
    expect(session.episodeSwitchError, contains('未能打开'));
    next.failOpen = false;
    final retry = session.retryEpisodeSwitch();
    await tester.pump();
    await retry;
    expect(session.index, 1);
    expect(next.state.playing, isTrue);
    expect(session.episodeSwitchError, isNull);
    session.dispose();
    await tester.pump();
  });

  testWidgets('转正后的迟到预热错误不能停止当前视频或回退旧集', (tester) async {
    final repo = _Repository();
    final main = FakePlayer(), next = FakePlayer();
    final probe = Completer<void>();
    final session = PlaybackSession(
      repository: repo,
      store: await openStore(),
      detail: dramaDetail(drama('late-probe'), count: 2),
      player: main,
      standby: next,
      index: 0,
      adoptedPlan: const PlaybackPlan(url: 'https://fixture.invalid/current'),
      prepareVideo: (player) =>
          identical(player, next) ? probe.future : Future<void>.value(),
    );
    final switching = session.play(1);
    await tester.pump();
    await switching;
    expect(session.player, same(next));
    probe.completeError(TimeoutException('late probe'));
    await tester.pump();
    expect(session.index, 1);
    expect(next.state.playing, isTrue);
    expect(next.stops, 0);
    expect(next.opened, hasLength(1));
    expect(session.episodeSwitchError, isNull);
    session.dispose();
    await tester.pump();
  });

  Future<void> warm(
    WidgetTester tester,
    FakePlayer player,
    _Repository repo,
  ) async {
    await player.play();
    player.state = player.state.copyWith(buffer: const Duration(seconds: 120));
    player.progress(
      const Duration(seconds: 8),
      duration: const Duration(seconds: 120),
    );
    await tester.pump(const Duration(milliseconds: 201));
    repo.pending.complete(
      const PlaybackPlan(url: 'https://fixture.invalid/next', session: 'next'),
    );
    await tester.pump();
  }

  for (final retainOutput in [false, true]) {
    testWidgets('邻集回零失败重新加载目标集，不沿用预播进度 output=$retainOutput', (tester) async {
      final repo = _Repository();
      final main = FakePlayer(), next = _FailingSeek();
      final session = PlaybackSession(
        repository: repo,
        store: await openStore(),
        detail: dramaDetail(drama('rewind-failure'), count: 2),
        player: main,
        standby: next,
        index: 0,
        adoptedPlan: const PlaybackPlan(url: 'https://fixture.invalid/current'),
        prepareVideo: retainOutput ? (_) async {} : null,
      );
      await warm(tester, main, repo);
      next.progress(const Duration(seconds: 20));
      final switching = session.play(1);
      await tester.pump();
      await switching;
      expect(session.index, 1);
      expect(session.player.state.position, Duration.zero);
      expect(session.player.state.playing, isTrue);
      expect(session.episodeSwitchError, isNull);
      expect(repo.resolved, 1);
      session.dispose();
      await tester.pump();
    });
  }

  for (final action in ['cancel', 'pause', 'switchAgain']) {
    testWidgets('邻集回零等待期间尊重最新操作 $action', (tester) async {
      final repo = _Repository();
      final main = FakePlayer(), next = _SlowSeek();
      final session = PlaybackSession(
        repository: repo,
        store: await openStore(),
        detail: dramaDetail(drama('rewind-intent'), count: 2),
        player: main,
        standby: next,
        index: 0,
        adoptedPlan: const PlaybackPlan(url: 'https://fixture.invalid/current'),
        prepareVideo: (_) async {},
      );
      await warm(tester, main, repo);
      next.progress(const Duration(seconds: 20));
      next.gate = Completer<void>();
      final switching = session.play(1);
      await tester.pump();
      expect(session.player, same(main));
      expect(session.waitingForNext, isTrue);
      expect(next.state.playing, isFalse);
      expect(next.state.volume, 0);
      Future<void>? latest;
      if (action == 'pause') {
        session.togglePlayback();
      } else {
        session.cancelPendingEpisodeSwitch(resume: action == 'cancel');
        if (action == 'switchAgain') latest = session.play(1);
      }
      await tester.pump();
      next.gate!.complete();
      await tester.pump();
      await switching;
      await latest;
      expect(session.index, action == 'cancel' ? 0 : 1);
      expect(next.state.position, Duration.zero);
      expect(next.state.playing, action == 'switchAgain');
      expect(
        main.state.position,
        action == 'cancel' ? const Duration(seconds: 8) : Duration.zero,
      );
      expect(session.waitingForNext, isFalse);
      expect(session.episodeSwitchError, isNull);
      if (action == 'switchAgain') {
        next.progress(const Duration(seconds: 6));
        await tester.pump();
        expect(next.state.position, const Duration(seconds: 6));
        expect(next.seeks, [Duration.zero]);
      }
      session.dispose();
      await tester.pump();
    });
  }

  testWidgets('连续切集等待前次音量交接，不继承预览静音', (tester) async {
    final repo = _Repository();
    final main = FakePlayer(), next = _SlowVolume();
    final session = PlaybackSession(
      repository: repo,
      store: await openStore(),
      detail: dramaDetail(drama('volume'), count: 2),
      player: main,
      standby: next,
      index: 0,
      adoptedPlan: const PlaybackPlan(url: 'https://fixture.invalid/old'),
      prepareVideo: (_) async {},
    );
    await warm(tester, main, repo);
    await main.setVolume(65);
    next.gate = Completer<void>();
    final forward = session.play(1);
    await tester.pump();
    expect(session.index, 1);
    expect(next.state.volume, 0);
    final back = session.play(0);
    await tester.pump();
    expect(session.index, 1, reason: '交接配置未完成，后续切集必须等待');
    next.gate!.complete();
    await tester.pump();
    await forward;
    await back;
    expect(session.index, 0);
    expect(main.state.volume, 65);
    expect(main.state.playing, isTrue);
    session.dispose();
    await tester.pump();
  });

  testWidgets('恢复看门狗不能在等待下一集时重开旧集', (tester) async {
    final repo = _Repository();
    final main = FakePlayer(), next = _SlowOpen()..gate = Completer<void>();
    final output = Completer<void>();
    final session = PlaybackSession(
      repository: repo,
      store: await openStore(),
      detail: dramaDetail(drama('watchdog'), count: 2),
      player: main,
      standby: next,
      index: 0,
      adoptedPlan: const PlaybackPlan(url: 'https://fixture.invalid/old'),
      prepareVideo: (_) => output.future,
    );
    await tester.pump();
    await main.play();
    session.togglePlayback();
    await tester.pump(const Duration(seconds: 6));
    session.togglePlayback();
    await tester.pump();
    final switching = session.play(1);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(session.waitingForNext, isTrue);
    expect(main.opened, isEmpty);
    expect(main.stops, 0);
    expect(main.state.playing, isFalse);
    output.complete();
    next.gate!.complete();
    await tester.pump();
    await switching;
    expect(session.index, 1);
    session.dispose();
    await tester.pump();
  });

  testWidgets('探测失败不挡播放，直接复用下一集且无旧画面错误提示', (tester) async {
    final repo = _Repository();
    final main = FakePlayer(), next = FakePlayer();
    final output = Completer<void>();
    final session = PlaybackSession(
      repository: repo,
      store: await openStore(),
      detail: dramaDetail(drama('handoff'), count: 2),
      player: main,
      standby: next,
      index: 0,
      adoptedPlan: const PlaybackPlan(
        url: 'https://fixture.invalid/old',
        session: 'old',
      ),
      prepareVideo: (_) => output.future,
    );
    await warm(tester, main, repo);
    output.completeError(TimeoutException('surface probe unavailable'));
    await tester.pump();
    final switching = session.play(1);
    await tester.pump();
    await switching;
    expect(main.stops, 0);
    expect(main.opened, isEmpty);
    expect(session.index, 1);
    expect(session.player, same(next));
    expect(next.state.playing, isTrue);
    expect(session.ready, isTrue);
    expect(session.episodeSwitchError, isNull);
    expect(next.opened, hasLength(1));
    expect(next.stops, 0);
    expect(main.stops, 0);
    session.dispose();
    await tester.pump();
  });

  testWidgets('等待seek期间候选失效仍完成最新切集请求', (tester) async {
    final repo = _Repository();
    final main = _SlowSeek(), next = FakePlayer();
    final session = PlaybackSession(
      repository: repo,
      store: await openStore(),
      detail: dramaDetail(drama('handoff'), count: 2),
      player: main,
      standby: next,
      index: 0,
      adoptedPlan: const PlaybackPlan(
        url: 'https://fixture.invalid/old',
        session: 'old',
      ),
      prepareVideo: (_) async {},
    );
    await warm(tester, main, repo);
    main.gate = Completer<void>();
    final seeking = session.seekTo(const Duration(seconds: 12));
    await tester.pump();
    final switching = session.play(1);
    await tester.pump();
    expect(session.waitingForNext, isTrue);
    next.fail('candidate failed while waiting for seek');
    main.gate!.complete();
    await tester.pump();
    await seeking;
    await switching;
    expect(session.index, 1);
    expect(session.player.state.playing, isTrue);
    expect(repo.resolved, 1);
    expect(main.stops, 0);
    session.dispose();
    await tester.pump();
  });

  testWidgets('Surface身份变化立即撤销邻页可见资格，原输出复核后恢复', (tester) async {
    final repo = _Repository();
    final main = FakePlayer(), next = FakePlayer();
    var identity = 1;
    Completer<void>? checking;
    final session = PlaybackSession(
      repository: repo,
      store: await openStore(),
      detail: dramaDetail(drama('handoff'), count: 2),
      player: main,
      standby: next,
      index: 0,
      adoptedPlan: const PlaybackPlan(
        url: 'https://fixture.invalid/old',
        session: 'old',
      ),
      prepareVideo: (_) => checking?.future ?? Future<void>.value(),
      videoOutputIdentity: (_) => identity,
    );
    await warm(tester, main, repo);
    expect(session.episodeFrameRetained(1), isTrue);
    checking = Completer<void>();
    identity++;
    // 即使UI尚未收到通知，同步身份检查也不能显示旧代次的输出。
    expect(session.episodeFrameRetained(1), isFalse);
    session.videoOutputChanged(next);
    expect(session.episodeVideoReady(1), isFalse);
    await tester.pump();
    expect(next.opened, hasLength(1));
    checking.complete();
    await tester.pump();
    expect(session.episodeFrameRetained(1), isTrue);
    expect(session.episodeVideoReady(1), isTrue);
    expect(next.opened, hasLength(1));
    session.dispose();
    await tester.pump();
  });
}

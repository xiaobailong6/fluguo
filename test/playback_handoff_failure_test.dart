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

class _SlowVolume extends FakePlayer {
  Completer<void>? gate;
  @override
  Future<void> setVolume(double value) async {
    if (value > 0) await gate?.future;
    await super.setVolume(value);
  }
}

void main() {
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
    final main = FakePlayer(), next = FakePlayer();
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
    await tester.pump();
    await switching;
    expect(session.index, 1);
    session.dispose();
    await tester.pump();
  });

  testWidgets('首帧失败保留当前真实输出，重试成功后才切集', (tester) async {
    final repo = _Repository();
    final main = FakePlayer(), next = FakePlayer();
    final output = Completer<void>();
    var recovered = false;
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
      prepareVideo: (_) => recovered ? Future<void>.value() : output.future,
    );
    await warm(tester, main, repo);
    final switching = session.play(1);
    await tester.pump();
    output.completeError(TimeoutException('surface unavailable'));
    await tester.pump();
    await switching;
    expect(main.stops, 0);
    expect(main.opened, isEmpty);
    expect(session.index, 0);
    expect(session.player, same(main));
    expect(session.ready, isTrue);
    expect(session.episodeSwitchError, isNotNull);
    expect(next.opened.length, lessThanOrEqualTo(2), reason: '失败只能有限重试');
    recovered = true;
    final retry = session.retryEpisodeSwitch();
    await tester.pump();
    await retry;
    expect(session.index, 1);
    expect(session.player, same(next));
    expect(session.episodeSwitchError, isNull);
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

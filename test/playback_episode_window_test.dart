import 'dart:async';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_episode_window.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class WindowRepository extends FakeRepository {
  final resolves = <int>[];
  final preloads = <int>[];
  final releases = <String>[];
  var serial = 0;
  PlaybackPlan plan(int number) => PlaybackPlan(
    url: 'https://fixture.invalid/$number',
    session: '$number-${serial++}',
    prefetchedBytes: 1024,
  );
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    resolves.add(episode.number);
    return plan(episode.number);
  }

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async {
    preloads.add(episode.number);
    return plan(episode.number);
  }

  @override
  Future<void> release(String session) async {
    releases.add(session);
  }
}

class _SlowPlayer extends FakePlayer {
  Completer<void>? pauseGate;
  Completer<void>? stopGate;
  @override
  Future<void> pause() async {
    await pauseGate?.future;
    await super.pause();
  }

  @override
  Future<void> stop() async {
    await stopGate?.future;
    await super.stop();
  }
}

void main() {
  test('窗口按完整身份匹配，仅保留两侧；取得时间不会被往返刷新', () {
    var now = DateTime.utc(2030);
    final released = <PlaybackEpisodeEntry>[];
    final window = PlaybackEpisodeWindow(release: released.add, now: () => now);
    final detail = dramaDetail(drama('window'), count: 110);
    PlaybackEpisodeEntry entry(int index, {int quality = 0}) =>
        PlaybackEpisodeEntry(
          identity: playbackEpisodeIdentity(
            detail.drama,
            detail.episodes[index],
            quality,
            false,
            3,
          ),
          index: index,
          plan: PlaybackPlan(url: 'memory:$index', session: '$index'),
          expires: now.add(const Duration(minutes: 2)),
        );
    for (var center = 1; center < 100; center++) {
      window.move(detail, center, 0, false, 3);
      for (final index in [center - 1, center + 1]) {
        if (window.find(index, entry(index).identity) == null) {
          window.add(entry(index));
        }
      }
      expect(window.length, 2);
      expect(
        window.entries.every((e) => (e.index - center).abs() == 1),
        isTrue,
      );
    }
    final kept = window.entries.first;
    now = now.add(const Duration(minutes: 3));
    expect(window.find(kept.index, kept.identity), isNull);
    window.clear();
    expect(released.toSet().length, released.length, reason: '每个entry只释放一次');
  });

  test('往返转移不续期，画质、在线意图和用户变化隔离缓存', () {
    var now = DateTime.utc(2030);
    final released = <PlaybackEpisodeEntry>[];
    final window = PlaybackEpisodeWindow(release: released.add, now: () => now);
    final detail = dramaDetail(drama('identity'), count: 4);
    final expiry = playbackPlanExpiry(
      const PlaybackPlan(url: 'memory:test'),
      now,
    );
    final entry = PlaybackEpisodeEntry(
      identity: playbackEpisodeIdentity(
        detail.drama,
        detail.episodes[1],
        0,
        false,
        1,
      ),
      index: 1,
      plan: const PlaybackPlan(url: 'memory:test'),
      expires: expiry,
    );
    window.move(detail, 2, 0, false, 1);
    expect(window.add(entry), isTrue);
    final claimed = window.take(1, entry.identity)!;
    now = now.add(const Duration(seconds: 70));
    window.move(detail, 2, 0, false, 1);
    window.add(claimed);
    expect(claimed.expires, expiry);
    window.move(detail, 2, 720, false, 1);
    expect(window.length, 0);
    expect(released, [entry]);
    expect(
      playbackEpisodeIdentity(detail.drama, detail.episodes[1], 0, true, 1),
      isNot(entry.identity),
    );
    expect(
      playbackEpisodeIdentity(detail.drama, detail.episodes[1], 0, false, 2),
      isNot(entry.identity),
    );
    final short = PlaybackPlan(
      url: 'memory:short',
      expiresAt: now.add(const Duration(seconds: 10)).millisecondsSinceEpoch,
    );
    expect(
      playbackPlanExpiry(short, now).millisecondsSinceEpoch,
      now.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
    );
  });

  Future<(PlaybackSession, WindowRepository, List<FakePlayer>)> mount(
    WidgetTester tester, {
    bool preopen = true,
    FakePlayer? primary,
    Future<void> Function(Player)? prepareVideo,
  }) async {
    final repo = WindowRepository();
    final players = [primary ?? FakePlayer()];
    final session = PlaybackSession(
      repository: repo,
      store: await openStore(),
      detail: dramaDetail(drama('window'), count: 110),
      player: players.first,
      standby: preopen ? (players..add(FakePlayer())).last : null,
      createSparePlayer: preopen
          ? () {
              final p = FakePlayer();
              players.add(p);
              return p;
            }
          : null,
      index: 1,
      prepareVideo: prepareVideo,
    );
    await tester.pump();
    return (session, repo, players);
  }

  Future<void> warm(WidgetTester tester, PlaybackSession session) async {
    final player = session.player as FakePlayer;
    await player.play();
    player.state = player.state.copyWith(buffer: const Duration(seconds: 120));
    player.progress(
      const Duration(seconds: 8),
      duration: const Duration(seconds: 120),
    );
    await tester.pump(const Duration(milliseconds: 201));
    await tester.pump(const Duration(milliseconds: 201));
    await tester.pump();
  }

  Future<void> select(
    WidgetTester tester,
    PlaybackSession session,
    int index,
  ) async {
    final result = session.play(index);
    await tester.pump();
    await tester.pump();
    await result;
  }

  testWidgets('输出准备失败实际回收多余播放器，数据仍可供前台切集', (tester) async {
    final (session, repo, players) = await mount(
      tester,
      prepareVideo: (_) async {
        throw StateError('decoder capacity');
      },
    );
    await warm(tester, session);
    await tester.pump();
    await tester.pump();
    expect(session.playerCount, lessThanOrEqualTo(2));
    expect(session.retainedEpisodeCount, 3);
    final calls = repo.resolves.length + repo.preloads.length;
    await select(tester, session, 2);
    expect(repo.resolves.length + repo.preloads.length, calls);
    expect(session.ready, isTrue);
    expect(players.where((p) => !p.disposed).length, lessThanOrEqualTo(2));
    session.dispose();
    await tester.pump();
  });

  testWidgets('慢pause交接期间任何播放入口都不能提前启动新播放器', (tester) async {
    final primary = _SlowPlayer();
    final (session, repo, players) = await mount(tester, primary: primary);
    await warm(tester, session);
    primary.pauseGate = Completer<void>();
    final switched = session.play(2);
    await tester.pump();
    session.togglePlayback();
    await tester.pump();
    expect(primary.state.playing, isTrue);
    expect(
      players
          .where((p) => !identical(p, primary))
          .every((p) => !p.state.playing),
      isTrue,
    );
    primary.pauseGate!.complete();
    await tester.pump();
    await switched;
    expect(players.where((p) => p.state.playing).length, lessThanOrEqualTo(1));
    session.dispose();
    await tester.pump();
  });
  testWidgets('慢stop期间切入已就绪邻集不会清掉新安装的计划', (tester) async {
    final primary = _SlowPlayer();
    final (session, repo, players) = await mount(tester, primary: primary);
    await warm(tester, session);
    final third = session.playerForEpisode(2);
    primary.stopGate = Completer<void>();
    final first = session.play(3);
    await tester.pump();
    final second = session.play(2);
    await tester.pump();
    primary.stopGate!.complete();
    await tester.pump();
    await tester.pump();
    await Future.wait([first, second]);
    expect(session.index, 2);
    expect(session.player, same(third));
    expect(session.ready, isTrue);
    expect(repo.releases.where((id) => id.startsWith('3-')), isEmpty);
    session.dispose();
    await tester.pump();
  });
  testWidgets('撤销站源权限无需退出页面即清空播放计划和邻集解码器', (tester) async {
    final (session, repo, players) = await mount(tester);
    await warm(tester, session);
    await session.store.setSourceEnabled('hongguo', false);
    await tester.pump();
    await tester.pump();
    expect(session.retainedEpisodeCount, 0);
    expect(session.playerCount, 1);
    expect(players.every((p) => !p.state.playing), isTrue);
    expect(repo.releases.length, repo.resolves.length + repo.preloads.length);
    session.dispose();
    await tester.pump();
    expect(repo.releases.toSet().length, repo.releases.length);
  });

  testWidgets('2→3→2保留计划和播放器，回看从零且不再解析，只有当前有声', (tester) async {
    final (session, repo, players) = await mount(tester);
    await warm(tester, session);
    final second = session.player;
    final third = session.playerForEpisode(2);
    expect(third, isNotNull);
    expect(session.retainedEpisodeCount, 3);
    final requests = repo.resolves.length + repo.preloads.length;
    await select(tester, session, 2);
    expect(session.player, same(third));
    await tester.pump();
    expect(session.playerForEpisode(1), same(second));
    expect(session.episodeVideoReady(1), isTrue);
    await select(tester, session, 1);
    expect(session.player, same(second));
    expect(session.player.state.position, Duration.zero);
    expect(repo.resolves.length + repo.preloads.length, requests);
    expect(players.where((p) => p.state.playing).length, 1);
    expect(repo.releases.where((id) => id.startsWith('2-')), isEmpty);
    session.dispose();
    await tester.pump();
    await tester.pump();
    expect(repo.releases.toSet().length, repo.releases.length);
    expect(players.every((p) => p.disposed), isTrue);
  });
  testWidgets('连续100集窗口和播放器数量不增长，退出释放所有资源', (tester) async {
    final (session, repo, players) = await mount(tester);
    for (var index = 1; index < 101; index++) {
      await warm(tester, session);
      expect(session.retainedEpisodeCount, lessThanOrEqualTo(3));
      expect(session.playerCount, lessThanOrEqualTo(3));
      await select(tester, session, index + 1);
    }
    expect(players.length, 3, reason: '槽位复用，不按集创建播放器');
    session.dispose();
    await tester.pump();
    await tester.pump();
    expect(repo.releases.length, repo.resolves.length + repo.preloads.length);
    expect(repo.releases.toSet().length, repo.releases.length);
  });
  testWidgets('预开关闭只保留一个播放器，2→3→2仍复用视频计划', (tester) async {
    final (session, repo, players) = await mount(tester, preopen: false);
    await warm(tester, session);
    final requests = repo.resolves.length + repo.preloads.length;
    await select(tester, session, 2);
    await select(tester, session, 1);
    expect(repo.resolves.length + repo.preloads.length, requests);
    expect(players.length, 1);
    expect(session.player.state.position, Duration.zero);
    session.dispose();
    await tester.pump();
  });
  testWidgets('内存压力清邻集且暂停重建，当前播放保持', (tester) async {
    final (session, repo, players) = await mount(tester);
    await warm(tester, session);
    final active = session.player;
    session.memoryPressure();
    await tester.pump();
    await tester.pump();
    expect(session.player, same(active));
    expect(session.retainedEpisodeCount, 1);
    expect(session.playerCount, 1);
    final requests = repo.preloads.length;
    await warm(tester, session);
    expect(repo.preloads.length, requests);
    expect(players.where((p) => !p.disposed).length, 1);
    session.dispose();
    await tester.pump();
  });
}

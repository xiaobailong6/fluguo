import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'support/fakes.dart';
import 'support/fake_player.dart';

class _Repository extends FakeRepository {
  final preloads = <Completer<PlaybackPlan?>>[];
  final resolved = <int>[];
  final released = <String>[];
  int cancels = 0;
  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    final work = Completer<PlaybackPlan?>();
    preloads.add(work);
    return work.future;
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    resolved.add(episode.number);
    return PlaybackPlan(
      url: 'https://fixture.invalid/${episode.number}',
      session: 'normal-${episode.number}',
    );
  }

  @override
  Future<void> release(String session) async => released.add(session);
  @override
  Future<void> cancelPreload() async {
    cancels++;
  }
}

class _Standby extends FakePlayer {
  Completer<void>? gate;
  @override
  Future<void> open(Playable media, {bool play = true}) async {
    if (gate != null) await gate!.future;
    await super.open(media, play: play);
  }
}

PlaybackPlan _plan({String id = 'next', int expires = 0}) => PlaybackPlan(
  url: 'https://fixture.invalid/$id',
  session: id,
  prefetchedBytes: 4096,
  expiresAt: expires,
);

void main() {
  Future<(PlaybackSession, FakePlayer, _Repository)> open(
    WidgetTester tester, {
    FakePlayer? standby,
    bool local = false,
  }) async {
    final repository = _Repository();
    final player = FakePlayer();
    final session = PlaybackSession(
      repository: repository,
      store: await openStore(),
      detail: dramaDetail(drama('early'), count: 4),
      player: player,
      standby: standby,
      index: 0,
      adoptedPlan: PlaybackPlan(
        url: 'https://fixture.invalid/current',
        session: 'current',
        local: local,
      ),
    );
    await player.play();
    await tester.pump();
    return (session, player, repository);
  }

  void progress(FakePlayer player, int position, {int buffer = 120}) {
    player.state = player.state.copyWith(buffer: Duration(seconds: buffer));
    player.progress(
      Duration(seconds: position),
      duration: const Duration(seconds: 120),
    );
  }

  Future<void> close(WidgetTester tester, PlaybackSession session) async {
    session.dispose();
    await tester.pump();
  }

  testWidgets('本集开头完整缓冲就预取，临近切集预开并直接交换', (tester) async {
    final standby = _Standby();
    final (session, player, repository) = await open(tester, standby: standby);
    progress(player, 8);
    await tester.pump(const Duration(milliseconds: 201));
    expect(repository.preloads, hasLength(1));
    repository.preloads.single.complete(_plan());
    await tester.pump();
    expect(standby.opened, isEmpty, reason: '数据准备不能过早占用第二个解码器');
    progress(player, 95);
    await tester.pump();
    expect(standby.opened, hasLength(1));
    expect(standby.state.playing, isFalse);
    progress(player, 120);
    player.finish();
    await tester.pump();
    expect(session.index, 1);
    expect(session.player, same(standby));
    expect(standby.state.playing, isTrue);
    expect(repository.resolved, isEmpty);
    expect(standby.opened, hasLength(1));
    await close(tester, session);
  });
  testWidgets('提前手动切集接管在途预取，不二次resolve', (tester) async {
    final (session, player, repository) = await open(tester);
    progress(player, 8);
    await tester.pump(const Duration(milliseconds: 201));
    final next = session.play(1);
    await tester.pump();
    repository.preloads.single.complete(_plan());
    await tester.pump();
    await next;
    expect(repository.resolved, isEmpty);
    expect(player.opened.single.uri, 'https://fixture.invalid/next');
    expect(session.ready, isTrue);
    await close(tester, session);
  });
  testWidgets('接管超时回退，迟到预取释放且不覆盖新集', (tester) async {
    final (session, player, repository) = await open(tester);
    progress(player, 8);
    await tester.pump(const Duration(milliseconds: 201));
    final next = session.play(1);
    await tester.pump(const Duration(milliseconds: 1501));
    await next;
    expect(repository.resolved, [2]);
    repository.preloads.single.complete(_plan(id: 'late'));
    await tester.pump();
    expect(repository.released, contains('late'));
    expect(player.opened.single.uri, 'https://fixture.invalid/2');
    await close(tester, session);
  });
  testWidgets('快速跳过下一集只播放最新目标，旧预取不复活', (tester) async {
    final (session, player, repository) = await open(tester);
    progress(player, 8);
    await tester.pump(const Duration(milliseconds: 201));
    final old = session.play(1);
    final latest = session.play(2);
    await tester.pump();
    await Future.wait([old, latest]);
    repository.preloads.single.complete(_plan(id: 'old'));
    await tester.pump();
    expect(session.index, 2);
    expect(repository.resolved, [3]);
    expect(repository.released, contains('old'));
    await close(tester, session);
  });
  testWidgets('本集卡顿取消在途预取，缓冲恢复后再准备', (tester) async {
    final (session, player, repository) = await open(tester);
    progress(player, 40, buffer: 60);
    await tester.pump(const Duration(milliseconds: 201));
    expect(repository.preloads, hasLength(1));
    player.buffer(true);
    await tester.pump();
    expect(repository.cancels, 1);
    repository.preloads.first.complete(_plan(id: 'cancelled'));
    await tester.pump();
    player.buffer(false);
    await tester.pump(const Duration(milliseconds: 201));
    expect(repository.preloads, hasLength(2));
    expect(repository.released, contains('cancelled'));
    await close(tester, session);
    repository.preloads.last.complete(null);
    await tester.pump();
  });
  testWidgets('等待备用open时暂停只暂停目标，不恢复上一集声音', (tester) async {
    final standby = _Standby()..gate = Completer<void>();
    final (session, player, repository) = await open(tester, standby: standby);
    progress(player, 95);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.single.complete(_plan());
    await tester.pump();
    final next = session.play(1);
    session.togglePlayback();
    standby.gate!.complete();
    await tester.pump();
    await next;
    expect(session.index, 1);
    expect(session.player, same(standby));
    expect(session.paused, isTrue);
    expect(standby.state.playing, isFalse);
    await close(tester, session);
  });
  testWidgets('用户切换与退出使预取失效，迟到结果释放', (tester) async {
    final (session, player, repository) = await open(tester);
    progress(player, 8);
    await tester.pump(const Duration(milliseconds: 201));
    final next = session.play(1);
    await session.store.switchProfile(session.store.profile.id);
    await tester.pump();
    await next;
    repository.preloads.single.complete(_plan(id: 'old-user'));
    await tester.pump();
    expect(repository.resolved, isEmpty);
    expect(repository.released, contains('old-user'));
    expect(player.opened, isEmpty);
    await close(tester, session);
  });
  testWidgets('后台听音不预开视频，回前台才恢复准备', (tester) async {
    final standby = _Standby();
    final (session, player, repository) = await open(tester, standby: standby);
    await session.store.setPlaybackPreferences(
      session.preferences.copyWith(backgroundPlayback: true),
    );
    session.setForeground(false);
    progress(player, 95);
    await tester.pump(const Duration(milliseconds: 201));
    expect(repository.preloads, isEmpty);
    session.setForeground(true);
    await tester.pump(const Duration(milliseconds: 201));
    // 不支持系统后台播放的测试平台会保持暂停，用户恢复后才准备。
    if (repository.preloads.isEmpty) {
      session.togglePlayback();
      await tester.pump(const Duration(milliseconds: 201));
    }
    expect(repository.preloads, hasLength(1));
    await close(tester, session);
    repository.preloads.single.complete(null);
    await tester.pump();
  });
  testWidgets('备用播放器仍缓冲时复用计划缓存，不重复解析', (tester) async {
    final standby = _Standby();
    final (session, player, repository) = await open(tester, standby: standby);
    progress(player, 95);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.single.complete(_plan());
    await tester.pump();
    standby.buffer(true);
    final next = session.play(1);
    await tester.pump();
    await next;
    expect(session.player, same(player));
    expect(player.opened.single.uri, 'https://fixture.invalid/next');
    expect(repository.resolved, isEmpty);
    expect(repository.released, isNot(contains('next')));
    await close(tester, session);
  });
  testWidgets('备用播放器迟到报错后不能交换到失败现场', (tester) async {
    final standby = _Standby();
    final (session, player, repository) = await open(tester, standby: standby);
    progress(player, 95);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.single.complete(_plan());
    await tester.pump();
    standby.fail('synthetic failure');
    final next = session.play(1);
    await tester.pump();
    await next;
    expect(repository.resolved, [2]);
    expect(session.player, same(player));
    expect(repository.released, contains('next'));
    await close(tester, session);
  });
  testWidgets('本地当前集也能提前准备下一集，不依赖缓冲上报', (tester) async {
    final (session, player, repository) = await open(tester, local: true);
    progress(player, 8, buffer: 0);
    await tester.pump(const Duration(milliseconds: 201));
    expect(repository.preloads, hasLength(1));
    repository.preloads.single.complete(
      const PlaybackPlan(url: '/local/next.mp4', local: true),
    );
    await tester.pump();
    final next = session.play(1);
    await tester.pump();
    await next;
    expect(repository.resolved, isEmpty);
    expect(session.local, isTrue);
    await close(tester, session);
  });
  testWidgets('备用播放器有效期不能短于预计切集时间', (tester) async {
    final standby = _Standby();
    final (session, player, repository) = await open(tester, standby: standby);
    progress(player, 95);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.single.complete(
      _plan(
        expires: DateTime.now()
            .add(const Duration(seconds: 15))
            .millisecondsSinceEpoch,
      ),
    );
    await tester.pump();
    expect(standby.opened, isEmpty);
    final next = session.play(1);
    await tester.pump();
    await next;
    expect(repository.resolved, isEmpty, reason: '手动提前切集时凭证仍有效可复用');
    await close(tester, session);
  });
  testWidgets('等待备用open时睡眠到时，不被旧切集意图重新起播', (tester) async {
    final standby = _Standby()..gate = Completer<void>();
    final (session, player, repository) = await open(tester, standby: standby);
    progress(player, 95);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.single.complete(_plan());
    await tester.pump();
    late void Function() expire;
    Timer? timer;
    runZoned(
      () => session.setSleepTimer(minutes: 15),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, delay, callback) {
          final created = parent.createTimer(zone, delay, callback);
          if (delay == const Duration(minutes: 15)) {
            expire = zone.bindCallback(callback);
            timer = created;
          }
          return created;
        },
      ),
    );
    final next = session.play(1);
    timer!.cancel();
    expire();
    standby.gate!.complete();
    await tester.pump();
    await next;
    expect(session.paused, isTrue);
    expect(player.state.playing, isFalse);
    expect(standby.state.playing, isFalse);
    await close(tester, session);
  });
}

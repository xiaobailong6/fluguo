import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

class _SlowStopPlayer extends FakePlayer {
  Completer<void>? stopGate;
  @override
  Future<void> stop() async {
    await stopGate?.future;
    await super.stop();
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
    FakePlayer? primary,
    bool local = false,
    Future<void> Function(Player)? prepareVideo,
  }) async {
    final repository = _Repository();
    final player = primary ?? FakePlayer();
    final session = PlaybackSession(
      repository: repository,
      store: await openStore(),
      detail: dramaDetail(drama('early'), count: 4),
      player: player,
      standby: standby,
      prepareVideo: prepareVideo,
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

  testWidgets('后台听音时撤回首帧等待，不重新解析或打断当前集', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('duanju/media');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => null,
    );
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    try {
      final frame = Completer<void>();
      final (session, player, repository) = await open(
        tester,
        standby: _Standby(),
        prepareVideo: (_) => frame.future,
      );
      await session.store.setPlaybackPreferences(
        session.store.playbackPreferences.copyWith(backgroundPlayback: true),
      );
      progress(player, 8);
      await tester.pump(const Duration(milliseconds: 201));
      repository.preloads.single.complete(_plan());
      await tester.pump();
      final next = session.play(1);
      await tester.pump();
      session.setForeground(false);
      await tester.pump();
      await next;
      expect(session.index, 0);
      expect(session.player, same(player));
      expect(player.state.playing, isTrue);
      expect(repository.resolved, isEmpty);
      frame.complete();
      await close(tester, session);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('交换后旧stop完成前不能在同一播放器预开再下一集', (tester) async {
    final primary = _SlowStopPlayer();
    final standby = _Standby();
    final (session, player, repository) = await open(
      tester,
      standby: standby,
      primary: primary,
    );
    progress(player, 95);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.single.complete(_plan());
    await tester.pump();
    primary.stopGate = Completer<void>();
    await session.play(1);
    await tester.pump();
    expect(session.player, same(standby));
    progress(standby, 95);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.last.complete(_plan(id: 'third'));
    await tester.pump();
    expect(primary.opened, isEmpty, reason: '旧stop不能与新open重叠');
    primary.stopGate!.complete();
    await tester.pump();
    expect(primary.opened.single.uri, 'https://fixture.invalid/third');
    await session.play(2);
    await tester.pump();
    expect(session.player, same(primary));
    expect(primary.state.playing, isTrue);
    await close(tester, session);
  });

  testWidgets('本集开头完整缓冲就预取和预开，提前切集直接交换', (tester) async {
    final standby = _Standby();
    final (session, player, repository) = await open(tester, standby: standby);
    progress(player, 8);
    await tester.pump(const Duration(milliseconds: 201));
    expect(repository.preloads, hasLength(1));
    repository.preloads.single.complete(_plan());
    await tester.pump();
    expect(standby.opened, hasLength(1), reason: '缓存完成就准备首帧，不必等到片尾');
    expect(standby.state.playing, isFalse);
    await session.play(1);
    await tester.pump();
    expect(session.index, 1);
    expect(session.player, same(standby));
    expect(standby.state.playing, isTrue);
    expect(repository.resolved, isEmpty);
    expect(standby.opened, hasLength(1));
    await close(tester, session);
  });
  testWidgets('首次预开等待视频输出就绪，接管不重开也不提前清空旧画面', (tester) async {
    final standby = _Standby();
    final frame = Completer<void>();
    var preparations = 0;
    final (session, player, repository) = await open(
      tester,
      standby: standby,
      prepareVideo: (target) {
        expectSync(target, same(standby));
        preparations++;
        return frame.future;
      },
    );
    progress(player, 8);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.single.complete(_plan());
    await tester.pump();
    expect(standby.opened, hasLength(1));
    expect(preparations, 1, reason: '视频输出准备应在open后执行');
    expect(repository.released, isEmpty, reason: '等待首帧期间不能释放备用计划');
    expect(session.standbyIndex, -1, reason: 'open返回不等于画面准备好');
    expect(session.preparingPlayer, same(standby));
    final next = session.play(1);
    await tester.pump();
    expect(session.player, same(player));
    expect(player.stops, 0);
    expect(standby.state.playing, isFalse);
    frame.complete();
    await tester.pump();
    await next;
    expect(session.player, same(standby));
    expect(repository.resolved, isEmpty);
    expect(standby.opened, hasLength(1));
    expect(preparations, 1);
    await close(tester, session);
  });

  testWidgets('等待备用首帧期间退出立即暂停当前声音，不等待备用通道', (tester) async {
    final frame = Completer<void>();
    final (session, player, repository) = await open(
      tester,
      standby: _Standby(),
      prepareVideo: (_) => frame.future,
    );
    progress(player, 8);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.single.complete(_plan());
    await tester.pump();
    expect(player.state.playing, isTrue);
    session.dispose();
    await tester.pump();
    expect(player.state.playing, isFalse);
    frame.complete();
    await tester.pump();
    expect(player.disposed, isTrue);
  });

  testWidgets('首帧准备失败回退正常解析，不接管无画面的备用播放器', (tester) async {
    final standby = _Standby();
    final frame = Completer<void>();
    final (session, player, repository) = await open(
      tester,
      standby: standby,
      prepareVideo: (_) => frame.future,
    );
    progress(player, 8);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.single.complete(_plan());
    await tester.pump();
    frame.completeError(StateError('output unavailable'));
    await tester.pump();
    expect(session.preparingPlayer, isNull);
    expect(
      repository.released,
      isNot(contains('next')),
      reason: '解码准备失败仍保留有效数据',
    );
    final next = session.play(1);
    await tester.pump();
    await next;
    expect(session.player, same(player));
    expect(repository.resolved, isEmpty);
    await close(tester, session);
  });

  testWidgets('等首帧时切后台丢弃计划，迟到首帧不恢复预开或声音', (tester) async {
    final standby = _Standby();
    final frame = Completer<void>();
    final (session, player, repository) = await open(
      tester,
      standby: standby,
      prepareVideo: (_) => frame.future,
    );
    progress(player, 8);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.single.complete(_plan());
    await tester.pump();
    session.setForeground(false);
    frame.complete();
    await tester.pump();
    expect(session.standbyIndex, -1);
    expect(session.preparingPlayer, isNull);
    expect(standby.state.playing, isFalse);
    expect(repository.released, contains('next'));
    await close(tester, session);
  });

  testWidgets('连续预载交换每集都调用输出准备回调', (tester) async {
    final standby = _Standby();
    final preparations = <Completer<void>>[];
    final (session, player, repository) = await open(
      tester,
      standby: standby,
      prepareVideo: (_) {
        final frame = Completer<void>();
        preparations.add(frame);
        return frame.future;
      },
    );
    progress(player, 8);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.single.complete(_plan());
    await tester.pump();
    preparations.single.complete();
    await tester.pump();
    await session.play(1);
    await tester.pump();
    // 离开的当前集也要准备回看首帧，不能把它的准备任务永远挂起。
    if (preparations.length > 1) preparations.last.complete();
    await tester.pump();
    progress(standby, 8);
    await tester.pump(const Duration(milliseconds: 201));
    repository.preloads.last.complete(_plan(id: 'third'));
    await tester.pump();
    expect(preparations, hasLength(3));
    expect(session.standbyIndex, -1);
    preparations.last.complete();
    await tester.pump();
    await session.play(2);
    expect(session.player, same(player));
    expect(repository.resolved, isEmpty);
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
  testWidgets('已有首帧的备用播放器仍缓冲时直接复用，不重新打开或解析', (tester) async {
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
    expect(session.player, same(standby));
    expect(player.opened, isEmpty);
    expect(player.state.playing, isFalse);
    expect(standby.opened.single.uri, 'https://fixture.invalid/next');
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
  testWidgets('仍有效的短期凭证也可预开供提前切集使用', (tester) async {
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
    expect(standby.opened, hasLength(1));
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

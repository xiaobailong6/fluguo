import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/player/playback_handle.dart';
import 'package:duanju_app/ui/player/player_video.dart';
import 'package:duanju_app/ui/player/player_surface.dart';
import 'package:duanju_app/ui/player/portrait_player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Repository extends FakeRepository {
  final pending = Completer<PlaybackPlan?>();
  var resolves = 0;
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
    resolves++;
    return const PlaybackPlan(url: 'https://example.invalid/cold');
  }
}

class _OpeningPlayer extends FakePlayer {
  Completer<void>? gate;
  @override
  Future<void> open(Playable media, {bool play = true}) async {
    await gate?.future;
    await super.open(media, play: play);
  }
}

class _Video extends Fake implements VideoController {
  _Video(this.player, {int? textureId}) {
    if (textureId != null) notifier.value = _TextureOutput(textureId);
  }
  @override
  final Player player;
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
}

// 只模拟平台输出标识，交给真实 Video/Texture 控件走 Flutter 绘制流程。
class _TextureOutput extends Fake implements PlatformVideoController {
  _TextureOutput(int textureId) : id = ValueNotifier(textureId);
  @override
  final ValueNotifier<int?> id;
  @override
  final rect = ValueNotifier<Rect?>(const Rect.fromLTWH(0, 0, 640, 360));
}

class _Handle extends Fake implements PlaybackHandle {
  _Handle(this.session, this.videos);
  @override
  final PlaybackSession session;
  final Map<Player, VideoController> videos;
  @override
  VideoController video(Player player) => videos[player]!;
}

void main() {
  testWidgets('同位置切换控制器不沿用旧播放器的视频状态', (tester) async {
    final repo = _Repository();
    final store = await openStore();
    final main = FakePlayer(), next = FakePlayer();
    main.state = main.state.copyWith(width: 640, height: 360);
    next.state = next.state.copyWith(width: 640, height: 360);
    final session = PlaybackSession(
      repository: repo,
      store: store,
      detail: dramaDetail(drama('controller'), count: 2),
      player: main,
      index: 0,
      adoptedPlan: const PlaybackPlan(url: 'https://example.invalid/current'),
    );
    final mainVideo = _Video(main, textureId: 101);
    final nextVideo = _Video(next, textureId: 202);
    final handle = _Handle(session, {main: mainVideo, next: nextVideo});
    Widget view(Player player) => MaterialApp(
      home: PlayerVideo(handle: handle, player: player),
    );
    await tester.pumpWidget(view(main));
    final original = tester.state(find.byType(Video));
    await tester.pumpWidget(view(main));
    expect(tester.state(find.byType(Video)), same(original));
    await tester.pumpWidget(view(next));
    expect(tester.state(find.byType(Video)), isNot(same(original)));
    expect(
      tester.widget<Video>(find.byType(Video)).controller,
      same(nextVideo),
    );
    expect(
      tester.layers.whereType<TextureLayer>().map((layer) => layer.textureId),
      [202],
    );
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    await tester.pump();
    mainVideo.notifier.dispose();
    nextVideo.notifier.dispose();
  });

  for (final portrait in [true, false]) {
    testWidgets('探测失败不挡下一集播放且无旧画面覆盖 portrait=$portrait', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = portrait
          ? const Size(390, 844)
          : const Size(844, 390);
      addTearDown(tester.view.reset);
      final repo = _Repository();
      final store = await openStore();
      final main = FakePlayer(), next = FakePlayer();
      main.state = main.state.copyWith(width: 640, height: 360);
      next.state = next.state.copyWith(width: 640, height: 360);
      final session = PlaybackSession(
        repository: repo,
        store: store,
        detail: dramaDetail(drama('retry'), count: 2),
        player: main,
        standby: next,
        index: 0,
        adoptedPlan: const PlaybackPlan(url: 'https://example.invalid/current'),
        prepareVideo: (_) async {
          throw TimeoutException('probe unavailable');
        },
      );
      final mainVideo = _Video(main, textureId: 101);
      final nextVideo = _Video(next, textureId: 202);
      final handle = _Handle(session, {main: mainVideo, next: nextVideo});
      final hint = ValueNotifier('');
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => AppScope(
            repository: repo,
            formFactor: FormFactor.phone,
            child: child!,
          ),
          home: portrait
              ? PortraitPlayerPage(store: store, handle: handle)
              : Scaffold(
                  body: PlayerSurface(
                    handle: handle,
                    hint: hint,
                    touch: true,
                    fullscreen: true,
                    wide: false,
                    onFullscreen: () {},
                    onWide: null,
                    onSurface: () {},
                  ),
                ),
        ),
      );
      final switching = session.play(1);
      await tester.pump();
      await switching;
      await tester.pump();
      expect(session.index, 1);
      expect(session.player, same(next));
      expect(next.state.playing, isTrue);
      expect(next.opened, hasLength(1));
      expect(find.byType(Image), findsNothing);
      expect(find.byKey(const ValueKey('retained-switch-frame')), findsNothing);
      expect(find.byKey(const ValueKey('episode-switch-retry')), findsNothing);
      expect(main.opened, isEmpty);
      expect(main.stops, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      await tester.pump();
      hint.dispose();
      mainVideo.notifier.dispose();
      nextVideo.notifier.dispose();
    });
  }

  for (final preopened in [true, false]) {
    testWidgets('横屏全屏交接，预开就绪=$preopened', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(844, 390);
      addTearDown(tester.view.reset);
      final repo = _Repository();
      final store = await openStore();
      final main = FakePlayer(), standby = FakePlayer();
      final firstFrame = Completer<void>();
      final session = PlaybackSession(
        repository: repo,
        store: store,
        detail: dramaDetail(drama('fullscreen'), count: 2),
        player: main,
        standby: standby,
        index: 0,
        prepareVideo: (_) => firstFrame.future,
        adoptedPlan: const PlaybackPlan(
          url: 'https://example.invalid/current',
          session: 'current',
        ),
      );
      main.state = main.state.copyWith(width: 640, height: 360);
      standby.state = standby.state.copyWith(width: 640, height: 360);
      final mainVideo = _Video(main, textureId: 101);
      final nextVideo = _Video(standby, textureId: 202);
      final handle = _Handle(session, {main: mainVideo, standby: nextVideo});
      final hint = ValueNotifier('');
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => AppScope(
            repository: repo,
            formFactor: FormFactor.phone,
            child: child!,
          ),
          home: Scaffold(
            body: PlayerSurface(
              handle: handle,
              hint: hint,
              touch: true,
              fullscreen: true,
              wide: false,
              onFullscreen: () {},
              onWide: null,
              onSurface: () {},
            ),
          ),
        ),
      );
      if (preopened) {
        await main.play();
        main.state = main.state.copyWith(buffer: const Duration(seconds: 120));
        main.progress(
          const Duration(seconds: 8),
          duration: const Duration(seconds: 120),
        );
        await tester.pump(const Duration(milliseconds: 201));
        firstFrame.complete();
        repo.pending.complete(
          const PlaybackPlan(
            url: 'https://example.invalid/next',
            session: 'next',
          ),
        );
        await tester.pump();
        expect(session.standby, same(standby));
        expect(standby.state.playing, isFalse);
        expect(standby.state.position, Duration.zero);
      }
      final currentLayer = find.byWidgetPredicate(
        (widget) => widget is PlayerVideo && identical(widget.player, main),
      );
      final nextLayer = find.byWidgetPredicate(
        (widget) => widget is PlayerVideo && identical(widget.player, standby),
        skipOffstage: false,
      );
      expect(currentLayer, findsOneWidget);
      if (preopened) {
        expect(nextLayer, findsOneWidget, reason: '下一集真实视频视图必须在切换前挂载');
        expect(
          tester.layers.whereType<TextureLayer>().map(
            (layer) => layer.textureId,
          ),
          [202, 101],
          reason: '候选真实纹理在下层，当前真实纹理在上层',
        );
      } else {
        expect(nextLayer, findsNothing);
        expect(
          tester.layers.whereType<TextureLayer>().map(
            (layer) => layer.textureId,
          ),
          [101],
        );
      }
      final nextElement = preopened ? tester.element(nextLayer) : null;
      expect(session.canHoldEpisodeFrame(1), isTrue);
      final switching = session.play(1);
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsNothing, reason: '切集不得使用截图或封面过渡');
      expect(main.stops, 0, reason: '交接前后旧播放器均不清空视频输出');
      expect(main.opened, isEmpty);
      if (!preopened) {
        expect(session.player, same(standby));
        expect(session.waitingForNext, isFalse);
        expect(standby.opened, hasLength(1));
        expect(standby.state.playing, isTrue);
        expect(firstFrame.isCompleted, isFalse, reason: '检测未结束也不能拦截真实播放');
        firstFrame.complete();
        await tester.pump();
        await tester.pump();
      }
      expect(session.player, same(standby));
      expect(
        tester.layers.whereType<TextureLayer>().map((layer) => layer.textureId),
        [101, 202],
        reason: '交接直接提升已就绪的真实纹理',
      );
      if (preopened) {
        expect(tester.element(nextLayer), same(nextElement));
        expect(standby.state.playing, isTrue);
        expect(standby.state.position, Duration.zero);
        expect(standby.seeks, isEmpty);
        expect(standby.opened, hasLength(1));
      }
      expect(repo.resolves, preopened ? 0 : 1);
      expect(standby.opened, hasLength(1));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(Image), findsNothing);
      await switching;
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      await tester.pump();
      mainVideo.notifier.dispose();
      nextVideo.notifier.dispose();
      hint.dispose();
    });
  }

  for (final mode in [
    'ready',
    'pending',
    'slow_frame',
    'back_ready',
    'back_timeout',
  ]) {
    testWidgets('预载视频层提前挂载与切集意图 $mode', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final repo = _Repository();
      final store = await openStore();
      final main = FakePlayer();
      final standby = _OpeningPlayer();
      if (mode.startsWith('back')) standby.gate = Completer<void>();
      final frame = Completer<void>();
      final rewind = Completer<void>();
      final session = PlaybackSession(
        repository: repo,
        store: store,
        detail: dramaDetail(drama('seamless'), count: 2),
        player: main,
        standby: standby,
        index: 0,
        prepareVideo: (_) => frame.future,
        resetVideo: (player, position) async {
          await player.seek(position);
          await rewind.future;
        },
        adoptedPlan: const PlaybackPlan(
          url: 'https://example.invalid/current',
          session: 'current',
        ),
      );
      final mainVideo = _Video(main), nextVideo = _Video(standby);
      final handle = _Handle(session, {main: mainVideo, standby: nextVideo});
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => AppScope(
            repository: repo,
            formFactor: FormFactor.phone,
            child: child!,
          ),
          home: PortraitPlayerPage(store: store, handle: handle),
        ),
      );
      await main.play();
      main.state = main.state.copyWith(buffer: const Duration(seconds: 120));
      main.progress(
        const Duration(seconds: 8),
        duration: const Duration(seconds: 120),
      );
      await tester.pump(const Duration(milliseconds: 201));
      final pages = find.byType(PageView);
      final controller = tester.widget<PageView>(pages).controller!;
      if (mode == 'pending') {
        await tester.drag(pages, const Offset(0, -550));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(session.waitingForNext, isTrue);
        expect(session.index, 0);
        expect(controller.page, closeTo(1, .01));
        expect(main.state.playing, isFalse);
        expect(
          find.byKey(const ValueKey('retained-switch-frame')),
          findsNothing,
        );
      }
      repo.pending.complete(
        const PlaybackPlan(
          url: 'https://example.invalid/next',
          session: 'next',
          prefetchedBytes: 4096,
        ),
      );
      await tester.pump();
      await tester.pump();
      final nextLayer = find.byWidgetPredicate(
        (widget) =>
            widget is PlayerVideo &&
            widget.key != null &&
            identical(widget.player, standby),
        skipOffstage: false,
      );
      expect(nextLayer, findsOneWidget, reason: '下一页不能等手势开始才创建视频层');
      final element = tester.element(nextLayer);
      final originalLayer = find.byWidgetPredicate(
        (widget) =>
            widget is PlayerVideo &&
            widget.key != null &&
            identical(widget.player, main),
        skipOffstage: false,
      );
      final originalElement = tester.element(originalLayer);
      final heldFrame = find.byKey(
        const ValueKey('retained-switch-frame'),
        skipOffstage: false,
      );
      expect(heldFrame, findsNothing, reason: '邻页不得复制上一集画面');
      expect(find.byKey(const ValueKey('preparing-video-cover')), findsNothing);
      expect(
        standby.state.playing,
        mode == 'pending',
        reason: '仅已完成切集的目标起播，尚未切入的邻页停在首帧',
      );
      if (mode.startsWith('back')) {
        await tester.drag(pages, const Offset(0, -550));
        await tester.pump();
        expect(main.state.playing, isFalse, reason: '翻页动画未结束也不能留旧声');
        await tester.pump(const Duration(milliseconds: 350));
        expect(session.waitingForNext, isTrue);
        expect(controller.page, closeTo(1, .01));
        expect(heldFrame, findsNothing);
        await tester.drag(pages, const Offset(0, 550));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(session.waitingForNext, isFalse);
        if (mode == 'back_timeout') {
          await tester.pump(const Duration(seconds: 2));
        }
        frame.complete();
        standby.gate!.complete();
        rewind.complete();
        await tester.pump();
        await tester.pump();
        expect(session.index, 0);
        expect(session.player, same(main));
        expect(controller.page, closeTo(0, .01));
        expect(main.stops, 0);
        expect(main.state.playing, isTrue, reason: '撤回后恢复原有播放意图');
        expect(repo.resolves, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
        await tester.pump();
        mainVideo.notifier.dispose();
        nextVideo.notifier.dispose();
        return;
      }
      if (mode == 'slow_frame') {
        await tester.drag(pages, const Offset(0, -550));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 2100));
        expect(session.waitingForNext, isFalse);
        expect(session.player, same(standby));
        expect(main.stops, 0);
        expect(heldFrame, findsNothing);
        expect(tester.element(nextLayer), same(element));
        expect(find.byType(Image), findsNothing);
      }
      frame.complete();
      await tester.pump();
      await tester.pump();
      expect(heldFrame, findsNothing);
      if (mode == 'ready') {
        expect(session.standbyIndex, 1);
        await tester.drag(pages, const Offset(0, -550));
        await tester.pump();
        expect(main.state.playing, isFalse);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
      }
      expect(session.index, 1);
      expect(session.player, same(standby));
      expect(tester.element(nextLayer), same(element));
      expect(standby.state.playing, isTrue);
      expect(standby.state.position, Duration.zero);
      expect(standby.seeks, isEmpty);
      expect(standby.opened, hasLength(1));
      expect(repo.resolves, 0);
      // 已播放的上一集仍挂载，切回零点无需再次解析或重建画面层。
      await tester.pump();
      expect(session.episodeVideoReady(0), isFalse);
      expect(session.episodeFrameRetained(0), isTrue);
      expect(
        find.byKey(
          const ValueKey('preparing-video-cover'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      rewind.complete();
      await tester.pump();
      expect(session.episodeVideoReady(0), isTrue);
      await tester.drag(find.byType(PageView), const Offset(0, 550));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(session.index, 0);
      expect(session.player, same(main));
      expect(tester.element(originalLayer), same(originalElement));
      expect(main.state.position, Duration.zero);
      expect(repo.resolves, 0);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      await tester.pump();
      mainVideo.notifier.dispose();
      nextVideo.notifier.dispose();
    });
  }
}

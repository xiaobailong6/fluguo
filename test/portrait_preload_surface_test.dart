import 'dart:async';
import 'dart:convert';

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
        autoplay: preopened,
        prepareVideo: (player) =>
            identical(player, main) ? firstFrame.future : Future<void>.value(),
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
      var captures = 0;
      final image = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRxoAAAAASUVORK5CYII=',
      );
      Player? capturedPlayer;
      int? stopsAtCapture;
      session.captureFullscreenSwitchFrame = (player) async {
        capturedPlayer = player;
        stopsAtCapture = main.stops;
        captures++;
        return image;
      };
      if (preopened) {
        await main.play();
        main.state = main.state.copyWith(buffer: const Duration(seconds: 120));
        main.progress(
          const Duration(seconds: 8),
          duration: const Duration(seconds: 120),
        );
        await tester.pump(const Duration(milliseconds: 201));
        repo.pending.complete(
          const PlaybackPlan(
            url: 'https://example.invalid/next',
            session: 'next',
          ),
        );
        await tester.pump();
        expect(session.standby, same(standby));
      }
      final currentLayer = find.byWidgetPredicate(
        (widget) => widget is PlayerVideo && identical(widget.player, main),
      );
      final nextLayer = find.byWidgetPredicate(
        (widget) => widget is PlayerVideo && identical(widget.player, standby),
        skipOffstage: false,
      );
      expect(currentLayer, findsOneWidget);
      expect(nextLayer, findsNothing, reason: '预开播放器只准备解码，不挂载第二个显示纹理');
      expect(
        tester.layers.whereType<TextureLayer>().map((layer) => layer.textureId),
        [101],
      );
      expect(session.canHoldEpisodeFrame(1), isTrue);
      final switching = session.play(1);
      await tester.pump();
      await tester.pump();
      final overlay = find.byKey(const ValueKey('fullscreen-switch-frame'));
      if (preopened) {
        expect(captures, 0);
        expect(overlay, findsNothing);
        expect(session.player, same(standby));
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is PlayerVideo && identical(widget.player, standby),
          ),
          findsOneWidget,
        );
        expect(
          tester.layers.whereType<TextureLayer>().map(
            (layer) => layer.textureId,
          ),
          [202],
        );
        expect(repo.resolves, 0);
        expect(standby.opened, hasLength(1));
      } else {
        expect(captures, 1);
        expect(capturedPlayer, same(main));
        expect(stopsAtCapture, 0);
        expect(main.opened, hasLength(1));
        expect(session.fullscreenSwitchFrame, same(image));
        await tester.pump(const Duration(milliseconds: 800));
        main.progress(
          const Duration(seconds: 1),
          duration: const Duration(seconds: 120),
        );
        await tester.pump(const Duration(milliseconds: 2300));
        expect(overlay, findsOneWidget, reason: '首帧探测未完成时不能按固定3秒撤掉旧帧');
        expect(session.fullscreenSwitchFrame, same(image));
        firstFrame.complete();
        await tester.pump();
        await switching;
        await tester.pump();
        expect(overlay, findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(session.fullscreenSwitchFrame, isNull);
      }
      await switching;
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      await tester.pump();
      mainVideo.notifier.dispose();
      nextVideo.notifier.dispose();
      hint.dispose();
    });
  }

  for (final mode in ['ready', 'pending', 'back_ready', 'back_timeout']) {
    testWidgets('预载视频层提前挂载与切集意图 $mode', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final repo = _Repository();
      final store = await openStore();
      final main = FakePlayer();
      final standby = FakePlayer();
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
          findsOneWidget,
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
      expect(heldFrame, findsOneWidget);
      expect(
        tester
            .widget<PlayerVideo>(
              find.descendant(
                of: heldFrame,
                matching: find.byType(PlayerVideo, skipOffstage: false),
              ),
            )
            .player,
        same(main),
      );
      expect(find.byKey(const ValueKey('preparing-video-cover')), findsNothing);
      expect(standby.state.playing, isFalse);
      if (mode.startsWith('back')) {
        await tester.drag(pages, const Offset(0, -550));
        await tester.pump();
        expect(main.state.playing, isFalse, reason: '翻页动画未结束也不能留旧声');
        await tester.pump(const Duration(milliseconds: 350));
        expect(session.waitingForNext, isTrue);
        expect(controller.page, closeTo(1, .01));
        expect(heldFrame, findsOneWidget);
        await tester.drag(pages, const Offset(0, 550));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(session.waitingForNext, isFalse);
        if (mode == 'back_timeout') {
          await tester.pump(const Duration(seconds: 2));
        }
        frame.complete();
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

import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/player/playback_handle.dart';
import 'package:duanju_app/ui/player/player_video.dart';
import 'package:duanju_app/ui/player/portrait_player_page.dart';
import 'package:flutter/material.dart';
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
  _Video(this.player);
  @override
  final Player player;
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
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
  for (final mode in ['ready', 'back_ready', 'back_timeout']) {
    testWidgets('预载视频层提前挂载与切集意图 $mode', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final repo = _Repository();
      final store = await openStore();
      final main = FakePlayer();
      final standby = FakePlayer();
      final frame = Completer<void>();
      final session = PlaybackSession(
        repository: repo,
        store: store,
        detail: dramaDetail(drama('seamless'), count: 2),
        player: main,
        standby: standby,
        index: 0,
        prepareVideo: (_) => frame.future,
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
        (widget) => widget is PlayerVideo && identical(widget.player, standby),
        skipOffstage: false,
      );
      expect(nextLayer, findsOneWidget, reason: '下一页不能等手势开始才创建视频层');
      final element = tester.element(nextLayer);
      expect(
        find.byKey(
          const ValueKey('preparing-video-cover'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(standby.state.playing, isFalse);
      if (mode != 'ready') {
        final pages = find.byType(PageView);
        final controller = tester.widget<PageView>(pages).controller!;
        await tester.drag(pages, const Offset(0, -550));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(session.waitingForNext, isTrue);
        expect(controller.page, closeTo(1, .01));
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
      expect(session.standbyIndex, 1);
      expect(
        find.byKey(
          const ValueKey('preparing-video-cover'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      await tester.drag(find.byType(PageView), const Offset(0, -550));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(session.index, 1);
      expect(session.player, same(standby));
      expect(tester.element(nextLayer), same(element));
      expect(standby.opened, hasLength(1));
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

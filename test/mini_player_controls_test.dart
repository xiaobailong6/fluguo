import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/player/mini_player.dart';
import 'package:duanju_app/ui/player/playback_handle.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Video extends Fake implements VideoController {
  _Video(this.player);
  @override
  final FakePlayer player;
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
  @override
  final id = ValueNotifier<int?>(null);
  @override
  final rect = ValueNotifier<Rect?>(null);
}

class _Repository extends FakeRepository {
  final pending = Completer<PlaybackPlan>();
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => pending.future;
}

void main() {
  testWidgets('切集等待与缓冲不弹控制栏，暂停和鼠标悬停仍显示', (tester) async {
    final store = await openStore();
    final player = FakePlayer();
    final video = _Video(player);
    final repository = _Repository();
    final handle = PlaybackHandle(
      repository: repository,
      store: store,
      detail: dramaDetail(drama('mini'), count: 2),
      index: 0,
      preopen: false,
      adoptedPlayer: player,
      adoptedVideo: video,
      adoptedPlan: const PlaybackPlan(url: 'https://fixture.invalid/1'),
    );
    await player.play();
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => AppScope(
          repository: repository,
          formFactor: FormFactor.window,
          child: child!,
        ),
        home: MiniWindowView(handle: handle, onRestore: () {}, onClose: () {}),
      ),
    );
    double opacity() => tester
        .widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first)
        .opacity;
    await tester.pump();
    expect(opacity(), 0);
    final switching = handle.session.play(1);
    await tester.pump();
    expect(handle.session.loading, isTrue);
    expect(opacity(), 0);
    repository.pending.complete(
      const PlaybackPlan(url: 'https://fixture.invalid/2'),
    );
    await switching;
    player.buffer(true);
    await tester.pump();
    expect(opacity(), 0);
    handle.session.togglePlayback();
    await tester.pump();
    expect(opacity(), 1);
    handle.session.togglePlayback();
    player.buffer(false);
    await tester.pump();
    expect(opacity(), 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    await mouse.moveTo(const Offset(40, 40));
    await tester.pump();
    expect(opacity(), 1);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
    await tester.pump(const Duration(seconds: 1));
    video.notifier.dispose();
    video.id.dispose();
    video.rect.dispose();
    expect(tester.takeException(), isNull);
  });
}

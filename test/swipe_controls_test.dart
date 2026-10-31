import 'dart:async';

import 'package:duanju_app/app_device.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:duanju_app/ui/player/swipe_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Repository extends FakeRepository {
  Completer<PlaybackPlan>? pending;

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => pending == null
      ? PlaybackPlan(url: 'https://media.test/${episode.number}.mp4')
      : await pending!.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlaybackSession session;
  late FakePlayer player;
  late _Repository repository;
  late List<String> methods;
  var taps = 0;

  setUp(() async {
    methods = [];
    taps = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppDevice.channel, (call) async {
          methods.add(call.method);
          return call.method == 'getBrightness' || call.method == 'volume'
              ? .5
              : null;
        });
    repository = _Repository();
    player = FakePlayer();
    session = PlaybackSession(
      repository: repository,
      store: await openStore(),
      detail: dramaDetail(drama('wide'), count: 3),
      player: player,
      index: 1,
    );
    await pumpEventQueue();
  });

  tearDown(() {
    session.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppDevice.channel, null);
  });

  Future<void> mount(
    WidgetTester tester, {
    bool enabled = true,
    bool levels = true,
    bool episodes = true,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            height: 300,
            child: Stack(
              fit: StackFit.expand,
              children: [
                SwipeControls(
                  session: session,
                  enabled: enabled,
                  levels: levels,
                  episodes: episodes,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 250,
                  child: SizedBox(
                    width: 100,
                    height: 48,
                    child: TextButton(
                      onPressed: () => taps++,
                      child: const Text('control'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Offset point(WidgetTester tester, double fraction) =>
      tester.getTopLeft(find.byType(SwipeControls)) +
      Offset(600 * fraction, 150);

  testWidgets('up is next, down is previous, and only commits on release', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(point(tester, .5));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(session.index, 1);
    await gesture.up();
    await tester.pump();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(session.index, 2);
    // 新一集准备完成后，下一次下滑才允许返回上一集。
    await tester.runAsync(() => session.play(2));
    expect(session.ready, isTrue);
    await tester.dragFrom(point(tester, .5), const Offset(0, 100));
    await tester.pump();
    expect(session.index, 1);
    expect(methods, isEmpty);
    expect(taps, 0);
  });

  testWidgets('short movement and cancelled drags do not switch', (
    tester,
  ) async {
    await mount(tester);
    await tester.dragFrom(point(tester, .5), const Offset(0, -40));
    final gesture = await tester.startGesture(point(tester, .5));
    await gesture.moveBy(const Offset(0, -120));
    await gesture.cancel();
    await tester.pump();
    expect(session.index, 1);
    expect(methods, isEmpty);
  });

  testWidgets('first and last episodes show boundaries without reopening', (
    tester,
  ) async {
    await tester.runAsync(() => session.play(0));
    await mount(tester);
    await tester.dragFrom(point(tester, .5), const Offset(0, 100));
    await tester.pump();
    expect(session.index, 0);
    expect(find.text('已经是第一集'), findsOneWidget);
    await tester.runAsync(() => session.play(2));
    await tester.dragFrom(point(tester, .5), const Offset(0, -100));
    await tester.pump();
    expect(session.index, 2);
    expect(find.text('已经是最后一集'), findsOneWidget);
    expect(player.opened, hasLength(3));
    await tester.pump(const Duration(milliseconds: 1300));
  });

  testWidgets(
    'side regions keep levels and cannot switch after crossing center',
    (tester) async {
      await mount(tester);
      for (final side in [.1, .9]) {
        final gesture = await tester.startGesture(point(tester, side));
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump();
        await gesture.moveBy(Offset(side < .5 ? 240 : -240, -60));
        await tester.pump();
        await gesture.up();
      }
      expect(session.index, 1);
      expect(
        methods,
        containsAll(['getBrightness', 'setBrightness', 'volume', 'setVolume']),
      );
    },
  );

  testWidgets('center remains episode gesture when moving into a side', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(point(tester, .5));
    await gesture.moveBy(const Offset(0, -40));
    await gesture.moveBy(const Offset(240, -60));
    await gesture.up();
    await tester.pump();
    expect(session.index, 2);
    expect(methods, isEmpty);
  });

  testWidgets(
    'embedded playback and disabled levels still allow center switching',
    (tester) async {
      await mount(tester, enabled: false, levels: false);
      await tester.dragFrom(point(tester, .5), const Offset(0, -100));
      await tester.pump();
      expect(session.index, 2);
      await tester.runAsync(() => session.play(2));
      await tester.dragFrom(point(tester, .1), const Offset(0, 100));
      await tester.pump();
      expect(session.index, 1);
      expect(methods, isEmpty);
    },
  );

  testWidgets('关闭亮度音量时全屏左右区域都切集且不调用设备调节', (tester) async {
    await mount(tester, levels: false);
    await tester.dragFrom(point(tester, .1), const Offset(0, -100));
    await tester.pump();
    expect(session.index, 2);
    await tester.runAsync(() => session.play(2));
    await tester.dragFrom(point(tester, .9), const Offset(0, 100));
    await tester.pump();
    expect(session.index, 1);
    expect(methods, isEmpty);
  });

  testWidgets(
    'loading and a session change during a drag invalidate switching',
    (tester) async {
      await mount(tester);
      final gesture = await tester.startGesture(point(tester, .5));
      await gesture.moveBy(const Offset(0, -100));
      await tester.runAsync(() => session.play(0));
      await gesture.up();
      await tester.pump();
      expect(session.index, 0);
      repository.pending = Completer<PlaybackPlan>();
      unawaited(session.play(1));
      await tester.pump();
      expect(session.loading, isTrue);
      await tester.dragFrom(point(tester, .5), const Offset(0, -100));
      expect(session.index, 1);
      repository.pending!.complete(
        PlaybackPlan(url: 'https://media.test/2.mp4'),
      );
      await tester.pump();
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(session.index, 1);
      expect(methods, isEmpty);
    },
  );

  testWidgets('surface taps and overlaid control taps/drags never switch', (
    tester,
  ) async {
    await mount(tester);
    await tester.tapAt(point(tester, .5));
    await tester.tap(find.text('control'));
    await tester.drag(find.text('control'), const Offset(0, 100));
    await tester.pump();
    expect(taps, 2);
    expect(session.index, 1);
    expect(methods, isEmpty);
  });

  testWidgets('portrait default leaves vertical gestures unclaimed', (
    tester,
  ) async {
    await mount(tester, episodes: false, levels: false);
    await tester.dragFrom(point(tester, .5), const Offset(0, -100));
    await tester.pump();
    expect(session.index, 1);
    expect(methods, isEmpty);
  });
}

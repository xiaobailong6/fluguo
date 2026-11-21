import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/player/playback_handle.dart';
import 'package:duanju_app/ui/player/player_screen_lock.dart';
import 'package:duanju_app/ui/player/player_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

// 真实 PlayerSurface/Session，仅替换媒体输出，测试不访问网络或原生解码器。
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

Future<PlaybackHandle> mountSurface(
  WidgetTester tester, {
  Size size = const Size(900, 500),
  EdgeInsets padding = EdgeInsets.zero,
  FormFactor form = FormFactor.phone,
  bool touch = true,
  bool fullscreen = true,
  bool supportsLock = true,
  bool reduced = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final store = await openStore();
  final repository = FakeRepository();
  final player = FakePlayer();
  final video = _Video(player);
  final hint = ValueNotifier('');
  final handle = PlaybackHandle(
    repository: repository,
    store: store,
    detail: dramaDetail(drama('lock-layout'), count: 2),
    index: 0,
    preopen: false,
    adoptedPlayer: player,
    adoptedVideo: video,
    adoptedPlan: PlaybackPlan(url: 'https://media.test/lock.mp4'),
  );
  addTearDown(() {
    video.notifier.dispose();
    video.id.dispose();
    video.rect.dispose();
    hint.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => AppScope(
        repository: repository,
        formFactor: form,
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            padding: padding,
            textScaler: TextScaler.linear(reduced ? 2 : 1),
            disableAnimations: reduced,
          ),
          child: child!,
        ),
      ),
      home: ListenableBuilder(
        listenable: handle.session,
        builder: (_, _) => PlayerScreenLock(
          locked: handle.session.locked,
          onUnlock: () => handle.session.setLocked(false),
          // 与 PlayerPage 相同：画面在 SafeArea 内，解锁层在外。
          child: Scaffold(
            body: SafeArea(
              child: PlayerSurface(
                handle: handle,
                hint: hint,
                touch: touch,
                fullscreen: fullscreen,
                wide: false,
                onFullscreen: () {},
                onWide: null,
                onLock: supportsLock
                    ? () => handle.session.setLocked(true)
                    : null,
                onSurface: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return handle;
}

Finder button(String action, String side) =>
    find.byKey(ValueKey('player-$action-$side'));

void main() {
  for (final form in [FormFactor.phone, FormFactor.pad]) {
    for (final side in ['left', 'right']) {
      testWidgets('$form $side 锁定解锁同位置，安全区不重复，大字体减少动画', (tester) async {
        const padding = EdgeInsets.fromLTRB(44, 8, 20, 24);
        final handle = await mountSurface(
          tester,
          form: form,
          padding: padding,
          reduced: true,
        );
        final positions = {
          for (final edge in ['left', 'right'])
            edge: tester.getRect(button('lock', edge)),
        };
        expect(find.byTooltip('锁定屏幕'), findsNWidgets(2));
        expect(find.byIcon(Icons.lock_outline_rounded), findsNWidgets(2));
        expect(positions['left']!.left, 44);
        expect(positions['right']!.right, 880);
        expect(positions['left']!.center.dy, 244);
        expect(positions['right']!.center.dy, 244);
        await tester.tap(button('lock', side));
        await tester.pump();
        expect(handle.session.locked, isTrue);
        expect(find.byTooltip('锁定屏幕'), findsNothing);
        for (final edge in ['left', 'right']) {
          expect(tester.getRect(button('unlock', edge)), positions[edge]);
          expect(button('unlock', edge).hitTestable(), findsOneWidget);
        }
        await tester.tap(button('unlock', side));
        await tester.pump();
        expect(handle.session.locked, isFalse);
        expect(find.byTooltip('解锁屏幕'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        handle.dispose();
        await tester.pump();
      });
    }
  }

  testWidgets('锁入口跟随菜单自动隐藏，退场立即禁用点击焦点与读屏', (tester) async {
    final semantics = tester.ensureSemantics();
    final handle = await mountSurface(tester);
    final left = tester.getCenter(button('lock', 'left'));
    final right = tester.getCenter(button('lock', 'right'));
    await handle.session.player.play();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    for (final edge in ['left', 'right']) {
      expect(button('lock', edge).hitTestable(), findsNothing);
      final focus = find.ancestor(
        of: button('lock', edge),
        matching: find.byType(ExcludeFocus),
      );
      expect(
        tester.widgetList<ExcludeFocus>(focus).any((w) => w.excluding),
        isTrue,
      );
    }
    expect(find.bySemanticsLabel('锁定屏幕'), findsNothing);
    await tester.tapAt(left);
    await tester.tapAt(right);
    await tester.pump();
    expect(handle.session.locked, isFalse);
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byTooltip('锁定屏幕'), findsNothing);
    await tester.tapAt(const Offset(450, 250));
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byTooltip('锁定屏幕'), findsNWidgets(2));
    // 单击收起/唤回菜单也必须同步两侧入口，而不留下透明点击区。
    await tester.tapAt(const Offset(450, 250));
    await tester.pump(const Duration(milliseconds: 301));
    expect(button('lock', 'left').hitTestable(), findsNothing);
    expect(button('lock', 'right').hitTestable(), findsNothing);
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tapAt(const Offset(450, 250));
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byTooltip('锁定屏幕'), findsNWidgets(2));
    await tester.tap(button('lock', 'left'));
    await tester.pump();
    expect(find.byTooltip('锁定屏幕'), findsNothing);
    expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
    expect(tester.getCenter(button('unlock', 'left')), left);
    expect(tester.getCenter(button('unlock', 'right')), right);
    expect(handle.session.player.state.playing, isTrue);
    await tester.pump(const Duration(seconds: 3));
    expect(button('unlock', 'left').hitTestable(), findsNothing);
    expect(button('unlock', 'right').hitTestable(), findsNothing);
    expect(find.bySemanticsLabel('解锁屏幕'), findsNothing);
    // 在旧坐标第一次触摸只能唤回按钮，不能从不可见状态直接解锁。
    await tester.tapAt(right);
    await tester.pump();
    expect(handle.session.locked, isTrue);
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tap(button('unlock', 'right'));
    await tester.pump();
    expect(handle.session.locked, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    handle.dispose();
    await tester.pump();
    semantics.dispose();
  });

  for (final scenario in [
    (
      name: '竖屏全屏',
      size: const Size(700, 1000),
      touch: true,
      full: true,
      lock: true,
      form: FormFactor.phone,
    ),
    (
      name: '横屏非全屏',
      size: const Size(900, 500),
      touch: true,
      full: false,
      lock: false,
      form: FormFactor.pad,
    ),
    (
      name: '桌面',
      size: const Size(1000, 600),
      touch: false,
      full: true,
      lock: false,
      form: FormFactor.window,
    ),
    (
      name: '电视',
      size: const Size(1200, 700),
      touch: false,
      full: true,
      lock: false,
      form: FormFactor.television,
    ),
  ]) {
    testWidgets('${scenario.name} 保持原入口，不新增两侧锁', (tester) async {
      final handle = await mountSurface(
        tester,
        size: scenario.size,
        form: scenario.form,
        touch: scenario.touch,
        fullscreen: scenario.full,
        supportsLock: scenario.lock,
      );
      expect(find.byType(PlayerLockControls), findsNothing);
      expect(
        find.byIcon(Icons.lock_outline_rounded),
        scenario.lock ? findsOneWidget : findsNothing,
      );
      if (scenario.lock) {
        final icon = find.byIcon(Icons.lock_outline_rounded);
        expect(
          tester.getCenter(icon).dy,
          greaterThan(scenario.size.height - 60),
        );
        await tester.tap(icon);
        await tester.pump();
        expect(handle.session.locked, isTrue);
        expect(find.byTooltip('解锁屏幕'), findsNWidgets(2));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      handle.dispose();
      await tester.pump();
    });
  }
}

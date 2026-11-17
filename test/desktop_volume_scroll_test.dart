import 'package:duanju_app/ui/player/desktop_volume_scroll.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void desktopTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Future<void> wheel(
    WidgetTester tester, {
    Offset position = const Offset(100, 100),
    Offset delta = const Offset(0, -120),
    PointerDeviceKind kind = PointerDeviceKind.mouse,
  }) async {
    tester.binding.handlePointerEvent(
      PointerScrollEvent(position: position, scrollDelta: delta, kind: kind),
    );
    await tester.pump();
  }

  Widget surface({
    required double Function() read,
    required ValueChanged<double> change,
    bool enabled = true,
    bool locked = false,
    Widget child = const ColoredBox(color: Colors.black),
  }) => DesktopVolumeScroll(
    readVolume: read,
    onVolumeChanged: change,
    enabled: enabled,
    locked: locked,
    child: child,
  );

  desktopTest('鼠标每档正负5，不按像素倍增，范围限制0到100', (tester) async {
    var volume = 50.0;
    await tester.pumpWidget(
      MaterialApp(
        home: surface(read: () => volume, change: (value) => volume = value),
      ),
    );
    await wheel(tester);
    expect(volume, 55);
    await wheel(tester, delta: const Offset(0, -1));
    expect(volume, 60);
    await wheel(tester, delta: const Offset(0, 500));
    expect(volume, 55);
    volume = 98;
    await wheel(tester);
    expect(volume, 100);
    await wheel(tester);
    expect(volume, 100);
    volume = 2;
    await wheel(tester, delta: const Offset(0, 120));
    expect(volume, 0);
    await wheel(tester, delta: const Offset(0, 120));
    expect(volume, 0);
  });

  desktopTest('水平滚动、触摸、触控板和触笔不处理', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: surface(read: () => 50, change: (_) => calls++),
      ),
    );
    await wheel(tester, delta: const Offset(120, 0));
    await wheel(tester, delta: Offset.zero);
    for (final kind in [
      PointerDeviceKind.touch,
      PointerDeviceKind.trackpad,
      PointerDeviceKind.stylus,
    ]) {
      await wheel(tester, kind: kind);
    }
    expect(calls, 0);
  });

  desktopTest('关闭输入、锁屏和移动平台不处理', (tester) async {
    var calls = 0;
    Future<void> mount({bool enabled = true, bool locked = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: surface(
              read: () => 50,
              change: (_) => calls++,
              enabled: enabled,
              locked: locked,
            ),
          ),
        );
    await mount(enabled: false);
    await wheel(tester);
    await mount(locked: true);
    await wheel(tester);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await mount();
    await wheel(tester);
    expect(calls, 0);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await mount();
    await wheel(tester);
    expect(calls, 1);
  });

  desktopTest('后台或失焦时不处理，恢复前台后生效', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: surface(read: () => 50, change: (_) => calls++),
      ),
    );
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await wheel(tester);
    }
    expect(calls, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await wheel(tester);
    expect(calls, 1);
  });

  desktopTest('透明新路由下旧画面不处理；返回后恢复', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: surface(read: () => 50, change: (_) => calls++),
      ),
    );
    navigator.currentState!.push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: null,
        pageBuilder: (_, _, _) => const IgnorePointer(child: SizedBox.expand()),
      ),
    );
    await tester.pumpAndSettle();
    await wheel(tester);
    expect(calls, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await wheel(tester);
    expect(calls, 1);
  });

  desktopTest('子列表先注册滚动，不被音量层抢走', (tester) async {
    var calls = 0;
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: surface(
          read: () => 50,
          change: (_) => calls++,
          child: ListView.builder(
            controller: controller,
            itemExtent: 80,
            itemCount: 50,
            itemBuilder: (_, index) => Text('$index'),
          ),
        ),
      ),
    );
    await wheel(tester, delta: const Offset(0, 120));
    expect(controller.offset, greaterThan(0));
    expect(calls, 0);
  });

  desktopTest('只有画面区域生效，不覆盖上层进度控件和旁边列表', (tester) async {
    var calls = 0;
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  surface(read: () => 50, change: (_) => calls++),
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 80,
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      child: SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 200,
              child: ListView.builder(
                controller: controller,
                itemCount: 50,
                itemExtent: 80,
                itemBuilder: (_, index) => Text('$index'),
              ),
            ),
          ],
        ),
      ),
    );
    await wheel(tester, position: const Offset(100, 550));
    await wheel(
      tester,
      position: const Offset(700, 100),
      delta: const Offset(0, 120),
    );
    expect(calls, 0);
    expect(controller.offset, greaterThan(0));
    await wheel(tester);
    expect(calls, 1);
  });
}

import 'package:duanju_app/ui/app_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _TrackedAnimation extends AnimationController {
  _TrackedAnimation(TickerProvider vsync)
    : super(
        vsync: vsync,
        duration: AppMotion.enter,
        reverseDuration: AppMotion.exit,
      );

  final listeners = <AnimationStatusListener>{};

  @override
  void addStatusListener(AnimationStatusListener listener) {
    listeners.add(listener);
    super.addStatusListener(listener);
  }

  @override
  void removeStatusListener(AnimationStatusListener listener) {
    listeners.remove(listener);
    super.removeStatusListener(listener);
  }
}

void main() {
  testWidgets('转场逐帧重建不累积监听，中途反向保持当前画面', (tester) async {
    final first = _TrackedAnimation(tester);
    final second = _TrackedAnimation(tester);
    PageRouteBuilder<void>? route;
    Widget frame(Animation<double> animation) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: Builder(
          builder: (context) {
            route ??= AppMotion.page(context, (_) => const SizedBox());
            return AnimatedBuilder(
              animation: animation,
              builder: (context, _) => route!.transitionsBuilder(
                context,
                animation,
                const AlwaysStoppedAnimation(0),
                const SizedBox(width: 100, height: 100),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpWidget(frame(first));
    final count = first.listeners.length;
    final curve = tester
        .widget<FadeTransition>(find.byType(FadeTransition))
        .opacity;
    first.forward();
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(first.listeners.length, count);
      expect(
        tester.widget<FadeTransition>(find.byType(FadeTransition)).opacity,
        same(curve),
      );
    }
    final before = curve.value;
    first.reverse();
    await tester.pump();
    expect(curve.value, closeTo(before, .0001));
    await tester.pump(const Duration(milliseconds: 20));
    expect(curve.value, lessThan(before));
    final reversed = curve.value;
    first.forward();
    await tester.pump();
    expect(curve.value, closeTo(reversed, .0001));
    await tester.pumpWidget(frame(second));
    expect(first.listeners, isEmpty);
    expect((curve as CurvedAnimation).isDisposed, isTrue);
    expect(second.listeners.length, count);
    await tester.pumpWidget(const SizedBox());
    expect(second.listeners, isEmpty);
    first.dispose();
    second.dispose();
  });

  testWidgets('真实路由进入未结束即可返回，重开及减少动画仍可用', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Scaffold()),
    );
    for (final reduced in [false, true]) {
      final route = AppMotion.page<void>(
        navigator.currentContext!,
        (_) => const Scaffold(body: Text('目标页面')),
      );
      if (reduced) {
        // 使用真正的减少动画上下文创建下一条路由。
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const Scaffold(),
          ),
        );
      }
      final target = reduced
          ? AppMotion.page<void>(
              navigator.currentState!.overlay!.context,
              (_) => const Scaffold(body: Text('目标页面')),
            )
          : route;
      navigator.currentState!.push(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      if (reduced) expect(target.transitionDuration, Duration.zero);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('目标页面'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}

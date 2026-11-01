import 'package:duanju_app/ui/widgets/smooth_scroll.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<BuildContext> mount(
    WidgetTester tester,
    ScrollController controller, {
    bool reduced = false,
    bool accessible = false,
  }) async {
    late BuildContext target;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            disableAnimations: reduced,
            accessibleNavigation: accessible,
          ),
          child: Builder(
            builder: (context) {
              target = context;
              return Scaffold(
                body: ListView(
                  controller: controller,
                  children: const [SizedBox(height: 12000)],
                ),
                floatingActionButton: FloatingActionButton(
                  onPressed: () =>
                      smoothScrollToTop(context, controller.position),
                  child: const Icon(Icons.arrow_upward),
                ),
              );
            },
          ),
        ),
      ),
    );
    return target;
  }

  for (final distance in [600.0, 6000.0]) {
    for (final accessible in [false, true]) {
      testWidgets('真实点击平滑回顶 distance=$distance accessible=$accessible', (
        tester,
      ) async {
        final controller = ScrollController();
        await mount(tester, controller, accessible: accessible);
        controller.jumpTo(distance);
        await tester.pump();
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pump();
        expect(controller.offset, distance);
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.offset, inExclusiveRange(distance * .8, distance));
        await tester.pump(const Duration(milliseconds: 200));
        expect(controller.offset, inExclusiveRange(0, distance));
        // 长距离仍有足够行程，不会在原来的 320/360ms 内突然结束。
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.offset, greaterThan(0));
        await tester.pumpAndSettle();
        expect(controller.offset, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('disableAnimations 即时回顶，优先于 accessibleNavigation', (
    tester,
  ) async {
    final controller = ScrollController();
    final context = await mount(
      tester,
      controller,
      reduced: true,
      accessible: true,
    );
    controller.jumpTo(6000);
    await smoothScrollToTop(context, controller.position);
    expect(controller.offset, 0);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('重复回顶完成 Future，手势自然取消且不被旧动画拉回', (tester) async {
    final controller = ScrollController();
    final context = await mount(tester, controller);
    controller.jumpTo(6000);
    final first = smoothScrollToTop(context, controller.position);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final second = smoothScrollToTop(context, controller.position);
    await first;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await second;
    final interrupted = controller.offset;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.offset, interrupted);
    expect(controller.offset, greaterThan(0));
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('动画中销毁完成 Future；过期 context 调用安全返回', (tester) async {
    final controller = ScrollController();
    final context = await mount(tester, controller);
    controller.jumpTo(6000);
    final position = controller.position;
    final result = smoothScrollToTop(context, position);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
    await result;
    await smoothScrollToTop(context, position);
    controller.dispose();
    expect(tester.takeException(), isNull);
  });
}

import 'package:duanju_app/ui/app_motion.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/widgets/sliver_content_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class MotionHeader extends SliverPersistentHeaderDelegate {
  @override
  double get minExtent => 40;
  @override
  double get maxExtent => 100;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => const ColoredBox(key: ValueKey('header-box'), color: Colors.blue);
  @override
  bool shouldRebuild(MotionHeader oldDelegate) => false;
}

void main() {
  final repository = FakeRepository();

  Widget frame({
    Object identity = 0,
    bool ready = true,
    bool reduced = false,
    bool accessible = false,
    bool enabled = true,
    bool television = false,
    ScrollController? controller,
    Widget? child,
    bool wrap = true,
  }) {
    final content =
        child ??
        const SliverToBoxAdapter(
          child: SizedBox(key: ValueKey('body'), height: 1200),
        );
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          disableAnimations: reduced,
          accessibleNavigation: accessible,
        ),
        child: AppScope(
          repository: repository,
          formFactor: television ? FormFactor.television : FormFactor.phone,
          child: TickerMode(
            enabled: enabled,
            child: CustomScrollView(
              controller: controller,
              slivers: [
                SliverPersistentHeader(
                  key: const ValueKey('header'),
                  pinned: true,
                  floating: true,
                  delegate: MotionHeader(),
                ),
                if (wrap)
                  SliverContentTransition(
                    identity: identity,
                    ready: ready,
                    child: content,
                  )
                else
                  content,
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double opacity(WidgetTester tester) => tester
      .widget<SliverFadeTransition>(find.byType(SliverFadeTransition))
      .opacity
      .value;

  testWidgets('initial content is still; only latest ready identity fades in', (
    tester,
  ) async {
    await tester.pumpWidget(frame());
    expect(opacity(tester), 1);
    await tester.pumpWidget(frame(identity: 1, ready: false));
    expect(opacity(tester), 1);
    await tester.pumpWidget(frame(identity: 1));
    expect(opacity(tester), closeTo(.55, .001));
    await tester.pump(const Duration(milliseconds: 50));
    expect(opacity(tester), inExclusiveRange(.55, 1));
    await tester.pumpWidget(frame(identity: 2, ready: false));
    expect(opacity(tester), 1);
    await tester.pumpWidget(frame(identity: 3));
    expect(opacity(tester), closeTo(.55, .001));
    expect(find.byKey(const ValueKey('body')), findsOneWidget);
    expect(find.byType(SliverFadeTransition), findsOneWidget);
    await tester.pump(AppMotion.state);
    expect(opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['reduced', 'accessible', 'hidden']) {
    testWidgets('$mode stops motion and does not replay on return', (
      tester,
    ) async {
      Widget suppressed(int identity) => frame(
        identity: identity,
        reduced: mode == 'reduced',
        accessible: mode == 'accessible',
        enabled: mode != 'hidden',
      );
      await tester.pumpWidget(frame());
      await tester.pumpWidget(frame(identity: 1));
      await tester.pump(const Duration(milliseconds: 40));
      expect(opacity(tester), lessThan(1));
      await tester.pumpWidget(suppressed(1));
      expect(opacity(tester), 1);
      await tester.pumpWidget(suppressed(2));
      expect(opacity(tester), 1);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(frame(identity: 2));
      expect(opacity(tester), 1);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('TV entry settles within the shared maximum', (tester) async {
    await tester.pumpWidget(frame(television: true));
    await tester.pumpWidget(frame(identity: 1, television: true));
    expect(opacity(tester), closeTo(.55, .001));
    await tester.pump(AppMotion.televisionMax);
    expect(opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('pagination preserves sliver state, scroll client and offset', (
    tester,
  ) async {
    final controller = ScrollController();
    final key = GlobalKey();
    Widget list(int count) => SliverMainAxisGroup(
      key: key,
      slivers: [
        SliverList.builder(
          itemCount: count,
          itemBuilder: (_, index) =>
              SizedBox(height: 70, child: Text('$index')),
        ),
      ],
    );
    await tester.pumpWidget(frame(controller: controller, child: list(30)));
    controller.jumpTo(140);
    await tester.pump();
    final element = key.currentContext;
    final oldExtent = controller.position.maxScrollExtent;
    await tester.pumpWidget(frame(controller: controller, child: list(40)));
    await tester.pump();
    expect(opacity(tester), 1);
    expect(key.currentContext, same(element));
    expect(controller.positions.length, 1);
    expect(controller.offset, 140);
    // 惰性列表的范围估计可能保留到下一次布局；滚向新增尾部确认其真实可达。
    controller.jumpTo(oldExtent + 700);
    await tester.pump();
    expect(controller.position.maxScrollExtent, greaterThan(oldExtent));
    expect(find.text('39'), findsOneWidget);
    controller.jumpTo(140);
    await tester.pump();
    await tester.pumpWidget(
      frame(identity: 1, controller: controller, child: list(40)),
    );
    expect(opacity(tester), closeTo(.55, .001));
    expect(key.currentContext, same(element));
    expect(controller.positions.length, 1);
    expect(controller.offset, 140);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('fade and grouping preserve header and fill-remaining geometry', (
    tester,
  ) async {
    final controller = ScrollController();
    const content = SliverFillRemaining(
      key: ValueKey('fill'),
      hasScrollBody: false,
      child: SizedBox(key: ValueKey('status'), height: 80),
    );
    await tester.pumpWidget(
      frame(controller: controller, child: content, wrap: false),
    );
    final statusRect = tester.getRect(find.byKey(const ValueKey('status')));
    final headerRect = tester.getRect(find.byKey(const ValueKey('header-box')));
    final geometry = tester
        .renderObject<RenderSliver>(find.byKey(const ValueKey('fill')))
        .geometry!;
    final extent = controller.position.maxScrollExtent;
    Widget grouped() => const SliverMainAxisGroup(slivers: [content]);
    await tester.pumpWidget(frame(controller: controller, child: grouped()));
    await tester.pumpWidget(
      frame(identity: 1, controller: controller, child: grouped()),
    );
    expect(opacity(tester), closeTo(.55, .001));
    expect(tester.getRect(find.byKey(const ValueKey('status'))), statusRect);
    expect(
      tester.getRect(find.byKey(const ValueKey('header-box'))),
      headerRect,
    );
    final animated = tester
        .renderObject<RenderSliver>(find.byKey(const ValueKey('fill')))
        .geometry!;
    expect(animated.scrollExtent, geometry.scrollExtent);
    expect(animated.paintExtent, geometry.paintExtent);
    expect(controller.position.maxScrollExtent, extent);
    await tester.pump(AppMotion.state);
    expect(tester.getRect(find.byKey(const ValueKey('status'))), statusRect);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    expect(tester.takeException(), isNull);
  });
}

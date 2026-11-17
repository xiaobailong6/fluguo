import 'package:duanju_app/ui/widgets/local_content_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget frame({
    required int index,
    bool ready = true,
    bool reduced = false,
    bool enabled = true,
    bool animateOnMount = false,
    Offset travel = const Offset(18, 0),
    TextDirection direction = TextDirection.ltr,
    Widget? child,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Directionality(
        textDirection: direction,
        child: TickerMode(
          enabled: enabled,
          child: LocalContentTransition(
            identity: (index, ready),
            index: index,
            ready: ready,
            animateOnMount: animateOnMount,
            travel: travel,
            child:
                child ??
                const SizedBox(key: ValueKey('body'), width: 100, height: 100),
          ),
        ),
      ),
    ),
  );

  Offset translation(WidgetTester tester) {
    final transform = tester.widget<Transform>(
      find.descendant(
        of: find.byType(LocalContentTransition),
        matching: find.byType(Transform),
      ),
    );
    return Offset(
      transform.transform.entry(0, 3),
      transform.transform.entry(1, 3),
    );
  }

  testWidgets(
    'switches animate one existing tree and settle after fast reversals',
    (tester) async {
      await tester.pumpWidget(frame(index: 0));
      expect(translation(tester), Offset.zero);
      await tester.pumpWidget(frame(index: 1));
      expect(translation(tester).dx, greaterThan(0));
      expect(find.byKey(const ValueKey('body')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 60));
      expect(translation(tester).dx, inExclusiveRange(0, 18));
      await tester.pumpWidget(frame(index: 0));
      expect(translation(tester).dx, lessThan(0));
      await tester.pumpAndSettle();
      expect(translation(tester), Offset.zero);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'loading stays readable, ready content enters, reduced motion stops',
    (tester) async {
      await tester.pumpWidget(frame(index: 0));
      await tester.pumpWidget(frame(index: 1, ready: false));
      expect(translation(tester), Offset.zero);
      await tester.pumpWidget(frame(index: 1));
      expect(translation(tester).dx, greaterThan(0));
      await tester.pumpWidget(frame(index: 1, reduced: true));
      expect(translation(tester), Offset.zero);
      await tester.pumpWidget(frame(index: 2, reduced: true));
      expect(translation(tester), Offset.zero);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'RTL reverses travel and hidden content does not keep animating',
    (tester) async {
      await tester.pumpWidget(frame(index: 0, direction: TextDirection.rtl));
      await tester.pumpWidget(frame(index: 1, direction: TextDirection.rtl));
      expect(translation(tester).dx, lessThan(0));
      await tester.pumpWidget(frame(index: 1, enabled: false));
      expect(translation(tester), Offset.zero);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('does not duplicate scroll clients or reset child state', (
    tester,
  ) async {
    final scroll = ScrollController();
    final key = GlobalKey();
    Widget list() => ListView(
      key: key,
      controller: scroll,
      children: List.generate(
        30,
        (i) => SizedBox(height: 70, child: Text('$i')),
      ),
    );
    await tester.pumpWidget(frame(index: 0, child: list()));
    scroll.jumpTo(140);
    final element = key.currentContext;
    await tester.pumpWidget(frame(index: 1, child: list()));
    expect(scroll.positions.length, 1);
    expect(scroll.offset, 140);
    expect(key.currentContext, same(element));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('newly mounted content enters once and respects reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(frame(index: 0, animateOnMount: true));
    expect(translation(tester).dx, greaterThan(0));
    await tester.pumpAndSettle();
    await tester.pumpWidget(frame(index: 0, animateOnMount: true));
    expect(translation(tester), Offset.zero);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      frame(index: 0, animateOnMount: true, reduced: true),
    );
    expect(translation(tester), Offset.zero);
    expect(tester.binding.transientCallbackCount, 0);
  });
  testWidgets('popup travel is vertical and unchanged by RTL', (tester) async {
    await tester.pumpWidget(frame(index: 0, travel: const Offset(0, 8)));
    await tester.pumpWidget(
      frame(index: 1, travel: const Offset(0, 8), direction: TextDirection.rtl),
    );
    expect(translation(tester).dx, 0);
    expect(translation(tester).dy, greaterThan(0));
    await tester.pumpAndSettle();
    expect(translation(tester), Offset.zero);
  });
}

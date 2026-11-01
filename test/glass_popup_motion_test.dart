import 'package:duanju_app/ui/app_motion.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'support/fakes.dart';
import 'package:duanju_app/ui/widgets/choice_panel.dart';
import 'package:duanju_app/ui/widgets/glass/glass_popup_transition.dart';
import 'package:duanju_app/ui/widgets/glass/glass_selector.dart';
import 'package:duanju_app/ui/player/playback_sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final reduced in [false, true]) {
    for (final rtl in [false, true]) {
      testWidgets('selector above bottom trigger rtl=$rtl reduced=$reduced', (
        tester,
      ) async {
        late BuildContext anchor;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(accessibleNavigation: reduced),
              child: Directionality(
                textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                child: AppScope(
                  repository: FakeRepository(),
                  formFactor: FormFactor.phone,
                  child: child!,
                ),
              ),
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomRight,
                child: Builder(
                  builder: (context) {
                    anchor = context;
                    return const SizedBox(width: 60, height: 40);
                  },
                ),
              ),
            ),
          ),
        );
        final result = showGlassSelector<int>(
          anchor: anchor,
          menuKey: const ValueKey('menu'),
          selected: 1,
          options: const [ChoiceOption(1, 'one'), ChoiceOption(2, 'two')],
        );
        await tester.pump();
        final route = ModalRoute.of(tester.element(find.text('one')))!;
        expect(
          route.transitionDuration,
          reduced ? Duration.zero : AppMotion.enter,
        );
        expect(
          route.reverseTransitionDuration,
          reduced ? Duration.zero : AppMotion.exit,
        );
        if (!reduced) {
          await tester.pump(const Duration(milliseconds: 120));
          final transition = find.byType(GlassPopupTransition);
          final scale = tester
              .widgetList<Transform>(
                find.descendant(
                  of: transition,
                  matching: find.byType(Transform),
                ),
              )
              .where((t) => t.transform.storage[0] != 1)
              .first;
          expect(scale.transform.storage[0], inInclusiveRange(.96, 1));
        }
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byKey(const ValueKey('menu')));
        final trigger = anchor.findRenderObject()! as RenderBox;
        expect(
          rect.bottom,
          lessThanOrEqualTo(trigger.localToGlobal(Offset.zero).dy - 6),
        );
        expect(rect.left, greaterThanOrEqualTo(16));
        expect(rect.right, lessThanOrEqualTo(784));
        await tester.tap(find.text('two'));
        await tester.pumpAndSettle();
        expect(await result, 2);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('player panel remains opaque and barrier dismissible', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold();
          },
        ),
      ),
    );
    final closed = showPlayerPanel(
      context,
      (_) => const SizedBox(height: 120, child: Text('settings')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('settings'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await closed;
    expect(find.text('settings'), findsNothing);
  });

  testWidgets('弹层途中反向和重开保持连续映射', (tester) async {
    final animation = AnimationController(
      vsync: tester,
      duration: AppMotion.enter,
      reverseDuration: AppMotion.exit,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: GlassPopupTransition(
          animation: animation,
          child: const SizedBox(width: 120, height: 60),
        ),
      ),
    );
    animation.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final before = tester.widget<Opacity>(find.byType(Opacity)).opacity;
    animation.reverse();
    await tester.pump();
    expect(
      tester.widget<Opacity>(find.byType(Opacity)).opacity,
      closeTo(before, .001),
    );
    await tester.pump(const Duration(milliseconds: 20));
    final reverse = tester.widget<Opacity>(find.byType(Opacity)).opacity;
    animation.forward();
    await tester.pump();
    expect(
      tester.widget<Opacity>(find.byType(Opacity)).opacity,
      closeTo(reverse, .001),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    animation.dispose();
    expect(tester.takeException(), isNull);
  });
}

import 'package:duanju_app/ui/widgets/control_presence.dart';
import 'package:duanju_app/ui/widgets/state_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/ui/widgets/follow_button.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'support/fakes.dart';

Widget _frame(
  Widget child, {
  bool reduced = false,
  bool hidden = false,
  bool accessible = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      disableAnimations: reduced,
      accessibleNavigation: accessible,
    ),
    child: TickerMode(
      enabled: !hidden,
      child: AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.phone,
        child: Center(child: child),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'icon change animates latest state without replacing button or its layout',
    (tester) async {
      final focus = FocusNode();
      final key = GlobalKey();
      var taps = 0;
      Widget button(IconData icon) => IconButton(
        key: key,
        focusNode: focus,
        onPressed: () => taps++,
        icon: StateIcon(icon, size: 24, color: Colors.red),
      );
      await tester.pumpWidget(_frame(button(Icons.play_arrow_rounded)));
      focus.requestFocus();
      await tester.pump();
      final element = key.currentContext;
      final rect = tester.getRect(find.byKey(key));
      await tester.pumpWidget(_frame(button(Icons.pause_rounded)));
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(key.currentContext, same(element));
      expect(focus.hasFocus, isTrue);
      expect(tester.getRect(find.byKey(key)), rect);
      final transform = find.descendant(
        of: find.byType(StateIcon),
        matching: find.byType(Transform),
      );
      expect(
        tester.widget<Transform>(transform).transform.entry(0, 0),
        lessThan(1),
      );
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpWidget(_frame(button(Icons.play_arrow_rounded)));
      expect(find.byType(Icon), findsOneWidget);
      await tester.tap(find.byKey(key));
      expect(taps, 1);
      await tester.pumpAndSettle();
      expect(tester.widget<Transform>(transform).transform.entry(0, 0), 1);
      expect(tester.widget<Icon>(find.byType(Icon)).color, Colors.red);
      await tester.pumpWidget(const SizedBox());
      focus.dispose();
    },
  );

  for (final mode in ['reduced', 'accessible', 'hidden']) {
    testWidgets('$mode settles animations immediately without a stale icon', (
      tester,
    ) async {
      Widget frame(IconData icon) => _frame(
        StateIcon(icon),
        reduced: mode == 'reduced',
        accessible: mode == 'accessible',
        hidden: mode == 'hidden',
      );
      await tester.pumpWidget(frame(Icons.play_arrow_rounded));
      await tester.pumpWidget(frame(Icons.pause_rounded));
      final transform = find.descendant(
        of: find.byType(StateIcon),
        matching: find.byType(Transform),
      );
      expect(tester.widget<Transform>(transform).transform.entry(0, 0), 1);
      expect(tester.binding.transientCallbackCount, 0);
    });
  }

  testWidgets(
    'control fade blocks input focus and semantics before the exit finishes',
    (tester) async {
      final key = GlobalKey();
      final focus = FocusNode();
      var taps = 0;
      final semantics = tester.ensureSemantics();
      Widget frame(bool visible) => _frame(
        ControlPresence(
          visible: visible,
          child: TextButton(
            key: key,
            focusNode: focus,
            onPressed: () => taps++,
            child: const Text('control'),
          ),
        ),
      );
      await tester.pumpWidget(frame(true));
      focus.requestFocus();
      await tester.pump();
      final element = key.currentContext;
      final center = tester.getCenter(find.byKey(key));
      await tester.pumpWidget(frame(false));
      expect(focus.hasFocus, isFalse);
      expect(
        tester
            .binding
            .renderViews
            .single
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!
            .toStringDeep(),
        isNot(contains('control')),
      );
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 60));
      expect(taps, 0);
      final opacity = find.descendant(
        of: find.byType(ControlPresence),
        matching: find.byType(Opacity),
      );
      expect(tester.widget<Opacity>(opacity).opacity, inExclusiveRange(0, 1));
      await tester.pumpWidget(frame(true));
      expect(key.currentContext, same(element));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(key));
      expect(taps, 1);
      await tester.pumpWidget(frame(false));
      await tester.pumpAndSettle();
      expect(find.byKey(key), findsNothing);
      expect(key.currentContext, same(element));
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
      focus.dispose();
    },
  );

  testWidgets('reduced and hidden controls settle with no lingering ticker', (
    tester,
  ) async {
    Widget frame(bool visible, {bool reduced = false, bool hidden = false}) =>
        _frame(
          ControlPresence(
            visible: visible,
            child: const SizedBox(
              key: ValueKey('control'),
              width: 40,
              height: 40,
            ),
          ),
          reduced: reduced,
          hidden: hidden,
        );
    await tester.pumpWidget(frame(true));
    await tester.pumpWidget(frame(false));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(frame(false, reduced: true));
    expect(find.byKey(const ValueKey('control')), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(frame(true, hidden: true));
    expect(find.byKey(const ValueKey('control')), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });
  testWidgets(
    'follow feedback keeps button size focus and immediate latest label',
    (tester) async {
      final store = await openStore();
      final item = drama('motion-follow');
      final focus = FocusNode();
      await tester.pumpWidget(
        _frame(FollowPill(store: store, drama: item, focusNode: focus)),
      );
      final button = find.byKey(const ValueKey('follow-toggle'));
      focus.requestFocus();
      await tester.pump();
      final rect = tester.getRect(button);
      await store.toggleFavorite(item);
      await tester.pump();
      expect(find.byIcon(Icons.bookmark_rounded), findsOneWidget);
      // 原按钮用一份不可见文字固定宽度，另一份显示当前状态。
      expect(find.text('已追剧'), findsNWidgets(2));
      expect(focus.hasFocus, isTrue);
      expect(tester.getRect(button), rect);
      await store.toggleFavorite(item);
      await tester.pump();
      expect(find.byIcon(Icons.bookmark_border_rounded), findsOneWidget);
      expect(find.text('追剧'), findsOneWidget);
      expect(tester.getRect(button), rect);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      focus.dispose();
    },
  );
}

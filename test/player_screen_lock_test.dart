import 'package:duanju_app/ui/player/player_screen_lock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'lock blocks gestures, wheel, focus and semantics without replacing child',
    (tester) async {
      final locked = ValueNotifier(false);
      final focus = FocusNode();
      final childKey = GlobalKey();
      var inputs = 0;
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: locked,
            child: Focus(
              focusNode: focus,
              autofocus: true,
              onKeyEvent: (_, _) {
                inputs++;
                return KeyEventResult.handled;
              },
              child: Listener(
                onPointerSignal: (_) => inputs++,
                child: GestureDetector(
                  key: childKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: () => inputs++,
                  onDoubleTap: () => inputs++,
                  onLongPress: () => inputs++,
                  onPanUpdate: (_) => inputs++,
                  child: Semantics(
                    label: 'player controls',
                    child: const ColoredBox(color: Colors.black),
                  ),
                ),
              ),
            ),
            builder: (_, value, child) => PlayerScreenLock(
              locked: value,
              onUnlock: () => locked.value = false,
              child: child!,
            ),
          ),
        ),
      );
      await tester.pump();
      final original = childKey.currentContext;
      expect(focus.hasFocus, isTrue);
      locked.value = true;
      await tester.pump();
      await tester.pump();
      expect(childKey.currentContext, same(original));
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
        isNot(contains('player controls')),
      );
      final center = tester.getCenter(find.byType(PlayerScreenLock));
      await tester.tapAt(center);
      await tester.tapAt(center);
      await tester.longPressAt(center);
      await tester.dragFrom(center, const Offset(180, 0));
      await tester.dragFrom(center, const Offset(0, -180));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 50)),
      );
      for (final key in [
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.mediaPlayPause,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.f11,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.pump();
      expect(inputs, 0);
      await tester.tap(find.byKey(const ValueKey('player-unlock-right')));
      await tester.pump();
      expect(locked.value, isFalse);
      expect(childKey.currentContext, same(original));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 350));
      expect(inputs, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
      focus.dispose();
      locked.dispose();
    },
  );

  testWidgets(
    'back reveals unlock instead of popping; affordances hide after three seconds',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final locked = ValueNotifier(true);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('home')),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ValueListenableBuilder<bool>(
            valueListenable: locked,
            builder: (_, value, _) => PlayerScreenLock(
              locked: value,
              onUnlock: () => locked.value = false,
              child: const Scaffold(body: Text('video')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('解锁屏幕'), findsNWidgets(2));
      await tester.pump(const Duration(seconds: 3));
      expect(find.byTooltip('解锁屏幕'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('video'), findsOneWidget);
      expect(find.byTooltip('解锁屏幕'), findsNWidgets(2));
      await tester.pump(const Duration(seconds: 3));
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      expect(find.byTooltip('解锁屏幕'), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('player-unlock-left')));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      locked.dispose();
    },
  );

  testWidgets('keyboard can focus and activate unlock but not the player', (
    tester,
  ) async {
    final locked = ValueNotifier(true);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: locked,
          builder: (_, value, _) => PlayerScreenLock(
            locked: value,
            onUnlock: () => locked.value = false,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(locked.value, isFalse);
    await tester.pumpWidget(const SizedBox());
    locked.dispose();
  });
}

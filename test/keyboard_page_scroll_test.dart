import 'package:duanju_app/ui/widgets/keyboard_page_scroll.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Page keys target focused pane, clamp and leave TV alone', (
    tester,
  ) async {
    final left = ScrollController(), right = ScrollController();
    final focus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  controller: left,
                  children: [
                    Focus(
                      focusNode: focus,
                      child: const SizedBox(height: 2400),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: right,
                  children: const [SizedBox(height: 2400)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    const down = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.pageDown,
      logicalKey: LogicalKeyboardKey.pageDown,
      timeStamp: Duration.zero,
    );
    expect(keyboardPageScroll(down, television: true), KeyEventResult.ignored);
    expect(keyboardPageScroll(down, television: false), KeyEventResult.handled);
    expect(left.offset, closeTo(.8 * left.position.viewportDimension, .01));
    expect(right.offset, 0);
    const up = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.pageUp,
      logicalKey: LogicalKeyboardKey.pageUp,
      timeStamp: Duration.zero,
    );
    expect(keyboardPageScroll(up, television: false), KeyEventResult.handled);
    expect(left.offset, 0);
    for (var i = 0; i < 10; i++) {
      keyboardPageScroll(down, television: false);
    }
    expect(left.offset, left.position.maxScrollExtent);
    await tester.pumpWidget(const SizedBox());
    focus.dispose();
    left.dispose();
    right.dispose();
  });
  testWidgets('PageDown is not intercepted while editing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(children: const [TextField(), SizedBox(height: 2400)]),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    const down = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.pageDown,
      logicalKey: LogicalKeyboardKey.pageDown,
      timeStamp: Duration.zero,
    );
    expect(keyboardPageScroll(down, television: false), KeyEventResult.ignored);
  });
}

import 'package:duanju_app/ui/live/live_control_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('亮背景上线路和画质胶囊有底色描边、点击与禁用状态', (tester) async {
    var lines = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: SizedBox(
              width: 240,
              child: Row(
                children: [
                  LiveControlPill(label: '线路', onPressed: () => lines++),
                  const Flexible(
                    child: LiveControlPill(
                      label: '超高清原画画质超长名称',
                      onPressed: null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '线路'),
    );
    expect(button.style!.backgroundColor!.resolve({})!.a, greaterThan(.7));
    expect(button.style!.side!.resolve({})!.color.a, greaterThan(.3));
    expect(button.style!.shape!.resolve({}), isA<StadiumBorder>());
    await tester.tap(find.text('线路'));
    expect(lines, 1);
    final disabled = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '超高清原画画质超长名称'),
    );
    expect(disabled.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

import 'package:duanju_app/ui/player/wide_video_fullscreen_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('仅已确认横屏视频显示全屏入口，回调可用且大字体无溢出', (tester) async {
    var entries = 0;
    for (final value in [
      (false, 16 / 9),
      (true, 9 / 16),
      (true, 1.0),
      (true, 16 / 9),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Center(
                child: WideVideoFullscreenButton(
                  aspectKnown: value.$1,
                  aspectRatio: value.$2,
                  onPressed: () => entries++,
                ),
              ),
            ),
          ),
        ),
      );
      final button = find.byKey(const ValueKey('wide-video-fullscreen'));
      if (value.$1 && value.$2 > 1) {
        expect(button, findsOneWidget);
        await tester.tap(button);
      } else {
        expect(button, findsNothing);
      }
      expect(tester.takeException(), isNull);
    }
    expect(entries, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

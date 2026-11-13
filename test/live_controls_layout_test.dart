import 'package:duanju_app/ui/live/live_playback_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final full in [false, true]) {
    for (final width in [320.0, 1200.0]) {
      testWidgets('直播按钮贴右下且长画质无溢出 full=$full width=$width', (tester) async {
        tester.view.physicalSize = Size(width, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var lines = 0;
        var qualities = 0;
        for (final scale in [1.0, 2.0]) {
          for (final quality in ['原画', '超高清原画非常长的清晰度名称']) {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  backgroundColor: Colors.black,
                  body: MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 600),
                      textScaler: TextScaler.linear(scale),
                    ),
                    child: Stack(
                      children: [
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8,
                          child: LivePlaybackControls(
                            playing: true,
                            full: full,
                            middle: full ? null : const Text('0 KB/S'),
                            quality: quality,
                            showLine: true,
                            showMini: true,
                            onTogglePlayback: () {},
                            onLine: () => lines++,
                            onQuality: () => qualities++,
                            onMini: () {},
                            onFullscreen: () {},
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final group = tester.getRect(
              find.byKey(const ValueKey('live-right-controls')),
            );
            final line = tester.getRect(
              find.byKey(const ValueKey('live-line-control')),
            );
            final qualityRect = tester.getRect(
              find.byKey(const ValueKey('live-quality-control')),
            );
            final mini = tester.getRect(
              find.byKey(const ValueKey('live-mini-control')),
            );
            final fullButton = tester.getRect(
              find.byKey(const ValueKey('live-fullscreen-control')),
            );
            expect(group.right, closeTo(width - 8, .01));
            expect(fullButton.right, closeTo(width - 8, .01));
            expect(group.bottom, closeTo(592, .01));
            expect(fullButton.center.dy, closeTo(group.center.dy, .01));
            expect(mini.left - qualityRect.right, lessThanOrEqualTo(1));
            expect(qualityRect.left - line.right, lessThanOrEqualTo(1));
            if (width > 600 && quality == '原画') {
              expect(line.left, greaterThan(width * .65));
            }
            expect(tester.takeException(), isNull);
            await tester.tap(find.byKey(const ValueKey('live-line-control')));
            await tester.tap(
              find.byKey(const ValueKey('live-quality-control')),
            );
          }
        }
        expect(lines, 4);
        expect(qualities, 4);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}

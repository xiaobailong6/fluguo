import 'package:duanju_app/ui/live/live_player_gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('单击全屏只唤出菜单，双击只切换播放，不双重触发', (tester) async {
    var plays = 0;
    var menus = 0;
    var restored = 0;
    Future<void> mount({required bool full, bool mini = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: LivePlayerGestures(
              full: full,
              mini: mini,
              controlsVisible: false,
              onTogglePlayback: () => plays++,
              onToggleControls: () => menus++,
              onRestoreMini: () => restored++,
              onDragMini: () {},
              onToggleFull: () {},
              onBack: () {},
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        );
    await mount(full: false);
    final video = find.byKey(const ValueKey('live-video-gestures'));
    await tester.tap(video);
    await tester.pump(const Duration(milliseconds: 350));
    expect(plays, 0);
    expect(menus, 0);
    await mount(full: true);
    await tester.tap(video);
    await tester.pump(const Duration(milliseconds: 350));
    expect(menus, 1);
    await tester.tap(video);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(video);
    await tester.pump(const Duration(milliseconds: 350));
    expect(plays, 1);
    expect(menus, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(menus, 2);
    await mount(full: false, mini: true);
    await tester.tap(video);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(video);
    await tester.pump(const Duration(milliseconds: 350));
    expect(restored, 1);
    expect(plays, 1);
  });
}

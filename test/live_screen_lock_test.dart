import 'package:duanju_app/ui/live/live_playback_controls.dart';
import 'package:duanju_app/ui/live/live_player_gestures.dart';
import 'package:duanju_app/ui/live/live_screen_lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('全屏左中小锁锁定所有画面与按钮，只有解锁后恢复', (tester) async {
    var locked = false;
    var full = true;
    final actions = <String>[];
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (_, setState) {
            rebuild = setState;
            return Scaffold(
              body: LiveScreenLock(
                enabled: full,
                locked: locked,
                onToggle: () => setState(() => locked = !locked),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    LivePlayerGestures(
                      full: full,
                      mini: false,
                      controlsVisible: false,
                      onTogglePlayback: () => actions.add('play'),
                      onToggleControls: () => actions.add('menu'),
                      onRestoreMini: () => actions.add('restore'),
                      onDragMini: () => actions.add('drag'),
                      onToggleFull: () => actions.add('full'),
                      onBack: () => actions.add('back'),
                      child: const ColoredBox(color: Colors.black),
                    ),
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
                      child: LivePlaybackControls(
                        playing: true,
                        full: full,
                        quality: '原画',
                        showLine: true,
                        showMini: true,
                        onTogglePlayback: () => actions.add('play'),
                        onLine: () => actions.add('line'),
                        onQuality: () => actions.add('quality'),
                        onMini: () => actions.add('mini'),
                        onFullscreen: () => actions.add('full'),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: TextButton(
                        onPressed: () => actions.add('back'),
                        child: const Text('返回'),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: TextButton(
                        onPressed: () => actions.add('retry'),
                        child: const Text('重试'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final lock = find.byKey(const ValueKey('live-screen-lock'));
    final position = tester.getCenter(lock);
    expect(position.dy, closeTo(300, 1));
    expect(position.dx, lessThan(50));
    await tester.tap(lock);
    await tester.pumpAndSettle();
    expect(locked, isTrue);
    expect(find.byTooltip('解锁屏幕'), findsOneWidget);
    for (final key in [
      'live-playback-toggle',
      'live-line-control',
      'live-quality-control',
      'live-mini-control',
      'live-fullscreen-control',
    ]) {
      await tester.tapAt(tester.getCenter(find.byKey(ValueKey(key))));
    }
    await tester.tapAt(tester.getCenter(find.text('返回')));
    await tester.tapAt(tester.getCenter(find.text('重试')));
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.dragFrom(const Offset(400, 300), const Offset(100, 100));
    for (final key in [
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.goBack,
      LogicalKeyboardKey.mediaPlayPause,
      LogicalKeyboardKey.f11,
      LogicalKeyboardKey.arrowDown,
    ]) {
      await tester.sendKeyEvent(
        key,
        physicalKey: key == LogicalKeyboardKey.goBack
            ? PhysicalKeyboardKey.escape
            : null,
      );
    }
    expect(actions, isEmpty);
    expect(locked, isTrue);
    await tester.tap(lock);
    await tester.pumpAndSettle();
    expect(locked, isFalse);
    for (final key in [
      'live-playback-toggle',
      'live-line-control',
      'live-quality-control',
      'live-mini-control',
      'live-fullscreen-control',
    ]) {
      await tester.tap(find.byKey(ValueKey(key)));
    }
    await tester.tap(find.text('返回'));
    await tester.tap(find.text('重试'));
    expect(actions, [
      'play',
      'line',
      'quality',
      'mini',
      'full',
      'back',
      'retry',
    ]);
    rebuild(() => full = false);
    await tester.pumpAndSettle();
    expect(lock, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('锁定隔离键盘焦点，确认小锁可解锁，禁用全屏遮罩后恢复输入', (tester) async {
    var locked = true;
    var enabled = true;
    var plays = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (_, setState) {
            rebuild = setState;
            return Scaffold(
              body: LiveScreenLock(
                enabled: enabled,
                locked: locked,
                onToggle: () => setState(() => locked = !locked),
                child: LivePlayerGestures(
                  full: true,
                  mini: false,
                  controlsVisible: false,
                  onTogglePlayback: () => plays++,
                  onToggleControls: () {},
                  onRestoreMini: () {},
                  onDragMini: () {},
                  onToggleFull: () {},
                  onBack: () {},
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    expect(plays, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(locked, isFalse);
    rebuild(() {
      locked = true;
      enabled = false;
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('live-screen-lock')), findsNothing);
    final point = tester.getCenter(
      find.byKey(const ValueKey('live-video-gestures')),
    );
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 350));
    expect(plays, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

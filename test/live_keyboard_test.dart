import 'package:duanju_app/live_player_policy.dart';
import 'package:duanju_app/ui/live/live_player_gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('直播缓存不关闭缓存本身；静音恢复上次音量', () {
    expect(liveNativeProperties, {'cache-pause': 'no', 'force-seekable': 'no'});
    final mute = LiveMuteState();
    expect(mute.toggle(40), 0);
    expect(mute.toggle(0), 40);
    expect(mute.toggle(65), 0);
    expect(mute.toggle(0), 65);
  });

  testWidgets('F/M/Space/Esc 保留原按键且忽略长按和组合键', (tester) async {
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: LivePlayerGestures(
          full: false,
          mini: false,
          controlsVisible: true,
          onTogglePlayback: () => actions.add('play'),
          onToggleFull: () => actions.add('full'),
          onToggleMute: () => actions.add('mute'),
          onBack: () => actions.add('back'),
          onToggleControls: () {},
          onRestoreMini: () {},
          onDragMini: () {},
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    for (final key in [
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.keyM,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.f11,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect(actions, ['full', 'mute', 'play', 'back', 'full']);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyM);
    expect(actions.where((e) => e == 'mute').length, 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(actions.where((e) => e == 'full').length, 2);
  });

  testWidgets('播控按钮持有焦点时仍能使用 M，不把按钮点击当成画面手势', (tester) async {
    final button = FocusNode();
    addTearDown(button.dispose);
    var muted = 0;
    var menus = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LivePlayerGestures(
            full: true,
            mini: false,
            controlsVisible: true,
            onTogglePlayback: () {},
            onToggleFull: () {},
            onBack: () {},
            onToggleMute: () => muted++,
            onToggleControls: () => menus++,
            onRestoreMini: () {},
            onDragMini: () {},
            surfaceBuilder: (_, video) => Column(
              children: [
                Expanded(child: video),
                TextButton(
                  focusNode: button,
                  onPressed: () {},
                  child: const Text('播控'),
                ),
              ],
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();
    button.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(muted, 1);
    await tester.tap(find.text('播控'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(menus, 0);
  });

  testWidgets('展示切换恢复空焦点，不抢文本输入或弹窗', (tester) async {
    final input = FocusNode();
    addTearDown(input.dispose);
    var full = false;
    var muted = 0;
    late StateSetter rebuild;
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            page = context;
            return Scaffold(
              body: LivePlayerGestures(
                full: full,
                mini: false,
                controlsVisible: true,
                onTogglePlayback: () {},
                onToggleFull: () {},
                onBack: () {},
                onToggleMute: () => muted++,
                onToggleControls: () {},
                onRestoreMini: () {},
                onDragMini: () {},
                child: TextField(focusNode: input),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    rebuild(() => full = true);
    await tester.pump();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(muted, 1);
    input.requestFocus();
    await tester.pump();
    rebuild(() => full = false);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(input.hasFocus, isTrue);
    expect(muted, 1);
    showDialog<void>(
      context: page,
      builder: (_) => const AlertDialog(content: Text('弹窗')),
    );
    await tester.pumpAndSettle();
    rebuild(() => full = true);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(muted, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });
}

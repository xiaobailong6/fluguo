import 'package:duanju_app/ui/live/live_screen_lock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'live_player_recovery_test.dart' show Source, mount, unmount;
import 'support/fake_player.dart';

void main() {
  testWidgets('全屏锁定再解锁后 F/M 仍可用', (tester) async {
    // 原生方向队列具有进程级状态，单独 isolate 验证焦点归还。
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('duanju/device'),
      (_) async => null,
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final source = Source();
      final player = FakePlayer()
        ..state = const PlayerState(width: 1920, height: 1080, volume: 40);
      await mount(tester, source, player);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(
        tester.widget<LiveScreenLock>(find.byType(LiveScreenLock)).enabled,
        isTrue,
      );
      tester.widget<LiveScreenLock>(find.byType(LiveScreenLock)).onToggle();
      await tester.pump();
      expect(
        tester.widget<LiveScreenLock>(find.byType(LiveScreenLock)).locked,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      expect(player.state.volume, 40);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      expect(player.state.volume, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<LiveScreenLock>(find.byType(LiveScreenLock)).enabled,
        isFalse,
      );
      await unmount(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

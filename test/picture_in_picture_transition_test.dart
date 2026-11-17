import 'dart:async';

import 'package:duanju_app/app_device.dart';
import 'package:duanju_app/picture_in_picture.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('resize cannot reopen mini window during exit commit', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final messenger = tester.binding.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      final calls = <bool>[];
      final restore = Completer<void>();
      var nativeExited = false;
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        // 故意停在原生已退出、置顶恢复未完成的位置。
        if (call.method == 'setAlwaysOnTop' && nativeExited) {
          await restore.future;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
        if (call.method != 'setMiniWindow') return null;
        final enabled = (call.arguments as Map)['enabled'] == true;
        calls.add(enabled);
        if (!enabled) nativeExited = true;
        return enabled ? null : {'left': 10, 'top': 20, 'extent': 480};
      });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(AppDevice.channel, null);
      });
      await tester.pumpWidget(const SizedBox());
      final pip = PictureInPicture.instance;
      final entering = pip.enter(16 / 9);
      await tester.pumpAndSettle();
      await entering;
      expect(pip.window, isTrue);
      // 刚入队但尚未执行的 resize 也应被退出代次淘汰。
      pip.resize(4 / 3);
      final exiting = pip.exit();
      expect(identical(pip.exit(), exiting), isTrue);
      await tester.pump();
      expect(nativeExited, isTrue);
      expect(pip.window, isTrue);
      pip.resize(9 / 16);
      await tester.pump();
      expect(calls, [true, false]);
      restore.complete();
      await tester.pumpAndSettle();
      expect(await exiting, (left: 10.0, top: 20.0, extent: 480.0));
      expect(pip.window, isFalse);
      pip.resize(1);
      await tester.pump();
      expect(calls, [true, false]);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

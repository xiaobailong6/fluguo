import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/desktop_window_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_retriever/screen_retriever.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const displays = [
    Display(
      id: 'primary',
      size: Size(1920, 1080),
      visiblePosition: Offset.zero,
      visibleSize: Size(1920, 1040),
    ),
    Display(
      id: 'left',
      size: Size(1280, 1024),
      visiblePosition: Offset(-1280, 0),
      visibleSize: Size(1280, 984),
    ),
  ];
  final value = <String, dynamic>{
    'version': 1,
    'display': 'left',
    'x': -1200,
    'y': 50,
    'width': 1000,
    'height': 700,
  };
  test('普通窗口保留负坐标显示器位置', () {
    expect(
      DesktopWindowState.restoreBounds(value, displays),
      const Rect.fromLTWH(-1200, 50, 1000, 700),
    );
  });
  test('原显示器不在时回退默认位置而不是恢复到屏幕外', () {
    expect(DesktopWindowState.restoreBounds(value, [displays.first]), isNull);
  });
  test('工作区缩小时约束位置与大小，损坏或小窗尺寸不接受', () {
    expect(
      DesktopWindowState.restoreBounds({
        ...value,
        'x': -9999,
        'width': 1800,
      }, displays),
      const Rect.fromLTWH(-1280, 50, 1280, 700),
    );
    expect(
      DesktopWindowState.restoreBounds({...value, 'x': double.nan}, displays),
      isNull,
    );
    expect(
      DesktopWindowState.restoreBounds({
        ...value,
        'width': 320,
        'height': 180,
      }, displays),
      isNull,
    );
    expect(
      DesktopWindowState.restoreBounds({...value, 'version': 2}, displays),
      isNull,
    );
  });

  for (final savedMaximized in [false, true]) {
    test('重启恢复普通尺寸和最大化标志，退出捕获原生普通窗口位置 max=$savedMaximized', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final directory = await Directory.systemTemp.createTemp('window-state-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/window.json');
      await file.writeAsString(
        jsonEncode({...value, if (savedMaximized) 'maximized': true}),
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      const displayChannel = MethodChannel(
        'dev.leanflutter.plugins/screen_retriever',
      );
      const deviceChannel = MethodChannel('duanju/device');
      final calls = <MethodCall>[];
      final destroyed = Completer<void>();
      var native = <String, dynamic>{...value, 'maximized': savedMaximized};
      messenger.setMockMethodCallHandler(
        displayChannel,
        (call) async => call.method == 'getAllDisplays'
            ? {'displays': displays.map((item) => item.toJson()).toList()}
            : displays.first.toJson(),
      );
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        calls.add(call);
        if (call.method == 'destroy') destroyed.complete();
        return null;
      });
      messenger.setMockMethodCallHandler(deviceChannel, (_) async => native);
      addTearDown(() {
        for (final channel in [windowChannel, displayChannel, deviceChannel]) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      });
      final manager = DesktopWindowState.test();
      addTearDown(manager.dispose);
      await manager.initialize(file);
      final bounds =
          calls.firstWhere((call) => call.method == 'setBounds').arguments
              as Map;
      expect(bounds['x'], -1200);
      expect(bounds['width'], 1000);
      expect(
        calls.where((call) => call.method == 'maximize').length,
        savedMaximized ? 1 : 0,
      );
      // A move immediately followed by maximize/fullscreen must use native
      // normal placement, not the old debounced position or screen-sized frame.
      native = {...value, 'x': -1100.0, 'width': 900.0, 'maximized': true};
      manager.onWindowMove();
      manager.onWindowMaximize();
      manager.fullScreenRequested(true);
      manager.onWindowClose();
      await destroyed.future.timeout(const Duration(seconds: 5));
      final saved = jsonDecode(await file.readAsString()) as Map;
      expect(saved['x'], -1100);
      expect(saved['width'], 900);
      expect(saved['maximized'], isTrue);
      expect(calls.where((call) => call.method == 'destroy'), hasLength(1));
    });
  }
}

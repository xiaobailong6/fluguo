import 'dart:async';

import 'package:duanju_app/app_device.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  Completer<void>? pending;
  String? blockedMethod;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      calls.add(call);
      if (call.method == blockedMethod) await pending!.future;
      return null;
    });
    await AppDevice.releaseHeldOrientation();
    await AppDevice.setTelevisionMode(false);
    await AppDevice.setPhoneMode(false);
    calls.clear();
  });

  tearDown(() async {
    if (pending != null && !pending!.isCompleted) pending!.complete();
    pending = null;
    blockedMethod = null;
    await AppDevice.releaseHeldOrientation();
    await AppDevice.setPhoneMode(false);
    messenger.setMockMethodCallHandler(AppDevice.channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('hold and release are temporary, ordered and idempotent', () async {
    await AppDevice.setPhoneMode(true);
    await AppDevice.setPlayerOrientation(PlayerOrientation.lockedLandscape);
    await AppDevice.holdOrientation(landscape: true);
    await AppDevice.holdOrientation(landscape: true);
    await AppDevice.releaseHeldOrientation();
    await AppDevice.releaseHeldOrientation();
    await AppDevice.releaseOrientation();
    expect(calls.map((call) => call.method), [
      'setPlayerOrientation',
      'setPlayerOrientation',
      'holdPlayerOrientation',
      'releasePlayerOrientationHold',
      'setPlayerOrientation',
    ]);
    expect(calls.last.arguments, {'mode': 'lockedPortrait'});
  });

  test('unlock invalidates a queued hold before it reaches Android', () async {
    pending = Completer<void>();
    blockedMethod = 'setPlayerOrientation';
    final normal = AppDevice.setPlayerOrientation(
      PlayerOrientation.lockedLandscape,
    );
    await Future<void>.delayed(Duration.zero);
    final hold = AppDevice.holdOrientation(landscape: true);
    final release = AppDevice.releaseHeldOrientation();
    pending!.complete();
    await Future.wait([normal, hold, release]);
    expect(calls.map((call) => call.method), ['setPlayerOrientation']);
  });

  test('in-flight hold completes before unlock and normal policy', () async {
    pending = Completer<void>();
    blockedMethod = 'holdPlayerOrientation';
    final hold = AppDevice.holdOrientation(landscape: true);
    await Future<void>.delayed(Duration.zero);
    final release = AppDevice.releaseHeldOrientation();
    final normal = AppDevice.setPhoneMode(true);
    expect(calls.map((call) => call.method), ['holdPlayerOrientation']);
    pending!.complete();
    await Future.wait([hold, release, normal]);
    expect(calls.map((call) => call.method), [
      'holdPlayerOrientation',
      'releasePlayerOrientationHold',
      'setPlayerOrientation',
    ]);
    expect(calls.last.arguments, {'mode': 'lockedPortrait'});
  });

  test(
    'new normal or TV policy prevents late restoration of old policy',
    () async {
      await AppDevice.holdOrientation(landscape: false);
      await AppDevice.setPlayerOrientation(PlayerOrientation.auto);
      await AppDevice.releaseHeldOrientation();
      await AppDevice.holdOrientation(landscape: false);
      await AppDevice.setTelevisionMode(true);
      await AppDevice.releaseHeldOrientation();
      expect(calls.map((call) => call.method), [
        'holdPlayerOrientation',
        'setPlayerOrientation',
        'holdPlayerOrientation',
        'setTelevisionMode',
      ]);
    },
  );

  test('iOS fallback restores the previous orientation policy', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final orientations = <Object?>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        orientations.add(call.arguments);
      }
      return null;
    });
    await AppDevice.setPlayerOrientation(PlayerOrientation.lockedLandscape);
    await AppDevice.holdOrientation(landscape: true);
    await AppDevice.releaseHeldOrientation();
    expect(orientations, [
      ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'],
      ['DeviceOrientation.landscapeLeft'],
      ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'],
    ]);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
  test(
    'iOS holds reverse landscape returned by the current interface',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final orientations = <Object?>[];
      messenger.setMockMethodCallHandler(
        AppDevice.channel,
        (call) async => call.method == 'playerInterfaceOrientation'
            ? 'landscapeRight'
            : null,
      );
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientations.add(call.arguments);
        }
        return null;
      });
      await AppDevice.holdOrientation(landscape: true);
      expect(orientations.single, ['DeviceOrientation.landscapeRight']);
      await AppDevice.releaseHeldOrientation();
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    },
  );
}

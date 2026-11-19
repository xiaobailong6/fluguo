import 'dart:async';

import 'package:duanju_app/app_device.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const title = '下载完成后自动导出';
final row = find.widgetWithText(SwitchListTile, title);

Future<void> openDownloadSettings(WidgetTester tester, LocalStore store) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.phone,
        child: child!,
      ),
      home: SettingsPage(store: store),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('下载'));
  await tester.pumpAndSettle();
  expect(row, findsOneWidget);
}

void main() {
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  testWidgets('下载一级菜单：授权后开启、重启保留，关闭不再申请权限', (tester) async {
    final store = await openStore();
    final messenger = tester.binding.defaultBinaryMessenger;
    var requests = 0;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      expect(call.method, 'requestVideoExport');
      requests++;
      return true;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
    );
    await openDownloadSettings(tester, store);
    expect(tester.widget<SwitchListTile>(row).value, isFalse);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(row).value, isTrue);
    expect(restartStore(store).autoExport, isTrue);
    expect(find.text('自动导出后删除 App 内副本'), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(restartStore(store).autoExport, isFalse);
    expect(find.text('自动导出后删除 App 内副本'), findsNothing);
    expect(requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: android);

  testWidgets('拒绝权限后开关仍关闭，权限弹窗期间不能重复请求', (tester) async {
    final store = await openStore();
    final answer = Completer<bool>();
    var requests = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      requests++;
      return answer.future;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
    );
    await openDownloadSettings(tester, store);
    await tester.tap(row);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(row).onChanged, isNull);
    await tester.tap(row);
    answer.complete(false);
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(store.autoExport, isFalse);
    expect(tester.widget<SwitchListTile>(row).onChanged, isNotNull);
    expect(find.textContaining('自动导出未开启'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: android);

  testWidgets('在权限弹窗打开期间切换到访客，迟到的授权无效', (tester) async {
    final store = await openStore({
      ...viewerPreferences,
      'activeProfile': 'default',
      'forceLogin': false,
    });
    final answer = Completer<bool>();
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (_) => answer.future);
    addTearDown(
      () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
    );
    await openDownloadSettings(tester, store);
    expect(tester.widget<SwitchListTile>(row).onChanged, isNotNull);
    await tester.tap(row);
    await tester.pump();
    await store.switchProfile('viewer');
    answer.complete(true);
    await tester.pumpAndSettle();
    expect(store.autoExport, isFalse);
    expect(tester.widget<SwitchListTile>(row).onChanged, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: android);

  testWidgets('无下载权限时不能开启', (tester) async {
    final store = await openStore(viewerPreferences);
    await openDownloadSettings(tester, store);
    expect(tester.widget<SwitchListTile>(row).onChanged, isNull);
    await store.setAutoExport(true);
    expect(store.autoExport, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: android);

  testWidgets('没有系统导出通道的平台显示说明且不能打开', (tester) async {
    final store = await openStore();
    await openDownloadSettings(tester, store);
    expect(tester.widget<SwitchListTile>(row).onChanged, isNull);
    expect(find.text('仅 Android 支持导出到系统视频目录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/settings/storage_view.dart';
import 'package:duanju_app/ui/widgets/glass/glass_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _StorageRepository extends FakeRepository {
  int clears = 0;
  bool fails = false;
  Completer<void>? pending;
  @override
  Future<Map<String, dynamic>> storage() async => {
    'directory': '/downloads',
    'bytes': 2048,
    'files': 2,
    'free': 4096,
    'default': true,
    'cacheDirectory': '/cache',
    'cacheBytes': 1024,
    'cacheFiles': 1,
    'cacheFree': 8192,
  };
  @override
  Future<Map<String, dynamic>> clearCache() async {
    clears++;
    await pending?.future;
    if (fails) throw AppFailure('synthetic cache in use');
    return {'clearedBytes': 1024, 'remainingBytes': 0};
  }
}

void main() {
  Future<void> open(
    WidgetTester tester,
    LocalStore store,
    _StorageRepository repository,
  ) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AppScope(
        repository: repository,
        formFactor: FormFactor.window,
        child: MaterialApp(
          // 交互回归不依赖 Material 的运行时 shader 资源。
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(body: StorageView(store: store)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'cache and downloads remain separate and clearing needs confirmation',
    (tester) async {
      final store = await openStore();
      final repository = _StorageRepository();
      await open(tester, store, repository);
      expect(find.text('下载已使用 2.0 KB'), findsOneWidget);
      expect(find.text('缓存 1.0 KB'), findsOneWidget);
      expect(find.textContaining('所在磁盘剩余 8.0 KB'), findsOneWidget);
      await tester.ensureVisible(find.text('清理缓存'));
      await tester.tap(find.text('清理缓存'));
      await tester.pumpAndSettle();
      expect(find.byType(GlassDialogBody), findsOneWidget);
      expect(repository.clears, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repository.clears, 0);
      await tester.tap(find.text('清理缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '清理'));
      await tester.pumpAndSettle();
      expect(repository.clears, 1);
      expect(find.text('清理缓存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('partial failure is visible and does not stay busy', (
    tester,
  ) async {
    final store = await openStore();
    final repository = _StorageRepository()..fails = true;
    await open(tester, store, repository);
    await tester.ensureVisible(find.text('清理缓存'));
    await tester.tap(find.text('清理缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清理'));
    await tester.pumpAndSettle();
    expect(repository.clears, 1);
    expect(find.textContaining('synthetic cache in use'), findsOneWidget);
    expect(find.text('正在清理缓存…'), findsNothing);
  });

  testWidgets('switching user during confirmation cancels clearing', (
    tester,
  ) async {
    final store = await openStore();
    final repository = _StorageRepository();
    await open(tester, store, repository);
    await tester.ensureVisible(find.text('清理缓存'));
    await tester.tap(find.text('清理缓存'));
    await tester.pumpAndSettle();
    await store.switchProfile(store.profile.id);
    await tester.tap(find.widgetWithText(FilledButton, '清理'));
    await tester.pumpAndSettle();
    expect(repository.clears, 0);
  });
}

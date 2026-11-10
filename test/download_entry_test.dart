import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/downloads/download_picker_page.dart';
import 'package:duanju_app/ui/player/episode_grid.dart';
import 'package:duanju_app/ui/widgets/follow_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<BuildContext> _mount(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.phone,
        child: child!,
      ),
      home: Builder(
        builder: (context) {
          captured = context;
          return const Scaffold(body: SizedBox.expand());
        },
      ),
    ),
  );
  return captured;
}

void main() {
  for (final allowed in [true, false]) {
    testWidgets('三点菜单在${allowed ? '有' : '无'}下载权限时${allowed ? '显示' : '隐藏'}下载剧集', (
      tester,
    ) async {
      final store = await openStore(allowed ? const {} : viewerPreferences);
      expect(store.canDownload, allowed);
      final context = await _mount(tester);
      final opened = showFollowMenu(
        context,
        store,
        drama('menu'),
        const Offset(300, 240),
      );
      await tester.pumpAndSettle();
      expect(find.text('追剧'), findsOneWidget);
      expect(find.text('下载剧集'), allowed ? findsOneWidget : findsNothing);
      // 点遮罩关闭菜单，避免残留路由。
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      await opened;
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('菜单打开后切换用户，旧菜单不会修改当前用户追剧', (tester) async {
    final store = await openStore();
    final context = await _mount(tester);
    final item = drama('stale-menu');
    final opened = showFollowMenu(context, store, item, const Offset(300, 240));
    await tester.pumpAndSettle();
    await store.switchProfile('default');
    await tester.tap(find.text('追剧'));
    await tester.pumpAndSettle();
    await opened;
    expect(store.isFavorite(item.id), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('只给短剧时下载选集页自行读取选集', (tester) async {
    final item = drama('picker');
    final store = await openStore();
    final repository = FakeRepository()
      ..details[item.id] = dramaDetail(item, count: 4);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: repository,
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: DownloadPickerPage(store: store, drama: item),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(EpisodeGrid), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('读取选集失败时显示可重试的错误页', (tester) async {
    final item = drama('picker-fail');
    final store = await openStore();
    final repository = FakeRepository()..detailFailure = '站源暂时不可用';
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: repository,
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: DownloadPickerPage(store: store, drama: item),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('无法读取选集'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(EpisodeGrid), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

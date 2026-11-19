import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/search/search_page.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:duanju_app/ui/widgets/source_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  final menu = find.byKey(const ValueKey('recent-search-options'));
  Future<void> mount(
    WidgetTester tester,
    LocalStore store,
    FakeRepository repo,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: repo,
          formFactor: FormFactor.pad,
          child: child!,
        ),
        home: AppShell(store: store),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('真实顶栏显示历史，删除即时更新且不重新加载目录，点击进入搜索', (tester) async {
    final store = await openStore();
    await store.rememberSearch('保留记录');
    await store.rememberSearch('待删除记录');
    final repo = FakeRepository();
    await mount(tester, store, repo);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(menu, findsOneWidget);
    final requests = repo.recommendRequests.length;
    await tester.longPress(find.text('待删除记录'));
    await tester.pumpAndSettle();
    expect(store.recentSearches, ['保留记录']);
    expect(find.text('待删除记录'), findsNothing);
    expect(menu, findsOneWidget);
    expect(repo.recommendRequests, hasLength(requests));
    await tester.tap(find.text('保留记录'));
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    expect(find.byType(SearchPage), findsOneWidget);
    expect(
      repo.catalogRequests.any((request) => request.contains('|保留记录|')),
      isTrue,
    );
    Navigator.of(tester.element(find.byType(SearchPage))).pop();
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('切用户关闭历史并阻止旧回调删除或搜索，窄窗口无悬挂弹层', (tester) async {
    final store = await openStore(viewerPreferences);
    await store.rememberSearch('用户记录');
    final repo = FakeRepository();
    await mount(tester, store, repo);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final old = tester.widget<SourceBar>(find.byType(SourceBar));
    expect(menu, findsOneWidget);
    // 即使重新选择同一用户也会推进 epoch，旧回调必须失效。
    await store.switchProfile(store.profile.id);
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    old.onForgetSearch!('用户记录');
    old.onSearchSubmitted('旧回调');
    await tester.pumpAndSettle();
    expect(store.recentSearches, ['用户记录']);
    expect(find.byType(SearchPage), findsNothing);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(menu, findsOneWidget);
    tester.view.physicalSize = const Size(600, 800);
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('切Tab或滚动隐藏顶栏时关闭历史，恢复页面不重新弹出', (tester) async {
    final store = await openStore();
    await store.rememberSearch('记录');
    await mount(
      tester,
      store,
      FakeRepository()
        ..recommended = List.generate(30, (i) => drama('item-$i')),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(menu, findsOneWidget);
    final scroll = tester
        .widget<CustomScrollView>(
          find.descendant(
            of: find.byType(ExplorePage),
            matching: find.byType(CustomScrollView),
          ),
        )
        .controller!;
    scroll.jumpTo(500);
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(menu, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-follow')));
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    await tester.tap(find.byKey(const ValueKey('nav-explore')));
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

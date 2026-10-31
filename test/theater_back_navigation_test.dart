import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/theater_preview_backend.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:duanju_app/ui/shell/theater_navigation_notification.dart';
import 'package:duanju_app/ui/theater/theater_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'theater_test.dart' as theater;

// 播放页面可能持续调度帧；这里只等待导航过渡，不等待播放器全局静止。
Future<void> pumpNavigation(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 75));
  }
}

Future<void> mountShell(
  WidgetTester tester,
  LocalStore store,
  FormFactor form,
) async {
  tester.view.physicalSize = form == FormFactor.phone
      ? const Size(400, 900)
      : const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => AppScope(
        repository: theater.PreviewRepository(),
        formFactor: form,
        child: child!,
      ),
      home: PreviewBackendScope(
        factory: theater.FakePreviewBackend.new,
        child: AppShell(store: store),
      ),
    ),
  );
  await pumpNavigation(tester);
}

int selectedTab(WidgetTester tester) => tester
    .widget<IndexedStack>(
      find
          .descendant(
            of: find.byType(AppShell),
            matching: find.byType(IndexedStack),
          )
          .first,
    )
    .index!;

void leaveTheater(WidgetTester tester) =>
    tester.widget<TheaterPage>(find.byType(TheaterPage)).onExit!();

void main() {
  for (final form in FormFactor.values) {
    for (final uiBack in [false, true]) {
      testWidgets('剧场返回保留短剧 Navigator 和滚动 ${form.name} UI=$uiBack', (
        tester,
      ) async {
        final store = await openStore();
        await mountShell(tester, store, form);
        final exploreState = tester.state(find.byType(ExplorePage));
        final exploreNavigator = Navigator.of(
          tester.element(find.byType(ExplorePage)),
        );
        final enter = tester
            .widget<InkWell>(find.byKey(const ValueKey('nav-theater')))
            .onTap!;
        final scroll = ScrollController();
        // 在短剧栈保留一个有滚动位置的子页，验证返回不是重建或 pop 到根页。
        final route = exploreNavigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: ListView.builder(
                controller: scroll,
                itemExtent: 80,
                itemCount: 100,
                itemBuilder: (_, index) => Text('短剧保留项 $index'),
              ),
            ),
          ),
        );
        await pumpNavigation(tester);
        scroll.jumpTo(640);
        await pumpNavigation(tester);
        enter();
        await pumpNavigation(tester);
        expect(selectedTab(tester), AppTab.theater.index);
        if (uiBack) {
          leaveTheater(tester);
        } else {
          await tester.binding.handlePopRoute();
        }
        await pumpNavigation(tester);
        expect(selectedTab(tester), AppTab.explore.index);
        expect(exploreNavigator.canPop(), isTrue);
        expect(scroll.offset, 640);
        expect(
          identical(
            tester.state(find.byType(ExplorePage, skipOffstage: false)),
            exploreState,
          ),
          isTrue,
        );
        exploreNavigator.pop();
        await pumpNavigation(tester);
        await route;
        await tester.pumpWidget(const SizedBox.shrink());
        scroll.dispose();
      });
    }

    testWidgets('全集系统/UI返回只回剧场，子路由拦截不切页 ${form.name}', (tester) async {
      final store = await openStore();
      await mountShell(tester, store, form);
      await tester.tap(find.byKey(const ValueKey('nav-theater')));
      await pumpNavigation(tester);
      final pageContext = tester.element(find.byType(TheaterPage));
      // 覆盖手机/TV 根路由，以及桌面内层 Navigator 的实际 openPage 策略。
      for (final uiBack in [false, true]) {
        final closed = openPage<void>(
          pageContext,
          (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.maybePop(context),
              child: const Text('测试全集返回'),
            ),
          ),
        );
        await pumpNavigation(tester);
        if (uiBack) {
          await tester.tap(find.text('测试全集返回'));
        } else {
          await tester.binding.handlePopRoute();
        }
        await pumpNavigation(tester);
        await closed;
        expect(selectedTab(tester), AppTab.theater.index);
        expect(find.byType(TheaterPage), findsOneWidget);
      }
      // 显式内层栈拒绝返回时，同一按键也不能落到 shell 的退短剧逻辑。
      var blocked = 0;
      Navigator.of(pageContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) blocked++;
            },
            child: const Scaffold(body: Text('全集拦截')),
          ),
        ),
      );
      await pumpNavigation(tester);
      await tester.binding.handlePopRoute();
      await pumpNavigation(tester);
      expect(blocked, 1);
      expect(selectedTab(tester), AppTab.theater.index);
      expect(find.text('全集拦截'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('短剧隐藏时返回配置首个可见非剧场菜单', (tester) async {
    final store = await openStore();
    await store.setNavigationOrder(['theater', 'follow', 'mine', 'explore']);
    await store.setNavigationVisible('explore', false);
    await mountShell(tester, store, FormFactor.phone);
    expect(selectedTab(tester), AppTab.theater.index);
    await tester.binding.handlePopRoute();
    await pumpNavigation(tester);
    expect(selectedTab(tester), AppTab.follow.index);
    await tester.tap(find.byKey(const ValueKey('nav-theater')));
    await pumpNavigation(tester);
    leaveTheater(tester);
    await pumpNavigation(tester);
    expect(selectedTab(tester), AppTab.follow.index);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final uiBack in [false, true]) {
    testWidgets('仅剧场可见时双返回可退出 UI=$uiBack', (tester) async {
      final store = await openStore();
      for (final tab in AppTab.values.where((tab) => tab != AppTab.theater)) {
        await store.setNavigationVisible(tab.name, false);
      }
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      await mountShell(tester, store, FormFactor.phone);
      final semantics = tester.ensureSemantics();
      const TheaterNavigationToggleNotification().dispatch(
        tester.element(find.byType(TheaterPage)),
      );
      await pumpNavigation(tester);
      // 菜单不构建，因而不存在可聚焦或可被读屏访问的透明底栏。
      for (final tab in AppTab.values) {
        expect(
          find.byKey(ValueKey('nav-${tab.name}'), skipOffstage: false),
          findsNothing,
        );
      }
      for (var attempt = 0; attempt < 2; attempt++) {
        if (uiBack) {
          leaveTheater(tester);
        } else {
          await tester.binding.handlePopRoute();
        }
        await pumpNavigation(tester);
        if (attempt == 0) {
          expect(
            calls.where((call) => call.method == 'SystemNavigator.pop'),
            isEmpty,
          );
          expect(find.text('再按一次返回退出应用'), findsOneWidget);
        }
      }
      expect(
        calls.where((call) => call.method == 'SystemNavigator.pop'),
        hasLength(1),
      );
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

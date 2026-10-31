import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/navigation_order.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/settings/navigation_order_settings.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:duanju_app/ui/shell/theater_navigation_notification.dart';
import 'package:duanju_app/ui/theater/theater_page.dart';
import 'package:duanju_app/theater_preview_backend.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'theater_test.dart' as theater;

void main() {
  test('默认顺序、去重补足和稳定身份', () {
    expect(normalizeNavigationOrder(const []), defaultNavigationOrder);
    expect(normalizeNavigationOrder(['mine', 'mine', 'invalid', 4]), [
      'mine',
      'theater',
      'explore',
      'live',
      'follow',
    ]);
    expect(AppTab.explore.index, 0);
    expect(AppTab.theater.index, 1);
  });

  test('显隐 normalize 保留有效项，空或坏值回退全部显示', () {
    expect(normalizeNavigationVisible([]), defaultNavigationOrder);
    expect(
      normalizeNavigationVisible(['bad', 3, null]),
      defaultNavigationOrder,
    );
    expect(normalizeNavigationVisible(['mine', 'mine', false, 'live']), [
      'mine',
      'live',
    ]);
  });

  test('显隐快照、文件重启、备份兼容和最后一项保护', () async {
    final store = await openStore();
    final dir = await Directory.systemTemp.createTemp('navigation-visible-');
    try {
      expect(store.navigationVisible, defaultNavigationOrder);
      await Future.wait([
        for (final name in defaultNavigationOrder)
          store.setNavigationVisible(name, false),
      ]);
      expect(store.navigationVisible, ['mine']);
      expect(LocalStore(store.preferences).navigationVisible, ['mine']);
      await store.setNavigationVisible('mine', false);
      expect(store.navigationVisible, ['mine']);
      await store.setNavigationOrder(['mine']);
      final backup = await store.exportBackup();
      final files = await LocalStore.open(store.preferences, dir);
      expect(files.navigationVisible, ['mine']);
      await files.setNavigationVisible('follow', true);
      files.dispose();
      final reopened = await LocalStore.open(store.preferences, dir);
      expect(reopened.navigationVisible, ['mine', 'follow']);
      await reopened.importBackup(backup);
      expect(reopened.navigationVisible, ['mine']);
      expect(reopened.navigationOrder.first, 'mine');
      final oldBackup = jsonDecode(backup) as Map<String, dynamic>
        ..remove('navigationVisible')
        ..remove('navigationOrder');
      await reopened.importBackup(jsonEncode(oldBackup));
      expect(reopened.navigationVisible, defaultNavigationOrder);
      expect(reopened.navigationOrder, defaultNavigationOrder);
      reopened.dispose();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('显隐损坏 JSON、非列表及无有效菜单安全回退', () async {
    for (final value in ['broken', '{}', '[]', '["unknown",7]']) {
      SharedPreferences.setMockInitialValues({'navigationVisible': value});
      final store = LocalStore(await SharedPreferences.getInstance());
      expect(store.navigationVisible, defaultNavigationOrder);
      store.dispose();
    }
  });

  test('快照和分文件重启保留顺序，损坏列表安全回退', () async {
    SharedPreferences.setMockInitialValues({'navigationOrder': 'broken'});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalStore(prefs);
    expect(store.navigationOrder, defaultNavigationOrder);
    await store.setNavigationOrder(['mine', 'live', 'mine', 'unknown']);
    final expected = ['mine', 'live', 'theater', 'explore', 'follow'];
    expect(LocalStore(prefs).navigationOrder, expected);
    final dir = await Directory.systemTemp.createTemp('navigation-order-');
    try {
      final files = await LocalStore.open(prefs, dir);
      expect(files.navigationOrder, expected);
      await files.setNavigationOrder(['follow']);
      files.dispose();
      final reopened = await LocalStore.open(prefs, dir);
      expect(reopened.navigationOrder, [
        'follow',
        'theater',
        'explore',
        'live',
        'mine',
      ]);
      reopened.dispose();
    } finally {
      store.dispose();
      await dir.delete(recursive: true);
    }
  });

  testWidgets('排序按钮移动并持久化，支持恢复默认', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await openStore();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: Scaffold(
          body: ListView(children: [NavigationOrderSettings(store: store)]),
        ),
      ),
    );
    await tester.tap(find.byTooltip('上移短剧'));
    await tester.pumpAndSettle();
    expect(store.navigationOrder.first, 'explore');
    await tester.tap(find.byKey(const ValueKey('visible-explore')));
    await tester.pumpAndSettle();
    expect(store.navigationVisible, isNot(contains('explore')));
    expect(store.navigationOrder.first, 'explore');
    for (final name in ['theater', 'live', 'follow']) {
      await store.setNavigationVisible(name, false);
    }
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Switch>(find.byKey(const ValueKey('visible-mine')))
          .onChanged,
      isNull,
    );
    expect(find.text('至少保留一个功能'), findsOneWidget);
    await tester.ensureVisible(find.text('恢复默认'));
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(store.navigationOrder, defaultNavigationOrder);
    expect(store.navigationVisible, defaultNavigationOrder);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final form in FormFactor.values) {
    testWidgets('隐藏默认短剧时启动选择首可见项，进度保存不重建 shell ${form.name}', (tester) async {
      tester.view.physicalSize = form == FormFactor.phone
          ? const Size(400, 900)
          : const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await openStore();
      await store.setNavigationOrder(['follow', 'mine', 'explore']);
      await store.setNavigationVisible('explore', false);
      await store.setNavigationVisible('theater', false);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => AppScope(
            repository: FakeRepository(),
            formFactor: form,
            child: child!,
          ),
          home: AppShell(store: store),
        ),
      );
      await tester.pumpAndSettle();
      final stack = find
          .descendant(
            of: find.byType(AppShell),
            matching: find.byType(IndexedStack),
          )
          .first;
      expect(tester.widget<IndexedStack>(stack).index, AppTab.follow.index);
      expect(find.byKey(const ValueKey('nav-explore')), findsNothing);
      expect(find.byKey(const ValueKey('nav-theater')), findsNothing);
      final before = tester.widget<IndexedStack>(stack);
      await store.saveWatch(watching(drama('navigation-progress')));
      await tester.pumpAndSettle();
      expect(identical(tester.widget<IndexedStack>(stack), before), isTrue);
      if (form == FormFactor.television) {
        final follow = tester.widget<InkWell>(
          find.byKey(const ValueKey('nav-follow')),
        );
        expect(follow.focusNode!.hasFocus, isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets('菜单顺序、Navigator保留及剧场显隐 ${form.name}', (tester) async {
      tester.view.physicalSize = form == FormFactor.phone
          ? const Size(400, 900)
          : const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await openStore();
      final backend = theater.FakePreviewBackend();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => AppScope(
            repository: theater.PreviewRepository(),
            formFactor: form,
            child: child!,
          ),
          home: PreviewBackendScope(
            factory: () => backend,
            child: AppShell(store: store),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('nav-theater'));
      final exploreMenu = find.byKey(const ValueKey('nav-explore'));
      expect(
        tester.getTopLeft(menu).dx <= tester.getTopLeft(exploreMenu).dx,
        isTrue,
      );
      await tester.tap(menu);
      await tester.pumpAndSettle();
      final pageState = tester.state(find.byType(TheaterPage));
      bool hidden() => tester
          .widget<IgnorePointer>(
            find.ancestor(of: menu, matching: find.byType(IgnorePointer)).first,
          )
          .ignoring;
      void toggle() => const TheaterNavigationToggleNotification().dispatch(
        tester.element(find.byType(TheaterPage)),
      );
      if (form == FormFactor.phone) {
        expect(hidden(), isTrue);
        final view = tester.widget<PageView>(find.byType(PageView));
        view.controller!.jumpToPage(1);
        await tester.pumpAndSettle();
        expect(hidden(), isTrue);
        toggle();
        await tester.pumpAndSettle();
        expect(hidden(), isFalse);
        toggle();
        await tester.pumpAndSettle();
        expect(hidden(), isTrue);
        toggle();
        await tester.pumpAndSettle();
      } else {
        toggle();
        await tester.pumpAndSettle();
        expect(menu.hitTestable(), findsOneWidget);
      }
      await store.setNavigationOrder([
        'mine',
        'follow',
        'live',
        'explore',
        'theater',
      ]);
      await tester.pumpAndSettle();
      expect(
        identical(tester.state(find.byType(TheaterPage)), pageState),
        isTrue,
      );
      await tester.tap(exploreMenu);
      await tester.pumpAndSettle();
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(
        identical(tester.state(find.byType(TheaterPage)), pageState),
        isTrue,
      );
      if (form == FormFactor.phone) expect(hidden(), isTrue);
      // 隐藏当前页切到配置顺序首个可见项，已访问 Navigator 不销毁。
      await store.setNavigationVisible('theater', false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nav-theater')), findsNothing);
      final stack = find
          .descendant(
            of: find.byType(AppShell),
            matching: find.byType(IndexedStack),
          )
          .first;
      expect(tester.widget<IndexedStack>(stack).index, AppTab.mine.index);
      expect(
        identical(
          tester.state(find.byType(TheaterPage, skipOffstage: false)),
          pageState,
        ),
        isTrue,
      );
      if (form == FormFactor.television) {
        expect(
          tester
              .widget<InkWell>(find.byKey(const ValueKey('nav-mine')))
              .focusNode!
              .hasFocus,
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(tester.widget<IndexedStack>(stack).index, AppTab.follow.index);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(tester.widget<IndexedStack>(stack).index, AppTab.mine.index);
      }
      await store.setNavigationVisible('theater', true);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-theater')));
      await tester.pumpAndSettle();
      expect(
        identical(tester.state(find.byType(TheaterPage)), pageState),
        isTrue,
      );
      await store.setNavigationVisible('explore', false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nav-explore')), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.widget<IndexedStack>(stack).index, AppTab.mine.index);
      expect(find.byKey(const ValueKey('nav-explore')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

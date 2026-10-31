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
    await tester.ensureVisible(find.text('恢复默认'));
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(store.navigationOrder, defaultNavigationOrder);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final form in FormFactor.values) {
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
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

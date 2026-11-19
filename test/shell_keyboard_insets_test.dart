import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final form in [FormFactor.pad, FormFactor.window]) {
    testWidgets('宽屏嵌套页面只避让一次键盘 $form', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      final store = await openStore();
      final repo = FakeRepository()
        ..recommended = List.generate(20, (i) => drama('keyboard-$i'));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              AppScope(repository: repo, formFactor: form, child: child!),
          home: AppShell(store: store),
        ),
      );
      await tester.pumpAndSettle();
      final page = find.byType(ExplorePage);
      final scroll = find.descendant(
        of: page,
        matching: find.byType(CustomScrollView),
      );
      final before = tester.getSize(scroll).height;
      // 更高键盘在旧实现下会压到零高度，不能仅断言没有布局异常。
      for (final inset in [320.0, 450.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pumpAndSettle();
        expect(tester.getSize(scroll).height, closeTo(before - inset, 1));
        expect(
          tester.getSize(find.byKey(const ValueKey('side-bar'))).height,
          closeTo(before - inset - 16, 1),
          reason: '侧栏仍填满原可用高度',
        );
        expect(MediaQuery.viewInsetsOf(tester.element(page)).bottom, 0);
        expect(
          find.byKey(const ValueKey('nav-explore')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

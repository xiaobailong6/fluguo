import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/live/live_navigation.dart';
import 'package:duanju_app/ui/live/live_page.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final form in [
    FormFactor.phone,
    FormFactor.window,
    FormFactor.television,
  ]) {
    testWidgets('直播系统返回只退出子页，不切换短剧：${form.name}', (tester) async {
      final store = await openStore();
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
      await tester.tap(find.text('直播').last);
      await tester.pumpAndSettle();
      final liveContext = tester.element(find.byType(LivePage));
      var intercept = true;
      var intercepted = 0;
      late StateSetter rebuild;
      // 模拟全屏/PiP 的 PopScope；外壳必须把拒绝退出也视为已消费。
      final closed = pushLivePage<void>(
        liveContext,
        (context) => StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return PopScope(
              canPop: !intercept,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) intercepted++;
              },
              child: Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: const Text('测试直播返回'),
                ),
              ),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(intercepted, 1);
      expect(find.text('测试直播返回'), findsOneWidget);
      rebuild(() => intercept = false);
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await closed;
      expect(find.byType(LivePage), findsOneWidget);
      expect(find.byType(ExplorePage), findsNothing);
      // 工具栏返回同样应保留直播 Tab。
      final toolbarClosed = pushLivePage<void>(
        liveContext,
        (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.maybePop(context),
            child: const Text('工具栏返回'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('工具栏返回'));
      await tester.pumpAndSettle();
      await toolbarClosed;
      expect(find.byType(LivePage), findsOneWidget);
      expect(find.byType(ExplorePage), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

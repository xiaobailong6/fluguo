import 'package:duanju_app/theater_preview_backend.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:duanju_app/ui/theater/theater_page.dart';
import 'package:duanju_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'theater_test.dart' show PreviewRepository, FakePreviewBackend;

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('剧场系统栏在${brightness.name}主题下可见，退出和覆盖路由恢复样式', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.reset);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      Map<Object?, Object?> lastStyle() => Map<Object?, Object?>.from(
        calls
                .lastWhere(
                  (call) =>
                      call.method == 'SystemChrome.setSystemUIOverlayStyle',
                )
                .arguments
            as Map,
      );
      // 先提交不同样式，避免 SystemChrome 跨用例去重导致没有初始调用记录。
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(statusBarColor: Colors.red),
      );
      await tester.pump();
      final store = await openStore();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Colors.orange, brightness, television: false),
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.systemBars(Theme.of(context).brightness),
            child: AppScope(
              repository: PreviewRepository(),
              formFactor: FormFactor.phone,
              child: child!,
            ),
          ),
          home: PreviewBackendScope(
            factory: FakePreviewBackend.new,
            child: AppShell(store: store),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final normalIcons = brightness == Brightness.light
          ? 'Brightness.dark'
          : 'Brightness.light';
      expect(lastStyle()['statusBarIconBrightness'], normalIcons);
      await tester.tap(find.byKey(const ValueKey('nav-theater')));
      await tester.pumpAndSettle();
      expect(lastStyle()['statusBarIconBrightness'], 'Brightness.light');
      expect(lastStyle()['statusBarBrightness'], 'Brightness.dark');
      expect(lastStyle()['statusBarColor'], Colors.transparent.toARGB32());
      expect(
        calls.where(
          (call) => call.method == 'SystemChrome.setEnabledSystemUIMode',
        ),
        isEmpty,
        reason: '剧场仅改变图标对比度，不隐藏系统状态栏',
      );
      final navigator = Navigator.of(
        tester.element(find.byType(TheaterPage)),
        rootNavigator: true,
      );
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.systemBars(Brightness.light),
            child: const Scaffold(
              backgroundColor: Colors.white,
              body: SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(lastStyle()['statusBarIconBrightness'], 'Brightness.dark');
      navigator.pop();
      await tester.pumpAndSettle();
      expect(lastStyle()['statusBarIconBrightness'], 'Brightness.light');
      tester.widget<TheaterPage>(find.byType(TheaterPage)).onExit!();
      await tester.pumpAndSettle();
      expect(
        lastStyle()['statusBarIconBrightness'],
        normalIcons,
        reason: '隐藏的剧场不能覆盖短剧页系统栏',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}

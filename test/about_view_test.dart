import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/settings/about_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<void> mount(WidgetTester tester, {double scale = 1}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          version: '1.0.8+108',
          child: child!,
        ),
      ),
      home: const Scaffold(
        body: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: AboutView(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('默认隐藏四个外链，第五击后顺序显示在简介下方', (tester) async {
    await mount(tester);
    expect(find.text(appName), findsOneWidget);
    expect(find.text('轻松找剧，随时开看'), findsOneWidget);
    final links = find.byKey(const ValueKey('about-hidden-links'));
    final version = find.byKey(const ValueKey('about-version'));
    for (var index = 0; index < 4; index++) {
      await tester.tap(version);
      await tester.pump();
      expect(links, findsNothing);
    }
    await tester.tap(version);
    await tester.pumpAndSettle();
    expect(links, findsOneWidget);
    for (final label in [
      'GitHub · 重建版',
      'GitHub · 原作者',
      'Telegram · 交流群组',
      'Telegram · 更新频道',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(
      tester.getRect(links).top,
      greaterThan(
        tester.getRect(find.byKey(const ValueKey('about-introduction'))).bottom,
      ),
    );
    await tester.tap(version);
    await tester.pump();
    expect(links, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester);
    expect(links, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分散点击不累计，窄屏大字体展开不重叠不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await mount(tester, scale: 2);
    final version = find.byKey(const ValueKey('about-version'));
    for (var index = 0; index < 4; index++) {
      await tester.tap(version);
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(version);
    await tester.pump();
    expect(find.byKey(const ValueKey('about-hidden-links')), findsNothing);
    for (var index = 0; index < 4; index++) {
      await tester.tap(version);
      await tester.pump();
    }
    final links = find.byKey(const ValueKey('about-hidden-links'));
    expect(links, findsOneWidget);
    expect(
      tester.getRect(links).top,
      greaterThan(
        tester.getRect(find.byKey(const ValueKey('about-introduction'))).bottom,
      ),
    );
    await tester.scrollUntilVisible(find.text('Telegram · 更新频道'), 200);
    expect(tester.takeException(), isNull);
  });
}

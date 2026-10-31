import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_hero.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final width in [280.0, 390.0, 800.0]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      testWidgets('推荐横幅宽度$width 字号$scale不溢出', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var played = false;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: AppScope(
                repository: FakeRepository(),
                formFactor: FormFactor.window,
                child: child!,
              ),
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: ExploreHero(
                  drama: drama('1', title: '这是一个需要正确适配宽度的短剧名称'),
                  kicker: '继续观看',
                  meta: '看到第 100 集 · 共 120 集',
                  action: '继续第 101 集',
                  progress: .5,
                  onPlay: () => played = true,
                  onDetail: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('继续第 101 集'));
        await tester.tap(find.text('继续第 101 集'));
        expect(played, isTrue);
      });
    }
  }
}

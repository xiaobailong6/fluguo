import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/widgets/glass/glass_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('首页占位跟随含外边距的顶栏高度，字体变化保留滚动位置', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 680));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await openStore();
    final repository = FakeRepository()
      ..recommended = List.generate(24, (i) => drama('inset-$i'));
    final scale = ValueNotifier(1.4);
    addTearDown(scale.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<double>(
          valueListenable: scale,
          builder: (context, value, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(value)),
            child: child!,
          ),
          child: AppScope(
            repository: repository,
            formFactor: FormFactor.phone,
            child: ExplorePage(store: store),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final header = find.byType(GlassHeader);
    final hero = find.byKey(const ValueKey('explore-hero-motion'));
    final view = find.byType(CustomScrollView);
    final position = tester.widget<CustomScrollView>(view).controller!.position;
    void expectInset() {
      // 首页卡片还有自身的 12px 上边距；顶栏则量整个外框，而非内部 Column。
      expect(
        tester.getTopLeft(hero).dy + position.pixels,
        closeTo(tester.getBottomLeft(header).dy + 12, 0.01),
      );
    }

    expectInset();
    final initialHeight = tester.getSize(header).height;
    position.jumpTo(32);
    await tester.pumpAndSettle();
    scale.value = 1.7;
    await tester.pumpAndSettle();
    expect(tester.getSize(header).height, greaterThan(initialHeight));
    expect(
      tester.widget<CustomScrollView>(view).controller!.position,
      same(position),
    );
    expect(position.pixels, 32);
    expectInset();
    expect(tester.takeException(), isNull);
  });
}

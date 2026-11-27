import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/explore/explore_hero.dart';
import 'package:duanju_app/ui/widgets/drama_grid.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _HeldRepository extends FakeRepository {
  var result = Completer<CatalogPage>();
  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) => result.future;
}

void main() {
  for (final form in FormFactor.values) {
    testWidgets('探索页首屏骨架适配 $form，刷新保留内容与滚动位置', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = form == FormFactor.phone
          ? const Size(390, 844)
          : const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final repo = _HeldRepository();
      final store = await openStore();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorSchemeSeed: Colors.pink,
            brightness: Brightness.dark,
          ),
          home: MediaQuery(
            data: MediaQueryData(
              size: tester.view.physicalSize,
              textScaler: TextScaler.linear(form == FormFactor.phone ? 2 : 1),
            ),
            child: AppScope(
              repository: repo,
              formFactor: form,
              child: ExplorePage(store: store),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DramaSkeletonGrid), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(DramaTile), findsNothing);
      expect(tester.takeException(), isNull);
      final heroRect = tester.getRect(find.byType(ExploreHeroSkeleton));
      repo.result.complete(
        CatalogPage(List.generate(30, (i) => drama('poster-$i'))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DramaTile), findsWidgets);
      expect(tester.getRect(find.byType(ExploreHero)), heroRect);
      expect(find.byType(DramaSkeletonGrid).hitTestable(), findsNothing);
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView).first)
          .controller!;
      scroll.jumpTo(100);
      await tester.pumpAndSettle();
      final offset = scroll.offset;
      if (form != FormFactor.television) {
        repo.result = Completer<CatalogPage>();
        final refreshed = tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh();
        await tester.pump();
        expect(find.byType(DramaTile), findsWidgets);
        expect(find.byType(DramaSkeletonGrid).hitTestable(), findsNothing);
        expect(scroll.offset, offset);
        repo.result.complete(
          CatalogPage(List.generate(30, (i) => drama('poster-$i'))),
        );
        await refreshed;
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('骨架沿用网格的列宽与字号高度，布局无常驻 ticker', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: CustomScrollView(
            slivers: const [DramaSkeletonGrid(width: 800)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    final expected =
        dramaGridDelegate(tester.element(find.byType(DramaSkeletonGrid)), 800)
            as SliverGridDelegateWithFixedCrossAxisCount;
    final actual =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(actual.crossAxisCount, expected.crossAxisCount);
    expect(actual.mainAxisExtent, expected.mainAxisExtent);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}

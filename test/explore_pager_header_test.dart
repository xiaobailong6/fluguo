import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_hero.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/widgets/category_tabs.dart';
import 'package:duanju_app/ui/widgets/scroll_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Catalog extends FakeRepository {
  _Catalog() {
    recommended = List.generate(45, (i) => drama('recommend-$i'));
    categoryList = const [
      CatalogCategory.all,
      CatalogCategory('short_play', '真人剧'),
    ];
  }

  @override
  CatalogPage pageFor(String source, String category, String query, int page) =>
      CatalogPage(List.generate(45, (i) => drama('$category-$i')));
}

class _HeldCatalog extends _Catalog {
  final pending = Completer<CatalogPage>();

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) => pending.future;
}

Finder categoryScroll(String category) => find.byWidgetPredicate((widget) {
  if (widget is! CustomScrollView) return false;
  final key = widget.key;
  return key is PageStorageKey<(int, String?, String)> &&
      key.value.$3 == category;
});

bool headerHidden(WidgetTester tester) => tester
    .widget<ScrollChromeVisibility>(
      find.byKey(const ValueKey('explore-chrome-motion')),
    )
    .hidden;

Future<void> swipeCategory(WidgetTester tester, {bool back = false}) async {
  final rect = tester.getRect(find.byType(PageView));
  await tester.dragFrom(
    Offset(
      rect.left + rect.width * (back ? .2 : .8),
      rect.top + rect.height * .65,
    ),
    Offset(rect.width * (back ? .7 : -.7), 0),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final form in [FormFactor.phone, FormFactor.pad]) {
    for (final reduced in [false, true]) {
      testWidgets('顶栏收起后横滑分类不留空白并恢复各页滚动 $form reduced=$reduced', (
        tester,
      ) async {
        final size = form == FormFactor.phone
            ? const Size(390, 844)
            : const Size(900, 1000);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final store = await openStore();
        await store.saveWatch(watching(drama('resume')));
        final repository = _Catalog();
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: AppScope(
                repository: repository,
                formFactor: form,
                child: child!,
              ),
            ),
            home: ExplorePage(store: store),
          ),
        );
        await tester.pumpAndSettle();
        final first = categoryScroll('app:recommend');
        final controller = tester.widget<CustomScrollView>(first).controller!;
        final top = tester.getTopLeft(first).dy;
        final initialHero = tester
            .getTopLeft(
              find.descendant(of: first, matching: find.byType(ExploreHero)),
            )
            .dy;
        // 精确复现：浮栏已离场，继续观看卡片正好滚到视口顶部附近。
        final offset = initialHero - top - 4;
        controller.jumpTo(offset);
        await tester.pumpAndSettle();
        final collapsedOffset = controller.offset;
        expect(headerHidden(tester), isTrue);
        expect(
          tester
                  .getTopLeft(
                    find.descendant(
                      of: first,
                      matching: find.byType(ExploreHero),
                    ),
                  )
                  .dy -
              top,
          closeTo(4, 1),
        );
        await swipeCategory(tester);
        expect(
          tester
              .widget<CategoryTabs<String>>(find.byType(CategoryTabs<String>))
              .selected,
          '',
        );
        final second = categoryScroll('');
        final secondScroll = tester
            .widget<CustomScrollView>(second)
            .controller!;
        expect(secondScroll.offset, closeTo(0, .1));
        // 横滑不展开顶栏；邻页直接折叠占位，而不是拿顶栏遮住空白。
        expect(headerHidden(tester), isTrue);
        final heroTop = tester
            .getTopLeft(
              find.descendant(of: second, matching: find.byType(ExploreHero)),
            )
            .dy;
        expect(heroTop - tester.getTopLeft(second).dy, inInclusiveRange(0, 18));
        await swipeCategory(tester, back: true);
        final returned = tester
            .widget<CustomScrollView>(categoryScroll('app:recommend'))
            .controller!;
        expect(returned.offset, closeTo(collapsedOffset, .1));
        expect(headerHidden(tester), isTrue);
        // 完全离屏的页可被PageView回收，但恢复的阅读位置和顶栏状态必须一致。
        // 返回后小幅反向滚动也须沿用本页基准，而非上一分类的0位置。
        returned.jumpTo(returned.offset - 14);
        await tester.pumpAndSettle();
        expect(headerHidden(tester), isFalse);
        final expandedOffset = returned.offset;
        await tester.tap(find.text('全部'));
        await tester.pumpAndSettle();
        expect(headerHidden(tester), isFalse);
        await swipeCategory(tester, back: true);
        final visibleAgain = tester
            .widget<CustomScrollView>(categoryScroll('app:recommend'))
            .controller!;
        expect(visibleAgain.offset, closeTo(expandedOffset, .1));
        expect(headerHidden(tester), isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  for (final fails in [false, true]) {
    testWidgets('切到加载中的分类保留折叠，迟到结果不留下占位 fails=$fails', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = await openStore();
      await store.saveWatch(watching(drama('pending-resume')));
      final repository = _HeldCatalog();
      await tester.pumpWidget(
        MaterialApp(
          home: AppScope(
            repository: repository,
            formFactor: FormFactor.phone,
            child: ExplorePage(store: store),
          ),
        ),
      );
      // 邻页请求保持未完成，不能用pumpAndSettle等待无限进度动画。
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final scroll = tester
          .widget<CustomScrollView>(categoryScroll('app:recommend'))
          .controller!;
      scroll.jumpTo(130);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(headerHidden(tester), isTrue);
      await tester.dragFrom(const Offset(330, 500), const Offset(-290, 0));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        tester
            .widget<CategoryTabs<String>>(find.byType(CategoryTabs<String>))
            .selected,
        '',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(headerHidden(tester), isTrue);
      if (fails) {
        repository.pending.completeError(const AppFailure('测试分类失败'));
      } else {
        repository.pending.complete(repository.pageFor('hongguo', '', '', 1));
      }
      await tester.pumpAndSettle();
      expect(headerHidden(tester), isTrue);
      if (!fails) {
        expect(
          tester
              .widget<CustomScrollView>(categoryScroll(''))
              .controller!
              .offset,
          0,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

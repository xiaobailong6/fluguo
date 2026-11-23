import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/ui/explore/explore_header_inset.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_hero.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:duanju_app/ui/widgets/category_tabs.dart';
import 'package:duanju_app/ui/widgets/scroll_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Catalog extends FakeRepository {
  _Catalog() {
    recommended = List.generate(40, (i) => drama('recommended-$i'));
  }

  @override
  CatalogPage pageFor(String source, String category, String query, int page) =>
      CatalogPage(List.generate(40, (i) => drama('$category-$i')));
}

class _EmptyCatalog extends _Catalog {
  _EmptyCatalog(this.fails);
  final bool fails;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    if (fails) throw const AppFailure('fixture unavailable');
    return CatalogPage(const []);
  }
}

Finder scrollFor(String tab) => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return widget is CustomScrollView &&
      key is PageStorageKey<(int, String?, String)> &&
      key.value.$3 == tab;
});

Finder heroFor(String tab) =>
    find.descendant(of: scrollFor(tab), matching: find.byType(ExploreHero));

bool hidden(WidgetTester tester) => tester
    .widget<ScrollChromeVisibility>(
      find.byKey(const ValueKey('explore-chrome-motion')),
    )
    .hidden;

void main() {
  for (final form in [FormFactor.phone, FormFactor.pad]) {
    testWidgets('真实外壳慢速横滑中和落定后均无顶部空白 $form', (tester) async {
      final size = form == FormFactor.phone
          ? const Size(390, 844)
          : const Size(1000, 900);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = await openStore();
      await store.saveWatch(watching(drama('resume')));
      final repository = _Catalog();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(padding: const EdgeInsets.only(top: 28, bottom: 24)),
            child: AppScope(
              repository: repository,
              formFactor: form,
              child: child!,
            ),
          ),
          home: AppShell(store: store),
        ),
      );
      await tester.pumpAndSettle();
      final pager = tester.getRect(find.byType(PageView));
      final first = tester
          .widget<CustomScrollView>(scrollFor('app:recommend'))
          .controller!;
      final offset =
          tester.getTopLeft(heroFor('app:recommend')).dy - pager.top - 4;
      first.jumpTo(offset);
      await tester.pumpAndSettle();
      expect(hidden(tester), isTrue);
      final collapsed = first.offset;
      final before = tester.getTopLeft(heroFor('app:recommend')).dy;
      final cancelled = await tester.startGesture(
        Offset(pager.right - 30, pager.center.dy),
      );
      await cancelled.moveBy(const Offset(-24, 0));
      await tester.pump();
      await cancelled.moveBy(Offset(-pager.width * .2, 0));
      await tester.pump();
      expect(
        tester.getTopLeft(heroFor('')).dy - pager.top,
        inInclusiveRange(-1, 18),
      );
      await cancelled.moveBy(Offset(pager.width * .2 + 24, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await cancelled.up();
      await tester.pumpAndSettle();
      expect(first.offset, collapsed);
      expect(
        tester.getTopLeft(heroFor('app:recommend')).dy,
        closeTo(before, .1),
      );
      expect(hidden(tester), isTrue);
      final gesture = await tester.startGesture(
        Offset(pager.right - 30, pager.center.dy),
      );
      await gesture.moveBy(const Offset(-24, 0));
      await tester.pump();
      await gesture.moveBy(Offset(-pager.width * .4, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      // 不松手、不等pumpAndSettle：直接测量正在进入视口的邻页。
      expect(
        tester.getTopLeft(heroFor('')).dy - pager.top,
        inInclusiveRange(-1, 18),
      );
      expect(hidden(tester), isTrue);
      await gesture.moveBy(Offset(-pager.width * .4, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CategoryTabs<String>>(find.byType(CategoryTabs<String>))
            .selected,
        '',
      );
      expect(hidden(tester), isTrue);
      expect(
        tester.getTopLeft(heroFor('')).dy - pager.top,
        inInclusiveRange(-1, 18),
      );
      // 折叠后的新页在0位置也能下拉展开，不需要先往下滚一大段。
      await tester.dragFrom(
        Offset(pager.center.dx, pager.top + 170),
        const Offset(0, 55),
      );
      await tester.pumpAndSettle();
      expect(hidden(tester), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  for (final fails in [false, true]) {
    testWidgets('无继续观看的空/失败分类保留折叠并可下拉展开 fails=$fails', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = await openStore();
      final repository = _EmptyCatalog(fails);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => AppScope(
            repository: repository,
            formFactor: FormFactor.phone,
            child: child!,
          ),
          home: AppShell(store: store),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .widget<CustomScrollView>(scrollFor('app:recommend'))
          .controller!
          .jumpTo(130);
      await tester.pumpAndSettle();
      expect(hidden(tester), isTrue);
      final pager = tester.getRect(find.byType(PageView));
      await tester.dragFrom(
        Offset(pager.right - 30, pager.center.dy),
        Offset(-pager.width * .75, 0),
      );
      await tester.pumpAndSettle();
      expect(hidden(tester), isTrue);
      expect(
        tester
            .widget<CategoryTabs<String>>(find.byType(CategoryTabs<String>))
            .selected,
        '',
      );
      expect(scrollFor(''), findsOneWidget);
      final inset = find.descendant(
        of: scrollFor(''),
        matching: find.byType(ExploreHeaderInset, skipOffstage: false),
        skipOffstage: false,
      );
      expect(tester.widget<ExploreHeaderInset>(inset).extent, 0);
      await tester.dragFrom(
        Offset(pager.center.dx, pager.top + 150),
        const Offset(0, 55),
      );
      await tester.pumpAndSettle();
      expect(hidden(tester), isFalse);
      expect(tester.widget<ExploreHeaderInset>(inset).extent, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/widgets/category_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('发现分类真实跟手，邻页数据与独立滚动、快速切换一致', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await openStore();
    final repo = FakeRepository()
      ..categoryList = const [
        CatalogCategory.all,
        CatalogCategory('tag:a', '甲'),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          repository: repo,
          formFactor: FormFactor.phone,
          child: ExplorePage(store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final pager = tester.widget<PageView>(find.byType(PageView)).controller!;
    final gesture = await tester.startGesture(const Offset(340, 500));
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump();
    expect(pager.page, inExclusiveRange(0, 1));
    final views = tester
        .widgetList<CustomScrollView>(find.byType(CustomScrollView))
        .toList();
    expect(views.length, greaterThanOrEqualTo(2));
    expect(views[0].controller, isNot(same(views[1].controller)));
    expect(find.text('分类'), findsOneWidget);
    await gesture.moveBy(const Offset(-160, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CategoryTabs<String>>(find.byType(CategoryTabs<String>))
          .selected,
      '',
    );
    expect(pager.page, closeTo(1, .001));
    await tester.tap(find.text('甲'));
    await tester.pump();
    await tester.tap(find.text('推荐'));
    await tester.pumpAndSettle();
    expect(pager.page, closeTo(0, .001));
    expect(
      tester
          .widget<CategoryTabs<String>>(find.byType(CategoryTabs<String>))
          .selected,
      'app:recommend',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

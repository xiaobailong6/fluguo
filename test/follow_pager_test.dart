import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/widgets/category_tabs.dart';
import 'package:duanju_app/ui/widgets/choice_panel.dart';
import 'package:duanju_app/ui/widgets/follow_pager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('拖动中邻页位移，松手分类与下划线使用同一页位置', (tester) async {
    final pager = PageController();
    addTearDown(pager.dispose);
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: StatefulBuilder(
            builder: (context, update) => Scaffold(
              body: Column(
                children: [
                  CategoryTabs<int>(
                    options: const [
                      ChoiceOption(0, '甲'),
                      ChoiceOption(1, '乙'),
                      ChoiceOption(2, '丙'),
                    ],
                    selected: selected,
                    pager: pager,
                    onSelected: (value) => update(() => selected = value),
                  ),
                  Expanded(
                    child: FollowPager(
                      index: selected,
                      count: 3,
                      controller: pager,
                      onSelected: (value) => update(() => selected = value),
                      itemBuilder: (_, index) => ColoredBox(
                        key: ValueKey('page-$index'),
                        color: Colors.white,
                        child: Center(child: Text('内容$index')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(650, 300));
    await gesture.moveBy(const Offset(-300, 0));
    await tester.pump();
    expect(pager.page, greaterThan(0));
    expect(pager.page, lessThan(1));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('page-0'))).dx,
      lessThan(0),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('page-1'))).dx,
      lessThan(800),
    );
    expect(
      tester.widget<CategoryTabs<int>>(find.byType(CategoryTabs<int>)).pager,
      same(pager),
    );
    await gesture.moveBy(const Offset(-280, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(pager.page, closeTo(1, .001));
    expect(
      tester.widget<CategoryTabs<int>>(find.byType(CategoryTabs<int>)).selected,
      1,
    );
    await tester.tap(find.text('丙'));
    await tester.pump();
    await tester.tap(find.text('甲'));
    await tester.pumpAndSettle();
    expect(selected, 0);
    expect(pager.page, closeTo(0, .001));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('减少动画、数据缩短和空页不越界，每页独立滚动控制器', (tester) async {
    var selected = 0;
    var count = 3;
    late StateSetter update;
    final pager = PageController();
    addTearDown(pager.dispose);
    final controllers = <int, ScrollController>{};
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: StatefulBuilder(
            builder: (context, setter) {
              update = setter;
              return FollowPager(
                index: selected,
                count: count,
                controller: pager,
                onSelected: (value) => update(() => selected = value),
                itemBuilder: (_, index) => PagerScrollPage(
                  key: ValueKey(index),
                  builder: (_, scroll) {
                    controllers[index] = scroll;
                    return ListView(
                      controller: scroll,
                      children: [Text('$index')],
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    update(() => selected = 2);
    await tester.pumpAndSettle();
    expect(pager.page, 2);
    expect(controllers[0], isNot(same(controllers[2])));
    update(() => count = 1);
    await tester.pumpAndSettle();
    expect(pager.page, 0);
    update(() => count = 0);
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('选集页高度跟随手势，短尾页及旋转不会溢出', (tester) async {
    final pager = PageController();
    addTearDown(pager.dispose);
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, update) => SingleChildScrollView(
            child: FollowPager(
              index: selected,
              count: 2,
              controller: pager,
              onSelected: (value) => update(() => selected = value),
              pageHeight: (index) => index == 0 ? 400 : 80,
              itemBuilder: (_, index) => SizedBox(
                key: ValueKey('group-$index'),
                height: index == 0 ? 400 : 80,
                child: Text('组$index'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(700, 60));
    await gesture.moveBy(const Offset(-320, 0));
    await tester.pump();
    final height = tester.getSize(find.byType(PageView)).height;
    expect(height, inExclusiveRange(80, 400));
    expect(find.byKey(const ValueKey('group-1')), findsOneWidget);
    await gesture.moveBy(const Offset(-340, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(tester.getSize(find.byType(PageView)).height, 80);
    await tester.binding.setSurfaceSize(const Size(500, 800));
    await tester.pumpAndSettle();
    expect(pager.page, closeTo(1, .001));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });
}

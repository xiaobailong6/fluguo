import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/widgets/recent_search_field.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  final menu = find.byKey(const ValueKey('recent-search-options'));
  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    double scale = 1,
  }) async {
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
          body: Align(alignment: Alignment.topRight, child: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空输入框聚焦显示历史，输入时隐藏，选择或提交后关闭', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final submitted = <String>[];
    await mount(
      tester,
      RecentSearchField(
        width: 280,
        hint: '搜索',
        controller: controller,
        recent: const ['第一条', '第二条'],
        onSubmitted: submitted.add,
      ),
    );
    expect(menu, findsNothing);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(menu, findsOneWidget);
    await tester.enterText(find.byType(TextField), '新词');
    await tester.pump();
    expect(menu, findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(submitted, ['新词']);
    controller.clear();
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二条'));
    await tester.pumpAndSettle();
    expect(submitted, ['新词', '第二条']);
    expect(menu, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Esc与点外部关闭，不误搜索；重新聚焦可以打开', (tester) async {
    var submissions = 0;
    await mount(
      tester,
      RecentSearchField(
        width: 280,
        hint: '搜索',
        recent: const ['历史'],
        onSubmitted: (_) => submissions++,
      ),
    );
    for (final escape in [true, false]) {
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(menu, findsOneWidget);
      if (escape) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.tapAt(const Offset(10, 500));
      }
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
    }
    expect(submissions, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Tab可进入历史项，Enter选择后关闭', (tester) async {
    String? selected;
    await mount(
      tester,
      RecentSearchField(
        width: 280,
        hint: '搜索',
        recent: const ['键盘记录'],
        onSubmitted: (query) => selected = query,
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(menu, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, '键盘记录');
    expect(menu, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('右键与长按删除不搜索，历史更新后保持弹层可用', (tester) async {
    var recent = ['甲', '乙', '丙'];
    var searches = 0;
    late StateSetter update;
    await mount(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return RecentSearchField(
            width: 280,
            hint: '搜索',
            recent: recent,
            onSubmitted: (_) => searches++,
            onForget: (query) => update(
              () => recent = recent.where((item) => item != query).toList(),
            ),
          );
        },
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.down(tester.getCenter(find.text('甲')));
    await mouse.up();
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(recent, ['乙', '丙']);
    expect(menu, findsOneWidget);
    await tester.longPress(find.text('乙'));
    await tester.pumpAndSettle();
    expect(recent, ['丙']);
    expect(searches, 0);
    expect(menu, findsOneWidget);
    await tester.longPress(find.text('丙'));
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('隐藏页面与禁用顶栏撤销弹层，恢复不擅自打开', (tester) async {
    var visible = true;
    var enabled = true;
    late StateSetter update;
    await mount(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return TickerMode(
            enabled: visible,
            child: RecentSearchField(
              width: 280,
              hint: '搜索',
              recent: const ['记录'],
              enabled: enabled,
              onSubmitted: (_) {},
            ),
          );
        },
      ),
    );
    for (final hide in [true, false]) {
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(menu, findsOneWidget);
      update(() {
        if (hide) {
          visible = false;
        } else {
          enabled = false;
        }
      });
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      update(() {
        visible = true;
        enabled = true;
      });
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('替换外部controller后旧输入不影响弹层且由调用方持有', (tester) async {
    final first = TextEditingController();
    final second = TextEditingController(text: '新输入');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    var controller = first;
    late StateSetter update;
    await mount(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return RecentSearchField(
            width: 280,
            hint: '搜索',
            controller: controller,
            recent: const ['记录'],
            onSubmitted: (_) {},
          );
        },
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    update(() => controller = second);
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    first.text = '旧输入';
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    second.clear();
    await tester.pumpAndSettle();
    expect(menu, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    second.text = '组件销毁后仍可使用';
    expect(tester.takeException(), isNull);
  });

  testWidgets('大字号与键盘下弹层不越过视口且列表可滚动', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 600);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    await mount(
      tester,
      RecentSearchField(
        width: 280,
        hint: '搜索',
        recent: List.generate(20, (i) => '记录$i'),
        onSubmitted: (_) {},
      ),
      scale: 2,
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final rect = tester.getRect(menu);
    expect(rect.right, lessThanOrEqualTo(700));
    expect(rect.bottom, lessThanOrEqualTo(300));
    await tester.drag(
      find.descendant(of: menu, matching: find.byType(ListView)),
      const Offset(0, -1200),
    );
    await tester.pumpAndSettle();
    expect(find.text('记录19').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

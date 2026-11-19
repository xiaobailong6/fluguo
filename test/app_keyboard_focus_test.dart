import 'package:duanju_app/ui/app.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  final desktop = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets('桌面根应用：Tab 聚焦普通按钮，Enter 和空格均可激活', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      DuanjuApp(
        repository: FakeRepository(),
        bootstrapError: '测试',
        onRetry: () => retries++,
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(Focus.of(tester.element(find.text('重新打开'))).hasPrimaryFocus, isTrue);
    expect(FocusManager.instance.highlightMode, FocusHighlightMode.traditional);
    for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
    expect(retries, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: desktop);

  testWidgets('桌面海报：可聚焦、菜单执行后焦点复原，翻页键仍滚动页面', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 820);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final store = await openStore();
    final repository = FakeRepository()
      ..recommended = List.generate(30, (i) => drama('键盘选片$i'));
    await tester.pumpWidget(DuanjuApp(store: store, repository: repository));
    await tester.pumpAndSettle();

    final poster = repository.recommended[1]; // 第一部是推荐大卡。
    final title = find.descendant(
      of: find.byType(DramaTile),
      matching: find.text(poster.title),
    );
    final node = Focus.of(tester.element(title));
    // 桌面不再由根组件吞掉 Tab：海报节点本身参与顺序遍历。
    expect(node.canRequestFocus, isTrue);
    expect(node.skipTraversal, isFalse);
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(node.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('poster-menu-opacity'));
    final action = find.descendant(of: panel, matching: find.text('追剧'));
    expect(Focus.of(tester.element(action)).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(store.isFavorite(poster.id), isTrue);
    expect(node.hasPrimaryFocus, isTrue);

    // 没有菜单键的键盘也能打开海报三点：Enter 打开、Esc 取消并还原焦点。
    final tile = find.ancestor(of: title, matching: find.byType(DramaTile));
    final more = find.descendant(
      of: tile,
      matching: find.byIcon(Icons.more_horiz_rounded),
    );
    final inner = Focus.of(tester.element(more));
    final menuButton = [
      inner,
      ...inner.ancestors,
    ].firstWhere((node) => node.canRequestFocus && !node.skipTraversal);
    menuButton.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: panel, matching: find.text('取消追剧')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(menuButton.hasPrimaryFocus, isTrue);

    final scroll = tester
        .widget<CustomScrollView>(
          find.descendant(
            of: find.byType(ExplorePage),
            matching: find.byType(CustomScrollView),
          ),
        )
        .controller!
        .position;
    final start = scroll.pixels;
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(scroll.pixels - start, closeTo(.8 * scroll.viewportDimension, 1));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }, variant: desktop);
}

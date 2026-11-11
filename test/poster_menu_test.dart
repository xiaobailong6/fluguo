import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/theme/glass_style.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:duanju_app/ui/widgets/poster_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('海报仅通过玻璃三点按钮打开菜单，坐标锚定按钮', (tester) async {
    Offset? anchor;
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              height: 320,
              child: ProgressPoster(
                drama: drama('menu'),
                width: 160,
                progress: 0,
                caption: '未观看',
                cover: const ColoredBox(color: Colors.grey),
                onTap: () => opens++,
                onMore: (point) => anchor = point,
              ),
            ),
          ),
        ),
      ),
    );
    final menu = find.byTooltip('追剧菜单');
    expect(menu, findsOneWidget);
    final glass = find.descendant(of: menu, matching: find.byType(GlassSurface));
    expect(glass, findsOneWidget);
    expect(tester.getSize(menu), const Size(44, 44));
    expect(tester.getSize(glass), const Size(30, 30));
    expect(tester.widget<Icon>(find.byIcon(Icons.more_horiz_rounded)).size, 18);
    final posterRect = tester.getRect(find.byType(ProgressPoster));
    expect(tester.getTopRight(glass), posterRect.topRight + const Offset(-6, 6));
    final poster = find.byType(ProgressPoster);
    await tester.longPressAt(tester.getTopLeft(poster) + const Offset(30, 80));
    await tester.pump();
    expect(anchor, isNull);
    final opensBeforeMenu = opens;
    final menuRect = tester.getRect(glass);
    await tester.tap(menu);
    await tester.pump();
    expect(anchor, menuRect.bottomRight);
    expect(opens, opensBeforeMenu);
    await tester.tapAt(tester.getTopLeft(poster) + const Offset(30, 80));
    expect(opens, opensBeforeMenu + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('短剧海报三点恢复原大小，弹窗菜单进一步紧凑且无横条', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: Scaffold(
          body: Builder(builder: (context) => Center(
            child: SizedBox(
              width: 160,
              child: DramaTile(
                drama: drama('compact'),
                onTap: () {},
                onMore: (anchor) => showPosterMenu(context, anchor, const [
                  PosterMenuItem('follow', '追剧', Icons.bookmark_rounded),
                  PosterMenuItem('remove', '移除', Icons.delete_outline_rounded),
                ]),
              ),
            ),
          )),
        ),
      ),
    );
    final button = find.byTooltip('追剧菜单');
    final chrome = find.descendant(of: button, matching: find.byType(GlassSurface));
    expect(tester.getSize(button), const Size(44, 44));
    expect(tester.getSize(chrome), const Size(30, 30));
    expect(tester.widget<Icon>(find.byIcon(Icons.more_horiz_rounded)).size, 18);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(Divider), findsNothing);
    final panel = find.byWidgetPredicate((widget) =>
        widget is GlassSurface && widget.role == GlassRole.panel);
    expect(panel, findsOneWidget);
    expect(tester.getSize(panel).width, lessThanOrEqualTo(220));
    expect(tester.widget<GlassSurface>(panel).padding, const EdgeInsets.all(3));
    final row = find.widgetWithText(InkWell, '追剧');
    expect(tester.getSize(row).height, 32);
    expect(tester.widget<Text>(find.text('追剧')).style!.fontSize, 14);
    expect(tester.widget<Icon>(find.byIcon(Icons.bookmark_rounded)).size, 18);
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(tester.takeException(), isNull);
  });
}

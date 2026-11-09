import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
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
    expect(find.ancestor(of: menu, matching: find.byType(GlassSurface)), findsOneWidget);
    final poster = find.byType(ProgressPoster);
    await tester.longPressAt(tester.getTopLeft(poster) + const Offset(30, 80));
    await tester.pump();
    expect(anchor, isNull);
    final opensBeforeMenu = opens;
    final menuRect = tester.getRect(menu);
    await tester.tap(menu);
    await tester.pump();
    expect(anchor, menuRect.bottomRight);
    expect(opens, opensBeforeMenu);
    await tester.tapAt(tester.getTopLeft(poster) + const Offset(30, 80));
    expect(opens, opensBeforeMenu + 1);
    expect(tester.takeException(), isNull);
  });
}

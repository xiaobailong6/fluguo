import 'package:duanju_app/models.dart';
import 'package:duanju_app/recent_history.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/theme/glass_style.dart';
import 'package:duanju_app/ui/widgets/cover_image.dart';
import 'package:duanju_app/ui/widgets/drama_grid.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:duanju_app/ui/widgets/follow_button.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:duanju_app/ui/widgets/recent_poster.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final recent in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('追剧心形即时刷新且菜单同宽 recent=$recent scale=$scale',
          (tester) async {
        // 使用禁用下载的访客，避免第二个四字菜单项掩盖追剧项宽度变化。
        final store = await openStore(viewerPreferences);
        final item = drama('follow-heart');
        await tester.pumpWidget(_app(Builder(builder: (context) {
          if (recent) {
            return Center(child: RecentPoster(
              store: store,
              entry: RecentEntry.drama(watching(item)),
              width: 160,
            ));
          }
          return CustomScrollView(slivers: [
            DramaSliverGrid(
              store: store,
              width: 800,
              items: [item],
              onOpen: (_) {},
              onMore: (entry) => showFollowMenu(
                context, store, entry.$1, entry.$2),
            ),
          ]);
        }), scale: scale));
        await tester.pumpAndSettle();
        expect(find.byType(FollowHeart), findsNothing);
        await tester.tap(find.byTooltip('追剧菜单'));
        await tester.pumpAndSettle();
        final before = tester.getSize(_panel).width;
        expect(before, greaterThanOrEqualTo(120 * scale));
        expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
        expect(find.text('下载剧集'), findsNothing);
        await tester.tap(find.text('追剧'));
        await tester.pumpAndSettle();
        expect(store.isFavorite(item.id), isTrue);
        expect(find.byType(FollowHeart), findsOneWidget);
        await tester.tap(find.byTooltip('追剧菜单'));
        await tester.pumpAndSettle();
        expect(find.text('取消追剧'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
        expect(tester.getSize(_panel).width, closeTo(before, .01));
        await tester.tap(find.text('取消追剧'));
        await tester.pumpAndSettle();
        expect(store.isFavorite(item.id), isFalse);
        expect(find.byType(FollowHeart), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('心形位于左上角且与排名和 VIP 分离', (tester) async {
    await tester.pumpWidget(_app(Center(child: SizedBox(
      width: 160,
      child: DramaTile(
        drama: const Drama(id: '', source: 'hongguo', title: '角标', vip: true),
        rank: 1,
        followed: true,
        onTap: () {},
      ),
    ))));
    final cover = tester.getRect(find.byType(DramaCover));
    final heart = tester.getRect(find.byType(FollowHeart));
    final rank = tester.getRect(find.byType(RankBadge));
    final vip = tester.getRect(find.byType(VipBadge));
    expect(heart.topLeft, cover.topLeft + const Offset(6, 6));
    expect(heart.overlaps(rank), isFalse);
    expect(heart.overlaps(vip), isFalse);
    expect(rank.overlaps(vip), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('进度海报追剧心形避开站源和更新标签', (tester) async {
    await tester.pumpWidget(_app(Center(child: ProgressPoster(
      drama: drama('progress-heart'),
      progress: .2,
      caption: '看到第 2 集',
      tag: '红果',
      badge: '3 集更新',
      followed: true,
      width: 160,
      cover: const ColoredBox(color: Colors.grey),
      onTap: () {},
      onMore: (_) {},
    ))));
    final heart = tester.getRect(find.byType(FollowHeart));
    expect(heart.overlaps(tester.getRect(find.text('红果'))), isFalse);
    expect(heart.overlaps(tester.getRect(find.text('3 集更新'))), isFalse);
    expect(find.byTooltip('追剧菜单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final _panel = find.byWidgetPredicate((widget) =>
    widget is GlassSurface && widget.role == GlassRole.panel);

Widget _app(Widget child, {double scale = 1}) => MaterialApp(
  builder: (context, child) => AppScope(
    repository: FakeRepository(),
    formFactor: FormFactor.phone,
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
  ),
  home: Scaffold(body: child),
);

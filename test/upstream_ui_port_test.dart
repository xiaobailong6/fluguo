import 'dart:io';

import 'package:duanju_app/explore_feed.dart';
import 'package:duanju_app/local_file_store.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_hero.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/follow/follow_page.dart';
import 'package:duanju_app/ui/history/history_page.dart';
import 'package:duanju_app/ui/widgets/drama_grid.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:duanju_app/ui/widgets/favorite_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Widget _app(Widget child, {FormFactor form = FormFactor.phone}) => MaterialApp(
  builder: (_, child) =>
      AppScope(repository: FakeRepository(), formFactor: form, child: child!),
  home: Scaffold(body: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('横幅开关不丢推荐、不额外取数，偏好重启和备份保持', () async {
    final store = await openStore();
    final repository = FakeRepository();
    final feed = ExploreFeed(repository, store)..setPrefetchActive(false);
    addTearDown(feed.dispose);
    await pumpEventQueue();
    expect(feed.featured, isNotNull);
    final requests = repository.recommendRequests.length;
    final all = [feed.featured!.id, ...feed.items.map((item) => item.id)];
    await store.setExploreBanner(false);
    expect(feed.featured, isNull);
    expect(feed.items.map((item) => item.id), all);
    await store.saveWatch(watching(drama('continue')));
    expect(feed.resume, isNull);
    expect(repository.recommendRequests.length, requests);
    expect(restartStore(store).exploreBanner, isFalse);
    final backup = await store.exportBackup();
    await store.setExploreBanner(true);
    expect(feed.resume!.drama.id, 'hongguo:continue');
    await store.importBackup(backup);
    expect(store.exploreBanner, isFalse);
    expect(feed.resume, isNull);
  });

  test('横幅开关兼容分文件存储', () async {
    final directory = await Directory.systemTemp.createTemp('banner-store-');
    addTearDown(() => directory.delete(recursive: true));
    final memory = await openStore();
    final store = LocalStore(
      memory.preferences,
      fileStore: LocalFileStore(directory),
      runWatchBatch: inlineWatchBatch,
    );
    addTearDown(store.dispose);
    await store.setExploreBanner(false);
    final reopened = await LocalStore.open(memory.preferences, directory);
    addTearDown(reopened.dispose);
    expect(reopened.exploreBanner, isFalse);
  });

  for (final form in [FormFactor.phone, FormFactor.window]) {
    for (final history in [false, true]) {
      testWidgets('空页和搜索无结果没有多余滚动范围 $form history=$history', (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final store = await openStore();
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await tester.pumpWidget(
          _app(
            history
                ? HistoryPage(store: store)
                : FollowPage(store: store, entryFocus: focus, onExitUp: () {}),
            form: form,
          ),
        );
        await tester.pumpAndSettle();
        final vertical = find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              ),
            )
            .first;
        ScrollPosition position() =>
            tester.state<ScrollableState>(vertical).position;
        expect(position().maxScrollExtent, closeTo(0, .01));
        await tester.runAsync(() async {
          for (var i = 0; i < 18; i++) {
            final item = drama('list-$i');
            if (history) {
              await store.saveWatch(watching(item));
            } else {
              await store.toggleFavorite(item);
            }
          }
        });
        await tester.pumpAndSettle();
        expect(position().maxScrollExtent, greaterThan(0));
        await tester.enterText(find.byType(TextField).first, '找不到的标题');
        await tester.pumpAndSettle();
        expect(position().maxScrollExtent, closeTo(0, .01));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('已看标题弱化不改变卡片尺寸，清历史后立即恢复', (tester) async {
    final store = await openStore();
    final item = drama('watched-style');
    await tester.pumpWidget(
      _app(
        CustomScrollView(
          slivers: [
            DramaSliverGrid(
              width: 800,
              items: [item],
              store: store,
              onOpen: (_) {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = tester.getSize(find.byType(DramaTile));
    final bold = tester.widget<Text>(find.text(item.title)).style!;
    await store.saveWatch(watching(item));
    await tester.pumpAndSettle();
    expect(tester.widget<DramaTile>(find.byType(DramaTile)).watched, isTrue);
    final watched = tester.widget<Text>(find.text(item.title)).style!;
    expect(watched.fontWeight, FontWeight.w400);
    expect(watched.color, isNot(bold.color));
    expect(tester.getSize(find.byType(DramaTile)), before);
    await store.removeHistory({item.id});
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(item.title)).style, bold);
  });

  testWidgets('已看状态离屏后恢复订阅；进度更新不重建标题', (tester) async {
    final store = await openStore();
    final item = drama('watched-listener');
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    var builds = 0;
    await tester.pumpWidget(
      _app(
        ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (_, active, child) =>
              TickerMode(enabled: active, child: child!),
          child: WatchedBuilder(
            store: store,
            id: item.id,
            builder: (_, value) {
              builds++;
              return Text(value ? '已看' : '未看');
            },
          ),
        ),
      ),
    );
    await store.saveWatch(watching(item));
    await tester.pump();
    expect(find.text('已看'), findsOneWidget);
    final previous = builds;
    await store.saveWatch(watching(item, position: 30), quiet: true);
    await tester.pump();
    expect(builds, previous);
    enabled.value = false;
    await tester.pump();
    await store.removeHistory({item.id});
    await tester.pump();
    expect(find.text('已看'), findsOneWidget);
    enabled.value = true;
    await tester.pump();
    expect(find.text('未看'), findsOneWidget);
  });

  testWidgets('发现页隐藏横幅后网格向上填充，重新开启恢复继续观看', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await openStore();
    await store.saveWatch(watching(drama('resume')));
    await tester.pumpWidget(_app(ExplorePage(store: store)));
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(find.byType(DramaTile).first).dy;
    expect(find.byType(ExploreHero), findsOneWidget);
    await store.setExploreBanner(false);
    await tester.pumpAndSettle();
    expect(find.byType(ExploreHero), findsNothing);
    expect(
      tester.getTopLeft(find.byType(DramaTile).first).dy,
      lessThan(top - 50),
    );
    await store.setExploreBanner(true);
    await tester.pumpAndSettle();
    expect(find.byType(ExploreHero), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

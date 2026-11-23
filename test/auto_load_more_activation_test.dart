import 'package:duanju_app/drama_feed.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/widgets/drama_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('自动翻页停用保持纵向视图，离屏不加载，激活后继续', (tester) async {
    final requests = <int>[];
    final feed = DramaFeed(
      load: (page, _) async {
        requests.add(page);
        return CatalogPage(
          [drama('page-$page')],
          page: page,
          hasMore: page < 3,
        );
      },
    );
    final scroll = ScrollController();
    final active = ValueNotifier(false);
    addTearDown(feed.dispose);
    addTearDown(scroll.dispose);
    addTearDown(active.dispose);
    await feed.reload();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, enabled, _) => AutoLoadMore(
              feed: feed,
              enabled: enabled,
              child: CustomScrollView(
                controller: scroll,
                slivers: const [
                  SliverToBoxAdapter(child: SizedBox(height: 1500)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final original = scroll.position;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(requests, [1]);
    active.value = true;
    await tester.pumpAndSettle();
    expect(requests, [1, 2, 3]);
    expect(scroll.position, same(original));
    active.value = false;
    await tester.pump();
    expect(scroll.position, same(original));
    await feed.reload();
    await tester.pumpAndSettle();
    expect(requests, [1, 2, 3, 1]);
    expect(scroll.position, same(original));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('切走页面取消已排队的自动翻页', (tester) async {
    final requests = <int>[];
    final feed = DramaFeed(
      load: (page, _) async {
        requests.add(page);
        return CatalogPage([drama('queued-$page')], page: page, hasMore: true);
      },
    );
    final scroll = ScrollController();
    final active = ValueNotifier(true);
    addTearDown(feed.dispose);
    addTearDown(scroll.dispose);
    addTearDown(active.dispose);
    await feed.reload();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, enabled, _) => AutoLoadMore(
              feed: feed,
              enabled: enabled,
              child: CustomScrollView(
                controller: scroll,
                slivers: const [
                  SliverToBoxAdapter(child: SizedBox(height: 2000)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, [1]);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    active.value = false;
    await tester.pumpAndSettle();
    expect(requests, [1]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

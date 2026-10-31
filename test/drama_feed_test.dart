import 'dart:async';

import 'package:duanju_app/drama_feed.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/widgets/drama_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  final a = drama('a'), b = drama('b'), c = drama('c');

  DramaFeed feedOf(DramaFeed feed) {
    addTearDown(feed.dispose);
    return feed;
  }

  test('stale cache shows first, then the first page replaces it', () async {
    final first = Completer<CatalogPage>();
    final feed = feedOf(
      DramaFeed(
        cached: () async => CatalogPage([a], page: 7, hasMore: true),
        load: (page, force) => first.future,
      ),
    );
    final reload = feed.reload();
    await pumpEventQueue();
    expect(feed.items, [a]);
    expect(feed.loading, isTrue);

    first.complete(CatalogPage([b], hasMore: true));
    await reload;
    expect(feed.items, [b]);
    expect(feed.loading, isFalse);
  });

  test('fresh cache skips the network and continues its page', () async {
    final pages = <int>[];
    final feed = feedOf(
      DramaFeed(
        cached: () async =>
            CatalogPage([a], page: 7, hasMore: true, fresh: true),
        load: (page, force) async {
          pages.add(page);
          return CatalogPage([b], page: page);
        },
      ),
    );
    await feed.reload();
    expect(pages, isEmpty);
    await feed.loadMore();
    expect(pages, [8]);
    expect(feed.items, [a, b]);
    expect(feed.hasMore, isFalse);
  });

  test('forced reloads skip the cache', () async {
    final forced = <bool>[];
    final feed = feedOf(
      DramaFeed(
        cached: () async => CatalogPage([a], fresh: true),
        load: (page, force) async {
          forced.add(force);
          return CatalogPage([b]);
        },
      ),
    );
    await feed.reload(force: true);
    expect(forced, [true]);
    expect(feed.items, [b]);
  });

  test('pages merge without repeats and a warning retries its page', () async {
    final pages = <int>[];
    final feed = feedOf(
      DramaFeed(
        load: (page, force) async {
          pages.add(page);
          return page == 1
              ? CatalogPage([a, b], hasMore: true)
              : CatalogPage([b, c], page: 2, warning: '部分失败');
        },
      ),
    );
    await feed.reload();
    await feed.loadMore();
    expect(feed.items, [a, b, c]);
    expect(feed.error, '部分失败');
    expect(feed.hasMore, isTrue);
    expect(feed.canLoadMore, isFalse);

    await feed.loadMore();
    expect(pages, [1, 2, 2]);
  });

  test('cumulative feeds replace their items with each answer', () async {
    final feed = feedOf(
      DramaFeed(
        cumulative: true,
        load: (page, force) async =>
            CatalogPage(page == 1 ? [a] : [a, b], hasMore: page == 1),
      ),
    );
    await feed.reload();
    await feed.loadMore();
    expect(feed.items, [a, b]);
  });

  test('an older answer never overwrites a newer reload', () async {
    final answers = <Completer<CatalogPage>>[];
    final feed = feedOf(
      DramaFeed(
        load: (page, force) {
          answers.add(Completer());
          return answers.last.future;
        },
      ),
    );
    final older = feed.reload();
    final newer = feed.reload();
    answers[1].complete(CatalogPage([b]));
    await newer;
    answers[0].complete(CatalogPage([a]));
    await older;
    expect(feed.items, [b]);
  });

  test('a failure is shown until the next reload succeeds', () async {
    var fail = true;
    final feed = feedOf(
      DramaFeed(
        load: (page, force) async =>
            fail ? throw StateError('网络错误') : CatalogPage([a]),
      ),
    );
    await feed.reload();
    expect(feed.items, isEmpty);
    expect(feed.error, contains('网络错误'));

    fail = false;
    await feed.reload(force: true);
    expect(feed.error, isEmpty);
    expect(feed.items, [a]);
  });
  testWidgets('刷新失败保留旧列表，页脚重试第一页而非下一页', (tester) async {
    final pages = <(int, bool)>[];
    var fail = false;
    final feed = feedOf(
      DramaFeed(
        load: (page, force) async {
          pages.add((page, force));
          if (fail) throw StateError('刷新失败');
          return CatalogPage([a], hasMore: true);
        },
      ),
    );
    await feed.reload();
    fail = true;
    await feed.reload(force: true);
    expect(feed.items, [a]);
    expect(feed.canLoadMore, isFalse);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: Scaffold(body: FeedFooter(feed: feed)),
      ),
    );
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(pages, [(1, false), (1, true), (1, true)]);
    expect(feed.error, isEmpty);
  });

  test('分页失败重试仍请求失败页，第一页警告重试强制刷新', () async {
    final pages = <(int, bool)>[];
    var fail = false;
    var warning = false;
    final feed = feedOf(
      DramaFeed(
        load: (page, force) async {
          pages.add((page, force));
          if (fail) throw StateError('分页失败');
          return CatalogPage(
            [a],
            page: page,
            hasMore: true,
            warning: warning ? '部分失败' : '',
          );
        },
      ),
    );
    await feed.reload();
    fail = true;
    await feed.loadMore();
    fail = false;
    await feed.retry();
    expect(pages, [(1, false), (2, false), (2, false)]);
    warning = true;
    await feed.reload();
    warning = false;
    await feed.retry();
    expect(pages.last, (1, true));
    expect(feed.error, isEmpty);
  });
}

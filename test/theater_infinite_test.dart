import 'dart:async';
import 'dart:math';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/theater_feed.dart';
import 'package:duanju_app/theater_recommendations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fakes.dart';

class PagedTheaterRepository extends FakeRepository {
  int pages = 80;
  int recommendationPage = 0;
  int calls = 0;
  bool fails = false;
  Completer<CatalogPage>? held;
  final moreFlags = <bool>[];
  final catalogPages = <int>[];
  Future<CatalogPage> result(String source, int page) async {
    calls++;
    if (fails) throw StateError('offline');
    final pending = held;
    held = null;
    if (pending != null) return pending.future;
    return CatalogPage(
      [
        for (var i = 0; i < 10; i++) drama('$page-$i', source: source),
        drama('$page-0', source: source),
      ],
      page: page,
      hasMore: page < pages,
    );
  }

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) {
    moreFlags.add(more);
    recommendationPage = more ? recommendationPage + 1 : 1;
    return result('hongguo', recommendationPage);
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) {
    catalogPages.add(page);
    return result(source, page);
  }
}

Future<void> ready(TheaterFeed feed) async {
  for (var i = 0; i < 1000 && feed.loading; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(feed.loading, false);
}

Future<List<String>> swipe(TheaterFeed feed, int count) async {
  var index = 0;
  final seen = <String>[];
  for (var i = 0; i < count; i++) {
    expect(index, lessThan(feed.items.length));
    final current = feed.items[index];
    seen.add(theaterIdentity(current.drama));
    feed.position(index);
    if (index >= feed.items.length - 4) {
      await feed.loadMore();
      index = feed.items.indexOf(current);
      expect(index, greaterThanOrEqualTo(0));
      expect(feed.items.length, lessThanOrEqualTo(60));
      expect(feed.candidateCount, lessThanOrEqualTo(600));
    }
    index++;
  }
  return seen;
}

Future<LocalStore> theaterStore() async {
  final store = await openStore();
  for (final source in store.sources.toList()) {
    if (source.id != 'hongguo') await store.setSourceEnabled(source.id, false);
  }
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final count in [30, 100, 800]) {
    test('连续滑动$count项，分页去重且队列/候选有界', () async {
      final store = await theaterStore();
      final repo = PagedTheaterRepository();
      final feed = TheaterFeed(repo, store, random: Random(3));
      addTearDown(feed.dispose);
      await ready(feed);
      final seen = await swipe(feed, count);
      expect(seen.toSet().length, count);
      expect(repo.catalogPages.any((p) => p > 1), true);
      expect(repo.moreFlags, contains(true));
    });
  }

  test('有限目录循环但不恢复隐藏和已完成内容', () async {
    final store = await theaterStore();
    final repo = PagedTheaterRepository()..pages = 1;
    final feed = TheaterFeed(repo, store, random: Random(1));
    addTearDown(feed.dispose);
    await ready(feed);
    final hidden = feed.items.first.drama;
    await feed.hide(hidden);
    final done = feed.items.first.drama;
    await store.saveWatch(
      watching(done, episode: done.episodes, position: 100),
    );
    // 原队列保持不变；新 append 的候选必须按最新历史过滤。
    feed.position(feed.items.length - 1);
    final original = feed.items.toSet();
    await feed.loadMore();
    final appended = feed.items.where((p) => !original.contains(p));
    expect(appended, isNotEmpty);
    expect(
      appended.any(
        (p) =>
            theaterIdentity(p.drama) == theaterIdentity(hidden) ||
            theaterIdentity(p.drama) == theaterIdentity(done),
      ),
      false,
    );
    final calls = repo.calls;
    await swipe(feed, 100);
    expect(repo.calls, calls);
  });

  test('失败不自旋，可显式重试，loadingMore防并发', () async {
    final store = await theaterStore();
    final repo = PagedTheaterRepository();
    final feed = TheaterFeed(repo, store);
    addTearDown(feed.dispose);
    await ready(feed);
    repo.fails = true;
    for (var i = 0; i < 10 && feed.error == null; i++) {
      feed.position(feed.items.length - 1);
      await feed.loadMore();
    }
    expect(feed.error, isNotNull);
    final calls = repo.calls;
    await feed.loadMore();
    expect(repo.calls, calls);
    repo.fails = false;
    repo.held = Completer<CatalogPage>();
    final held = repo.held!;
    final pending = feed.loadMore(retry: true);
    await Future<void>.delayed(Duration.zero);
    final before = repo.calls;
    await feed.loadMore(retry: true);
    expect(repo.calls, before);
    held.complete(CatalogPage([drama('retry')], hasMore: false));
    await pending;
    expect(feed.error, isNull);
    expect(feed.loadingMore, false);
  });

  test('append迟到响应在撤销来源权限后丢弃', () async {
    final store = await theaterStore();
    final repo = PagedTheaterRepository();
    final feed = TheaterFeed(repo, store);
    addTearDown(feed.dispose);
    await ready(feed);
    repo.held = Completer<CatalogPage>();
    final held = repo.held!;
    feed.position(feed.items.length - 1);
    final pending = feed.loadMore();
    await Future<void>.delayed(Duration.zero);
    await store.setSourceEnabled('hongguo', false);
    held.complete(CatalogPage([drama('late')]));
    await pending;
    await ready(feed);
    expect(feed.items.any((p) => p.drama.source == 'hongguo'), false);
  });
}

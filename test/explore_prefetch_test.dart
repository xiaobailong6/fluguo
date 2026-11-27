import 'dart:async';
import 'dart:convert';
import 'package:duanju_app/local_profiles.dart';

import 'package:duanju_app/explore_feed.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _HeldCatalog extends FakeRepository {
  final pending = <String, Completer<CatalogPage>>{};
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) {
    catalogRequests.add(category);
    return (pending[category] = Completer<CatalogPage>()).future;
  }
}

class _SizedCatalog extends FakeRepository {
  _SizedCatalog(this.sizes);
  final Map<String, int> sizes;

  @override
  CatalogPage pageFor(String source, String category, String query, int page) =>
      CatalogPage(
        [
          for (var i = 0; i < (sizes[category] ?? 3); i++)
            drama('$category-$page-$i'),
        ],
        page: page,
        hasMore: page < 4,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('总条目预算淘汰最久未用分类，当前分页不截断', () async {
    final store = await openStore();
    final repo = _SizedCatalog({})
      ..recommended = []
      ..categoryList = const [
        CatalogCategory.all,
        CatalogCategory('a', '甲'),
        CatalogCategory('b', '乙'),
        CatalogCategory('c', '丙'),
      ];
    final explore = ExploreFeed(repo, store, cacheItemLimit: 8)
      ..setPrefetchActive(false);
    addTearDown(explore.dispose);
    await pumpEventQueue();
    for (final id in ['a', 'b', 'c']) {
      explore.select(id);
      await pumpEventQueue();
    }
    expect(explore.retainedItemCount, 6);
    expect(explore.feedOf(const CatalogCategory('a', '甲')), isNull);
    final b = explore.feedOf(const CatalogCategory('b', '乙'));
    explore.select('b');
    await pumpEventQueue();
    expect(explore.feed, same(b));
    await explore.feed!.loadMore();
    await explore.feed!.loadMore();
    await pumpEventQueue();
    expect(explore.feed!.items, hasLength(9));
    expect(explore.keptTabCount, 0);
    explore.select('a');
    await pumpEventQueue();
    expect(explore.feed!.items, hasLength(3));
    expect(explore.retainedItemCount, lessThanOrEqualTo(8));
    expect(explore.feedOf(const CatalogCategory('b', '乙')), isNull);
  });

  test('超大邻页淘汰后不循环预取，显式进入仍可加载', () async {
    final store = await openStore();
    await store.rememberCatalogCategory(
      'hongguo',
      'b',
      profileEpoch: store.profileEpoch,
    );
    final repo = _SizedCatalog({'a': 10, 'b': 1, 'c': 10})
      ..recommended = []
      ..categoryList = const [
        CatalogCategory.all,
        CatalogCategory('a', '甲'),
        CatalogCategory('b', '乙'),
        CatalogCategory('c', '丙'),
      ];
    final explore = ExploreFeed(repo, store, cacheItemLimit: 4);
    addTearDown(explore.dispose);
    await pumpEventQueue();
    expect(repo.catalogRequests, hasLength(3));
    expect(explore.retainedItemCount, 1);
    await pumpEventQueue();
    expect(repo.catalogRequests, hasLength(3));
    explore.select('a');
    await pumpEventQueue();
    expect(explore.feed!.items, hasLength(10));
    expect(explore.keptTabCount, 0);
  });

  test('推荐网格派生列表复用，换数据后更新', () async {
    final store = await openStore();
    final repo = FakeRepository();
    final explore = ExploreFeed(repo, store)..setPrefetchActive(false);
    addTearDown(explore.dispose);
    await pumpEventQueue();
    final first = explore.items;
    expect(explore.itemsIn(recommendTab), same(first));
    expect(explore.items, same(first));
    repo.recommended = [drama('new-hero'), drama('new-item')];
    await explore.refresh();
    expect(explore.items.single.id, 'hongguo:new-item');
    expect(explore.items, isNot(same(first)));
  });

  test('隐藏时不启动邻页预取，恢复后按两路上限继续', () async {
    final store = await openStore();
    await store.rememberCatalogCategory(
      'hongguo',
      'b',
      profileEpoch: store.profileEpoch,
    );
    final repo = _HeldCatalog()
      ..recommended = []
      ..categoryList = const [
        CatalogCategory.all,
        CatalogCategory('a', '甲'),
        CatalogCategory('b', '乙'),
        CatalogCategory('c', '丙'),
      ];
    final explore = ExploreFeed(repo, store);
    addTearDown(explore.dispose);
    await pumpEventQueue();
    explore.setPrefetchActive(false);
    repo.pending['b']!.complete(CatalogPage([drama('b')]));
    await pumpEventQueue();
    expect(repo.catalogRequests, ['b']);
    explore.setPrefetchActive(true);
    await pumpEventQueue();
    expect(repo.catalogRequests, ['b', 'a', 'c']);
    explore.setPrefetchActive(false);
    expect(repo.cancelledExploreLanes, hasLength(2));
    repo.pending['a']!.complete(CatalogPage([drama('a')]));
    repo.pending['c']!.complete(CatalogPage([drama('c')]));
    await pumpEventQueue();
    expect(repo.catalogRequests, ['b', 'a', 'c']);
    expect(explore.feedOf(const CatalogCategory('a', '甲')), isNull);
  });

  test('成功后仅预取两侧，lane 独立；切换取消旧任务且最新目标优先', () async {
    final store = await openStore();
    await store.rememberCatalogCategory(
      'hongguo',
      'b',
      profileEpoch: store.profileEpoch,
    );
    final repo = _HeldCatalog()
      ..recommended = []
      ..categoryList = const [
        CatalogCategory.all,
        CatalogCategory('a', '甲'),
        CatalogCategory('b', '乙'),
        CatalogCategory('c', '丙'),
        CatalogCategory('d', '丁'),
      ];
    final explore = ExploreFeed(repo, store);
    addTearDown(explore.dispose);
    await pumpEventQueue();
    expect(repo.catalogRequests, ['b']);
    expect(explore.feedOf(const CatalogCategory('a', '甲')), isNull);
    repo.pending['b']!.complete(CatalogPage([drama('b')]));
    await pumpEventQueue();
    expect(repo.catalogRequests, ['b', 'a', 'c']);
    expect(repo.catalogLanes.map((item) => item.lane).toSet(), hasLength(3));
    explore.select('d');
    await pumpEventQueue();
    expect(repo.cancelledExploreLanes, hasLength(2));
    repo.pending['a']!.complete(CatalogPage([drama('late-a')]));
    repo.pending['c']!.complete(CatalogPage([drama('late-c')]));
    repo.pending['d']!.complete(CatalogPage([]));
    await pumpEventQueue();
    expect(explore.tab.id, 'd');
    expect(explore.feed!.items, isEmpty);
    expect(explore.feedOf(const CatalogCategory('a', '甲')), isNull);
    expect(repo.catalogRequests, ['b', 'a', 'c', 'd']);
  });

  test('缓存最多六个，清缓存与撤销权限丢弃预取', () async {
    final store = await openStore();
    final repo = FakeRepository()
      ..categoryList = [
        CatalogCategory.all,
        for (var i = 0; i < 15; i++) CatalogCategory('c$i', '分类$i'),
      ];
    final explore = ExploreFeed(repo, store);
    addTearDown(explore.dispose);
    await pumpEventQueue();
    for (var i = 0; i < 15; i++) {
      explore.select('c$i');
      await pumpEventQueue();
      expect(explore.keptTabCount, lessThanOrEqualTo(6));
    }
    final previous = explore.feed;
    repo.cacheChanges.value++;
    await pumpEventQueue();
    expect(explore.feed, isNot(same(previous)));
    await store.setSourceEnabled('hongguo', false);
    await pumpEventQueue();
    expect(explore.source?.id, isNot('hongguo'));
    expect(explore.feedOf(const CatalogCategory('c14', '分类14')), isNull);
    expect(repo.cancelledExploreLanes, isNotEmpty);
  });

  test('空数据与错误不预取，不循环后台重试', () async {
    final store = await openStore();
    final repo = _HeldCatalog()..recommended = [];
    final explore = ExploreFeed(repo, store);
    addTearDown(explore.dispose);
    await pumpEventQueue();
    expect(repo.catalogRequests, isEmpty);
    explore.select('short_play');
    await pumpEventQueue();
    repo.pending['short_play']!.completeError(StateError('offline'));
    await pumpEventQueue();
    expect(explore.feed!.error, isNotEmpty);
    expect(repo.catalogRequests, ['short_play']);
  });

  test('换用户拒绝迟到结果', () async {
    final store = await openStore({
      ...viewerPreferences,
      'profiles': jsonEncode([
        ...(jsonDecode(viewerPreferences['profiles'] as String) as List),
        const LocalProfile(
          id: 'other',
          name: '另一用户',
          sources: ['hongguo'],
        ).toJson(),
      ]),
    });
    final repo = _HeldCatalog()..recommended = [];
    final explore = ExploreFeed(repo, store);
    addTearDown(explore.dispose);
    await pumpEventQueue();
    explore.select('short_play');
    await pumpEventQueue();
    final previous = explore.feed;
    final pending = repo.pending['short_play']!;
    await store.switchProfile('other');
    pending.complete(CatalogPage([drama('private')]));
    await pumpEventQueue();
    expect(
      explore.items.where((item) => item.id == 'hongguo:private'),
      isEmpty,
    );
    expect(explore.feed, isNot(same(previous)));
    expect(repo.cancelledExploreLanes, isNotEmpty);
  });
}

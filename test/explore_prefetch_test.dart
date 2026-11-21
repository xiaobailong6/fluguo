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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

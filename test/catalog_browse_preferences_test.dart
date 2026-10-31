import 'dart:async';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/explore_feed.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _DelayedCategories extends FakeRepository {
  final response = Completer<List<CatalogCategory>>();
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) => response.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('分类重启按站源恢复，站源沿用持久化设置', () async {
    final store = await openStore();
    final feed = ExploreFeed(FakeRepository(), store);
    await pumpEventQueue();
    feed.select('short_play');
    await pumpEventQueue();
    expect(store.catalogCategory('hongguo'), 'short_play');
    feed.dispose();
    final reopened = restartStore(store);
    final next = ExploreFeed(FakeRepository(), reopened);
    addTearDown(next.dispose);
    await pumpEventQueue();
    expect(next.tab.id, 'short_play');
    if (allSourcesEnabled) {
      await reopened.setCatalogSource('hanxiaoquan');
      await pumpEventQueue();
      next.select('short_play');
      await pumpEventQueue();
      await reopened.setCatalogSource('hongguo');
      await pumpEventQueue();
      expect(next.tab.id, 'short_play');
      expect(restartStore(reopened).source, 'hongguo');
    }
  });

  test('失效分类回退默认，损坏数据不阻止启动', () async {
    final store = await openStore();
    await store.rememberCatalogCategory(
      'hongguo',
      'removed',
      profileEpoch: store.profileEpoch,
    );
    final feed = ExploreFeed(FakeRepository(), store);
    addTearDown(feed.dispose);
    await pumpEventQueue();
    expect(feed.tab, recommendTab);
    expect(store.catalogCategory('hongguo'), recommendTab.id);
    final corrupt = await openStore({'catalogCategories.default': 'invalid'});
    expect(corrupt.catalogCategory('hongguo'), isNull);
  });

  test('迟到分类不覆盖用户手动选择', () async {
    final store = await openStore();
    await store.rememberCatalogCategory(
      'hongguo',
      'short_play',
      profileEpoch: store.profileEpoch,
    );
    final repository = _DelayedCategories();
    final feed = ExploreFeed(repository, store);
    addTearDown(feed.dispose);
    feed.select('');
    repository.response.complete(repository.categoryList);
    await pumpEventQueue();
    expect(feed.tab.id, '');
    expect(store.catalogCategory('hongguo'), '');
  });

  test('用户隔离及旧epoch写入保护', () async {
    final profiles = {...viewerPreferences};
    final store = await openStore(profiles);
    final epoch = store.profileEpoch;
    await store.rememberCatalogCategory(
      'hongguo',
      'short_play',
      profileEpoch: epoch,
    );
    expect(store.catalogCategory('hongguo'), 'short_play');
    await store.rememberCatalogCategory(
      'hongguo',
      'late',
      profileEpoch: epoch - 1,
    );
    expect(store.catalogCategory('hongguo'), 'short_play');
    final admin = LocalStore(store.preferences);
    addTearDown(admin.dispose);
    // 重新载入仍保持访客的用户级偏好。
    expect(admin.catalogCategory('hongguo'), 'short_play');
    final separate = await openStore();
    expect(separate.catalogCategory('hongguo'), isNull);
  });
  test('分类网络失败不覆盖保存值，重开成功后恢复', () async {
    final store = await openStore();
    await store.rememberCatalogCategory(
      'hongguo',
      'short_play',
      profileEpoch: store.profileEpoch,
    );
    final repo = _DelayedCategories();
    final feed = ExploreFeed(repo, store);
    await pumpEventQueue();
    repo.response.completeError(StateError('离线'));
    await pumpEventQueue();
    expect(store.catalogCategory('hongguo'), 'short_play');
    feed.dispose();
    final next = ExploreFeed(FakeRepository(), store);
    addTearDown(next.dispose);
    await pumpEventQueue();
    expect(next.tab.id, 'short_play');
  });
}

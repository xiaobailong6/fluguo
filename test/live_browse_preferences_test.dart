import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/live_bilibili.dart';
import 'package:duanju_app/live_browse_preferences.dart';
import 'package:duanju_app/live_feed.dart';
import 'package:duanju_app/local_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'live_feed_test.dart' show FakeLive, parent;
import 'support/fakes.dart';

const second = LiveCategory(name: '第二类', parentId: 'second');

class FailingBrowseStore extends LocalStore {
  FailingBrowseStore(super.preferences);

  @override
  Future<void> rememberLiveBrowse(
    String platformId,
    String? categoryId, {
    required int profileEpoch,
  }) async => throw StateError('保存失败');
}

void main() {
  test('旧快照、坏字段安全默认，序列化只包含稳定标识', () async {
    final store = await openStore();
    expect(store.liveBrowsePreferences.platformId, isEmpty);
    final value = LiveBrowsePreferences.fromJson({
      'platformId': 'douyu',
      'categoryIds': {'douyu': 'second'},
    });
    expect(value.toJson(), {
      'platformId': 'douyu',
      'categoryIds': {'douyu': 'second'},
    });
    expect(
      () => LiveBrowsePreferences.fromJson({
        'categoryIds': {'douyu': 2},
      }),
      throwsFormatException,
    );
    final corrupt = await openStore({'liveBrowsePreferences.default': 'bad'});
    expect(corrupt.liveBrowsePreferences.categoryIds, isEmpty);
  });

  test('独立用户设置重启恢复，不覆盖播放配置', () async {
    final store = await openStore();
    final playback = store.playbackPreferences.toJson();
    await store.rememberLiveBrowse(
      'douyu',
      'a',
      profileEpoch: store.profileEpoch,
    );
    await store.rememberLiveBrowse(
      'bilibili',
      'b',
      profileEpoch: store.profileEpoch,
    );
    final reopened = LocalStore(store.preferences);
    addTearDown(reopened.dispose);
    expect(reopened.liveBrowsePreferences.platformId, 'bilibili');
    expect(reopened.liveBrowsePreferences.categoryIds, {
      'douyu': 'a',
      'bilibili': 'b',
    });
    expect(reopened.playbackPreferences.toJson(), playback);
  });

  test('异步分类按 ID 恢复新对象，切回平台不先显示首类，删除后回首类', () async {
    final store = await openStore();
    await store.rememberLiveBrowse(
      'a',
      'second',
      profileEpoch: store.profileEpoch,
    );
    final response = Completer<List<LiveCategory>>();
    final a = FakeLive(key: 'a')..onCategories = () => response.future;
    final b = FakeLive(key: 'b');
    final feed = LiveFeed(a, store: store);
    addTearDown(feed.dispose);
    final starting = feed.start();
    expect(feed.category, isNull);
    response.complete(const [parent, second]);
    await starting;
    expect(feed.category, same(second));
    await feed.switchPlatform(b);
    expect(feed.category, parent);
    a.onCategories = () async => [
      parent,
      const LiveCategory(name: '重命名', parentId: 'second'),
    ];
    await feed.switchPlatform(a);
    expect(feed.category?.name, '重命名');
    await feed.select(parent);
    await feed.select(second);
    a.onCategories = () async => [parent];
    await feed.refresh();
    expect(feed.category, parent);
    expect(a.calls, isEmpty);
    expect(b.calls, isEmpty);
  });

  test('保存失败不破坏分类、二级列表和搜索结果', () async {
    final original = await openStore();
    final store = FailingBrowseStore(original.preferences);
    addTearDown(store.dispose);
    final platform = FakeLive()..onCategories = () async => [parent, second];
    final feed = LiveFeed(platform, store: store);
    addTearDown(feed.dispose);
    await feed.start();
    await feed.select(second);
    expect(feed.category, second);
    expect(feed.error, isEmpty);
    await feed.select(parent);
    expect(feed.areas, parent.children);
    await feed.search('直播');
    await Future<void>.delayed(Duration.zero);
    expect(feed.rooms, isNotEmpty);
    expect(feed.error, isEmpty);
  });

  test('锁定与旧 epoch 拒绝偏好写入并忽略迟到分类', () async {
    final store = await openStore({
      ...viewerPreferences,
      'activeProfile': 'default',
      'forceLogin': false,
    });
    final epoch = store.profileEpoch;
    final response = Completer<List<LiveCategory>>();
    final feed = LiveFeed(
      FakeLive()..onCategories = () => response.future,
      store: store,
    );
    addTearDown(feed.dispose);
    final starting = feed.start();
    store.lock();
    response.complete(const [parent, second]);
    await starting;
    await store.rememberLiveBrowse('douyu', 'second', profileEpoch: epoch);
    expect(feed.categories, isEmpty);
    expect(store.liveBrowsePreferences.platformId, isEmpty);
  });

  test('用户隔离，旧用户回调不可写入新用户', () async {
    final profiles =
        jsonDecode(viewerPreferences['profiles'] as String) as List;
    profiles.add({
      ...Map<String, dynamic>.from(profiles.last as Map),
      'id': 'other',
    });
    final store = await openStore({
      ...viewerPreferences,
      'profiles': jsonEncode(profiles),
    });
    final oldEpoch = store.profileEpoch;
    await store.rememberLiveBrowse('douyu', 'second', profileEpoch: oldEpoch);
    await store.switchProfile('other');
    expect(store.liveBrowsePreferences.platformId, isEmpty);
    await store.rememberLiveBrowse('bilibili', 'late', profileEpoch: oldEpoch);
    expect(store.liveBrowsePreferences.categoryIds, isEmpty);
    await store.switchProfile('viewer');
    expect(store.liveBrowsePreferences.platformId, 'douyu');
    expect(
      jsonEncode(store.liveBrowsePreferences.toJson()),
      isNot(contains('url')),
    );
  });
}

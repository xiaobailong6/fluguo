import 'package:duanju_app/explore_feed.dart';
import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/theater_cache.dart';
import 'package:duanju_app/theater_feed.dart';
import 'package:duanju_app/theater_preview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'theater_test.dart'
    show PreviewRepository, FakePreviewBackend, flushPreview;

class BlockedCatalog extends PreviewRepository {
  final held = Completer<CatalogPage>();
  final forces = <bool>[];
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) =>
      held.future;
  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) {
    forces.add(force);
    return held.future;
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) => held.future;
  void finish() {
    if (!held.isCompleted) held.complete(CatalogPage(const [], hasMore: false));
  }
}

class PausableCatalog extends BlockedCatalog {
  int caches = 0;
  int categoriesRead = 0;
  int catalogs = 0;
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) {
    caches++;
    return super.cached(source, category: category);
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    categoriesRead++;
    return const [];
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) {
    catalogs++;
    return super.catalog(
      source,
      page: page,
      query: query,
      category: category,
      force: force,
    );
  }
}

void main() {
  test('隐藏后旧缓存响应不派生后续目录/分类，恢复可继续', () async {
    final store = await openStore();
    final repo = PausableCatalog();
    final feed = TheaterFeed(repo, store);
    await flushPreview();
    expect(repo.caches, 1);
    expect(repo.forces.length, 1);
    feed.setActive(false);
    repo.finish();
    await flushPreview();
    expect(repo.caches, 1);
    expect(repo.categoriesRead, 0);
    expect(repo.catalogs, 0);
    expect(repo.forces.length, 1);
    feed.setActive(true);
    await flushPreview();
    expect(repo.forces.length, greaterThan(1));
    feed.dispose();
  });

  test('暂停清除详情引用，恢复重新读取并保留预览秒数', () async {
    final store = await openStore();
    final repo = PreviewRepository();
    final backend = FakePreviewBackend();
    final preview = TheaterPreview(repo, store, backend: () => backend);
    preview.select(drama('resume-fresh'));
    preview.setVisible(true);
    await flushPreview();
    backend.position = const Duration(seconds: 18);
    await preview.suspend();
    expect(preview.detail, isNull);
    expect(backend.playing, isFalse);
    preview.setVisible(true);
    await flushPreview();
    expect(
      repo.requested.where((id) => id == drama('resume-fresh').id).length,
      2,
    );
    expect(backend.opens.last, const Duration(seconds: 18));
    expect(backend.playing, isTrue);
    preview.dispose();
    await flushPreview();
  });

  test('短剧页已加载卡片预热剧场，无额外目录请求', () async {
    final store = await openStore();
    final repo = PreviewRepository();
    final explore = ExploreFeed(repo, store);
    addTearDown(explore.dispose);
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(repo.recommendRequests.length, 1);
    final cache = TheaterCandidateCache(store.preferences);
    expect(cache.read(store.profile.id), isNotEmpty);
    final blocked = BlockedCatalog();
    final theater = TheaterFeed(blocked, store);
    expect(theater.items, isNotEmpty);
    expect(theater.loading, isFalse);
    theater.dispose();
    blocked.finish();
    await flushPreview();
  });

  test('候选缓存最多48项且限大小，过期/坏值忽略，白名单不含详情凭据', () async {
    final store = await openStore();
    var now = DateTime(2026, 11, 1);
    final cache = TheaterCandidateCache(store.preferences, clock: () => now);
    final raw = cache.encode([for (var i = 0; i < 100; i++) drama('$i')]);
    expect(
      utf8.encode(raw).length,
      lessThanOrEqualTo(TheaterCandidateCache.maxBytes),
    );
    await store.preferences.setString(cache.key('default'), raw);
    expect(cache.read('default').length, 48);
    expect(cache.read('viewer'), isEmpty);
    final fields = (jsonDecode(raw)['items'] as List).first as Map;
    expect(fields.keys, isNot(contains('raw')));
    expect(fields.keys, isNot(contains('session')));
    expect(fields.keys, isNot(contains('url')));
    now = now.add(const Duration(days: 3));
    expect(cache.read('default'), isEmpty);
    await store.preferences.setString(cache.key('default'), '{broken');
    expect(cache.read('default'), isEmpty);
  });

  test('重启同步显示缓存，首屏不强制刷新；完成/排除/无权限项仍过滤', () async {
    final store = await openStore();
    final cache = TheaterCandidateCache(store.preferences);
    final done = drama('done');
    await store.saveWatch(
      watching(done, episode: done.episodes, position: 100),
    );
    await store.preferences.setStringList('theater.hidden.default', [
      'hongguo:${drama('hidden').id}',
    ]);
    await store.preferences.setString(
      cache.key('default'),
      cache.encode([
        drama('ready'),
        done,
        drama('hidden'),
        drama('other', source: 'nonexistent'),
      ]),
    );
    final repo = BlockedCatalog();
    final feed = TheaterFeed(repo, store);
    expect(feed.loading, isFalse);
    expect(feed.items.map((e) => e.drama.id), [drama('ready').id]);
    await flushPreview();
    expect(repo.forces, [false]);
    expect(repo.held.isCompleted, isFalse);
    feed.dispose();
    repo.finish();
    await flushPreview();
  });

  test('观看后缓存落盘可重启恢复，网络失败不抹掉已有候选', () async {
    final store = await openStore();
    final repo = PreviewRepository();
    final feed = TheaterFeed(repo, store);
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final cache = TheaterCandidateCache(store.preferences);
    expect(cache.read('default'), isNotEmpty);
    feed.dispose();
    final blocked = BlockedCatalog();
    final restored = TheaterFeed(blocked, store);
    expect(restored.items, isNotEmpty);
    expect(restored.loading, isFalse);
    final ids = restored.items.map((e) => e.drama.id).toList();
    await flushPreview();
    expect(restored.items.map((e) => e.drama.id), ids);
    restored.dispose();
    blocked.finish();
    await flushPreview();
  });

  test('详情预读合并在途请求、TTL与LRU有界，失效后旧响应不回填', () async {
    final store = await openStore();
    final repo = PreviewRepository();
    var now = DateTime.now();
    final cache = TheaterDetailCache(repo, store, clock: () => now);
    addTearDown(cache.dispose);
    final item = drama('next');
    repo.heldDetail = Completer<DramaDetail>();
    final held = repo.heldDetail!;
    final warm = cache.warm(item);
    final current = cache.load(item);
    expect(repo.requested, [item.id]);
    held.complete(dramaDetail(item));
    await warm;
    await current;
    await cache.load(item);
    expect(repo.requested.length, 1);
    now = now.add(const Duration(minutes: 11));
    await cache.load(item);
    expect(repo.requested.length, 2);
    for (var i = 0; i < 4; i++) {
      await cache.load(drama('evict-$i'));
    }
    await cache.load(item);
    expect(repo.requested.where((e) => e == item.id).length, 3);
    repo.heldDetail = Completer<DramaDetail>();
    final late = repo.heldDetail!;
    final pending = cache.load(drama('late'));
    cache.invalidate();
    late.complete(dramaDetail(drama('late')));
    await pending;
    await cache.load(drama('late'));
    expect(repo.requested.where((e) => e == drama('late').id).length, 2);
  });

  test('首集播放后只预读下一部详情，不解析媒体，不创建第二播放器；隐藏后不预读', () async {
    final store = await openStore();
    final repo = PreviewRepository();
    final backend = FakePreviewBackend();
    final preview = TheaterPreview(repo, store, backend: () => backend);
    preview.select(drama('current'));
    preview.setVisible(true);
    await flushPreview();
    expect(backend.playing, isTrue);
    final resolved = repo.resolved.length;
    await preview.warmNext(drama('next'));
    expect(repo.resolved.length, resolved);
    expect(backend.opens.length, 1);
    preview.select(drama('next'));
    await flushPreview();
    expect(repo.requested.where((id) => id == drama('next').id).length, 1);
    expect(backend.opens.length, 2);
    await preview.suspend();
    final requests = repo.requested.length;
    await preview.warmNext(drama('hidden'));
    expect(repo.requested.length, requests);
    preview.dispose();
    await flushPreview();
  });
}

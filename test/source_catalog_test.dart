import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/ranking_models.dart';
import 'package:duanju_app/source_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _TopicRepository extends FakeRepository {
  @override
  CatalogPage pageFor(String source, String category, String query, int page) =>
      CatalogPage(
        [drama('p$page', source: source, category: '都市')],
        hasMore: true,
        page: page,
      );
}

class _DelayedCategories extends FakeRepository {
  final requests = <Completer<List<CatalogCategory>>>[];
  Completer<List<RankingBoard>>? heldBoards;

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) {
    final request = Completer<List<CatalogCategory>>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<List<RankingBoard>> rankingBoards() {
    final held = heldBoards;
    heldBoards = null;
    return held?.future ?? super.rankingBoards();
  }
}

void main() {
  test('分页预算保留本地合成分类所需模型及改分类语义', () async {
    final repo = FakeRepository()..categoryList = const [CatalogCategory.all];
    final catalog = SourceCatalog(repo, SourceSite.hongguo);
    await catalog.loadCategories();
    catalog.remember([
      drama('old', category: '都市'),
      drama('kept', category: '成长'),
    ]);
    catalog.trimLibrary({'hongguo:kept'}, extraBudget: 0);
    expect(catalog.rememberedDramaCount, 2);
    expect(
      catalog.categories.map((item) => item.name),
      containsAll(['都市', '成长']),
    );
    // 回收后仍能准确迁移已知 ID 的分类计数，不留下过期分类。
    catalog.remember([drama('old', category: '成长')]);
    expect(catalog.categories.map((item) => item.name), isNot(contains('都市')));
    final local = catalog.categories.firstWhere((item) => item.name == '成长');
    final result = await catalog.fetch(local);
    expect(
      result.items.map((item) => item.id),
      containsAll(['hongguo:kept', 'hongguo:old']),
    );
  });

  test('远端支持分类查询时回收非当前完整元数据', () async {
    final repo = FakeRepository()
      ..categoryList = const [
        CatalogCategory.all,
        CatalogCategory('tag:urban', '都市'),
      ];
    final catalog = SourceCatalog(repo, SourceSite.hongguo);
    await catalog.loadCategories();
    catalog.remember([
      for (var i = 0; i < 1000; i++) drama('$i', category: '都市'),
    ]);
    catalog.trimLibrary({'hongguo:999'}, extraBudget: 2);
    expect(catalog.rememberedDramaCount, 3);
    expect(catalog.categories.map((item) => item.id), ['', 'tag:urban']);
    catalog.remember([drama('0', category: '都市')]);
    catalog.trimLibrary({'hongguo:999'}, extraBudget: 0);
    expect(catalog.rememberedDramaCount, 1);
  });

  test('分类刷新先返回后，迟到的旧请求不能覆盖新分类', () async {
    final repository = _DelayedCategories();
    final catalog = SourceCatalog(repository, SourceSite.hongguo);
    final old = catalog.loadCategories();
    await pumpEventQueue();
    final fresh = catalog.loadCategories(force: true);
    await pumpEventQueue();
    repository.requests[1].complete(const [CatalogCategory('new', '新分类')]);
    await fresh;
    repository.requests[0].complete(const [CatalogCategory('old', '旧分类')]);
    await old;
    expect(catalog.categories.map((item) => item.id), ['', 'new']);
  });

  test('旧榜单响应不覆盖刷新结果，也不再派发旧分类请求', () async {
    final held = Completer<List<RankingBoard>>();
    final repository = _DelayedCategories()
      ..heldBoards = held
      ..boardList = const [
        RankingBoard(id: 'new', source: 'hongguo', name: '新榜单'),
      ];
    final catalog = SourceCatalog(repository, SourceSite.hongguo);
    final old = catalog.loadCategories();
    await pumpEventQueue();
    final fresh = catalog.loadCategories(force: true);
    await pumpEventQueue();
    repository.requests.single.complete(const [CatalogCategory('new', '新分类')]);
    await fresh;
    held.complete(const [
      RankingBoard(id: 'old', source: 'hongguo', name: '旧榜单'),
    ]);
    await pumpEventQueue();
    // 让旧实现也能结束，以明确断言过时请求，而非依靠测试超时。
    for (final request in repository.requests) {
      if (!request.isCompleted) request.complete(const []);
    }
    await old;
    expect(catalog.boards.map((item) => item.id), ['new']);
    expect(repository.requests, hasLength(1));
    expect(catalog.categories.map((item) => item.id), ['', 'new']);
  });

  test('categories normalize remote names and add cached topics', () async {
    final repository = FakeRepository()
      ..categoryList = const [
        CatalogCategory.all,
        CatalogCategory('short_play', '真人剧'),
        CatalogCategory('comic', 'AI成人漫剧'),
        CatalogCategory('comic_again', 'AI漫剧'),
      ]
      ..cachedPages['hongguo|'] = CatalogPage([
        drama('1', category: '都市'),
        drama('2', category: '成长'),
        drama('3', category: 'AI 漫剧'),
        drama('4', source: 'huangdou', category: '甜宠'),
      ]);
    final catalog = SourceCatalog(repository, SourceSite.hongguo);
    await catalog.loadCategories();
    expect(
      [for (final category in catalog.categories) category.id],
      ['', 'short_play', 'comic', 'local:成长', 'local:都市'],
    );
    expect(catalog.categories[2].name, 'AI 漫剧');
  });

  test('server topics replace the cached topics', () async {
    final repository = FakeRepository()
      ..categoryList = const [
        CatalogCategory.all,
        CatalogCategory('short_play', '真人剧'),
        CatalogCategory('tag:cate_96', '甜宠'),
        CatalogCategory('tag:cate_1', '都市'),
      ]
      ..cachedPages['hongguo|'] = CatalogPage([
        drama('1', category: '都市'),
        drama('2', category: '成长'),
      ]);
    final catalog = SourceCatalog(repository, SourceSite.hongguo);
    await catalog.loadCategories();
    expect(
      [for (final category in catalog.categories) category.id],
      ['', 'short_play', 'tag:cate_96', 'tag:cate_1'],
    );
  });

  test('a cached topic lists every remembered drama in it', () async {
    final repository = _TopicRepository()
      ..cachedPages['hongguo|'] = CatalogPage([
        drama('1', category: '都市'),
        drama('2', category: '成长'),
      ]);
    final catalog = SourceCatalog(repository, SourceSite.hongguo);
    await catalog.loadCategories();
    final topic = catalog.categories.last;
    expect(topic.local, isTrue);

    final page = await catalog.fetch(topic);
    expect(repository.catalogRequests, ['hongguo|||1']);
    expect(
      [for (final item in page.items) item.id],
      ['hongguo:1', 'hongguo:p1'],
    );
    expect(page.hasMore, isTrue);
  });

  test('search pages only where the source searches by page', () async {
    final repository = _TopicRepository();
    final huangdou = await SourceCatalog(
      repository,
      const SourceSite('huangdou', '黄豆', '精选短剧'),
    ).search('剧名');
    final hongguo = await SourceCatalog(
      repository,
      SourceSite.hongguo,
    ).search('剧名', page: 2);
    expect(huangdou.hasMore, isFalse);
    expect(hongguo.hasMore, isTrue);
    expect(repository.catalogRequests, ['huangdou||剧名|1', 'hongguo||剧名|2']);
  });
}

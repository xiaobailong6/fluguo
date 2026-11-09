import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'drama_feed.dart';
import 'local_store.dart';
import 'models.dart';
import 'ranking_models.dart';
import 'source_catalog.dart';
import 'theater_cache.dart';

const recommendTab = CatalogCategory('app:recommend', '推荐');

CatalogCategory rankingTab(RankingBoard board) =>
    CatalogCategory('app:rank:${board.id}', board.name);

class ExploreFeed extends ChangeNotifier {
  ExploreFeed(this.repository, this.store) {
    store.addListener(_storeChanged);
    repository.catalogUpdates.addListener(_metadataChanged);
    _open();
  }
  final AppRepository repository;
  final LocalStore store;
  SourceCatalog? _catalog;
  CatalogCategory _tab = CatalogCategory.all;
  DramaFeed? _feed;
  Map<String, int> _ranks = const {};
  bool _disposed = false;
  int _rankingGeneration = 0;
  int? _profileEpoch;
  String? _restoreTab;
  Future<void> _candidateWrites = Future.value();

  SourceSite? get source => _catalog?.source;
  DramaFeed? get feed => _feed;
  CatalogCategory get tab => _tab;
  bool get recommending => _tab.id == recommendTab.id;

  List<CatalogCategory> get tabs {
    final catalog = _catalog;
    if (catalog == null) return const [];
    final [all, ...genres] = catalog.categories;
    return [
      if (catalog.recommends) recommendTab,
      all,
      for (final board in catalog.boards) rankingTab(board),
      ...genres,
    ];
  }

  int? rankOf(Drama drama) => _ranks[drama.id];

  WatchEntry? get resume {
    final source = this.source;
    // 继续观看属于当前站源的观看记录，不随启动后恢复的分类消失。
    if (source == null) return null;
    return store.history
        .where((entry) => entry.drama.source == source.id)
        .firstOrNull;
  }

  Drama? get featured =>
      recommending && resume == null ? _feed?.items.firstOrNull : null;

  List<Drama> get items {
    final items = _feed?.items ?? const <Drama>[];
    return featured == null ? items : items.skip(1).toList();
  }

  void select(String id) {
    if (id == _tab.id) return;
    final tab = tabs.where((tab) => tab.id == id).firstOrNull;
    if (tab != null) _select(tab);
  }

  Future<void> refresh() async {
    final catalog = _catalog;
    if (catalog == null) return;
    if (catalog.categories.length == 1) {
      unawaited(_loadCategories(catalog, force: true));
    }
    await _feed?.reload(force: true);
  }

  void _open() {
    final id = store.source;
    if (id == _catalog?.source.id && _profileEpoch == store.profileEpoch) {
      return;
    }
    _profileEpoch = store.profileEpoch;
    _restoreTab = id.isEmpty ? null : store.catalogCategory(id);
    unawaited(repository.cancelCatalog());
    unawaited(repository.cancelRecommendations());
    _feed?.dispose();
    _feed = null;
    if (id.isEmpty) {
      _catalog = null;
      return;
    }
    final catalog = _catalog = SourceCatalog(repository, SourceSite.byId(id));
    _select(
      catalog.recommends ? recommendTab : CatalogCategory.all,
      remember: false,
    );
    unawaited(_loadCategories(catalog));
  }

  Future<void> _loadCategories(
    SourceCatalog catalog, {
    bool force = false,
  }) async {
    try {
      await catalog.loadCategories(force: force);
    } catch (_) {
      // 网络失败不是分类被删除，保留恢复目标以便下次成功刷新重试。
      if (!_disposed && catalog == _catalog) _notify();
      return;
    }
    if (_disposed || catalog != _catalog) return;
    final wanted = _restoreTab;
    _restoreTab = null;
    if (wanted != null) {
      final restored = tabs.where((tab) => tab.id == wanted).firstOrNull;
      if (restored != null && restored.id != _tab.id) {
        _select(restored, remember: false);
      } else if (restored == null) {
        _rememberTab();
      }
    }
    _notify();
  }

  void _select(CatalogCategory tab, {bool remember = true}) {
    final catalog = _catalog!;
    if (recommending) unawaited(repository.cancelRecommendations());
    _tab = tab;
    if (remember) {
      _restoreTab = null;
      _rememberTab();
    }
    _feed?.dispose();
    final board = catalog.boards
        .where((board) => rankingTab(board).id == tab.id)
        .firstOrNull;
    final ranks = _ranks = <String, int>{};
    final feed = _feed = tab.id == recommendTab.id
        ? DramaFeed(
            cumulative: true,
            load: (page, force) =>
                _saved(catalog.recommendations(more: page > 1, force: force)),
          )
        : board != null
        ? DramaFeed(
            load: (page, force) =>
                _saved(_ranking(catalog, board, ranks, page, force)),
          )
        : DramaFeed(
            cached: () => catalog.cached(tab),
            load: (page, force) =>
                _saved(catalog.fetch(tab, page: page, force: force)),
          );
    feed.addListener(_notify);
    unawaited(feed.reload());
    _notify();
  }

  void _rememberTab() {
    final catalog = _catalog;
    if (catalog == null || store.locked) return;
    unawaited(
      store
          .rememberCatalogCategory(
            catalog.source.id,
            _tab.id,
            profileEpoch: store.profileEpoch,
          )
          .catchError((Object _) {}),
    );
  }

  Future<CatalogPage> _ranking(
    SourceCatalog catalog,
    RankingBoard board,
    Map<String, int> ranks,
    int page,
    bool force,
  ) async {
    // 先校验榜单自己的刷新代次，再修改排名副作用；列表的序号保护太晚。
    if (page == 1) _rankingGeneration++;
    final generation = _rankingGeneration;
    final result = await catalog.ranking(board, page: page, force: force);
    if (!_disposed &&
        identical(ranks, _ranks) &&
        generation == _rankingGeneration) {
      if (page == 1) ranks.clear();
      for (final item in result.items) {
        ranks[item.drama.id] = item.rank;
      }
    }
    return CatalogPage(
      [for (final item in result.items) item.drama],
      hasMore: result.hasMore,
      warning: result.warning,
      page: result.page,
    );
  }

  Future<CatalogPage> _saved(Future<CatalogPage> request) async {
    final epoch = store.profileEpoch;
    final catalog = _catalog;
    final user = store.profile.id;
    final page = await request;
    if (_disposed ||
        epoch != store.profileEpoch ||
        !identical(catalog, _catalog)) {
      return page;
    }
    unawaited(store.refreshDramas(page.items).catchError((Object _) {}));
    // 复用已经加载的卡片，不请求额外目录；独立本机缓存不触发资料/UI通知。
    final candidates = page.items.take(TheaterCandidateCache.limit).toList();
    _candidateWrites = _candidateWrites
        .catchError((Object _) {})
        .then((_) async {
          if (_disposed || epoch != store.profileEpoch || store.locked) return;
          final cache = TheaterCandidateCache(store.preferences);
          final allowed = [
            ...candidates,
            ...cache.read(user),
          ].where((drama) => store.allowsSource(drama.source));
          if (candidates.isNotEmpty) {
            await store.preferences.setString(
              cache.key(user),
              cache.encode(allowed),
            );
          }
        })
        .catchError((Object _) {
          /* 推荐预热失败不阻断短剧页。 */
        });
    return page;
  }

  void _storeChanged() {
    _open();
    _notify();
  }

  void _metadataChanged() {
    final drama = repository.catalogUpdates.latest;
    if (drama == null || drama.source != source?.id) return;
    _catalog?.remember([drama]);
    _feed?.update(drama);
    unawaited(store.refreshDrama(drama).catchError((Object _) {}));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_storeChanged);
    repository.catalogUpdates.removeListener(_metadataChanged);
    _feed?.dispose();
    unawaited(repository.cancelCatalog());
    unawaited(repository.cancelRecommendations());
    super.dispose();
  }
}

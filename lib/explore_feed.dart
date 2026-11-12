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

/// 切走分类时保留的 feed 与其榜单序号；超过 [expiresAt] 视为陈旧。
class _KeptTab {
  _KeptTab(this.feed, this.ranks, this.expiresAt);
  final DramaFeed feed;
  final Map<String, int> ranks;
  final DateTime expiresAt;
  bool get fresh => DateTime.now().isBefore(expiresAt);
}

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

  /// 切走分类时留存的结果，切回可直接复用；有界，并按时间过期。
  final _keptTabs = <String, _KeptTab>{};
  static const _keptTabLimit = 6;
  static const _keptTabTtl = Duration(minutes: 10);

  void _keep(CatalogCategory tab, DramaFeed feed, Map<String, int> ranks) {
    _keptTabs[tab.id] = _KeptTab(feed, ranks, DateTime.now().add(_keptTabTtl));
    while (_keptTabs.length > _keptTabLimit) {
      _keptTabs.remove(_keptTabs.keys.first)?.feed.dispose();
    }
  }

  void _dropKept() {
    for (final kept in _keptTabs.values) {
      kept.feed.dispose();
    }
    _keptTabs.clear();
  }

  /// 上一次通知时，页面真正消费到的 store 状态快照。
  ///
  /// 列表卡片的心形由卡片自己的监听更新，不依赖这里的通知；发现页从 store
  /// 读取的只有「继续观看」这一条记录，加上站源选择与用户代次。其余通知
  /// （播放进度落盘、下载偏好等）不改变渲染结果，跳过即可。
  Object? _renderKey;

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
    // 只看这个站源最近一条记录：不必为一次读取排序整份历史。
    return store.latestWatchFor(source.id);
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
    // 用户显式刷新：其它分类的留存结果一并作废，切回时重新取。
    _dropKept();
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
    // 换站源/换用户：留存的分类结果全部作废。
    _dropKept();
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
    final previous = _tab;
    final previousFeed = _feed;
    _tab = tab;
    if (remember) {
      _restoreTab = null;
      _rememberTab();
    }
    // 同一分类：保留现有 feed，不重建。
    if (previous.id == tab.id && previousFeed != null) {
      _notify();
      return;
    }
    // 切走时把上一份结果留存；切回同一分类可直接复用（有界 + 过期）。
    if (previousFeed != null) _keep(previous, previousFeed, _ranks);
    final kept = _keptTabs.remove(tab.id);
    if (kept != null && kept.fresh) {
      _feed = kept.feed;
      _ranks = kept.ranks;
      _notify();
      return;
    }
    kept?.feed.dispose();
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

  Object _renderKeyOf() {
    final watch = resume;
    return (
      // 用 store 里期望的站源而不是当前目录，否则换源时快照不变、_open 被跳过。
      store.source,
      store.profileEpoch,
      _tab.id,
      _catalog,
      _feed,
      watch?.drama.id ?? '',
      watch?.episode ?? 0,
      watch?.position ?? 0.0,
      watch?.duration ?? 0.0,
      watch?.updatedAt.microsecondsSinceEpoch ?? 0,
    );
  }

  void _storeChanged() {
    final key = _renderKeyOf();
    if (key == _renderKey) return;
    _renderKey = key;
    _open();
    _notify();
  }

  void _metadataChanged() {
    final drama = repository.catalogUpdates.latest;
    if (drama == null || drama.source != source?.id) return;
    _catalog?.remember([drama]);
    _feed?.update(drama);
    // 留存中的分类同步更新，切回时不会看到旧标题/集数。
    for (final kept in _keptTabs.values) {
      kept.feed.update(drama);
    }
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
    _dropKept();
    _feed?.dispose();
    unawaited(repository.cancelCatalog());
    unawaited(repository.cancelRecommendations());
    super.dispose();
  }
}

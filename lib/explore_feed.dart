import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'drama_feed.dart';
import 'local_store.dart';
import 'metadata_publication.dart';
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
  ExploreFeed(this.repository, this.store, {this.cacheItemLimit = 600})
    : assert(cacheItemLimit >= 0) {
    store.addListener(_storeChanged);
    repository.catalogUpdates.addListener(_metadataChanged);
    repository.cacheChanges.addListener(_cacheCleared);
    _open();
  }
  final AppRepository repository;
  final LocalStore store;

  /// 当前页不截断；超过预算时清掉非当前分类，并停止邻页预取。
  final int cacheItemLimit;
  SourceCatalog? _catalog;
  CatalogCategory _tab = CatalogCategory.all;
  DramaFeed? _feed;
  Map<String, int> _ranks = const {};
  bool _disposed = false;
  final _rankGenerations = Expando<int>();
  final _lanes = <DramaFeed, String>{};
  final _prefetching = <DramaFeed>{};
  int _laneSequence = 0;
  bool _prefetchScheduled = false;
  bool _prefetchActive = true;

  void setPrefetchActive(bool active) {
    if (_disposed || _prefetchActive == active) return;
    _prefetchActive = active;
    if (!active) {
      for (final entry in _keptTabs.entries.toList()) {
        if (_prefetching.contains(entry.value.feed)) {
          _disposeFeed(_keptTabs.remove(entry.key)!.feed);
        }
      }
    } else {
      _schedulePrefetch();
    }
  }

  int? _profileEpoch;
  String? _restoreTab;
  Future<void> _candidateWrites = Future.value();

  /// 切走分类时留存的结果，切回可直接复用；有界，并按时间过期。
  final _keptTabs = <String, _KeptTab>{};
  final _budgetEvicted = <String>{};
  final _withoutFeatured = Expando<List<Drama>>();
  static const _keptTabLimit = 6;
  static const _keptTabTtl = Duration(minutes: 10);

  void _keep(CatalogCategory tab, DramaFeed feed, Map<String, int> ranks) {
    _keptTabs.remove(tab.id);
    _keptTabs[tab.id] = _KeptTab(feed, ranks, DateTime.now().add(_keptTabTtl));
    while (_keptTabs.length > _keptTabLimit) {
      _disposeFeed(_keptTabs.remove(_keptTabs.keys.first)!.feed);
    }
  }

  @visibleForTesting
  int get retainedItemCount =>
      (_feed?.items.length ?? 0) +
      _keptTabs.values.fold(0, (sum, kept) => sum + kept.feed.items.length);

  bool _trimKept() {
    var changed = false;
    var count = retainedItemCount;
    for (final entry in _keptTabs.entries.toList()) {
      if (entry.value.fresh && count <= cacheItemLimit) continue;
      count -= entry.value.feed.items.length;
      _keptTabs.remove(entry.key);
      _budgetEvicted.add(entry.key);
      _disposeFeed(entry.value.feed);
      changed = true;
    }
    _catalog?.trimLibrary({
      for (final drama in _feed?.items ?? const <Drama>[]) drama.id,
      for (final kept in _keptTabs.values)
        for (final drama in kept.feed.items) drama.id,
    }, extraBudget: (cacheItemLimit - count).clamp(0, cacheItemLimit));
    return changed;
  }

  void _dropKept() {
    for (final kept in _keptTabs.values) {
      _disposeFeed(kept.feed);
    }
    _keptTabs.clear();
    _budgetEvicted.clear();
  }

  void _disposeFeed(DramaFeed feed) {
    final lane = _lanes.remove(feed);
    // 取消尚未返回时仍占用预取名额，连续切换也不能堆积后台请求。
    if (lane != null) unawaited(repository.cancelExploreLane(lane));
    feed.dispose();
  }

  /// 纯读取：PageView 构建邻页不能创建 feed 或发送请求。
  DramaFeed? feedOf(CatalogCategory tab) => tab.id == _tab.id
      ? _feed
      : (_keptTabs[tab.id]?.fresh == true ? _keptTabs[tab.id]?.feed : null);
  int? rankIn(CatalogCategory tab, Drama drama) =>
      tab.id == _tab.id ? _ranks[drama.id] : _keptTabs[tab.id]?.ranks[drama.id];
  Drama? featuredIn(CatalogCategory tab) =>
      store.exploreBanner && tab.id == recommendTab.id && resume == null
      ? feedOf(tab)?.items.firstOrNull
      : null;
  List<Drama> itemsIn(CatalogCategory tab) {
    final items = feedOf(tab)?.items ?? const <Drama>[];
    return featuredIn(tab) == null ? items : _tail(items);
  }

  List<Drama> _tail(List<Drama> items) =>
      _withoutFeatured[items] ??= List.unmodifiable(items.skip(1));

  @visibleForTesting
  int get keptTabCount => _keptTabs.length;

  void _feedChanged() {
    _schedulePrefetch();
    _notify();
  }

  void _schedulePrefetch() {
    if (_prefetchScheduled || _disposed) return;
    _prefetchScheduled = true;
    scheduleMicrotask(() {
      _prefetchScheduled = false;
      if (!_disposed) {
        // feed 的通知栈退出后再销毁淘汰项，避免 dispose 正在通知的对象。
        if (_trimKept()) _notify();
        _prefetch();
      }
    });
  }

  void _prefetch() {
    final feed = _feed;
    if (!_prefetchActive ||
        retainedItemCount >= cacheItemLimit ||
        feed == null ||
        feed.loading ||
        feed.loadingMore ||
        feed.error.isNotEmpty ||
        feed.items.isEmpty ||
        store.locked ||
        !store.allowsSource(source!.id)) {
      return;
    }
    final pages = tabs;
    final index = pages.indexWhere((tab) => tab.id == _tab.id);
    if (index < 0) return;
    // 只预取当前成功页的直接邻居，完成邻页不递归扩散，最多两条后台 lane。
    for (final neighbor in [index - 1, index + 1]) {
      if (neighbor < 0 ||
          neighbor >= pages.length ||
          _prefetching.length >= 2) {
        continue;
      }
      final tab = pages[neighbor];
      // 大邻页被预算淘汰后，本次浏览不反复预取同一页。
      if (_budgetEvicted.contains(tab.id)) continue;
      final kept = _keptTabs[tab.id];
      if (kept != null && kept.fresh) continue;
      if (kept != null) _disposeFeed(_keptTabs.remove(tab.id)!.feed);
      final entry = _create(tab);
      _keep(tab, entry.feed, entry.ranks);
      _prefetching.add(entry.feed);
      unawaited(
        entry.feed.reload().whenComplete(() {
          _prefetching.remove(entry.feed);
          _schedulePrefetch();
        }),
      );
    }
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
    if (!store.exploreBanner || source == null) return null;
    // 只看这个站源最近一条记录：不必为一次读取排序整份历史。
    return store.latestWatchFor(source.id);
  }

  Drama? get featured => store.exploreBanner && recommending && resume == null
      ? _feed?.items.firstOrNull
      : null;

  List<Drama> get items {
    final items = _feed?.items ?? const <Drama>[];
    return featured == null ? items : _tail(items);
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
    if (_feed case final feed?) _disposeFeed(feed);
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
      if (!await catalog.loadCategories(force: force)) return;
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
    _schedulePrefetch();
    _notify();
  }

  void _select(CatalogCategory tab, {bool remember = true}) {
    // 旧前台在途请求不继续后台翻页，已完成结果才进入有界留存。
    final previous = _tab;
    final previousFeed = _feed;
    _budgetEvicted.clear();
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
    final kept = _keptTabs.remove(tab.id);
    if (previousFeed != null) {
      if (previousFeed.loading || previousFeed.loadingMore) {
        _disposeFeed(previousFeed);
      } else {
        _keep(previous, previousFeed, _ranks);
      }
    }
    for (final entry in _keptTabs.entries.toList()) {
      if (_prefetching.contains(entry.value.feed)) {
        _disposeFeed(_keptTabs.remove(entry.key)!.feed);
      }
    }
    if (kept != null && kept.fresh) {
      _feed = kept.feed;
      _ranks = kept.ranks;
      _prefetching.remove(kept.feed);
      _schedulePrefetch();
      _notify();
      return;
    }
    if (kept != null) _disposeFeed(kept.feed);
    final entry = _create(tab);
    _feed = entry.feed;
    _ranks = entry.ranks;
    unawaited(entry.feed.reload());
    _notify();
  }

  _KeptTab _create(CatalogCategory tab) {
    final catalog = _catalog!;
    final lane = '${identityHashCode(this)}-${++_laneSequence}';
    final board = catalog.boards
        .where((board) => rankingTab(board).id == tab.id)
        .firstOrNull;
    final ranks = <String, int>{};
    late final DramaFeed feed;
    Future<CatalogPage> saved(Future<CatalogPage> request) =>
        _saved(request, current: () => _lanes.containsKey(feed));
    feed = tab.id == recommendTab.id
        ? DramaFeed(
            cumulative: true,
            load: (page, force) => saved(
              catalog.recommendations(more: page > 1, force: force, lane: lane),
            ),
          )
        : board != null
        ? DramaFeed(
            load: (page, force) =>
                saved(_ranking(catalog, board, ranks, page, force, lane)),
          )
        : DramaFeed(
            cached: () =>
                catalog.cached(tab, isCurrent: () => _lanes.containsKey(feed)),
            load: (page, force) => saved(
              catalog.fetch(
                tab,
                page: page,
                force: force,
                lane: lane,
                isCurrent: () => _lanes.containsKey(feed),
              ),
            ),
          );
    _lanes[feed] = lane;
    feed.addListener(_feedChanged);
    return _KeptTab(feed, ranks, DateTime.now().add(_keptTabTtl));
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
    String lane,
  ) async {
    // 每份榜单独立代次，预取另一榜单不能使当前榜单的排名失效。
    if (page == 1) _rankGenerations[ranks] = (_rankGenerations[ranks] ?? 0) + 1;
    final generation = _rankGenerations[ranks];
    final result = await catalog.ranking(
      board,
      page: page,
      force: force,
      lane: lane,
    );
    if (!_disposed &&
        identical(catalog, _catalog) &&
        (identical(ranks, _ranks) ||
            _keptTabs.values.any((kept) => identical(kept.ranks, ranks))) &&
        generation == _rankGenerations[ranks]) {
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

  Future<CatalogPage> _saved(
    Future<CatalogPage> request, {
    required bool Function() current,
  }) async {
    final epoch = store.profileEpoch;
    final catalog = _catalog;
    final user = store.profile.id;
    final page = await request;
    if (_disposed ||
        !current() ||
        store.locked ||
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
          if (_disposed ||
              !current() ||
              !identical(catalog, _catalog) ||
              epoch != store.profileEpoch ||
              store.locked) {
            return;
          }
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
      store.exploreBanner,
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

  void _cacheCleared() {
    if (_disposed) return;
    _catalog = null;
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
    // 详情已负责持久化时这里只更新展示；后台等其他发布者仍走原保存路径。
    if (!metadataPublicationOwned(repository.catalogUpdates, store)) {
      unawaited(store.refreshDrama(drama).catchError((Object _) {}));
    }
    _schedulePrefetch();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_storeChanged);
    repository.catalogUpdates.removeListener(_metadataChanged);
    repository.cacheChanges.removeListener(_cacheCleared);
    _dropKept();
    if (_feed case final feed?) _disposeFeed(feed);
    unawaited(repository.cancelCatalog());
    unawaited(repository.cancelRecommendations());
    super.dispose();
  }
}

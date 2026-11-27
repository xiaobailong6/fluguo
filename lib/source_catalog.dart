import 'core_bridge.dart';
import 'models.dart';
import 'ranking_models.dart';

String categoryName(String name) {
  final compact = name.trim().replaceAll(RegExp(r'\s+'), '');
  return switch (compact) {
    'AI成人短剧' || 'AI短剧' => 'AI 短剧',
    'AI成人漫剧' || 'AI漫剧' => 'AI 漫剧',
    'AI换脸' => 'AI 换脸',
    'AI魔改' => 'AI 魔改',
    'AI剧' => 'AI 剧',
    '' => '未分类',
    _ => name.trim(),
  };
}

class SourceCatalog {
  SourceCatalog(this.repository, this.source);
  final AppRepository repository;
  final SourceSite source;
  List<CatalogCategory> _remote = const [];
  List<RankingBoard> _boards = const [];
  final _library = <String, Drama>{};
  // 分类索引只保留 ID 和名称，完整元数据可随页面预算回收。
  final _categoryById = <String, String>{};
  final _categoryCounts = <String, int>{};
  List<CatalogCategory>? _categories;
  Set<String> _remoteNames = const {};
  bool _remoteTopics = false;
  int _categoryGeneration = 0;

  static const recommendGenre = 'find_drama';
  static const topicPrefix = 'tag:';

  bool get recommends => source.recommends;

  List<RankingBoard> get boards => _boards;

  List<CatalogCategory> get categories {
    final cached = _categories;
    if (cached != null) return cached;
    final names = <String>{};
    final remote = [
      for (final category in _remote)
        if (category.id.isNotEmpty && names.add(categoryName(category.name)))
          CatalogCategory(category.id, categoryName(category.name)),
    ];
    final topics = remote.any(
      (category) => category.id.startsWith(topicPrefix),
    );
    _remoteNames = Set<String>.of(names);
    _remoteTopics = topics;
    final local = topics
        ? const <String>[]
        : (_categoryCounts.keys.where(names.add).toList()..sort());
    return _categories = List<CatalogCategory>.unmodifiable([
      CatalogCategory.all,
      ...remote,
      for (final name in local)
        CatalogCategory('local:$name', name, local: true),
    ]);
  }

  /// 仅当前请求完成时返回 true，旧请求不能触发调用方的分类恢复。
  Future<bool> loadCategories({bool force = false}) async {
    final generation = ++_categoryGeneration;
    try {
      final cached = await repository.cached(source.id);
      if (generation != _categoryGeneration) return false;
      remember(cached.items);
    } catch (_) {}
    if (generation != _categoryGeneration) return false;
    try {
      final boards = await repository.rankingBoards();
      if (generation != _categoryGeneration) return false;
      _boards = [
        for (final board in boards)
          if (board.source == source.id) board,
      ];
    } catch (_) {}
    // 连续刷新时，旧缓存/榜单响应不能继续派发请求或覆盖新目录。
    if (generation != _categoryGeneration) return false;
    final remote = await repository.categories(source.id, force: force);
    if (generation != _categoryGeneration) return false;
    if (remote.length != _remote.length ||
        Iterable<int>.generate(remote.length).any(
          (index) =>
              remote[index].id != _remote[index].id ||
              categoryName(remote[index].name) !=
                  categoryName(_remote[index].name),
        )) {
      _remote = List<CatalogCategory>.of(remote);
      _categories = null;
    }
    return true;
  }

  Future<RankingPage> ranking(
    RankingBoard board, {
    int page = 1,
    bool force = false,
    String lane = '',
  }) => lane.isEmpty
      ? repository.rankings(board.id, page: page, force: force)
      : repository.rankingsInLane(
          board.id,
          lane: lane,
          page: page,
          force: force,
        );

  void remember(Iterable<Drama> items) {
    for (final drama in items) {
      if (drama.source != source.id) continue;
      final previous = _library[drama.id];
      final merged = previous?.merge(drama) ?? drama;
      _library[drama.id] = merged;
      final oldName = _categoryById[drama.id];
      final name = categoryName(merged.category);
      _categoryById[drama.id] = name;
      if (oldName == name) continue;
      // 计数允许同 ID 改分类时删除最后一个旧类别；普通元数据更新不失效。
      var changed = false;
      if (oldName != null) {
        final remaining = _categoryCounts[oldName]! - 1;
        if (remaining == 0) {
          _categoryCounts.remove(oldName);
          changed = !_remoteTopics && !_remoteNames.contains(oldName);
        } else {
          _categoryCounts[oldName] = remaining;
        }
      }
      if (!_categoryCounts.containsKey(name) &&
          !_remoteTopics &&
          !_remoteNames.contains(name)) {
        changed = true;
      }
      _categoryCounts[name] = (_categoryCounts[name] ?? 0) + 1;
      if (changed) _categories = null;
    }
  }

  /// 完整目录模型与分页共用预算；轻量索引保留分类发现和改名语义。
  void trimLibrary(Set<String> retained, {required int extraBudget}) {
    // 确保远端分类能力已计算。本地合成分类依赖完整目录，不能因缓存回收丢剧。
    final remoteTopics = categories.any(
      (category) => category.id.startsWith(topicPrefix),
    );
    final candidates = _library.keys
        .where(
          (id) =>
              !retained.contains(id) &&
              (remoteTopics ||
                  _remoteNames.contains(categoryName(_library[id]!.category))),
        )
        .toList();
    for (final id in candidates.take(
      (candidates.length - extraBudget).clamp(0, candidates.length),
    )) {
      _library.remove(id);
    }
  }

  int get rememberedDramaCount => _library.length;

  Future<CatalogPage> cached(
    CatalogCategory category, {
    bool Function()? isCurrent,
  }) async {
    final result = await repository.cached(
      source.id,
      category: _request(category),
    );
    return isCurrent?.call() == false ? result : _within(category, result);
  }

  Future<CatalogPage> fetch(
    CatalogCategory category, {
    int page = 1,
    bool force = false,
    String lane = '',
    bool Function()? isCurrent,
  }) async {
    final result = await (lane.isEmpty
        ? repository.catalog(
            source.id,
            category: _request(category),
            page: page,
            force: force,
          )
        : repository.catalogInLane(
            source.id,
            lane: lane,
            category: _request(category),
            page: page,
            force: force,
          ));
    return isCurrent?.call() == false ? result : _within(category, result);
  }

  Future<CatalogPage> recommendations({
    bool more = false,
    bool force = false,
    String lane = '',
  }) => lane.isEmpty
      ? repository.recommendations(recommendGenre, more: more, force: force)
      : repository.recommendationsInLane(
          recommendGenre,
          lane: lane,
          more: more,
          force: force,
        );

  /// 仅匹配已经读取过的本地目录；不为预览触发额外源站请求。
  Future<CatalogPage> cachedSearch(String query) =>
      repository.cachedSearch(source.id, query);

  Future<CatalogPage> search(String query, {int page = 1}) async {
    final result = await repository.catalog(
      source.id,
      query: query,
      page: page,
    );
    return CatalogPage(
      result.items,
      hasMore: source.pagedSearch && result.hasMore,
      warning: result.warning,
      failure: result.failure,
      page: result.page,
      fresh: result.fresh,
    );
  }

  String _request(CatalogCategory category) =>
      category.local ? '' : category.id;

  CatalogPage _within(CatalogCategory category, CatalogPage page) {
    remember(page.items);
    if (!category.local) return page;
    return CatalogPage(
      [
        for (final drama in _library.values)
          if (categoryName(drama.category) == category.name) drama,
      ],
      hasMore: page.hasMore,
      warning: page.warning,
      failure: page.failure,
      page: page.page,
      fresh: page.fresh,
    );
  }
}

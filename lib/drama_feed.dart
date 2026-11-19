import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_failure.dart';
import 'models.dart';

typedef PageLoader = Future<CatalogPage> Function(int page, bool force);

class DramaFeed extends ChangeNotifier {
  DramaFeed({
    required this.load,
    this.cached,
    this.cumulative = false,
    this.cacheAlongsideLoad = false,
  });
  final PageLoader load;
  final Future<CatalogPage> Function()? cached;
  final bool cumulative;
  final bool cacheAlongsideLoad;
  bool cachePreview = false;

  List<Drama> _items = const [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  AppFailure? _failure;
  int _next = 1;
  int _generation = 0;
  bool _disposed = false;
  bool _retryReload = false;

  List<Drama> get items => _items;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  AppFailure? get failure => _failure;
  String get error => _failure?.message ?? '';
  bool get canLoadMore =>
      _hasMore && !_loading && !_loadingMore && _failure == null;

  Future<void> reload({bool force = false}) async {
    if (_disposed) return;
    final generation = ++_generation;
    _loading = true;
    _loadingMore = false;
    _failure = null;
    if (_items.isEmpty) cachePreview = false;
    _notify();
    if (cacheAlongsideLoad && !force && cached != null) {
      final remote = _fetch(generation, page: 1, force: force, more: false);
      unawaited(_previewCache(generation));
      await remote;
      return;
    }
    if (!force && cached != null) {
      try {
        final page = await cached!();
        if (generation != _generation) return;
        if (page.items.isNotEmpty) {
          _accept(page, more: false, requested: page.page);
          if (page.fresh && page.warning.isEmpty) {
            _loading = false;
            _notify();
            return;
          }
          _notify();
        }
      } catch (_) {}
    }
    // 缓存读取抛错同样可能晚于销毁/换页，不能再派发旧代次的网络请求。
    if (_disposed || generation != _generation) return;
    await _fetch(generation, page: 1, force: force, more: false);
  }

  Future<void> _previewCache(int generation) async {
    try {
      final page = await cached!();
      // 远端成功、失败、切查询或销毁后都不能被迟到缓存覆盖。
      if (generation != _generation || !_loading || page.items.isEmpty) return;
      _items = page.items;
      cachePreview = true;
      _notify();
    } catch (_) {
      // 缓存只是首屏预览，读取失败仍由在途远端请求决定最终状态。
    }
  }

  Future<void> loadMore() async {
    if (_disposed || _loading || _loadingMore || !_hasMore) return;
    final generation = ++_generation;
    _loadingMore = true;
    _failure = null;
    _notify();
    await _fetch(generation, page: _next, force: false, more: true);
  }

  /// 重试失败的请求类型，不能把第一页刷新失败误当成下一页失败。
  Future<void> retry() async {
    if (_failure != null && !_failure!.canRetryAt(DateTime.now())) return;
    await (_retryReload || !_hasMore ? reload(force: true) : loadMore());
  }

  void update(Drama drama) {
    if (!_items.any((item) => item.id == drama.id)) return;
    _items = [
      for (final item in _items) item.id == drama.id ? item.merge(drama) : item,
    ];
    _notify();
  }

  Future<void> _fetch(
    int generation, {
    required int page,
    required bool force,
    required bool more,
  }) async {
    try {
      final result = await load(page, force);
      if (generation != _generation) return;
      _accept(result, more: more, requested: page);
      cachePreview = false;
    } catch (error) {
      if (generation != _generation) return;
      _failure = AppFailure.from(error);
      _retryReload = !more;
    }
    _loading = _loadingMore = false;
    _notify();
  }

  void _accept(CatalogPage page, {required bool more, required int requested}) {
    if (cumulative || !more) {
      _items = page.items;
    } else {
      final known = {for (final item in _items) item.id};
      _items = [
        ..._items,
        for (final item in page.items)
          if (known.add(item.id)) item,
      ];
    }
    final failed = page.warning.isNotEmpty;
    _retryReload = failed && !more;
    _next = failed ? requested : page.page + 1;
    _hasMore = page.hasMore || failed;
    _failure = failed ? page.failure ?? AppFailure(page.warning) : null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}

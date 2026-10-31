import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'source_catalog.dart';
import 'theater_recommendations.dart';

/// 不调用全局 cancelCatalog：其他已懒创建 Tab 可能正在使用同一个仓库。
/// 失效请求不再提交结果；共享的两个请求槽跨代次保留，避免切用户突破并发上限。
class _TheaterCursor {
  _TheaterCursor(this.source, {this.category = '', this.recommend = false});
  final String source;
  final String category;
  final bool recommend;
  int page = 1;
  bool exhausted = false;
}

class TheaterFeed extends ChangeNotifier {
  TheaterFeed(
    this.repository,
    this.store, {
    Random? random,
    DateTime Function()? clock,
  }) : random = random ?? Random(),
       clock = clock ?? DateTime.now {
    store.addListener(_changed);
    _changed();
  }
  final AppRepository repository;
  final LocalStore store;
  final Random random;
  final DateTime Function() clock;
  List<TheaterPick> items = [];
  bool loading = false;
  String? error;
  String? notice;
  List<Drama> _pool = [];
  String _access = '';
  String _history = '';
  int _generation = 0;
  int _active = 0;
  final _waiting = <Completer<void>>[];
  bool _disposed = false;
  final _hidden = <String>{};
  final _exposed = <String, int>{};
  bool loadingMore = false;
  bool _initializing = false;
  final _cursors = <_TheaterCursor>[];
  int _cursor = 0;
  TheaterPick? _current;
  int get candidateCount => _pool.length;

  /// 仅记录滑动位置；裁剪发生于 append，UI 用同一个 pick 对象重新定位。
  void position(int index) {
    if (index >= 0 && index < items.length) _current = items[index];
  }

  String _accessKey() =>
      '${store.profile.id}:${store.profileEpoch}:${store.locked}:${store.sources.map((s) => s.id).join(',')}';
  String _historyKey() => jsonEncode([
    for (final e in store.history)
      [
        theaterIdentity(e.drama),
        e.drama.category,
        e.drama.tags,
        theaterCompleted(e),
      ],
  ]);

  void _changed() {
    final access = _accessKey();
    if (_access != access) {
      _access = access;
      _generation++;
      items = [];
      _pool = [];
      _readPreferences();
      _history = _historyKey();
      unawaited(reload());
    } else {
      final history = _historyKey();
      if (history == _history) return;
      _history = history;
      // 历史变化不能重排当前队列，更不能重建全集返回的来源批次。
      _notify();
    }
  }

  void _readPreferences() {
    _hidden.clear();
    _exposed.clear();
    try {
      _hidden.addAll(
        store.preferences.getStringList('theater.hidden.${store.profile.id}') ??
            [],
      );
      final raw =
          jsonDecode(
                store.preferences.getString(
                      'theater.exposed.${store.profile.id}',
                    ) ??
                    '{}',
              )
              as Map;
      final cutoff = clock()
          .subtract(const Duration(hours: 24))
          .millisecondsSinceEpoch;
      for (final entry in raw.entries) {
        if (entry.key is String &&
            entry.value is int &&
            entry.value >= cutoff) {
          _exposed[entry.key as String] = entry.value as int;
        }
      }
    } catch (_) {
      /* 损坏的本地推荐记录不能阻塞目录。 */
    }
  }

  bool _valid(int generation) =>
      !_disposed && generation == _generation && _access == _accessKey();

  Future<T> _request<T>(int generation, Future<T> Function() call) async {
    if (_active >= 2) {
      final waiter = Completer<void>();
      _waiting.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    try {
      if (!_valid(generation)) throw StateError('推荐请求已失效');
      return await call();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }

  Future<void> reload() async {
    final generation = ++_generation;
    _initializing = true;
    final sources = store.sources.toList();
    loading = sources.isNotEmpty;
    loadingMore = false;
    error = null;
    notice = null;
    items = [];
    _current = null;
    _pool = [];
    _cursors.clear();
    _cursor = 0;
    _notify();
    final interests = theaterInterests(store.history, clock());
    // 先注册游标；缓存/分类只作增益，不能成为首屏所有来源的串行屏障。
    for (final source in sources) {
      _cursors.add(
        _TheaterCursor(
          source.id,
          recommend: source.id == SourceSite.hongguo.id,
        ),
      );
      if (source.id == SourceSite.hongguo.id) {
        _cursors.add(_TheaterCursor(source.id));
      }
    }
    if (sources.isNotEmpty) {
      unawaited(
        _warmCandidates(
          generation,
          sources.map((s) => s.id).toList(),
          interests,
        ),
      );
    }
    if (!_valid(generation)) return;
    await _fill(generation, cycle: true, initial: true);
    if (!_valid(generation)) return;
    loading = false;
    _initializing = false;
    loadingMore = false;
    _current ??= items.firstOrNull;
    _notify();
  }

  void _publishInitial(int generation) {
    if (!_valid(generation) || items.isNotEmpty) return;
    final picks = _sample(_exposed.keys.toSet(), 12);
    if (picks.isEmpty) return;
    _append(picks, generation);
    _current = items.first;
    loading = false;
    loadingMore = _initializing;
    error = null;
    notice = null;
    _notify();
  }

  Future<void> _warmCandidates(
    int generation,
    List<String> sources,
    Map<String, double> interests,
  ) async {
    // 只占一个后台通道，让另一通道能立即拉取推荐，不等所有缓存/分类。
    for (final source in sources) {
      try {
        final cached = await _request(
          generation,
          () => repository.cached(source),
        );
        if (!_valid(generation)) return;
        _collect(cached, source);
        _publishInitial(generation);
      } catch (_) {
        /* 缓存不可用不阻断推荐。 */
      }
      if (!_valid(generation)) return;
    }
    for (final source in sources) {
      try {
        final categories = await _request(
          generation,
          () => repository.categories(source),
        );
        if (!_valid(generation)) return;
        final matching =
            categories
                .where(
                  (c) =>
                      c.id.isNotEmpty &&
                      !c.local &&
                      (interests[theaterTag(c.name)] ?? 0) > 0,
                )
                .toList()
              ..sort(
                (a, b) => interests[theaterTag(b.name)]!.compareTo(
                  interests[theaterTag(a.name)]!,
                ),
              );
        if (matching.isNotEmpty) {
          _cursors.add(_TheaterCursor(source, category: matching.first.id));
        }
      } catch (_) {
        /* 分类仅影响后续兴趣候选。 */
      }
      if (!_valid(generation)) return;
    }
  }

  void _append(List<TheaterPick> picks, int generation) {
    final index = _current == null ? 0 : items.indexOf(_current!);
    final drop = max(0, index - 10);
    if (drop > 0) items.removeRange(0, drop);
    final added = picks.take(max(0, 60 - items.length)).toList();
    items.addAll(added);
    for (final p in added) {
      _exposed[theaterIdentity(p.drama)] = clock().millisecondsSinceEpoch;
    }
    while (_exposed.length > 600) {
      _exposed.remove(_exposed.keys.first);
    }
    unawaited(_save(generation));
  }

  void _collect(CatalogPage page, String source) {
    final unique = {for (final d in _pool) theaterIdentity(d): d};
    for (final d in page.items) {
      if (d.source != source) continue;
      final id = theaterIdentity(d);
      unique[id] = unique[id]?.merge(d) ?? d;
    }
    _pool = unique.values.toList();
    if (_pool.length > 600) _pool.removeRange(0, _pool.length - 600);
  }

  List<TheaterPick> _sample(Set<String> excluded, int count) => theaterSample(
    candidates: _pool,
    history: store.history,
    allowedSources: store.locked ? {} : store.sources.map((s) => s.id).toSet(),
    excluded: {..._hidden, ...excluded},
    random: random,
    now: clock(),
    count: count,
  );

  Future<void> _fill(
    int generation, {
    required bool cycle,
    bool initial = false,
  }) async {
    final cutoff = clock()
        .subtract(const Duration(hours: 24))
        .millisecondsSinceEpoch;
    _exposed.removeWhere((_, time) => time < cutoff);
    final queued = items.map((p) => theaterIdentity(p.drama)).toSet();
    var picks = _sample({..._exposed.keys, ...queued}, 12);
    if (initial) {
      _publishInitial(generation);
      if (items.isNotEmpty) return;
    }
    var failed = false;
    // 每次用户意图最多四轮、每轮两页；重复页/空页立即关闭游标，绝不自旋。
    for (var round = 0; picks.length < 12 && round < 4; round++) {
      final pending = <_TheaterCursor>[];
      for (var n = 0; n < _cursors.length && pending.length < 2; n++) {
        final c = _cursors[_cursor++ % _cursors.length];
        if (!c.exhausted) pending.add(c);
      }
      if (pending.isEmpty) break;
      await Future.wait(
        pending.map((c) async {
          try {
            final page = await _request(
              generation,
              () => c.recommend
                  ? repository.recommendations(
                      SourceCatalog.recommendGenre,
                      more: c.page > 1,
                      force: c.page == 1,
                    )
                  : repository.catalog(
                      c.source,
                      page: c.page,
                      category: c.category,
                      force: c.page == 1,
                    ),
            );
            if (!_valid(generation)) return;
            final known = _pool.map(theaterIdentity).toSet();
            final fresh = page.items.any(
              (d) =>
                  d.source == c.source && !known.contains(theaterIdentity(d)),
            );
            _collect(page, c.source);
            // 独立目录即使与推荐页重叠仍须允许第二页。
            c.exhausted =
                !page.hasMore || page.items.isEmpty || (!fresh && c.page > 1);
            c.page++;
            if (initial) _publishInitial(generation);
          } catch (_) {
            if (_valid(generation)) failed = true;
          }
        }),
      );
      if (!_valid(generation)) return;
      if (initial && items.isNotEmpty) return;
      picks = _sample({..._exposed.keys, ...queued}, 12);
      if (failed) break;
    }
    if (!_valid(generation)) return;
    if (cycle &&
        picks.isEmpty &&
        !failed &&
        _cursors.every((c) => c.exhausted)) {
      // 有限目录降权循环：先避开整个在场队列，再避开最近十项；极小目录也可滑。
      picks = _sample(queued, 12);
      if (picks.isEmpty) {
        final index = _current == null ? 0 : items.indexOf(_current!);
        final recent = items
            .skip(max(0, index - 10))
            .map((p) => theaterIdentity(p.drama))
            .toSet();
        picks = _sample(recent, 12);
        if (picks.isEmpty) picks = _sample({}, 12);
      }
      picks = picks
          .map((p) => TheaterPick(p.drama, '再次发现 · ${p.reason}'))
          .toList();
    }
    error = failed ? '推荐加载失败，请重试' : null;
    notice = picks.isEmpty && !failed ? '暂无可用新推荐，可重试继续查找' : null;
    if (picks.isNotEmpty) _append(picks, generation);
  }

  Future<void> loadMore({bool retry = false}) async {
    if (loading ||
        loadingMore ||
        _disposed ||
        store.locked ||
        (error != null && !retry)) {
      return;
    }
    final generation = _generation;
    loadingMore = true;
    _notify();
    await _fill(generation, cycle: true);
    if (!_valid(generation)) return;
    loadingMore = false;
    _notify();
  }

  Future<void> _writes = Future.value();

  Future<void> _save(int generation) {
    if (!_valid(generation) || store.locked) return Future.value();
    final user = store.profile.id;
    final hidden = _hidden.toList();
    final exposed = jsonEncode(_exposed);
    _writes = _writes
        .then((_) async {
          if (!_valid(generation) || store.locked) return;
          await store.preferences.setStringList('theater.hidden.$user', hidden);
          if (!_valid(generation)) return;
          await store.preferences.setString('theater.exposed.$user', exposed);
        })
        .catchError((Object _) {
          if (_valid(generation)) {
            notice = '本地推荐记录保存失败';
            _notify();
          }
        });
    return _writes;
  }

  Future<void> nextBatch() async {
    if (loading || loadingMore) return;
    final generation = _generation;
    loadingMore = true;
    items = [];
    _current = null;
    await _fill(generation, cycle: false);
    if (!_valid(generation)) return;
    loadingMore = false;
    _current = items.firstOrNull;
    _notify();
  }

  Future<void> hide(Drama drama) async {
    if (store.locked || !store.allowsSource(drama.source)) return;
    _hidden.add(theaterIdentity(drama));
    while (_hidden.length > 500) {
      _hidden.remove(_hidden.first);
    }
    items.removeWhere(
      (p) => theaterIdentity(p.drama) == theaterIdentity(drama),
    );
    _notify();
    await _save(_generation);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    store.removeListener(_changed);
    super.dispose();
  }
}

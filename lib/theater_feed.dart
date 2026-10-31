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
      // 进度保存不发网络；真正的历史题材/完成状态变化只在内存候选上重算。
      _select(keepCurrent: true);
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
    final sources = store.sources.take(3).toList();
    loading = sources.isNotEmpty;
    error = null;
    notice = null;
    items = [];
    _notify();
    if (sources.isEmpty) {
      loading = false;
      return;
    }
    final candidates = <Drama>[];
    var failures = 0;
    var successes = 0;
    final interests = theaterInterests(store.history, clock());
    // 每源最多缓存、分类、默认页、一个匹配分类页；不请求详情或媒体地址。
    await Future.wait(
      sources.map((source) async {
        Future<T?> attempt<T>(Future<T> Function() request) async {
          try {
            final value = await _request(generation, request);
            if (_valid(generation)) successes++;
            return value;
          } catch (_) {
            if (_valid(generation)) failures++;
            return null;
          }
        }

        void collect(CatalogPage? page) {
          if (_valid(generation) && page != null) {
            candidates.addAll(
              page.items.where((d) => d.source == source.id).take(200),
            );
          }
        }

        collect(await attempt(() => repository.cached(source.id)));
        if (!_valid(generation)) return;
        final categories = await attempt(
          () => repository.categories(source.id),
        );
        if (!_valid(generation)) return;
        collect(
          await attempt(
            () => source.id == SourceSite.hongguo.id
                ? repository.recommendations(
                    SourceCatalog.recommendGenre,
                    force: true,
                  )
                : repository.catalog(source.id, force: true),
          ),
        );
        if (!_valid(generation)) return;
        final matching =
            (categories ?? <CatalogCategory>[])
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
          collect(
            await attempt(
              () => repository.catalog(source.id, category: matching.first.id),
            ),
          );
        }
      }),
    );
    if (!_valid(generation)) return;
    _pool = candidates;
    loading = false;
    if (failures > 0) {
      if (candidates.isEmpty && successes == 0) {
        error = '推荐加载失败，请重试';
      } else {
        notice = '部分来源暂不可用，已使用可用候选';
      }
    }
    _select();
    _notify();
  }

  void _select({bool keepCurrent = false}) {
    final current = keepCurrent
        ? items.map((p) => theaterIdentity(p.drama)).toSet()
        : <String>{};
    final cutoff = clock()
        .subtract(const Duration(hours: 24))
        .millisecondsSinceEpoch;
    _exposed.removeWhere((_, time) => time < cutoff);
    items = theaterSample(
      candidates: _pool,
      history: store.history,
      allowedSources: store.sources.map((s) => s.id).toSet(),
      excluded: {
        ..._hidden,
        ..._exposed.keys.where((id) => !current.contains(id)),
      },
      random: random,
      now: clock(),
    );
    // 展示批次保守计为曝光；仅保存身份和时间戳，不保存任何媒体 URL。
    for (final item in items) {
      _exposed[theaterIdentity(item.drama)] = clock().millisecondsSinceEpoch;
    }
    while (_exposed.length > 300) {
      _exposed.remove(_exposed.keys.first);
    }
    unawaited(_save(_generation));
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
    if (loading) return;
    _select();
    _notify();
    if (items.isEmpty) await reload();
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

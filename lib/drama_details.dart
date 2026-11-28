import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'follow_state.dart';
import 'local_store.dart';
import 'metadata_publication.dart';
import 'models.dart';

const episodeGroupSize = 30;

class DramaDetails extends ChangeNotifier {
  DramaDetails(this.repository, this.store, Drama drama)
    : _drama = repository.catalogUpdates.current(drama),
      _epoch = store.profileEpoch {
    store.addListener(_storeChanged);
    load();
  }
  final AppRepository repository;
  final LocalStore store;
  final int _epoch;
  Drama _drama;
  List<Episode> _episodes = const [];
  List<DramaSeason> _seasons = const [];
  String _warning = '';
  String? _error;
  bool _loading = false;
  int _group = 0;
  int _generation = 0;
  bool _disposed = false;

  Drama get drama => _drama;
  List<Episode> get episodes => _episodes;
  List<DramaSeason> get seasons => allowed ? _seasons : const [];
  String get warning => _warning;
  String? get error => _error;
  bool get loading => _loading;
  bool get allowed =>
      store.profileEpoch == _epoch && store.allowsSource(_drama.source);
  WatchEntry? get watch => allowed ? store.watched(_drama.id) : null;
  int get resumeIndex => resumeEpisodeIndex(_episodes, watch);
  int? get currentIndex {
    final number = watch?.episode;
    final index = _episodes.indexWhere((episode) => episode.number == number);
    return index < 0 ? null : index;
  }

  int get groupCount => (_episodes.length / episodeGroupSize).ceil();
  int get group => _group;
  List<Episode> get groupEpisodes =>
      _episodes.skip(_group * episodeGroupSize).take(episodeGroupSize).toList();

  String groupLabel(int group) {
    final start = group * episodeGroupSize;
    final end = (start + episodeGroupSize).clamp(0, _episodes.length) - 1;
    return '${_episodes[start].number}-${_episodes[end].number}';
  }

  void selectGroup(int group) {
    if (group == _group || group < 0 || group >= groupCount) return;
    _group = group;
    _notify();
  }

  Future<void> selectSeason(DramaSeason season) async {
    if (!allowed ||
        !store.allowsSource(season.drama.source) ||
        season.drama.id == _drama.id ||
        !_seasons.any(
          (item) =>
              item.drama.id == season.drama.id &&
              item.drama.source == season.drama.source,
        )) {
      return;
    }
    _drama = repository.catalogUpdates.current(season.drama);
    _episodes = const [];
    _warning = '';
    _error = null;
    _group = 0;
    // 只沿本次已验证的官方列表携带缓存；新请求会替换而不是拼接列表。
    _seasons = DramaSeason.associated(_drama, _seasons);
    await load();
  }

  Future<void> load() async {
    if (!allowed) return;
    final generation = ++_generation;
    final requested = _drama;
    unawaited(_loadSeasons(requested, generation));
    _loading = true;
    _error = null;
    _notify();
    try {
      final detail = await repository.detail(requested);
      if (!_current(generation)) return;
      if (detail.drama.id != requested.id ||
          detail.drama.source != requested.source) {
        throw StateError('站源返回的剧集不匹配');
      }
      _drama = repository.catalogUpdates.current(_drama).merge(detail.drama);
      _episodes = detail.episodes;
      _warning = detail.warning;
      _group = groupCount == 0 ? 0 : resumeIndex ~/ episodeGroupSize;
      _loading = false;
      _notify();
      unawaited(
        publishPersistedMetadata(
          repository.catalogUpdates,
          store,
          _drama,
          retryCover: true,
        ).catchError((Object _) {}),
      );
      unawaited(_supplement(generation));
    } catch (error) {
      if (!_current(generation)) return;
      _error = error.toString();
      _loading = false;
      _notify();
      repository.catalogUpdates.publish(_drama, retryCover: true);
    }
  }

  Future<void> _loadSeasons(Drama requested, int generation) async {
    try {
      final rows = await repository.seasons(requested);
      if (!_current(generation) || _drama.id != requested.id) return;
      _seasons = DramaSeason.associated(requested, rows);
      _seedFollowSeasons();
      _notify();
    } catch (_) {
      // 官方关联属于补充信息，失败不能遮住已成功加载的选集。
    }
  }

  Future<void> _supplement(int generation) async {
    try {
      final fresh = await repository.supplementMetadata(_drama);
      if (fresh == null ||
          !_current(generation) ||
          fresh.id != _drama.id ||
          fresh.source != _drama.source) {
        return;
      }
      _drama = _drama.merge(fresh);
      _notify();
      await publishPersistedMetadata(repository.catalogUpdates, store, _drama);
    } catch (_) {}
  }

  void _seedFollowSeasons() {
    if (!allowed ||
        _disposed ||
        _seasons.isEmpty ||
        !store.isFavorite(_drama.id) ||
        store.following(_drama.id)?.seasonsSeeded == true) {
      return;
    }
    unawaited(
      store
          .observeFollowSeasonsBatch(
            {_drama.id: _seasons},
            epoch: _epoch,
            baselineOnly: true,
          )
          .catchError((Object _) {}),
    );
  }

  void _storeChanged() {
    _seedFollowSeasons();
    _notify();
  }

  bool _current(int generation) =>
      !_disposed && generation == _generation && allowed;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_storeChanged);
    super.dispose();
  }
}

import 'core_bridge.dart';
import 'models.dart';
import 'playback_request_retry.dart';

class PlaybackLoader {
  PlaybackLoader(this.repository);

  final AppRepository repository;
  int _generation = 0;
  bool _closed = false;

  Future<PlaybackPlan?> load(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool localOnly = false,
    bool online = false,
  }) => _load(() async {
    if (online) {
      return repository.resolveOnline(drama, episode, quality: quality);
    }
    if (localOnly) {
      final plan = await repository.localPlayback(
        drama,
        episode,
        playback: true,
      );
      if (plan == null || !plan.local) {
        throw AppFailure('本地视频不可用，请重新下载或选择在线播放。', code: 'local_media');
      }
      return plan;
    }
    return repository.resolve(drama, episode, quality: quality);
  }, retryNetwork: true);

  Future<PlaybackPlan?> fallback(PlaybackPlan current) =>
      _load(() => repository.fallback(current));

  // 预载计划仍由调用方持有：失效时由会话统一释放，不能两边各释放一次。
  Future<PlaybackPlan?> use(PlaybackPlan prepared) =>
      _load(() async => prepared, releaseStale: false);

  Future<PlaybackPlan?> _load(
    Future<PlaybackPlan> Function() resolve, {
    bool retryNetwork = false,
    bool releaseStale = true,
  }) async {
    if (_closed) {
      return null;
    }
    final generation = ++_generation;
    try {
      await repository.cancelPlayback();
      if (_closed || generation != _generation) {
        return null;
      }
      final plan = retryNetwork
          ? await retryPlaybackRequest(
              resolve,
              isCurrent: () => !_closed && generation == _generation,
            )
          : await resolve();
      if (_closed || generation != _generation) {
        if (releaseStale) await repository.release(plan.session);
        return null;
      }
      return plan;
    } catch (_) {
      if (_closed || generation != _generation) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    _generation++;
    await repository.cancelPlayback();
  }
}

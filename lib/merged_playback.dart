import 'core_bridge.dart';
import 'local_store.dart';
import 'merged_library.dart';
import 'models.dart';

/// 合并长视频只能走本地文件；不向源站解析首集，也不复用在线播放取消序号。
class MergedPlaybackRepository extends AppRepository {
  MergedPlaybackRepository(this.library, this.video, this.store, this.original)
      : _epoch = store.profileEpoch;
  final MergedLibrary library;
  final MergedVideo video;
  final LocalStore store;
  final AppRepository original;
  final int _epoch;

  void _check() {
    if (store.profileEpoch != _epoch || !store.canDownload ||
        !store.allowsSource(video.drama.source)) {
      throw AppFailure('当前用户没有此合并视频的播放权限');
    }
  }

  Future<PlaybackPlan> _plan() async {
    _check();
    final file = await library.fileFor(video);
    _check();
    return PlaybackPlan(url: Uri.file(file).toString(), local: true);
  }

  DramaDetail playbackDetail() => DramaDetail(video.drama, [
    Episode({'title': '合并视频', 'currentEpisode': 1}, 1),
  ]);

  @override
  Future<void> initialize() async {}
  @override
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0}) => _plan();
  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode, {bool playback = false}) => _plan();
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) => _plan();
  @override
  Future<void> cancelPlayback() async {}
  @override
  Future<void> release(String session) async {}
  @override
  Future<DramaDetail> detail(Drama drama) async {
    _check();
    return playbackDetail();
  }
  @override
  Future<CatalogPage> catalog(String source, {
    int page = 1, String query = '', String category = '', bool force = false,
  }) async => throw AppFailure('合并视频不支持在线目录');
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      throw AppFailure('合并视频不支持在线目录');
  @override
  Future<String> cover(Drama drama, {bool force = false}) => original.cover(drama, force: force);
  @override
  bool coverCached(Drama drama) => original.coverCached(drama);
}

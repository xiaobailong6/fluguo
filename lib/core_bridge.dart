import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show Listenable, ValueNotifier;
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'danmaku_models.dart';
import 'background_downloads.dart';
import 'local_store.dart';
import 'app_build.dart';
import 'ranking_models.dart';
import 'cover_decoder.dart';
import 'catalog_updates.dart';
import 'download_collections.dart';
import 'resource_settings.dart';
import 'diary_service.dart';
import 'app_update.dart';
import 'sorani_account.dart';
import 'native_request_pool.dart';
import 'app_failure.dart';
import 'native_protocol.dart';
import 'native_worker.dart';

export 'app_failure.dart';

abstract class AppRepository {
  Future<ResourceSettings> resourceSettings() async => const ResourceSettings();
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async => throw AppFailure('当前环境不支持资源设置');
  final catalogUpdates = CatalogUpdates();
  // 只表示本 isolate 内的下载状态可能变化；列表读取不递增，避免刷新循环。
  final downloadChanges = ValueNotifier<int>(0);
  final cacheChanges = ValueNotifier<int>(0);
  Future<void> cancelPreload() async {}
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => null;
  Future<void> cancelDanmaku() async {}
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async => throw AppFailure('当前环境不支持弹幕');
  Future<void> cancelCatalog() async {}
  Future<void> cancelSuggestions() async {}
  Future<void> cancelRecommendations() async {}
  Future<Drama?> supplementMetadata(Drama drama) async => null;
  Future<Drama> followCheck(Drama drama) async => (await detail(drama)).drama;
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持红果推荐');
  Future<List<RankingBoard>> rankingBoards() async => const [];
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持榜单');
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
  bool get supportsSourceManagement => false;
  Future<List<String>> suggestions(String query) async => const [];
  Future<Map<String, dynamic>> storage() async => {};
  Future<Map<String, dynamic>> clearCache() async =>
      throw AppFailure('当前环境不支持清理缓存');
  Future<String> downloadDirectory() async =>
      (await storage())['directory'] as String? ?? '';
  Future<void> moveDownloads(String directory) async =>
      throw AppFailure('当前环境不支持迁移');
  Future<int> workLease(String id, String command) async => 0;
  bool get supportsDownloads => false;

  /// 下载批次绑定发起时的身份，后续批次不能借用新用户权限。
  int? get downloadAccessEpoch => null;
  Future<List<DownloadJob>> downloads() async => [];
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async => throw AppFailure('当前环境不支持下载');
  Future<void> controlDownloads(String command, {String id = ''}) async {}
  Future<void> removeExportedDownload(DownloadJob job) =>
      controlDownloads('remove', id: job.id);
  Future<DownloadConversion> beginConversion(String id) async =>
      throw AppFailure('当前环境不支持处理下载');
  Future<void> finishConversion(String id, String result) async {}
  Future<DownloadConversion> beginNormalization(DownloadJob job) async =>
      throw AppFailure('当前环境不支持保存格式转换后的分集');
  Future<DownloadJob> finishNormalization(
    DownloadJob job,
    String result,
  ) async => job;
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids,
  ) async {
    final completed = <String>[], failures = <String, String>{};
    for (final id in ids.toSet()) {
      try {
        await controlDownloads(command, id: id);
        completed.add(id);
      } catch (error) {
        failures[id] = error.toString();
      }
    }
    if (completed.isNotEmpty) downloadChanges.value++;
    return DownloadBatchResult(completed: completed, failures: failures);
  }

  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) => enqueueDownloads(detail, episodes, quality: quality);

  /// [playback] 为真时这是一次新的播放意图，参与播放序号；
  /// 导出、合并等只是读取本地文件，不能打断正在排队的播放解析。
  Future<PlaybackPlan?> localPlayback(
    Drama drama,
    Episode episode, {
    bool playback = false,
  }) async => null;
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => resolve(drama, episode, quality: quality);
  Future<AppUpdate?> checkUpdate(String version) async => null;
  Future<bool> hongguoDevices({bool register = false}) async => true;
  Future<SoraniAccount> soraniAccount() async => const SoraniAccount();
  Future<SoraniCaptcha> soraniCaptcha() async =>
      throw AppFailure('当前版本不支持登录青空次元');
  Future<SoraniAccount> soraniLogin({
    required String identifier,
    required String password,
    required String captchaId,
    required SoraniCaptchaTrack track,
  }) async => throw AppFailure('当前版本不支持登录青空次元');
  Future<SoraniAccount> soraniLogout() async => const SoraniAccount();
  Future<void> initialize();
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  });
  Future<CatalogPage> cached(String source, {String category = ''});

  /// 旧仓库/fake 无需实现新接口；不支持核心筛选时显式在本地回退。
  Future<CatalogPage> cachedSearch(String source, String query) async {
    final page = await cached(source);
    return filterCachedSearch(page, source, query);
  }

  static CatalogPage filterCachedSearch(
    CatalogPage page,
    String source,
    String query,
  ) {
    final words = query.trim().toLowerCase().split(RegExp(r'\s+'));
    final seen = <String>{};
    return CatalogPage([
      for (final item in page.items)
        if (item.source == source &&
            seen.add(item.id) &&
            words.every(
              ('${item.title} ${item.description} ${item.tags.join(' ')}')
                  .toLowerCase()
                  .contains,
            ))
          item,
    ]);
  }

  Future<String> cover(Drama drama, {bool force = false});

  /// 仅返回已授权的内存路径提示；文件是否仍存在由 [cover] 异步核对。
  String? knownCover(Drama drama) => null;

  /// 封面权限或清理屏障变化；普通观看进度通知不应重新加载封面。
  Listenable? get coverChanges => null;
  Object? coverContext(Drama drama) => null;
  bool coverCached(Drama drama) => false;
  Future<DramaDetail> detail(Drama drama);
  Future<List<DramaSeason>> seasons(Drama drama) async => const [];
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0});
  Future<PlaybackPlan> fallback(PlaybackPlan current);
  Future<void> cancelPlayback();
  Future<void> release(String session);
}

class NativeRepository extends AppRepository {
  static final _coverDecoder = CoverDecoder();
  static final _coverPaths =
      <String, ({String path, int revision, LocalStore? owner, int? epoch})>{};
  static final _coverChanges = ValueNotifier<int>(0);
  static final _sharedCacheChanges = ValueNotifier<int>(0);
  static final _coverOperations = <Future<void>>{};
  static final _coverAttempts = <String, Set<Object>>{};
  static Future<void>? _cacheMaintenance;
  static int _cacheRevision = 0;
  @override
  ValueNotifier<int> get cacheChanges => _sharedCacheChanges;
  NativeRepository({
    this.background = false,
    NativeRequestDispatcher? dispatcher,
  }) : _dispatcher = dispatcher ?? nativeRequests;
  final NativeRequestDispatcher _dispatcher;
  final bool background;
  bool _nativeCachedSearch = false;
  LocalStore? _access;
  LocalStore? get access => _access;
  set access(LocalStore? value) {
    if (identical(_access, value)) return;
    _access = value;
    _coverChanges.value++;
  }

  // 由封面 widget 按生命周期订阅，不在仓库中永久监听 LocalStore。
  @override
  Listenable get coverChanges => Listenable.merge([_coverChanges, access]);
  @override
  Object coverContext(Drama drama) => (
    access,
    access?.profileEpoch,
    access?.locked,
    access?.allowsSource(drama.source),
    _cacheRevision,
  );
  @override
  int? get downloadAccessEpoch => access?.profileEpoch;
  final _readOwner = DateTime.now().microsecondsSinceEpoch.toString();
  int _readSequence = 0;
  final _activeReads = <String, int>{};

  void _adminPermission() {
    if (access != null && (access!.locked || !access!.profile.admin)) {
      throw AppFailure('仅管理员可修改本机资源设置');
    }
  }

  @override
  Future<ResourceSettings> resourceSettings() async {
    _adminPermission();
    final settings = ResourceSettings.fromJson(
      await _call({'action': 'resourceSettings'}),
    );
    DiaryService.traceEnabled = settings.traceEnabled;
    return settings;
  }

  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async {
    _adminPermission();
    final saved = ResourceSettings.fromJson(
      await _call({
        'action': 'saveResourceSettings',
        'settings': settings.toJson(),
      }),
    );
    DiaryService.traceEnabled = saved.traceEnabled;
    return saved;
  }

  Future<Map<String, dynamic>> _read(
    String scope,
    Map<String, dynamic> input,
  ) async {
    final sequence = ++_readSequence;
    _activeReads[scope] = sequence;
    try {
      return await _call({
        ...input,
        'session': '$_readOwner:$scope',
        'sequence': sequence,
      }, isCurrent: () => _activeReads[scope] == sequence);
    } finally {
      if (_activeReads[scope] == sequence) _activeReads.remove(scope);
    }
  }

  Future<void> _cancelReads(String prefix) async {
    final reads = _activeReads.entries
        .where((entry) => entry.key.startsWith(prefix))
        .toList();
    await Future.wait(
      reads.map((entry) async {
        if (_activeReads[entry.key] == entry.value) {
          _activeReads.remove(entry.key);
        }
        try {
          await _call({
            'action': 'cancelRead',
            'session': '$_readOwner:${entry.key}',
            'sequence': entry.value,
          });
        } catch (_) {}
      }),
    );
  }

  @override
  Future<void> cancelDanmaku() => _cancelReads('danmaku');

  @override
  Future<void> cancelPreload() => _cancelReads('preload');

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => PlaybackPlan.fromJson(
    await _read('preload', {
      'action': 'preload',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': online || access?.canDownload == false,
    }),
  );

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    _authorize('hongguo');
    if (plan.local || plan.session.isEmpty || plan.danmakuId.isEmpty) {
      throw AppFailure('本集暂不支持弹幕');
    }
    return DanmakuPage.fromJson(
      await _read('danmaku', {
        'action': 'danmaku',
        'playbackSession': plan.session,
        'startMs': startMs,
        'durationMs': durationMs,
      }),
      episodeId: plan.danmakuId,
      startMs: startMs,
      durationMs: durationMs,
    );
  }

  @override
  Future<void> cancelCatalog() => _cancelReads('catalog-');
  @override
  Future<void> cancelSuggestions() => _cancelReads('suggestions');
  @override
  Future<void> cancelRecommendations() => _cancelReads('recommendations-');

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async {
    _authorize('hongguo');
    return CatalogPage.fromJson(
      await _read('recommendations-$genre', {
        'action': 'recommendations',
        'category': genre,
        'command': more ? 'more' : '',
        'force': force,
      }),
    );
  }

  @override
  Future<Drama?> supplementMetadata(Drama drama) async {
    if (!(drama.source == 'hongguo' &&
            (drama.onlineDate.isEmpty || drama.score.isEmpty) ||
        drama.source == 'huangdou' &&
            (drama.heat.isEmpty || drama.vipStatus == null))) {
      return null;
    }
    final result = await _read('metadata', {
      'action': 'metadata',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  Future<Drama> followCheck(Drama drama) async {
    _authorize(drama.source);
    final result = await _call({
      'action': 'followCheck',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  bool get supportsSourceManagement => true;

  @override
  Future<List<RankingBoard>> rankingBoards() async {
    final result = await _call({'action': 'rankingBoards'});
    return [
          for (final row in result['items'] as List? ?? [])
            RankingBoard.fromJson(Map<String, dynamic>.from(row as Map)),
        ]
        .where(
          (board) =>
              SourceSite.isAvailable(board.source) &&
              (access?.allowsSource(board.source) ?? true),
        )
        .toList();
  }

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => RankingPage.fromJson(
    await _call({
      'action': 'rankings',
      'board': board,
      'page': page,
      'force': force,
    }),
  );

  void _authorize(String source, {bool download = false}) {
    if (!SourceSite.isAvailable(source)) {
      throw const AppFailure('当前版本不包含此站源', code: 'source_unavailable');
    }
    if (access == null) return;
    if (access!.locked ||
        !access!.allowsSource(source) ||
        download && !access!.canDownload) {
      throw const AppFailure('当前用户没有此操作权限', code: 'permission');
    }
  }

  void _downloadPermission() {
    if (access != null && (access!.locked || !access!.canDownload)) {
      throw const AppFailure('当前用户仅支持在线观看', code: 'permission');
    }
  }

  @override
  Future<List<String>> suggestions(String query) async {
    _authorize('hongguo');
    final result = await _read('suggestions', {
      'action': 'suggestions',
      'query': query,
    });
    return (result['items'] as List? ?? []).whereType<String>().toList();
  }

  @override
  Future<String> downloadDirectory() async {
    _downloadPermission();
    return (await _call({'action': 'downloadDirectory'}))['directory']
            as String? ??
        '';
  }

  @override
  Future<Map<String, dynamic>> storage() async {
    _downloadPermission();
    return _call({'action': 'storage'});
  }

  @override
  Future<Map<String, dynamic>> clearCache() async {
    _adminPermission();
    if (_cacheMaintenance != null) throw AppFailure('缓存正在清理，请稍后重试');
    final epoch = access?.profileEpoch;
    final barrier = Completer<void>();
    _cacheMaintenance = barrier.future;
    // 同步阻止此前排队的目录请求在原生清理释放锁后抢先回写。
    _cacheRevision++;
    // 在等待在途任务之前撤下屏幕上的旧图；cacheChanges 仍只在清理结束发出。
    _coverChanges.value++;
    var requested = false;
    try {
      // 转换的 finally 也会写文件，必须等整个封面任务及裁剪结束后再删除。
      await Future.wait(_coverOperations.toList());
      await _coverDecoder.waitForIdle();
      _adminPermission();
      if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
      requested = true;
      return await _call({'action': 'clearCache'});
    } finally {
      if (requested) {
        _coverPaths.clear();
        catalogUpdates.clear();
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        // 即使部分文件未能删除，也不能让旧的内存地址和目录结果继续回填。
        _sharedCacheChanges.value++;
      }
      _cacheMaintenance = null;
      barrier.complete();
    }
  }

  @override
  Future<void> moveDownloads(String directory) async {
    _downloadPermission();
    if (access != null && !access!.profile.admin) {
      throw AppFailure('仅管理员可更改下载目录');
    }
    await BackgroundDownloads.ensureStarted();
    await workLease('storage', 'start');
    try {
      await _call({'action': 'moveDownloads', 'directory': directory});
    } finally {
      await workLease('storage', 'end');
    }
  }

  @override
  Future<int> workLease(String id, String command) async => intValue(
    (await _call({
      'action': 'workLease',
      'jobId': id,
      'command': command,
    }))['count'],
  );
  int _playbackSequence = DateTime.now().microsecondsSinceEpoch;

  @override
  Future<AppUpdate?> checkUpdate(String version) async {
    final result = await _call({'action': 'checkUpdate', 'version': version});
    return result['available'] == true
        ? AppUpdate(
            version: result['version'] as String,
            url: result['url'] as String,
          )
        : null;
  }

  @override
  Future<bool> hongguoDevices({bool register = false}) async =>
      (await _call({
        'action': 'hongguoDevices',
        if (register) 'command': 'register',
      }))['ready'] ==
      true;

  void _soraniPermission() {
    if (access != null && (access!.locked || !access!.profile.admin)) {
      throw AppFailure('仅管理员可登录或退出青空次元账号');
    }
  }

  @override
  Future<SoraniAccount> soraniAccount() async =>
      SoraniAccount.fromJson(await _call({'action': 'soraniAccount'}));

  @override
  Future<SoraniCaptcha> soraniCaptcha() async {
    _soraniPermission();
    return SoraniCaptcha.fromJson(
      await _call({'action': 'soraniAccount', 'command': 'captcha'}),
    );
  }

  @override
  Future<SoraniAccount> soraniLogin({
    required String identifier,
    required String password,
    required String captchaId,
    required SoraniCaptchaTrack track,
  }) async {
    _soraniPermission();
    return SoraniAccount.fromJson(
      await _call({
        'action': 'soraniAccount',
        'command': 'login',
        'account': {
          'identifier': identifier,
          'password': password,
          'captchaId': captchaId,
          'track': track.toJson(),
        },
      }),
    );
  }

  @override
  Future<SoraniAccount> soraniLogout() async {
    _soraniPermission();
    return SoraniAccount.fromJson(
      await _call({'action': 'soraniAccount', 'command': 'logout'}),
    );
  }

  Future<Map<String, dynamic>> _call(
    Map<String, dynamic> input, {
    bool Function()? isCurrent,
    Duration? timeout,
  }) async {
    try {
      final action = input['action'] as String;
      final unrestricted =
          {
            'initialize',
            'protocol',
            'release',
            'cancelPlayback',
            'cancelRead',
            'updateSystemProxy',
          }.contains(action) ||
          action == 'workLease' && input['command'] == 'end' ||
          action == 'finishConversion' ||
          action == 'finishNormalization' ||
          action == 'lan' &&
              {
                'stop',
                'respond',
                'cancel',
                'disconnect',
              }.contains(input['command']);
      final epoch = access?.profileEpoch;
      final cacheRead = const {
        'catalog',
        'cached',
        'categories',
        'rankings',
        'recommendations',
        'cachedRecommendations',
        'metadata',
        'seasons',
        'detail',
      }.contains(action);
      // prepareCover 不进入此屏障：清理本身还在等待已有转换排空。
      if (cacheRead) {
        while (_cacheMaintenance != null) {
          await _cacheMaintenance;
        }
      }
      final cacheEpoch = _cacheRevision;
      if (action == 'clearCache') _adminPermission();
      if (!unrestricted && access?.locked == true) {
        throw const AppFailure('请先解锁当前用户', code: 'permission');
      }
      if (action == 'rankings') {
        _authorize(RankingBoard.sourceForID(input['board'] as String));
      }
      if (action == 'recommendations' ||
          action == 'cachedRecommendations' ||
          action == 'suggestions' ||
          action == 'danmaku') {
        _authorize('hongguo');
      }
      if ({'catalog', 'cached', 'categories'}.contains(action)) {
        _authorize(input['source'] as String);
      }
      if ({
        'cover',
        'prepareCover',
        'detail',
        'seasons',
        'metadata',
        'resolve',
        'preload',
        'enqueueDownloads',
        'localPlayback',
      }.contains(action)) {
        _authorize(
          (input['drama'] as Map)['source'] as String,
          download: action == 'enqueueDownloads' || action == 'localPlayback',
        );
      }
      if (!unrestricted &&
          {
            'downloads',
            'controlDownloads',
            'controlDownloadBatch',
            'beginConversion',
            'beginNormalization',
            'storage',
            'downloadDirectory',
            'moveDownloads',
            'workLease',
          }.contains(action)) {
        _downloadPermission();
      }
      if (action == 'resolve' && access != null && !access!.canDownload) {
        input['force'] = true;
      }
      final playbackRequest =
          input['sequence'] is int &&
          const {'resolve', 'fallback', 'localPlayback'}.contains(action);
      final playbackSequence = _playbackSequence;
      final response = await _dispatcher.send(
        input,
        isCurrent: () =>
            (unrestricted || epoch == access?.profileEpoch) &&
            (!cacheRead || cacheEpoch == _cacheRevision) &&
            (action != 'clearCache' ||
                access == null ||
                !access!.locked && access!.profile.admin) &&
            (isCurrent == null || isCurrent()) &&
            (!playbackRequest || playbackSequence == _playbackSequence),
        timeout:
            timeout ??
            Duration(
              seconds: action == 'moveDownloads'
                  ? 620
                  : action == 'danmaku'
                  ? 15
                  : action == 'preload'
                  ? 20
                  : 70,
            ),
      );
      // 部分失败（例如转换恢复已补交成品）也可能改变状态，应触发一次核对。
      if (const {
        'enqueueDownloads',
        'controlDownloads',
        'controlDownloadBatch',
        'beginConversion',
        'finishConversion',
        'beginNormalization',
        'finishNormalization',
        'moveDownloads',
      }.contains(action)) {
        downloadChanges.value++;
      }
      if (response['ok'] != true) {
        throw AppFailure.fromJson(response);
      }
      final data = response['data'];
      if (!unrestricted && epoch != access?.profileEpoch) {
        if (data is Map && data['session'] is String) {
          await release(data['session'] as String);
        }
        if (action == 'workLease' && input['command'] == 'start') {
          await workLease(input['jobId'] as String, 'end');
        }
        if (action == 'beginConversion') {
          // 原生已取得占用，失效响应也必须配对释放。
          await finishConversion(input['jobId'] as String, 'cancel');
        }
        if (action == 'beginNormalization') {
          await _call({
            'action': 'finishNormalization',
            'jobId': input['jobId'],
            'downloadIdentity': input['downloadIdentity'],
            'command': 'cancel',
          });
        }
        throw AppFailure('用户已切换，请重新操作');
      }
      if (cacheRead && cacheEpoch != _cacheRevision) {
        throw AppFailure('缓存已清理，请重新加载', code: 'cancelled');
      }
      return data is Map ? Map<String, dynamic>.from(data) : {};
    } on AppFailure {
      rethrow;
    } on NativeRequestCancelled {
      throw AppFailure('请求已取消', code: 'cancelled');
    } on TimeoutException {
      if (input['session'] is String &&
          input['sequence'] is int &&
          {
            'catalog',
            'categories',
            'suggestions',
            'recommendations',
            'metadata',
            'seasons',
            'danmaku',
            'preload',
          }.contains(input['action'])) {
        unawaited(
          _call({
            'action': 'cancelRead',
            'session': input['session'],
            'sequence': input['sequence'],
          }).catchError((Object _) => <String, dynamic>{}),
        );
      }
      throw const AppFailure('站源响应超时，请重试', code: 'timeout');
    } catch (_) {
      throw const AppFailure('本地核心加载失败，请使用完整安装包重新安装', code: 'core_unavailable');
    }
  }

  /// 独立于路径插件与业务初始化，便于验证真实启动顺序和旧库失败路径。
  Future<void> checkProtocol() async {
    final Map<String, dynamic> build;
    try {
      build = await _call({'action': 'protocol'});
    } on AppFailure catch (error) {
      if (error.code == 'timeout' || error.code == 'core_unavailable') rethrow;
      throw const AppFailure(
        '原生核心版本过旧，请使用完整安装包重新安装',
        code: 'protocol_mismatch',
      );
    }
    validateNativeProtocol(build, allSources: allSourcesEnabled);
    _nativeCachedSearch = (build['capabilities'] as List? ?? const []).contains(
      'cachedSearch',
    );
  }

  @override
  Future<void> initialize() async {
    await checkProtocol();
    final directory = await getApplicationSupportDirectory();
    // 系统缓存可清理；用户配置、站源身份和下载仍使用原应用支持目录。
    final cache = await getApplicationCacheDirectory();
    if (!background) {
      DiaryService.nativeLogPath = path.join(directory.path, 'logs', 'app.log');
    }
    final external = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : null;
    final build = await _call({
      'action': 'initialize',
      'directory': directory.path,
      'cache': cache.path,
      if (external != null) 'downloads': path.join(external.path, 'downloads'),
    });
    validateNativeProtocol(build, allSources: allSourcesEnabled);
    // 启动即恢复日志开关，不能等用户进入设置页才开启媒体过程记录。
    try {
      final settings = ResourceSettings.fromJson(
        await _call({
          'action': 'resourceSettings',
        }, timeout: const Duration(seconds: 2)),
      );
      DiaryService.traceEnabled = settings.traceEnabled;
    } catch (_) {
      // 诊断开关读取失败不能阻断启动；默认不记录详细媒体日志。
      DiaryService.traceEnabled = false;
    }
    if (!background) await BackgroundDownloads.prepare();
    if (!background) {
      SystemProxyMonitor.start((value) async {
        await _call({'action': 'updateSystemProxy', 'systemProxy': value});
      });
    }
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    final result = await _read('categories-$source', {
      'action': 'categories',
      'source': source,
      'force': force,
    });
    return [
      for (final row in result['items'] as List? ?? const [])
        CatalogCategory.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async => CatalogPage.fromJson(
    await _read(query.isEmpty ? 'catalog-$source' : 'catalog-$source-search', {
      'action': 'catalog',
      'source': source,
      'page': page,
      'query': query,
      'category': category,
      'force': force,
    }),
  );
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage.fromJson(
        await _call({
          'action': 'cached',
          'source': source,
          'category': category,
        }),
      );

  @override
  Future<CatalogPage> cachedSearch(String source, String query) async {
    // 未握手或旧核心不宣告能力时必须过滤，不能把未知 query 字段当作已执行。
    if (!_nativeCachedSearch) return super.cachedSearch(source, query);
    final page = CatalogPage.fromJson(
      await _call({'action': 'cached', 'source': source, 'query': query}),
    );
    return AppRepository.filterCachedSearch(page, source, query);
  }

  String _coverKey(Drama drama) =>
      '${drama.source}\u0000${drama.id}\u0000${drama.cover}';

  @override
  String? knownCover(Drama drama) {
    if (_cacheMaintenance != null ||
        !SourceSite.isAvailable(drama.source) ||
        access != null &&
            (access!.locked || !access!.allowsSource(drama.source))) {
      return null;
    }
    final known = _coverPaths[_coverKey(drama)];
    if (known == null ||
        known.revision != _cacheRevision ||
        !identical(known.owner, access) ||
        known.epoch != access?.profileEpoch) {
      return null;
    }
    return known.path;
  }

  @override
  bool coverCached(Drama drama) => knownCover(drama) != null;

  @override
  Future<String> cover(Drama drama, {bool force = false}) async {
    final owner = access;
    final epoch = access?.profileEpoch;
    _authorize(drama.source);
    while (_cacheMaintenance != null) {
      final maintenance = _cacheMaintenance!;
      await maintenance;
    }
    _authorize(drama.source);
    if (!identical(owner, access) || epoch != access?.profileEpoch) {
      throw AppFailure('用户已切换，请重新操作');
    }
    final revision = _cacheRevision;
    final key = _coverKey(drama);
    final attempt = Object();
    // 强制请求使同图的旧任务失效；仅保存尚未完成的任务，避免无界增长。
    final attempts = _coverAttempts.putIfAbsent(key, () => <Object>{});
    if (force) attempts.clear();
    attempts.add(attempt);
    final finished = Completer<void>();
    _coverOperations.add(finished.future);
    try {
      final file = await _cover(drama, attempt, force: force);
      _validateCover(drama, owner, epoch, revision, attempt);
      return file;
    } finally {
      attempts.remove(attempt);
      if (attempts.isEmpty && identical(_coverAttempts[key], attempts)) {
        _coverAttempts.remove(key);
      }
      _coverOperations.remove(finished.future);
      finished.complete();
    }
  }

  void _validateCover(
    Drama drama,
    LocalStore? owner,
    int? epoch,
    int revision,
    Object attempt,
  ) {
    _authorize(drama.source);
    if (!identical(owner, access) || epoch != access?.profileEpoch) {
      throw AppFailure('用户已切换，请重新操作');
    }
    if (_cacheMaintenance != null || revision != _cacheRevision) {
      throw AppFailure('缓存已清理，请重新加载', code: 'cancelled');
    }
    if (!(_coverAttempts[_coverKey(drama)]?.contains(attempt) ?? false)) {
      throw AppFailure('海报请求已失效', code: 'cancelled');
    }
  }

  Future<String> _cover(
    Drama drama,
    Object attempt, {
    bool force = false,
  }) async {
    final key = _coverKey(drama);
    final owner = access;
    final epoch = access?.profileEpoch;
    final revision = _cacheRevision;
    // 强制重试即刻撤销旧提示，失败时也不能重新暴露该路径。
    final known = force ? _coverPaths.remove(key) : _coverPaths[key];
    if (!force &&
        known != null &&
        known.revision == revision &&
        identical(known.owner, owner) &&
        known.epoch == epoch) {
      final exists = await File(known.path).exists();
      _validateCover(drama, owner, epoch, revision, attempt);
      if (exists && _coverPaths[key] == known) {
        return _rememberCover(key, known.path);
      }
      if (_coverPaths[key] == known) _coverPaths.remove(key);
    }
    final result = await _call({
      'action': 'cover',
      'drama': drama.toJson(),
      'force': force,
    });
    _validateCover(drama, owner, epoch, revision, attempt);
    final file = result['path'] as String? ?? '';
    if (file.isEmpty) throw AppFailure('海报暂不可用');
    if (result['heic'] != true) return _rememberCover(key, file);
    final converted = await _coverDecoder.convert(
      file,
      () => _call({'action': 'prepareCover', 'drama': drama.toJson()}),
      force: force,
    );
    _validateCover(drama, owner, epoch, revision, attempt);
    return _rememberCover(key, converted);
  }

  String _rememberCover(String key, String path) {
    _coverPaths.remove(key);
    _coverPaths[key] = (
      path: path,
      revision: _cacheRevision,
      owner: access,
      epoch: access?.profileEpoch,
    );
    if (_coverPaths.length > 2000) _coverPaths.remove(_coverPaths.keys.first);
    return path;
  }

  @override
  Future<List<DramaSeason>> seasons(Drama drama) async {
    _authorize(drama.source);
    final result = await _call({'action': 'seasons', 'drama': drama.toJson()});
    final rows = result['items'] as List? ?? const [];
    if (rows.length > 200) throw AppFailure('系列季数超过上限');
    return [
      for (final row in rows)
        DramaSeason.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail.fromJson(
    await _call({'action': 'detail', 'drama': drama.toJson()}),
  );
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'sequence': ++_playbackSequence,
    }),
  );
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      PlaybackPlan.fromJson(
        await _call({
          'action': 'fallback',
          'session': current.session,
          'sequence': ++_playbackSequence,
        }),
      );
  @override
  Future<void> cancelPlayback() async {
    await _call({'action': 'cancelPlayback', 'sequence': ++_playbackSequence});
  }

  @override
  bool get supportsDownloads => access?.canDownload ?? true;

  /// 下载列表的增量拉取缓存：上次快照指纹 + 已解析结果。
  (String, List<DownloadJob>) _downloadCache = ('', const []);
  List<DownloadJob> _visibleDownloads = const [];

  @override
  Future<List<DownloadJob>> downloads() async {
    final result = await _call({
      'action': 'downloads',
      'since': _downloadCache.$1,
    });
    if (result['jobs'] case final List jobs) {
      _downloadCache = (
        result['fingerprint'] as String? ?? '',
        jobs
            .whereType<Map>()
            .map(
              (value) => DownloadJob.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList(),
      );
    }
    final visible = _downloadCache.$2
        .where(
          (job) =>
              SourceSite.isAvailable(job.drama.source) &&
              (access == null || access!.allowsSource(job.drama.source)),
        )
        .toList();
    // 内容完全一致时复用上次的不可变列表：下游拿到同一实例就能整段跳过。
    final previous = _visibleDownloads;
    if (visible.length == previous.length &&
        visible.indexed.every(
          (entry) => identical(entry.$2, previous[entry.$1]),
        )) {
      return previous;
    }
    return _visibleDownloads = List.unmodifiable(visible);
  }

  @override
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    _authorize(detail.drama.source, download: true);
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    final result = await _call({
      'action': 'enqueueDownloads',
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    _authorize(detail.drama.source, download: true);
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    final result = await _call({
      'action': 'enqueueDownloads',
      'force': true,
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids,
  ) async {
    _downloadPermission();
    final epoch = access?.profileEpoch;
    if (ids.isEmpty || ids.length > 500) throw AppFailure('每批请选择 1 至 500 个任务');
    final visible = (await downloads()).map((job) => job.id).toSet();
    if (ids.any((id) => !visible.contains(id))) {
      throw AppFailure('部分任务已删除或当前用户无权操作，请刷新');
    }
    if (command == 'resume') await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return DownloadBatchResult.fromJson(
      await _call({
        'action': 'controlDownloadBatch',
        'command': command,
        'jobIds': ids,
      }),
    );
  }

  @override
  Future<void> controlDownloads(String command, {String id = ''}) async {
    _downloadPermission();
    if (command == 'resume' || command == 'resumeAll') {
      await BackgroundDownloads.ensureStarted();
    }
    if (access != null && !access!.profile.admin) {
      final visible = await downloads();
      if (command == 'pauseAll' || command == 'resumeAll') {
        for (final job in visible.where(
          (job) => command == 'pauseAll' ? job.active : job.resumable,
        )) {
          await _call({
            'action': 'controlDownloads',
            'command': command == 'pauseAll' ? 'pause' : 'resume',
            'jobId': job.id,
          });
        }
        return;
      }
      if (!visible.any((job) => job.id == id)) {
        throw AppFailure('当前用户没有此下载任务权限');
      }
    }
    await _call({
      'action': 'controlDownloads',
      'command': command,
      'jobId': id,
    });
  }

  @override
  Future<void> removeExportedDownload(DownloadJob job) async {
    _authorize(job.drama.source, download: true);
    await _call({
      'action': 'controlDownloads',
      'command': 'remove',
      'jobId': job.id,
      'downloadIdentity': {'created': job.created, 'revision': job.revision},
    });
  }

  @override
  Future<DownloadConversion> beginConversion(String id) async {
    final result = await _call({'action': 'beginConversion', 'jobId': id});
    return (
      input: result['input'] as String? ?? '',
      key: result['key'] as String? ?? '',
      output: result['output'] as String? ?? '',
    );
  }

  @override
  Future<void> finishConversion(String id, String result) async {
    await _call({'action': 'finishConversion', 'jobId': id, 'command': result});
  }

  @override
  Future<DownloadConversion> beginNormalization(DownloadJob job) async {
    _authorize(job.drama.source, download: true);
    final result = await _call({
      'action': 'beginNormalization',
      'jobId': job.id,
      'downloadIdentity': {'created': job.created, 'revision': job.revision},
    });
    return (
      input: result['input'] as String,
      key: '',
      output: result['output'] as String,
    );
  }

  @override
  Future<DownloadJob> finishNormalization(
    DownloadJob job,
    String result,
  ) async {
    final data = await _call({
      'action': 'finishNormalization',
      'jobId': job.id,
      'command': result,
      'downloadIdentity': {'created': job.created, 'revision': job.revision},
    });
    return data.isEmpty ? job : DownloadJob.fromJson(data);
  }

  @override
  Future<PlaybackPlan?> localPlayback(
    Drama drama,
    Episode episode, {
    bool playback = false,
  }) async {
    final result = await _call({
      'action': 'localPlayback',
      'drama': drama.toJson(),
      'index': episode.number,
      // 只有真正的播放入口参与播放序号；导出/合并只是读取本地文件。
      if (playback) 'sequence': ++_playbackSequence,
    });
    if ((result['url'] as String? ?? '').isEmpty) return null;
    return PlaybackPlan.fromJson(result);
  }

  @override
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': true,
      'sequence': ++_playbackSequence,
    }),
  );

  @override
  Future<void> release(String session) async {
    if (session.isEmpty) {
      return;
    }
    try {
      await _call({'action': 'release', 'session': session});
    } catch (_) {}
  }
}

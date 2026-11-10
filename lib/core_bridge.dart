import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
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

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

/// 解析一次就复用的原生绑定。
///
/// dlopen 与 dlsym（含 FFI trampoline）都很贵，而这里的调用极密集（下载总览
/// 每 2 秒一次、封面最多 6 路并发），不能再按请求重复解析。
final class _NativeBindings {
  _NativeBindings() : _library = _open();

  final DynamicLibrary _library;
  late final _DartRequest _request = _library
      .lookupFunction<_NativeRequest, _DartRequest>('DuanjuRequest');
  late final _DartFree _free = _library
      .lookupFunction<_NativeFree, _DartFree>('DuanjuFree');

  static DynamicLibrary _open() {
    if (Platform.isAndroid) return DynamicLibrary.open('libduanju_core.so');
    if (Platform.isWindows) {
      return DynamicLibrary.open(
        path.join(path.dirname(Platform.resolvedExecutable), 'duanju_core.dll'),
      );
    }
    if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
    throw UnsupportedError('当前支持 Android、iOS、Windows 和 macOS');
  }

  String request(String body) {
    final input = body.toNativeUtf8();
    Pointer<Utf8> output = nullptr;
    try {
      output = _request(input);
      if (output == nullptr) throw StateError('本地核心没有返回结果');
      return output.toDartString();
    } finally {
      malloc.free(input);
      if (output != nullptr) _free(output);
    }
  }
}

/// 一次原生调用：worker 与调用方之间的交接。
final class _NativeTask {
  _NativeTask(this.body) {
    _subscription = _replies.listen(_receive);
  }

  final String body;
  final result = Completer<Map<String, dynamic>>();
  final ReceivePort _replies = ReceivePort();
  late final StreamSubscription<dynamic> _subscription;
  bool _done = false;

  SendPort get replyTo => _replies.sendPort;

  void _receive(dynamic message) {
    if (message is! List || message.length < 2) return;
    final payload = message[0];
    final failure = message[1];
    if (failure is String) {
      fail(StateError(failure));
    } else if (payload is Map) {
      complete(Map<String, dynamic>.from(payload));
    } else {
      fail(StateError('本地核心返回了无法识别的结果'));
    }
  }

  void complete(Map<String, dynamic> value) {
    if (_done) return;
    _done = true;
    _finish();
    result.complete(value);
  }

  void fail(Object error) {
    if (_done) return;
    _done = true;
    _finish();
    result.completeError(error);
  }

  void _finish() {
    unawaited(_subscription.cancel());
    _replies.close();
  }
}

/// 常驻 worker：把「每次调用新建 isolate 并重新解析绑定」的固定开销摊掉，
/// 调用本身依旧不在主 isolate 上执行。
final class _NativeWorker {
  _NativeWorker._(this._commands, ReceivePort signals) {
    _signals = signals;
    _subscription = signals.listen((_) => _died());
  }

  final SendPort _commands;
  late final ReceivePort _signals;
  late final StreamSubscription<dynamic> _subscription;
  final _dead = Completer<void>();
  _NativeTask? _running;

  bool get idle => _running == null;
  Future<void> get dead => _dead.future;

  static Future<_NativeWorker> spawn() async {
    final ready = ReceivePort();
    final signals = ReceivePort();
    final isolate = await Isolate.spawn(
      _nativeWorkerMain,
      ready.sendPort,
      onError: signals.sendPort,
      onExit: signals.sendPort,
      errorsAreFatal: true,
      debugName: 'duanju-native',
    );
    final first = await ready.first;
    ready.close();
    if (first is! SendPort) {
      // 绑定解析失败会回一个字符串：结束这个线程并把原因交给调用方。
      isolate.kill(priority: Isolate.immediate);
      signals.close();
      throw StateError('原生工作线程启动失败：$first');
    }
    return _NativeWorker._(first, signals);
  }

  void send(_NativeTask task) {
    _running = task;
    _commands.send([task.body, task.replyTo]);
  }

  /// 一次调用结束（成功或失败）：交还线程，供排队中的请求复用。
  void release(_NativeTask task) {
    if (identical(_running, task)) _running = null;
  }

  void _died() {
    // onError 与 onExit 都可能到达：只处理一次，避免重复关闭端口。
    if (_dead.isCompleted) return;
    _dead.complete();
    unawaited(_subscription.cancel());
    _signals.close();
    final running = _running;
    _running = null;
    running?.fail(StateError('原生工作线程已退出'));
  }
}

/// worker 池：空闲即复用，忙时才扩容，上限 [_limit]。
abstract final class _NativeWorkers {
  /// 与最高合法并发（封面 6 路）留出余量；超出则 FIFO 排队，不无限起线程。
  static const _limit = 8;
  static final _workers = <_NativeWorker>[];
  static final _queued = <_NativeTask>[];
  /// 正在创建中的线程数：多个请求同时到达时不能重复扩容超限。
  static int _spawning = 0;

  static Future<Map<String, dynamic>> send(String body) {
    final task = _NativeTask(body);
    _assign(task);
    return task.result.future;
  }

  static void _assign(_NativeTask task) {
    final idle = _idleWorker();
    if (idle != null) {
      _run(idle, task);
      return;
    }
    _queued.add(task);
    if (_workers.length + _spawning < _limit) {
      _spawning++;
      unawaited(_grow());
    }
  }

  static _NativeWorker? _idleWorker() =>
      _workers.where((worker) => worker.idle).firstOrNull;

  static void _run(_NativeWorker worker, _NativeTask task) {
    worker.send(task);
    // 结束（成功或失败）都必须把线程还回池，再把空闲线程交给排队请求；
    // 漏掉归还会让 _running 永远非空，池会一直扩容却再也不接单。
    unawaited(
      task.result.future
          .whenComplete(() {
            worker.release(task);
            _drain();
          })
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  static Future<void> _grow() async {
    try {
      final worker = await _NativeWorker.spawn();
      _workers.add(worker);
      unawaited(worker.dead.then((_) => _retire(worker)));
    } catch (error) {
      // 起不来就立刻失败排队请求，交给调用方的通用错误处理。
      final pending = List.of(_queued);
      _queued.clear();
      for (final task in pending) {
        task.fail(error);
      }
    } finally {
      _spawning--;
      _drain();
    }
  }

  static void _retire(_NativeWorker worker) {
    if (!_workers.remove(worker)) return;
    _drain();
    if (_queued.isNotEmpty && _workers.length + _spawning < _limit) {
      _spawning++;
      unawaited(_grow());
    }
  }

  static void _drain() {
    while (_queued.isNotEmpty) {
      final idle = _idleWorker();
      if (idle == null) return;
      _run(idle, _queued.removeAt(0));
    }
  }
}

/// worker isolate 主体：一次解析绑定，之后常驻接收请求。
void _nativeWorkerMain(SendPort ready) {
  final commands = ReceivePort();
  final _NativeBindings bindings;
  try {
    bindings = _NativeBindings();
  } catch (error) {
    // 初始化失败必须回信，否则父 isolate 会一直等在初始化端口上。
    ready.send('$error');
    commands.close();
    return;
  }
  ready.send(commands.sendPort);
  commands.listen((dynamic message) {
    if (message is! List || message.length < 2) return;
    final body = message[0];
    final reply = message[1];
    if (body is! String || reply is! SendPort) return;
    Object? payload;
    String? failure;
    try {
      payload = jsonDecode(bindings.request(body)) as Map<String, dynamic>;
    } catch (error) {
      // 单次失败只回传给调用方：worker 继续常驻，绑定仍可复用。
      failure = '$error';
    }
    reply.send([payload, failure]);
  });
}

class AppFailure implements Exception {
  AppFailure(this.message, {this.code = ''});
  final String message;
  final String code;
  @override
  String toString() => message;
}

abstract class AppRepository {
  Future<ResourceSettings> resourceSettings() async => const ResourceSettings();
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async => throw AppFailure('当前环境不支持资源设置');
  final catalogUpdates = CatalogUpdates();
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
  Future<String> downloadDirectory() async =>
      (await storage())['directory'] as String? ?? '';
  Future<void> moveDownloads(String directory) async =>
      throw AppFailure('当前环境不支持迁移');
  Future<int> workLease(String id, String command) async => 0;
  bool get supportsDownloads => false;
  Future<List<DownloadJob>> downloads() async => [];
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async => throw AppFailure('当前环境不支持下载');
  Future<void> controlDownloads(String command, {String id = ''}) async {}
  Future<DownloadConversion> beginConversion(String id) async =>
      throw AppFailure('当前环境不支持处理下载');
  Future<void> finishConversion(String id, String result) async {}
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
    return DownloadBatchResult(completed: completed, failures: failures);
  }

  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) => enqueueDownloads(detail, episodes, quality: quality);
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async =>
      null;
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
  Future<String> cover(Drama drama, {bool force = false});
  bool coverCached(Drama drama) => false;
  Future<DramaDetail> detail(Drama drama);
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0});
  Future<PlaybackPlan> fallback(PlaybackPlan current);
  Future<void> cancelPlayback();
  Future<void> release(String session);
}

class NativeRepository extends AppRepository {
  static final _coverDecoder = CoverDecoder();
  static final _coverPaths = <String, String>{};
  NativeRepository({this.background = false});
  final bool background;
  LocalStore? access;
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
    return ResourceSettings.fromJson(
      await _call({'action': 'resourceSettings'}),
    );
  }

  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async {
    _adminPermission();
    return ResourceSettings.fromJson(
      await _call({
        'action': 'saveResourceSettings',
        'settings': settings.toJson(),
      }),
    );
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
      });
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
      throw AppFailure('当前版本不包含此站源');
    }
    if (access == null) return;
    if (access!.locked ||
        !access!.allowsSource(source) ||
        download && !access!.canDownload) {
      throw AppFailure('当前用户没有此操作权限');
    }
  }

  void _downloadPermission() {
    if (access != null && (access!.locked || !access!.canDownload)) {
      throw AppFailure('当前用户仅支持在线观看');
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

  Future<Map<String, dynamic>> _call(Map<String, dynamic> input) async {
    try {
      final action = input['action'] as String;
      final unrestricted =
          {
            'initialize',
            'release',
            'cancelPlayback',
            'cancelRead',
            'updateSystemProxy',
          }.contains(action) ||
          action == 'workLease' && input['command'] == 'end' ||
          action == 'finishConversion' ||
          action == 'lan' &&
              {
                'stop',
                'respond',
                'cancel',
                'disconnect',
              }.contains(input['command']);
      final epoch = access?.profileEpoch;
      if (!unrestricted && access?.locked == true) throw AppFailure('请先解锁当前用户');
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
      final body = jsonEncode(input);
      // 常驻 worker 池：不再每次调用新建 isolate，原生绑定也只解析一次。
      // 超时只放弃等待；仍在执行的那次调用会继续占住它的 worker 直到返回。
      final response = await _NativeWorkers.send(body).timeout(
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
      if (response['ok'] != true) {
        throw AppFailure(
          response['error'] as String? ?? '读取失败，请重试',
          code: response['code'] as String? ?? '',
        );
      }
      final data = response['data'];
      if (!unrestricted && epoch != access?.profileEpoch) {
        if (data is Map && data['session'] is String) {
          await release(data['session'] as String);
        }
        if (action == 'workLease' && input['command'] == 'start') {
          await workLease(input['jobId'] as String, 'end');
        }
        throw AppFailure('用户已切换，请重新操作');
      }
      return data is Map ? Map<String, dynamic>.from(data) : {};
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      if (input['session'] is String &&
          input['sequence'] is int &&
          {
            'catalog',
            'categories',
            'suggestions',
            'recommendations',
            'metadata',
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
      throw AppFailure('站源响应超时，请重试');
    } catch (_) {
      throw AppFailure('本地核心加载失败，请使用完整安装包重新安装');
    }
  }

  @override
  Future<void> initialize() async {
    final directory = await getApplicationSupportDirectory();
    if (!background) {
      DiaryService.nativeLogPath = path.join(directory.path, 'logs', 'app.log');
    }
    final external = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : null;
    final build = await _call({
      'action': 'initialize',
      'directory': directory.path,
      if (external != null) 'downloads': path.join(external.path, 'downloads'),
    });
    if (build['allSources'] != allSourcesEnabled) {
      throw AppFailure('应用与原生核心的站源版本不一致，请使用完整安装包重新安装');
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
  bool coverCached(Drama drama) =>
      _coverPaths.containsKey('${drama.id}\u0000${drama.cover}');

  @override
  Future<String> cover(Drama drama, {bool force = false}) async {
    final key = '${drama.id}\u0000${drama.cover}';
    final known = force ? null : _coverPaths[key];
    if (known != null) {
      _authorize(drama.source);
      if (await File(known).exists()) return known;
      _coverPaths.remove(key);
    }
    final epoch = access?.profileEpoch;
    final result = await _call({
      'action': 'cover',
      'drama': drama.toJson(),
      'force': force,
    });
    final file = result['path'] as String? ?? '';
    if (file.isEmpty) throw AppFailure('海报暂不可用');
    if (result['heic'] != true) return _rememberCover(key, file);
    final converted = await _coverDecoder.convert(
      file,
      () => _call({'action': 'prepareCover', 'drama': drama.toJson()}),
      force: force,
    );
    _authorize(drama.source);
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return _rememberCover(key, converted);
  }

  String _rememberCover(String key, String path) {
    _coverPaths.remove(key);
    _coverPaths[key] = path;
    if (_coverPaths.length > 2000) _coverPaths.remove(_coverPaths.keys.first);
    return path;
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
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async {
    final result = await _call({
      'action': 'localPlayback',
      'drama': drama.toJson(),
      'index': episode.number,
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

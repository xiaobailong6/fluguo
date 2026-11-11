import 'dart:async';
import 'dart:math';

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/media_information_session.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/session_state.dart';

import 'core_bridge.dart';

class MediaProbe {
  MediaProbe(this.raw);
  final Map<String, dynamic> raw;
  List<Map<String, dynamic>> get streams => (raw['streams'] as List? ?? [])
      .whereType<Map>()
      .map((s) => Map<String, dynamic>.from(s))
      .toList();
  Map<String, dynamic> get video =>
      streams.firstWhere((s) => s['codec_type'] == 'video', orElse: () => {});
  double get duration =>
      double.tryParse('${(raw['format'] as Map?)?['duration']}') ?? 0;
  String get videoCodec => video['codec_name'] as String? ?? '';
  Map<String, dynamic> get audio =>
      streams.firstWhere((s) => s['codec_type'] == 'audio', orElse: () => {});
}

abstract class MediaExecutor {
  Future<MediaProbe> probe(String file);
  Future<void> run(
    List<String> arguments, {
    double duration = 0,
    void Function(double)? progress,
  });
  Future<void> cancel();
}


/// 取消可立即响应，文件清理必须等待原生会话确认退出。
abstract interface class MediaExitAware {
  Future<void> waitForIdle();
}
/// 原生边界必须提供真实状态；cancel 返回不代表进程已退出。
abstract class MediaNativeSessionHandle {
  Future<void> start();
  Future<void> cancel();
  Future<SessionState> getState();
}

/// 仅隔离探测插件边界，测试无需启动原生 FFprobe。
abstract class FFprobeSessionHandle implements MediaNativeSessionHandle {}

typedef FFprobeSessionFactory = Future<FFprobeSessionHandle> Function(
  List<String> arguments,
  void Function(Map<String, dynamic>?) complete,
);

class _NativeProbeSession implements FFprobeSessionHandle {
  _NativeProbeSession(this.session);
  final MediaInformationSession session;

  static Future<FFprobeSessionHandle> create(
    List<String> arguments,
    void Function(Map<String, dynamic>?) complete,
  ) async {
    final session = await MediaInformationSession.create(arguments, (result) {
      final data = result.getMediaInformation()?.getAllProperties();
      complete(data == null ? null : Map<String, dynamic>.from(data));
    });
    return _NativeProbeSession(session);
  }

  @override
  Future<void> start() =>
      FFmpegKitConfig.asyncGetMediaInformationExecute(session);

  @override
  Future<void> cancel() async {
    // 插件空 ID 会退化成全局取消，不能误伤其它执行器。
    if (session.getSessionId() != null) await session.cancel();
  }

  @override
  Future<SessionState> getState() async {
    if (session.getSessionId() == null) {
      throw StateError('原生探测会话 ID 尚未确认');
    }
    return session.getState();
  }
}

/// 调用结果与原生生命周期分离，直到回调或终态查询确认才释放占用。
abstract class _NativeOperation {
  final exited = Completer<void>();
  MediaNativeSessionHandle? session;
  bool stopped = false;
  bool startRequested = false;
  bool startSettled = false;
  bool _checkingExit = false;

  void cancelSession() {
    final current = session;
    if (current == null || exited.isCompleted) return;
    // 每次取消都可重发，即使上一次平台调用永久挂起。
    unawaited(Future<void>.sync(current.cancel).catchError((Object _) {}));
    checkExit();
  }

  void checkExit() {
    final current = session;
    if (current == null || exited.isCompleted || _checkingExit ||
        (startRequested && !startSettled)) {
      return;
    }
    _checkingExit = true;
    unawaited(() async {
      try {
        final state = await current.getState();
        // 启动请求未返回时，先前的终态可能早于迟到启动，不能释放文件。
        if ((!startRequested || startSettled) &&
            (state == SessionState.completed || state == SessionState.failed ||
                (stopped && !startRequested && state == SessionState.created)) &&
            !exited.isCompleted) {
          exited.complete();
        }
      } catch (_) {
        // 查询失败保留占用，由有界退出等待报告失败，不能假定已退出。
      } finally {
        _checkingExit = false;
      }
    }());
  }
}

class _ProbeOperation extends _NativeOperation {
  final result = Completer<MediaProbe>();
  void complete(Map<String, dynamic>? data) {
    if (!exited.isCompleted) exited.complete();
    if (result.isCompleted) return;
    if (data == null) {
      result.completeError(AppFailure('无法读取本地视频信息，请检查文件完整性。'));
    } else {
      result.complete(MediaProbe(Map<String, dynamic>.from(data)));
    }
  }

  void stop(AppFailure failure) {
    stopped = true;
    if (!result.isCompleted) result.completeError(failure);
    cancelSession();
  }
}

/// 拆分创建/启动，平台返回 ID 前也能取消等待。
abstract class FFmpegSessionHandle implements MediaNativeSessionHandle {}

typedef FFmpegSessionFactory = Future<FFmpegSessionHandle> Function(
  List<String> arguments,
  void Function(int?) complete,
  void Function(String) log,
  void Function(double) time,
);

class _NativeFFmpegSession implements FFmpegSessionHandle {
  _NativeFFmpegSession(this.session);
  final FFmpegSession session;

  static Future<FFmpegSessionHandle> create(
    List<String> arguments,
    void Function(int?) complete,
    void Function(String) log,
    void Function(double) time,
  ) async {
    final session = await FFmpegSession.create(arguments, (result) async {
      try {
        final code = await result.getReturnCode().timeout(const Duration(seconds: 30));
        complete(code?.getValue());
      } catch (_) {
        complete(null);
      }
    }, (entry) => log(entry.getMessage()),
        (statistics) => time(statistics.getTime().toDouble() / 1000));
    return _NativeFFmpegSession(session);
  }

  @override
  Future<void> start() => FFmpegKitConfig.asyncFFmpegExecute(session);

  @override
  Future<void> cancel() async {
    if (session.getSessionId() != null) await session.cancel();
  }

  @override
  Future<SessionState> getState() async {
    if (session.getSessionId() == null) {
      throw StateError('原生媒体会话 ID 尚未确认');
    }
    return session.getState();
  }
}

class _RunOperation extends _NativeOperation {
  final result = Completer<AppFailure?>();
  final tail = <String>[];
  String stage = '创建会话';
  double progress = 0;

  Timer? stageTimer;
  void log(String message) {
    if (result.isCompleted) return;
    for (var line in message.split('\n')) {
      // 不保存原命令、密钥、鉴权头或可识别的输入地址。
      if (RegExp(r'key|token|secret|authorization|cookie|password|credential|bearer|ffmpeg | -i |--',
          caseSensitive: false).hasMatch(line)) continue;
      line = line.replaceAll(RegExp(r'''["'][^"']*["']'''), '[已隐藏]')
          .replaceAll(RegExp(r'\S*[/\\]\S*'), '[路径]')
          .replaceAll(RegExp(r'[A-Za-z0-9_+=%-]{24,}'), '[已隐藏]')
          .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
      if (line.isEmpty) continue;
      tail.add(line.length > 160 ? line.substring(0, 160) : line);
      if (tail.length > 6) tail.removeAt(0);
    }
  }

  AppFailure failure(String message) => AppFailure(
      '$message（$stage），原分集已保留。'
      '${tail.isEmpty ? '' : '\n日志尾部：${tail.join('\n')}'}');

  void stop(AppFailure failure) {
    stopped = true;
    if (!result.isCompleted) result.complete(failure);
    cancelSession();
  }
}

class FFmpegExecutor implements MediaExecutor, MediaExitAware {
  FFmpegExecutor({
    Duration probeTimeout = const Duration(seconds: 30),
    Duration sessionTimeout = const Duration(seconds: 30),
    Duration? runTimeout,
    Duration exitTimeout = const Duration(seconds: 10),
    FFprobeSessionFactory? probeSessionFactory,
    FFmpegSessionFactory? sessionFactory,
  }) : _probeTimeout = probeTimeout,
       _sessionTimeout = sessionTimeout,
       _runTimeout = runTimeout,
       _exitTimeout = exitTimeout,
       _sessionFactory = sessionFactory ?? _NativeFFmpegSession.create,
       _probeSessionFactory = probeSessionFactory ?? _NativeProbeSession.create;

  final Duration _probeTimeout;
  final Duration _sessionTimeout;
  final Duration? _runTimeout;
  final Duration _exitTimeout;
  final FFmpegSessionFactory _sessionFactory;
  final FFprobeSessionFactory _probeSessionFactory;
  final Set<_ProbeOperation> _probes = {};
  final Set<_RunOperation> _runs = {};
  final Set<Future<void>> _exits = {};

  void _watchExit(_NativeOperation operation) {
    final exit = operation.exited.future;
    _exits.add(exit);
    unawaited(exit.then((_) {
      _exits.remove(exit);
      _runs.remove(operation);
      _probes.remove(operation);
    }));
  }

  @override
  Future<void> waitForIdle() async {
    if (_exits.isEmpty) return;
    void check() {
      for (final operation in <_NativeOperation>[..._runs, ..._probes]) {
        operation.checkExit();
      }
    }
    // 仅等待期间轮询，避免取消后的永久后台计时器；平台 Future 不阻塞 UI。
    final poll = Timer.periodic(const Duration(milliseconds: 100), (_) => check());
    check();
    Future<void> drain() async {
      while (_exits.isNotEmpty) {
        await Future.wait(_exits.toList());
      }
    }
    try {
      await drain().timeout(_exitTimeout, onTimeout: () {
        throw AppFailure('等待原生媒体会话退出超时，尚未确认退出，文件可能仍被占用。');
      });
    } finally {
      poll.cancel();
    }
  }

  @override
  Future<MediaProbe> probe(String file) async {
    final operation = _ProbeOperation();
    _probes.add(operation);
    _watchExit(operation);
    // 从创建会话前计时，平台迟迟不返回 ID 时也能结束等待。
    final timer = Timer(_probeTimeout, () {
      operation.stop(AppFailure('本地媒体探测超时，已中断，请检查文件完整性。'));
    });
    unawaited(_startProbe(operation, file));
    try {
      return await operation.result.future;
    } finally {
      timer.cancel();
    }
  }

  Future<void> _startProbe(_ProbeOperation operation, String file) async {
    try {
      final session = await _probeSessionFactory([
        '-v',
        'error',
        '-hide_banner',
        '-print_format',
        'json',
        '-show_format',
        '-show_streams',
        '-protocol_whitelist',
        'file,crypto,data',
        '-i',
        file,
      ], operation.complete);
      operation.session = session;
      // 取消可能早于 ID 返回：只清理该操作的会话，绝不启动或取消新会话。
      if (operation.stopped || operation.result.isCompleted) {
        if (operation.stopped) operation.cancelSession();
        return;
      }
      try {
        operation.startRequested = true;
        await session.start();
        operation.startSettled = true;
      } finally {
        // 仅成功返回才确认启动；异常也可能来自已提交的原生请求。
        if (operation.stopped) operation.cancelSession();
      }
    } catch (_) {
      if (!operation.startRequested && !operation.exited.isCompleted) operation.exited.complete();
      operation.stop(AppFailure('无法读取本地视频信息，请检查文件完整性。'));
    }
  }

  @override
  Future<void> run(
    List<String> arguments, {
    double duration = 0,
    void Function(double)? progress,
  }) async {
    final operation = _RunOperation();
    _runs.add(operation);
    _watchExit(operation);
    final timer = Timer(_runTimeout ?? _deadline(duration), () {
      operation.stop(operation.failure('本地媒体处理超时，已中断'));
    });
    unawaited(_startRun(operation, arguments, duration, progress));
    try {
      final failure = await operation.result.future;
      if (failure != null) throw failure;
    } finally {
      timer.cancel();
      operation.stageTimer?.cancel();
    }
  }

  Future<void> _startRun(
    _RunOperation operation,
    List<String> arguments,
    double duration,
    void Function(double)? progress,
  ) async {
    // 取消后即使平台调用永久挂起，也要清理阶段计时器。
    void armStage() {
      operation.stageTimer?.cancel();
      operation.stageTimer = Timer(_sessionTimeout, () {
        operation.stop(operation.failure('本地媒体处理超时，已中断'));
      });
    }
    armStage();
    try {
      final session = await _sessionFactory([
        '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
        '-protocol_whitelist', 'file,crypto,data', ...arguments,
      ], (code) {
        if (!operation.exited.isCompleted) operation.exited.complete();
        if (operation.result.isCompleted) return;
        operation.result.complete(code == 0 ? null : operation.failure(
            code == 255 ? '已取消本地媒体处理' : '本地媒体处理失败（${code ?? -1}）'));
      }, operation.log, (seconds) {
        if (operation.result.isCompleted || operation.stopped ||
            !seconds.isFinite || !duration.isFinite || duration <= 0) return;
        final value = (seconds / duration).clamp(0.0, .99).toDouble();
        if (value <= operation.progress) return;
        operation.progress = value;
        progress?.call(value);
      });
      operation.session = session;
      if (operation.stopped || operation.result.isCompleted) {
        if (operation.stopped) operation.cancelSession();
        return;
      }
      operation.stage = '启动会话';
      armStage();
      try {
        operation.startRequested = true;
        await session.start();
        operation.startSettled = true;
      } finally {
        if (operation.stopped) operation.cancelSession();
      }
      operation.stage = '等待处理结果';
    } catch (_) {
      if (!operation.startRequested && !operation.exited.isCompleted) operation.exited.complete();
      operation.stop(operation.failure('无法启动本地媒体处理'));
    } finally {
      operation.stageTimer?.cancel();
    }
  }

  /// 处理上限：按媒体时长留四倍余量再加三分钟；时长未知时给十五分钟兜底。
  static Duration _deadline(double duration) {
    final estimate = duration.isFinite && duration > 0 ? duration * 4 + 180 : 900;
    final seconds = estimate.clamp(300.0, 6 * 3600.0).toDouble();
    return Duration(milliseconds: (seconds * 1000).round());
  }

  @override
  Future<void> cancel() async {
    for (final operation in _runs.toList()) {
      operation.stop(operation.failure('已取消本地媒体处理'));
    }
    for (final operation in _probes.toList()) {
      operation.stop(AppFailure('已取消本地媒体处理'));
    }
  }
}

void verifyMediaDuration(MediaProbe probe, double expected) {
  if (probe.videoCodec.isEmpty ||
      !probe.duration.isFinite ||
      probe.duration <= 0 ||
      expected > 0 &&
          (probe.duration - expected).abs() > max(2, expected * .02)) {
    throw AppFailure('生成的视频时长或视频轨不完整，原分集已保留。');
  }
}

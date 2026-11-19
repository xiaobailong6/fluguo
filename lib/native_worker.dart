import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

import 'native_request_pool.dart';

/// 共享调度器仍按 lane 控制并发；仓库只处理业务权限与协议，不直接持有 C 指针。
final nativeRequests = NativeRequestDispatcher(_NativeWorker.spawn);

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

/// 每个常驻 worker 解析一次绑定，保留原先的输入/输出配对释放约定。
final class _NativeBindings {
  _NativeBindings() : _library = _open();

  final DynamicLibrary _library;
  late final _DartRequest _request = _library
      .lookupFunction<_NativeRequest, _DartRequest>('DuanjuRequest');
  late final _DartFree _free = _library.lookupFunction<_NativeFree, _DartFree>(
    'DuanjuFree',
  );

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

/// 调用方超时不释放仍在执行 C 调用的 worker，避免越过池的并发上限。
final class _NativeWorker implements NativeRequestWorker {
  _NativeWorker._(this._commands, ReceivePort signals) {
    _signals = signals;
    _subscription = signals.listen((_) => _died());
  }

  final SendPort _commands;
  late final ReceivePort _signals;
  late final StreamSubscription<dynamic> _subscription;
  final _dead = Completer<void>();
  _NativeTask? _running;

  @override
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
      isolate.kill(priority: Isolate.immediate);
      signals.close();
      throw StateError('原生工作线程启动失败：$first');
    }
    return _NativeWorker._(first, signals);
  }

  @override
  Future<Map<String, dynamic>> execute(String body) async {
    if (_dead.isCompleted) throw StateError('原生工作线程已退出');
    if (_running != null) throw StateError('原生工作线程仍在执行请求');
    final task = _NativeTask(body);
    _running = task;
    _commands.send([task.body, task.replyTo]);
    try {
      return await task.result.future;
    } finally {
      if (identical(_running, task)) _running = null;
    }
  }

  void _died() {
    // onError 与 onExit 可能连续到达，结果与端口只结束一次。
    if (_dead.isCompleted) return;
    _dead.complete();
    unawaited(_subscription.cancel());
    _signals.close();
    final running = _running;
    _running = null;
    running?.fail(StateError('原生工作线程已退出'));
  }
}

void _nativeWorkerMain(SendPort ready) {
  final commands = ReceivePort();
  final _NativeBindings bindings;
  try {
    bindings = _NativeBindings();
  } catch (error) {
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
      // 单次调用失败不销毁绑定，下一个请求仍可继续执行。
      failure = '$error';
    }
    reply.send([payload, failure]);
  });
}

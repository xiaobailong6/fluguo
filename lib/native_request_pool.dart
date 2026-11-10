import 'dart:async';
import 'dart:collection';
import 'dart:convert';

/// 调度层不依赖 FFI，回归测试可用受控 worker 模拟阻塞和退出。
abstract interface class NativeRequestWorker {
  Future<void> get dead;
  Future<Map<String, dynamic>> execute(String body);
}

class NativeRequestCancelled implements Exception {
  const NativeRequestCancelled();

  @override
  String toString() => '请求已取消';
}

/// 普通调用与控制调用分池，避免取消请求排在它要取消的同步 FFI 后面。
class NativeRequestDispatcher {
  NativeRequestDispatcher(
    Future<NativeRequestWorker> Function() spawn, {
    int concurrency = 8,
    int controlConcurrency = 2,
  }) : _requests = _RequestPool(spawn, concurrency),
       _controls = _RequestPool(spawn, controlConcurrency);

  final _RequestPool _requests;
  final _RequestPool _controls;

  Future<Map<String, dynamic>> send(
    Map<String, dynamic> input, {
    required Duration timeout,
    bool Function()? isCurrent,
  }) {
    final action = input['action'];
    final sequence = input['sequence'];
    final session = input['session'];
    if (action == 'cancelRead' && session is String && sequence is int) {
      _requests.cancelQueued(
        (pending) =>
            pending['session'] == session &&
            pending['sequence'] is int &&
            (pending['sequence'] as int) <= sequence,
      );
    } else if (action == 'cancelPlayback' && sequence is int) {
      _requests.cancelQueued(
        (pending) =>
            const {
              'resolve',
              'fallback',
              'localPlayback',
            }.contains(pending['action']) &&
            pending['sequence'] is int &&
            (pending['sequence'] as int) <= sequence,
      );
    } else if (session is String && sequence is int) {
      // 同一读取范围只保留最新意图；不同站源、不同范围互不取消。
      _requests.cancelQueued(
        (pending) =>
            pending['session'] == session &&
            pending['sequence'] is int &&
            (pending['sequence'] as int) < sequence,
      );
    }
    final control = const {
      'cancelRead',
      'cancelPlayback',
      'release',
    }.contains(action);
    return (control ? _controls : _requests).send(
      input,
      timeout: timeout,
      isCurrent: isCurrent,
    );
  }
}

class _QueuedRequest {
  _QueuedRequest(this.input, this.timeout, this.isCurrent);

  final Map<String, dynamic> input;
  final Duration timeout;
  final bool Function()? isCurrent;
  final result = Completer<Map<String, dynamic>>();
  final elapsed = Stopwatch()..start();
  Timer? timer;

  void fail(Object error, [StackTrace? stack]) {
    if (result.isCompleted) return;
    timer?.cancel();
    elapsed.stop();
    result.completeError(error, stack);
  }

  void complete(Map<String, dynamic> value) {
    if (result.isCompleted) return;
    timer?.cancel();
    elapsed.stop();
    result.complete(value);
  }

  bool ready() {
    if (result.isCompleted) return false;
    // 同步派发前也检查截止时间，不能依赖 Timer 回调恰好先于空闲通知运行。
    if (elapsed.elapsed >= timeout) {
      fail(TimeoutException('原生请求超时', timeout));
      return false;
    }
    try {
      if (isCurrent != null && !isCurrent!()) {
        fail(const NativeRequestCancelled());
        return false;
      }
    } catch (error, stack) {
      fail(error, stack);
      return false;
    }
    return true;
  }
}

class _RequestPool {
  _RequestPool(this.spawn, this.limit) : assert(limit > 0);

  final Future<NativeRequestWorker> Function() spawn;
  final int limit;
  final _workers = <NativeRequestWorker>{};
  final _busy = <NativeRequestWorker>{};
  final _queued = Queue<_QueuedRequest>();
  int _spawning = 0;

  Future<Map<String, dynamic>> send(
    Map<String, dynamic> input, {
    required Duration timeout,
    bool Function()? isCurrent,
  }) {
    final task = _QueuedRequest(Map.unmodifiable(input), timeout, isCurrent);
    task.timer = Timer(timeout, () {
      _queued.remove(task);
      task.fail(TimeoutException('原生请求超时', timeout));
      // 在途调用不释放 worker；只有底层真正返回或退出后才能接下一次调用。
    });
    _queued.add(task);
    _drain();
    return task.result.future;
  }

  void cancelQueued(bool Function(Map<String, dynamic>) matches) {
    final cancelled = _queued.where((task) => matches(task.input)).toList();
    for (final task in cancelled) {
      _queued.remove(task);
      task.fail(const NativeRequestCancelled());
    }
  }

  void _drain() {
    while (_queued.isNotEmpty) {
      if (!_queued.first.ready()) {
        _queued.removeFirst();
        continue;
      }
      final idle = _workers
          .where((worker) => !_busy.contains(worker))
          .firstOrNull;
      if (idle == null) break;
      final task = _queued.removeFirst();
      _busy.add(idle);
      unawaited(_run(idle, task));
    }
    // 把正在创建的 worker 也计入预算，防止突发请求重复扩容。
    while (_spawning < _queued.length && _workers.length + _spawning < limit) {
      _spawning++;
      unawaited(_grow());
    }
  }

  Future<void> _run(NativeRequestWorker worker, _QueuedRequest task) async {
    try {
      task.complete(await worker.execute(jsonEncode(task.input)));
    } catch (error, stack) {
      task.fail(error, stack);
    } finally {
      _busy.remove(worker);
      _drain();
    }
  }

  Future<void> _grow() async {
    try {
      final worker = await spawn();
      _workers.add(worker);
      unawaited(
        worker.dead.then((_) {
          _workers.remove(worker);
          _busy.remove(worker);
          _drain();
        }),
      );
    } catch (error, stack) {
      final pending = _queued.toList();
      _queued.clear();
      for (final task in pending) {
        task.fail(error, stack);
      }
    } finally {
      _spawning--;
      _drain();
    }
  }
}

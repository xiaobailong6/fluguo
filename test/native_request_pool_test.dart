import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/native_request_pool.dart';
import 'package:flutter_test/flutter_test.dart';

const _timeout = Duration(seconds: 5);
const _ok = <String, dynamic>{'ok': true};

class _Worker implements NativeRequestWorker {
  _Worker(this.run);
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) run;
  final exit = Completer<void>();

  @override
  Future<void> get dead => exit.future;

  @override
  Future<Map<String, dynamic>> execute(String body) =>
      run(jsonDecode(body) as Map<String, dynamic>);
}

void main() {
  test('七路普通请求和一路播放全部阻塞时，控制通道仍可用', () async {
    final blocked = Completer<Map<String, dynamic>>();
    final entered = Completer<void>();
    final actions = <String>[];
    var spawned = 0;
    final dispatcher = NativeRequestDispatcher(() async {
      spawned++;
      return _Worker((input) {
        final action = input['action'] as String;
        actions.add(action);
        if (action == 'detail' || action == 'resolve') {
          if (actions.length == 8) {
            entered.complete();
          }
          return blocked.future;
        }
        return Future.value(_ok);
      });
    });
    final requests = List.generate(
      8,
      (index) => dispatcher.send(
        index == 7
            ? {'action': 'resolve', 'sequence': 1}
            : {'action': 'detail'},
        timeout: _timeout,
      ),
    );
    await entered.future;
    expect(spawned, 8);
    for (final action in ['cancelRead', 'cancelPlayback', 'release']) {
      expect(await dispatcher.send({'action': action}, timeout: _timeout), _ok);
    }
    expect(spawned, 9);
    expect(blocked.isCompleted, isFalse);
    blocked.complete(_ok);
    await Future.wait(requests);
  });

  test('后台饱和时保留一席播放，预加载和本地探测不能占用', () async {
    final blocked = Completer<Map<String, dynamic>>();
    final actions = <String>[];
    var peak = 0, busy = 0;
    final dispatcher = NativeRequestDispatcher(
      () async => _Worker((input) async {
        actions.add(input['action'] as String);
        busy++;
        if (busy > peak) peak = busy;
        final result = input['sequence'] == 42 ? _ok : await blocked.future;
        busy--;
        return result;
      }),
    );
    final background = [
      for (var i = 0; i < 8; i++)
        dispatcher.send({'action': 'detail'}, timeout: _timeout),
      dispatcher.send({'action': 'preload', 'sequence': 1}, timeout: _timeout),
      dispatcher.send({'action': 'localPlayback'}, timeout: _timeout),
    ];
    await pumpEventQueue();
    expect(actions, hasLength(7));
    expect(
      await dispatcher.send({
        'action': 'resolve',
        'sequence': 42,
      }, timeout: _timeout),
      _ok,
    );
    expect(actions.last, 'resolve');
    expect(actions, hasLength(8));
    expect(peak, 8);
    blocked.complete(_ok);
    await Future.wait(background);
    expect(actions, hasLength(11));
  });

  test('连续播放优先请求之间普通队列仍有机会执行', () async {
    final blocked = Completer<Map<String, dynamic>>();
    final order = <String>[];
    final dispatcher = NativeRequestDispatcher(
      () async => _Worker((input) {
        order.add(input['id'] as String);
        return input['id'] == 'held' ? blocked.future : Future.value(_ok);
      }),
      concurrency: 1,
    );
    final first = dispatcher.send({
      'action': 'detail',
      'id': 'held',
    }, timeout: _timeout);
    await pumpEventQueue();
    final pending = [
      dispatcher.send({
        'action': 'catalog',
        'id': 'catalog',
      }, timeout: _timeout),
      for (var i = 1; i <= 5; i++)
        dispatcher.send({
          'action': 'resolve',
          'sequence': i,
          'id': 'p$i',
        }, timeout: _timeout),
      dispatcher.send({
        'action': 'downloads',
        'id': 'downloads',
      }, timeout: _timeout),
    ];
    blocked.complete(_ok);
    await Future.wait([first, ...pending]);
    expect(order, [
      'held',
      'p1',
      'p2',
      'p3',
      'catalog',
      'p4',
      'p5',
      'downloads',
    ]);
  });

  test('队列超时的请求不会在 worker 空闲后补执行', () async {
    final blocked = Completer<Map<String, dynamic>>();
    final actions = <String>[];
    final dispatcher = NativeRequestDispatcher(
      () async => _Worker((input) {
        actions.add(input['action'] as String);
        return blocked.future;
      }),
      concurrency: 1,
    );
    final first = dispatcher.send({'action': 'detail'}, timeout: _timeout);
    await pumpEventQueue();
    await expectLater(
      dispatcher.send({
        'action': 'enqueueDownloads',
      }, timeout: const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
    blocked.complete(_ok);
    await first;
    await pumpEventQueue();
    expect(actions, ['detail']);
  });

  test('在途超时不提前复用 worker，原调用返回后才派发下一项', () async {
    final blocked = Completer<Map<String, dynamic>>();
    final actions = <String>[];
    var spawned = 0;
    final dispatcher = NativeRequestDispatcher(() async {
      spawned++;
      return _Worker((input) {
        actions.add(input['action'] as String);
        return input['action'] == 'detail' ? blocked.future : Future.value(_ok);
      });
    }, concurrency: 1);
    await expectLater(
      dispatcher.send({
        'action': 'detail',
      }, timeout: const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
    final next = dispatcher.send({'action': 'downloads'}, timeout: _timeout);
    await pumpEventQueue();
    expect(actions, ['detail']);
    expect(spawned, 1);
    blocked.complete(_ok);
    expect(await next, _ok);
    expect(actions, ['detail', 'downloads']);
  });

  test('取消排队读取只移除对应 session 与序号，保留其他范围', () async {
    final blocked = Completer<Map<String, dynamic>>();
    final actions = <Map<String, dynamic>>[];
    final dispatcher = NativeRequestDispatcher(
      () async => _Worker((input) {
        actions.add(input);
        return input['action'] == 'detail' ? blocked.future : Future.value(_ok);
      }),
      concurrency: 1,
    );
    final first = dispatcher.send({'action': 'detail'}, timeout: _timeout);
    await pumpEventQueue();
    final cancelled = expectLater(
      dispatcher.send({
        'action': 'catalog',
        'session': 'a',
        'sequence': 1,
      }, timeout: _timeout),
      throwsA(isA<NativeRequestCancelled>()),
    );
    final other = dispatcher.send({
      'action': 'catalog',
      'session': 'b',
      'sequence': 1,
    }, timeout: _timeout);
    await dispatcher.send({
      'action': 'cancelRead',
      'session': 'a',
      'sequence': 1,
    }, timeout: _timeout);
    await cancelled;
    blocked.complete(_ok);
    await Future.wait([first, other]);
    expect(
      actions.where((input) => input['action'] == 'catalog').single['session'],
      'b',
    );
  });

  test('同范围新读取替换排队旧读取，旧取消不误删新序号', () async {
    final blocked = Completer<Map<String, dynamic>>();
    final actions = <Map<String, dynamic>>[];
    final dispatcher = NativeRequestDispatcher(
      () async => _Worker((input) {
        actions.add(input);
        return input['action'] == 'detail' ? blocked.future : Future.value(_ok);
      }),
      concurrency: 1,
    );
    final first = dispatcher.send({'action': 'detail'}, timeout: _timeout);
    await pumpEventQueue();
    final old = expectLater(
      dispatcher.send({
        'action': 'catalog',
        'session': 'a',
        'sequence': 1,
      }, timeout: _timeout),
      throwsA(isA<NativeRequestCancelled>()),
    );
    final next = dispatcher.send({
      'action': 'catalog',
      'session': 'a',
      'sequence': 2,
    }, timeout: _timeout);
    await old;
    await dispatcher.send({
      'action': 'cancelRead',
      'session': 'a',
      'sequence': 1,
    }, timeout: _timeout);
    blocked.complete(_ok);
    await Future.wait([first, next]);
    expect(
      actions.where((input) => input['action'] == 'catalog').single['sequence'],
      2,
    );
  });

  test('取消播放时丢弃排队的旧播放解析', () async {
    final blocked = Completer<Map<String, dynamic>>();
    final actions = <String>[];
    final dispatcher = NativeRequestDispatcher(
      () async => _Worker((input) {
        actions.add(input['action'] as String);
        return input['action'] == 'detail' ? blocked.future : Future.value(_ok);
      }),
      concurrency: 1,
    );
    final first = dispatcher.send({'action': 'detail'}, timeout: _timeout);
    await pumpEventQueue();
    final old = expectLater(
      dispatcher.send({'action': 'resolve', 'sequence': 1}, timeout: _timeout),
      throwsA(isA<NativeRequestCancelled>()),
    );
    await dispatcher.send({
      'action': 'cancelPlayback',
      'sequence': 2,
    }, timeout: _timeout);
    await old;
    blocked.complete(_ok);
    await first;
    expect(actions, ['detail', 'cancelPlayback']);
  });

  test('排队期间用户或请求意图失效时不执行', () async {
    final blocked = Completer<Map<String, dynamic>>();
    final actions = <String>[];
    var current = true;
    final dispatcher = NativeRequestDispatcher(
      () async => _Worker((input) {
        actions.add(input['action'] as String);
        return blocked.future;
      }),
      concurrency: 1,
    );
    final first = dispatcher.send({'action': 'detail'}, timeout: _timeout);
    await pumpEventQueue();
    final stale = expectLater(
      dispatcher.send(
        {'action': 'enqueueDownloads'},
        timeout: _timeout,
        isCurrent: () => current,
      ),
      throwsA(isA<NativeRequestCancelled>()),
    );
    current = false;
    blocked.complete(_ok);
    await first;
    await stale;
    expect(actions, ['detail']);
  });

  test('worker 创建期间已超时的任务不会执行', () async {
    final spawning = Completer<NativeRequestWorker>();
    var executions = 0;
    final dispatcher = NativeRequestDispatcher(
      () => spawning.future,
      concurrency: 1,
    );
    await expectLater(
      dispatcher.send({
        'action': 'detail',
      }, timeout: const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
    spawning.complete(
      _Worker((_) async {
        executions++;
        return _ok;
      }),
    );
    await pumpEventQueue();
    expect(executions, 0);
    expect(
      await dispatcher.send({'action': 'downloads'}, timeout: _timeout),
      _ok,
    );
    expect(executions, 1);
  });

  test('worker 创建失败后下次请求可以重新创建', () async {
    var attempts = 0;
    final dispatcher = NativeRequestDispatcher(() async {
      if (++attempts == 1) throw StateError('spawn failed');
      return _Worker((_) async => _ok);
    }, concurrency: 1);
    await expectLater(
      dispatcher.send({'action': 'detail'}, timeout: _timeout),
      throwsStateError,
    );
    expect(await dispatcher.send({'action': 'detail'}, timeout: _timeout), _ok);
  });

  test('执行失败后同一 worker 可继续处理下一项', () async {
    var spawned = 0;
    var attempts = 0;
    final dispatcher = NativeRequestDispatcher(() async {
      spawned++;
      return _Worker((_) async {
        if (++attempts == 1) throw StateError('request failed');
        return _ok;
      });
    }, concurrency: 1);
    await expectLater(
      dispatcher.send({'action': 'detail'}, timeout: _timeout),
      throwsStateError,
    );
    expect(await dispatcher.send({'action': 'detail'}, timeout: _timeout), _ok);
    expect(spawned, 1);
  });

  test('空闲 worker 退出后重新创建，不把请求交给已退出线程', () async {
    final workers = <_Worker>[];
    final dispatcher = NativeRequestDispatcher(() async {
      final worker = _Worker((_) async => _ok);
      workers.add(worker);
      return worker;
    }, concurrency: 1);
    await dispatcher.send({'action': 'detail'}, timeout: _timeout);
    workers.single.exit.complete();
    await pumpEventQueue();
    expect(await dispatcher.send({'action': 'detail'}, timeout: _timeout), _ok);
    expect(workers, hasLength(2));
  });

  test('有效性检查失败不派发任务，下一次请求不受影响', () async {
    var executions = 0;
    final dispatcher = NativeRequestDispatcher(
      () async => _Worker((_) async {
        executions++;
        return _ok;
      }),
    );
    await expectLater(
      dispatcher.send(
        {'action': 'detail'},
        timeout: _timeout,
        isCurrent: () => throw StateError('validation failed'),
      ),
      throwsStateError,
    );
    expect(executions, 0);
    expect(await dispatcher.send({'action': 'detail'}, timeout: _timeout), _ok);
    expect(executions, 1);
  });
}

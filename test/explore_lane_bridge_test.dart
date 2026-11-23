import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/native_request_pool.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReadWorker implements NativeRequestWorker {
  _ReadWorker(this.run);
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) run;
  final _dead = Completer<void>();

  @override
  Future<void> get dead => _dead.future;

  @override
  Future<Map<String, dynamic>> execute(String body) =>
      run(jsonDecode(body) as Map<String, dynamic>);
}

// 与 Go validNativeRead 的线上协议相同，避免 FakeRepository 绕过边界校验。
bool _validRead(Map<String, dynamic> input) {
  final session = input['session'] as String;
  return utf8.encode(session).length <= 128 &&
      RegExp(r'^[0-9a-zA-Z_:.\-]+$').hasMatch(session) &&
      (input['sequence'] as int) > 0;
}

Map<String, dynamic> _response() => {
  'ok': true,
  'data': {'items': <Object>[], 'page': 1},
};

Future<Object> _load(
  NativeRepository repository,
  String kind,
  String lane, {
  int page = 1,
  bool force = false,
}) => switch (kind) {
  'recommendations' => repository.recommendationsInLane(
    'short_play',
    lane: lane,
    more: page > 1,
    force: force,
  ),
  'rankings' => repository.rankingsInLane(
    'hongguo-hot',
    lane: lane,
    page: page,
    force: force,
  ),
  _ => repository.catalogInLane(
    kind,
    lane: lane,
    category: 'short_play',
    page: page,
    force: force,
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final kind in ['hongguo', 'fanguo', 'recommendations', 'rankings']) {
    test('$kind 分类加载、刷新和翻页的标识符合原生协议', () async {
      final calls = <Map<String, dynamic>>[];
      final repository = NativeRepository(
        dispatcher: NativeRequestDispatcher(
          () async => _ReadWorker((input) async {
            calls.add(input);
            if (!_validRead(input)) {
              return {'ok': false, 'error': '请求标记无效'};
            }
            return _response();
          }),
        ),
      );
      const lane = '2147483647-123';
      await _load(repository, kind, lane);
      await _load(repository, kind, lane, force: true);
      await _load(repository, kind, lane, page: 2);
      expect(calls, hasLength(3));
      expect(calls.map((input) => input['session']).toSet(), hasLength(1));
      expect(calls.map((input) => input['sequence']), [1, 2, 3]);
      expect(calls.map((input) => input['force']), [false, true, false]);
      expect(
        calls.last[kind == 'recommendations' ? 'command' : 'page'],
        kind == 'recommendations' ? 'more' : 2,
      );
    });
  }

  test('取消通道使用原请求标识，前缀相近的邻页与推荐不受影响', () async {
    final calls = <Map<String, dynamic>>[];
    final pending = <String, Completer<Map<String, dynamic>>>{};
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _ReadWorker((input) async {
          calls.add(input);
          if (!_validRead(input)) {
            return {'ok': false, 'error': '请求标记无效'};
          }
          final session = input['session'] as String;
          if (input['action'] == 'cancelRead') {
            pending.remove(session)!.complete({
              'ok': false,
              'error': '请求已取消',
              'code': 'cancelled',
            });
            return _response();
          }
          final result = Completer<Map<String, dynamic>>();
          pending[session] = result;
          return result.future;
        }),
      ),
    );
    final cancelled = expectLater(
      _load(repository, 'hongguo', '42-1'),
      throwsA(isA<AppFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    final neighbor = _load(repository, 'rankings', '42-10');
    final recommended = _load(repository, 'recommendations', '42-11');
    await pumpEventQueue();
    expect(pending, hasLength(3));
    expect(
      calls.take(3).map((input) => input['session']).toSet(),
      hasLength(3),
    );
    await repository.cancelExploreLane('42-1');
    await cancelled;
    final cancellation = calls.where(
      (input) => input['action'] == 'cancelRead',
    );
    expect(cancellation, hasLength(1));
    expect(cancellation.single['session'], calls.first['session']);
    expect(cancellation.single['sequence'], calls.first['sequence']);
    expect(pending, hasLength(2));
    for (final result in pending.values) {
      result.complete(_response());
    }
    await Future.wait([neighbor, recommended]);
    await repository.cancelExploreLane('42-1');
    expect(
      calls.where((input) => input['action'] == 'cancelRead'),
      hasLength(1),
    );
  });
  test('连续500个已完成分类复用原生槽位，不耗尽128个历史标记', () async {
    final sessions = <String>{};
    var sequence = 0;
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _ReadWorker((input) async {
          expect(_validRead(input), isTrue);
          sessions.add(input['session'] as String);
          expect(input['sequence'] as int, greaterThan(sequence));
          sequence = input['sequence'] as int;
          if (sessions.length > 128) {
            return {'ok': false, 'error': '正在处理的请求较多，请稍后重试'};
          }
          return _response();
        }),
      ),
    );
    for (var i = 0; i < 500; i++) {
      await _load(repository, 'hongguo', 'feed-$i');
    }
    expect(sessions, hasLength(1));
  });

  test('完成后复用槽位，旧lane迟到取消不影响新lane', () async {
    final calls = <Map<String, dynamic>>[];
    final pending = Completer<Map<String, dynamic>>();
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _ReadWorker((input) async {
          calls.add(input);
          if (calls.length == 1 || input['action'] == 'cancelRead') {
            return _response();
          }
          return pending.future;
        }),
      ),
    );
    await _load(repository, 'hongguo', 'old');
    final fresh = _load(repository, 'hongguo', 'new');
    await pumpEventQueue();
    await repository.cancelExploreLane('old');
    expect(calls, hasLength(2));
    expect(calls.first['session'], calls.last['session']);
    expect(
      calls.last['sequence'] as int,
      greaterThan(calls.first['sequence'] as int),
    );
    pending.complete(_response());
    await fresh;
  });

  test('同lane重叠刷新全部结束前不把槽位借给邻页', () async {
    final calls = <Map<String, dynamic>>[];
    final pending = <Completer<Map<String, dynamic>>>[];
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _ReadWorker((input) async {
          calls.add(input);
          final task = Completer<Map<String, dynamic>>();
          pending.add(task);
          return task.future;
        }),
      ),
    );
    final old = _load(repository, 'hongguo', 'a');
    await pumpEventQueue();
    final refresh = _load(repository, 'hongguo', 'a', force: true);
    await pumpEventQueue();
    pending[1].complete(_response());
    await refresh;
    final neighbor = _load(repository, 'rankings', 'b');
    await pumpEventQueue();
    expect(calls[0]['session'], calls[1]['session']);
    expect(calls[2]['session'], isNot(calls[0]['session']));
    pending[0].complete(_response());
    pending[2].complete(_response());
    await Future.wait([old, neighbor]);
  });
}

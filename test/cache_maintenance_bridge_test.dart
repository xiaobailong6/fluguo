import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/native_request_pool.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Worker implements NativeRequestWorker {
  _Worker(this.run);
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) run;
  final _dead = Completer<void>();
  @override
  Future<void> get dead => _dead.future;
  @override
  Future<Map<String, dynamic>> execute(String body) =>
      run(jsonDecode(body) as Map<String, dynamic>);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cache clearing is administrator-only before native dispatch', () async {
    final store = await openStore({
      'profiles': jsonEncode([
        LocalProfile(
          id: 'default',
          name: 'Admin',
          admin: true,
          salt: '0' * 32,
          pinHash: '1' * 64,
        ).toJson(),
        LocalProfile(
          id: 'viewer',
          name: 'Viewer',
          sources: ['hongguo'],
          download: false,
        ).toJson(),
      ]),
      'activeProfile': 'viewer',
    });
    var called = false;
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _Worker((_) async {
          called = true;
          return {'ok': true, 'data': <String, dynamic>{}};
        }),
      ),
    )..access = store;
    await expectLater(repository.clearCache(), throwsA(isA<AppFailure>()));
    expect(called, isFalse);
  });

  test(
    'cache barrier rejects duplicate clearing and invalidates stale reads',
    () async {
      final oldRead = Completer<Map<String, dynamic>>();
      final clear = Completer<Map<String, dynamic>>();
      var clears = 0;
      final repository = NativeRepository(
        dispatcher: NativeRequestDispatcher(
          () async => _Worker((input) async {
            if (input['action'] == 'catalog') return oldRead.future;
            if (input['action'] == 'clearCache') {
              clears++;
              return clear.future;
            }
            return {'ok': true, 'data': <String, dynamic>{}};
          }),
          concurrency: 3, // 两个普通请求槽 + 一个播放预留槽。
        ),
      )..access = await openStore();
      final before = repository.cacheChanges.value;
      final stale = expectLater(
        repository.catalog('hongguo'),
        throwsA(isA<AppFailure>()),
      );
      await pumpEventQueue();
      final clearing = repository.clearCache();
      await pumpEventQueue();
      await expectLater(repository.clearCache(), throwsA(isA<AppFailure>()));
      expect(clears, 1);
      clear.complete({
        'ok': true,
        'data': {'clearedBytes': 12, 'remainingBytes': 0},
      });
      expect((await clearing)['clearedBytes'], 12);
      expect(repository.cacheChanges.value, before + 1);
      oldRead.complete({
        'ok': true,
        'data': {'items': [], 'page': 1},
      });
      await stale;
    },
  );

  test(
    'partial cache failure still invalidates memory and releases barrier',
    () async {
      var fail = true;
      final repository = NativeRepository(
        dispatcher: NativeRequestDispatcher(
          () async => _Worker(
            (_) async => fail
                ? {'ok': false, 'error': 'synthetic partial deletion'}
                : {
                    'ok': true,
                    'data': {'clearedBytes': 0, 'remainingBytes': 0},
                  },
          ),
        ),
      )..access = await openStore();
      final before = repository.cacheChanges.value;
      await expectLater(repository.clearCache(), throwsA(isA<AppFailure>()));
      expect(repository.cacheChanges.value, before + 1);
      fail = false;
      await repository.clearCache();
      expect(repository.cacheChanges.value, before + 2);
    },
  );

  test('seasons use the same source permissions as detail', () async {
    final repository = NativeRepository();
    await expectLater(
      repository.seasons(drama('1', source: 'unknown')),
      throwsA(isA<AppFailure>()),
    );
  });

  test(
    'queued old reads are dropped; new reads wait until invalidation',
    () async {
      final blocker = Completer<Map<String, dynamic>>();
      final clear = Completer<Map<String, dynamic>>();
      final actions = <String>[];
      late NativeRepository repository;
      late int before;
      repository = NativeRepository(
        dispatcher: NativeRequestDispatcher(
          () async => _Worker((input) async {
            final action = input['action'] as String;
            actions.add(action);
            if (action == 'storage') return blocker.future;
            if (action == 'clearCache') return clear.future;
            if (action == 'cached') {
              expect(repository.cacheChanges.value, before + 1);
            }
            return {
              'ok': true,
              'data': {'items': [], 'page': 1},
            };
          }),
          concurrency: 1,
        ),
      )..access = await openStore();
      before = repository.cacheChanges.value;
      final occupied = repository.storage();
      await pumpEventQueue();
      final stale = expectLater(
        repository.catalog('hongguo'),
        throwsA(isA<AppFailure>()),
      );
      final clearing = repository.clearCache();
      await pumpEventQueue();
      final fresh = repository.cached('hongguo');
      blocker.complete({'ok': true, 'data': <String, dynamic>{}});
      await occupied;
      await stale;
      await pumpEventQueue();
      expect(actions, ['storage', 'clearCache']);
      clear.complete({
        'ok': true,
        'data': {'clearedBytes': 0, 'remainingBytes': 0},
      });
      await clearing;
      await fresh;
      expect(actions, ['storage', 'clearCache', 'cached']);
    },
  );
}

import 'dart:convert';
import 'dart:io';

import '../lib/local_file_store.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

/// 不依赖 Flutter 引擎的真实磁盘回归检查。传入临时目录，不接触应用数据。
Future<void> main(List<String> args) async {
  final root = args.isEmpty ? Directory.systemTemp : Directory(args.single);
  final directory = await root.createTemp('file-store-check-');
  try {
    final store = LocalFileStore(directory);
    await store.load();
    check(!store.initialized, 'new store unexpectedly initialized');
    final initial = <String, Object>{
      'profiles': '[{"id":"default","admin":true}]',
      'activeProfile': 'default',
      'history': '[{"episode":1}]',
      'liveFavorites': '[]',
      'favorites': '[{"id":"favorite"}]',
      'profile.viewer.history': '[{"episode":9}]',
      'themeMode': 'system',
    };
    await store.commit(initial);
    final user = File('${directory.path}/users.json');
    final favorite = File('${directory.path}/profiles/default/favorites.json');
    final marker = File('${directory.path}/initialized');
    final history = File('${directory.path}/profiles/default/history.json');
    final other = File('${directory.path}/profiles/viewer/history.json');
    for (final file in [user, favorite, marker, other]) {
      await file.setLastModified(DateTime(2001));
    }
    final before = {
      for (final file in [user, favorite, marker, other])
        file.path: await file.lastModified(),
    };
    await store.commit({...initial, 'history': '[{"episode":2}]'});
    for (final file in [user, favorite, marker, other]) {
      check(
        await file.lastModified() == before[file.path],
        'history update rewrote ${file.path}',
      );
    }
    check(
      jsonDecode(
            await File('${history.path}.bak').readAsString(),
          )['values']['history'] ==
          initial['history'],
      'history previous version missing',
    );
    final restarted = LocalFileStore(directory);
    await restarted.load();
    check(
      restarted.values['history'] == '[{"episode":2}]',
      'round trip failed',
    );
    check(
      restarted.values['profile.viewer.history'] ==
          initial['profile.viewer.history'],
      'user isolation failed',
    );
    print(
      'PASS partitioning / history-only writes / previous version / restart',
    );
    await marker.delete();
    await restarted.load();
    check(
      restarted.initialized &&
          restarted.values['profiles'] == initial['profiles'],
      'missing marker reset existing identity',
    );
    print('PASS missing initialization marker recovery');

    await history.writeAsString('{broken');
    final recovered = LocalFileStore(directory);
    await recovered.load();
    check(
      recovered.values['history'] == initial['history'],
      'backup did not recover history',
    );
    await history.writeAsString('{broken');
    await File('${history.path}.bak').writeAsString('{also broken');
    await recovered.load();
    check(
      !recovered.values.containsKey('history'),
      'both-broken category was not cleared',
    );
    check(
      recovered.values['favorites'] == initial['favorites'],
      'category corruption erased favorites',
    );
    check(
      recovered.values['profile.viewer.history'] ==
          initial['profile.viewer.history'],
      'category corruption crossed user',
    );
    print('PASS backup recovery / category corruption isolation');

    final tmp = Directory('${history.path}.tmp');
    await tmp.create(); // 强制在日志持久化后、类别文件写入前失败。
    var interrupted = false;
    final pending = {...recovered.values, 'history': '[{"episode":3}]'};
    try {
      await recovered.commit(pending);
    } on FileStoreRecoveryRequired {
      interrupted = true;
    }
    check(interrupted, 'mid-commit failure did not require recovery');
    check(
      await File('${directory.path}/transaction.json').exists(),
      'recovery journal missing',
    );
    await tmp.delete();
    final replayed = LocalFileStore(directory);
    await replayed.load();
    check(
      replayed.values['history'] == pending['history'],
      'journal did not replay',
    );
    check(
      !await File('${directory.path}/transaction.json').exists(),
      'completed journal not removed',
    );
    print('PASS interrupted transaction replay');

    final migration = replayed.prepareMigration({
      ...initial,
      'history': 'not JSON',
    });
    check(
      !migration.containsKey('history') &&
          migration['favorites'] == initial['favorites'],
      'migration isolation failed',
    );
    await replayed.commit({...replayed.values, 'activeProfile': 'viewer'});
    await user.writeAsString('{broken');
    final identity = LocalFileStore(directory);
    await identity.load();
    check(
      identity.values['activeProfile'] == 'default',
      'identity previous version not restored',
    );
    await user.writeAsString('{broken');
    await File('${user.path}.bak').writeAsString('{broken');
    var blocked = false;
    try {
      await LocalFileStore(directory).load();
    } on FormatException {
      blocked = true;
    }
    check(blocked, 'corrupt identity silently reset to administrator');
    print('PASS migration isolation / identity recovery / fail closed');

    var traversalBlocked = false;
    try {
      LocalFileStore.fileFor('profile.../../escape.history');
    } on FormatException {
      traversalBlocked = true;
    }
    check(traversalBlocked, 'unsafe path accepted');
    check(
      jsonDecode(await favorite.readAsString())['version'] == 1,
      'unrelated data was damaged',
    );
    print('PASS path validation; all local file-store checks passed');
  } finally {
    await directory.delete(recursive: true);
  }
}

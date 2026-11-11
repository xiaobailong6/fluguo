import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/merged_library.dart';
import 'package:duanju_app/media_cleanup.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'support/fakes.dart';

void main() {
  late Directory temporary;
  late Directory root;
  final show = drama('merged', title: '合并剧');

  MergedLibrary open() {
    final library = MergedLibrary(
      directory: root,
      now: () => DateTime.utc(2026, 10, 25, 12),
    );
    addTearDown(library.dispose);
    return library;
  }

  Future<void> write(String output) async {
    await File(output).writeAsBytes([0, 1, 2, 3], flush: true);
  }

  File index([String suffix = '']) => File(path.join(root.path, 'index.json$suffix'));
  Directory media() => Directory(path.join(root.path, 'media'));
  Directory folder(MergedVideo video) => Directory(path.join(media().path, video.id));

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('merged-library-test-');
    root = Directory(path.join(temporary.path, 'library'));
    addTearDown(() => temporary.delete(recursive: true));
  });

  test('原生未退出的合并隔离后，不阻塞其他成品删除', () async {
    final library = open();
    final existing = await library.create(show, [1, 2], write);
    final exited = Completer<void>();
    String? held;
    await expectLater(library.create(show, [3, 4], (output) async {
      held = output;
      await File(output).writeAsString('writing');
      throw MediaCleanupPending('等待原生退出', () => exited.future);
    }), throwsA(isA<MediaCleanupPending>()));
    expect(File(held!).existsSync(), isTrue);
    expect(await library.remove({existing.id}).timeout(const Duration(seconds: 1)), isEmpty);
    expect(library.videos, isEmpty);
    expect(File(held!).existsSync(), isTrue);
    exited.complete();
    await pumpEventQueue();
    expect(File(held!).existsSync(), isFalse);
  });

  test('restart preserves metadata and a portable managed MP4, not signed URLs', () async {
    final library = open();
    final video = await library.create(
      Drama(
        id: show.id,
        source: show.source,
        title: show.title,
        cover: 'https://example.test/cover?signature=secret',
        sourceId: 'https://example.test/play?token=secret',
      ),
      [3, 1, 3],
      write,
    );
    expect(video.episodes, [1, 3]);
    expect(video.bytes, 4);
    expect(video.createdAt, DateTime.utc(2026, 10, 25, 12));
    expect(video.fileName, '合并剧 第1、3集.mp4');
    expect(video.id, matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(File(await library.fileFor(video)).readAsBytesSync(), [0, 1, 2, 3]);
    expect(() => library.videos.clear(), throwsUnsupportedError);
    expect(() => video.episodes.add(9), throwsUnsupportedError);
    final encoded = index().readAsStringSync();
    expect(encoded, isNot(contains(root.path)));
    expect(encoded, isNot(contains('signature')));
    expect(encoded, isNot(contains('token')));
    expect(encoded, contains('media/${video.id}/video.mp4'));

    final restarted = open();
    await restarted.ensureInitialized();
    expect(restarted.error, isNull);
    expect(restarted.videos.single.id, video.id);
    expect(restarted.videos.single.drama.title, show.title);
    expect(await restarted.fileFor(restarted.videos.single), await library.fileFor(video));

    // 移动整个库相当于支持目录改变/跨平台恢复，索引无绝对路径依赖。
    final relocated = Directory(path.join(temporary.path, 'relocated'));
    root.renameSync(relocated.path);
    root = relocated;
    final moved = open();
    await moved.ensureInitialized();
    expect(File(await moved.fileFor(moved.videos.single)).lengthSync(), 4);
  });

  test('deleting a merged video leaves episode originals and external copies alone', () async {
    final original = File(path.join(temporary.path, 'episode.mp4'))..writeAsStringSync('original');
    final library = open();
    final video = await library.create(show, [1, 2], write);
    final exported = await File(await library.fileFor(video)).copy(path.join(temporary.path, 'export.mp4'));
    original.deleteSync();
    expect(File(await library.fileFor(video)).existsSync(), isTrue);
    original.writeAsStringSync('restored-original');

    expect(await library.remove({video.id}), isEmpty);
    expect(library.videos, isEmpty);
    expect(folder(video).existsSync(), isFalse);
    expect(original.readAsStringSync(), 'restored-original');
    expect(exported.readAsBytesSync(), [0, 1, 2, 3]);
    final restarted = open();
    await restarted.ensureInitialized();
    expect(restarted.videos, isEmpty);
  });

  test('write failures and empty outputs roll back only their new directory', () async {
    final library = open();
    final saved = await library.create(show, [1, 2], write);
    final previous = index().readAsStringSync();
    await expectLater(library.create(show, [2, 3], (output) async {
      await write(output);
      throw AppFailure('写入失败');
    }), throwsA(isA<AppFailure>()));
    await expectLater(library.create(show, [2, 3], (output) async {
      await File(output).writeAsBytes([]);
    }), throwsA(isA<AppFailure>()));
    expect(media().listSync().length, 1);
    expect(library.videos.single.id, saved.id);
    expect(index().readAsStringSync(), previous);
    expect(File(await library.fileFor(saved)).existsSync(), isTrue);
  });

  test('metadata failure removes the uncommitted MP4 and preserves the old index', () async {
    final library = open();
    final saved = await library.create(show, [1, 2], write);
    final previous = index().readAsStringSync();
    // 可移植地制造索引写入失败，不依赖 Windows/POSIX 权限语义。
    Directory(index('.tmp').path).createSync();
    await expectLater(library.create(show, [3, 4], write), throwsA(isA<AppFailure>()));
    expect(library.videos.single.id, saved.id);
    expect(media().listSync().length, 1);
    expect(index().readAsStringSync(), previous);
    expect(File(await library.fileFor(saved)).existsSync(), isTrue);
    expect(library.error, isNotNull);
  });

  test('corrupt main index uses backup read-only and never sweeps newer files', () async {
    final library = open();
    final first = await library.create(show, [1, 2], write);
    final second = await library.create(show, [3, 4], write);
    index().writeAsStringSync('{broken');
    final restarted = open();
    await restarted.ensureInitialized();
    expect(restarted.error, isNotNull);
    expect(restarted.videos.single.id, first.id);
    expect(File(await restarted.fileFor(first)).existsSync(), isTrue);
    expect(folder(second).existsSync(), isTrue);
    await expectLater(restarted.create(show, [5, 6], write), throwsA(isA<AppFailure>()));
    expect(await restarted.remove({first.id}), contains(first.id));
    expect(index().readAsStringSync(), '{broken');
    expect(folder(first).existsSync(), isTrue);
    expect(folder(second).existsSync(), isTrue);
  });

  test('corrupt or missing index without recovery is not a fresh installation', () async {
    final library = open();
    final video = await library.create(show, [1, 2], write);
    index('.bak').deleteSync();
    index().writeAsStringSync('not-json');
    final corrupt = open();
    await corrupt.ensureInitialized();
    expect(corrupt.error, isNotNull);
    await expectLater(corrupt.create(show, [3, 4], write), throwsA(isA<AppFailure>()));
    expect(index().readAsStringSync(), 'not-json');
    expect(folder(video).existsSync(), isTrue);

    index().deleteSync();
    final missing = open();
    await missing.ensureInitialized();
    expect(missing.error, isNotNull);
    expect(index().existsSync(), isFalse);
    expect(folder(video).existsSync(), isTrue);
  });

  test('missing file is reported on restart and playback without losing its record', () async {
    final library = open();
    final video = await library.create(show, [1, 2], write);
    File(await library.fileFor(video)).deleteSync();
    final restarted = open();
    await restarted.ensureInitialized();
    expect(restarted.error, isNotNull);
    expect(restarted.videos.single.id, video.id);
    await expectLater(restarted.fileFor(video), throwsA(isA<AppFailure>()));
    expect(await restarted.remove({video.id}), isEmpty);
    expect(restarted.videos, isEmpty);
  });

  test('interrupted index rotation rolls back backup and cleans only owned staging', () async {
    final library = open();
    final video = await library.create(show, [1, 2], write);
    final previous = index().readAsStringSync();
    index('.bak').deleteSync();
    index().renameSync(index('.bak').path);
    index('.tmp').writeAsStringSync('{interrupted');
    final abandoned = Directory(path.join(media().path, 'a' * 32))..createSync();
    File(path.join(abandoned.path, '.owner')).writeAsStringSync('fluguo-merged-video-v1');
    File(path.join(abandoned.path, '.pending')).writeAsStringSync('fluguo-merged-video-v1');
    File(path.join(abandoned.path, 'writing.mp4')).writeAsStringSync('unfinished');
    final unknown = Directory(path.join(media().path, 'b' * 32))..createSync();
    File(path.join(unknown.path, 'video.mp4')).writeAsStringSync('not-owned');

    final restarted = open();
    await restarted.ensureInitialized();
    expect(restarted.videos.single.id, video.id);
    expect(index().readAsStringSync(), previous);
    expect(index('.tmp').existsSync(), isFalse);
    expect(abandoned.existsSync(), isFalse);
    expect(unknown.existsSync(), isTrue);
    expect(File(await restarted.fileFor(video)).existsSync(), isTrue);
  });

  test('a valid first-install tmp is promoted and stale tmp never replaces a committed index', () async {
    final library = open();
    final video = await library.create(show, [1, 2], write);
    index('.bak').deleteSync();
    index().renameSync(index('.tmp').path);
    final recovered = open();
    await recovered.ensureInitialized();
    expect(recovered.videos.single.id, video.id);
    expect(index().existsSync(), isTrue);
    index('.tmp').writeAsStringSync('invalid stale tmp');
    final restarted = open();
    await restarted.ensureInitialized();
    expect(restarted.videos.single.id, video.id);
    expect(index('.tmp').existsSync(), isFalse);
  });

  test('partial delete reports failures per ID and retains failed records', () async {
    final library = open();
    final blocked = await library.create(show, [1, 2], write);
    final removed = await library.create(show, [3, 4], write);
    final extra = File(path.join(folder(blocked).path, 'not-ours.txt'))..writeAsStringSync('keep');
    final failures = await library.remove({blocked.id, removed.id, '../outside'});
    expect(failures.keys, containsAll([blocked.id, '../outside']));
    expect(failures, isNot(contains(removed.id)));
    expect(library.videos.single.id, blocked.id);
    expect(extra.existsSync(), isTrue);
    expect(File(await library.fileFor(blocked)).existsSync(), isTrue);
    expect(folder(removed).existsSync(), isFalse);
    final restarted = open();
    await restarted.ensureInitialized();
    expect(restarted.videos.single.id, blocked.id);
  });

  test('delete index failure retains record across restart and supports retry', () async {
    final library = open();
    final video = await library.create(show, [1, 2], write);
    final blocker = Directory(index('.tmp').path)..createSync();
    expect(await library.remove({video.id}), contains(video.id));
    expect(library.videos.single.id, video.id);
    blocker.deleteSync();
    final restarted = open();
    await restarted.ensureInitialized();
    expect(restarted.videos.single.id, video.id);
    expect(restarted.error, isNotNull);
    expect(await restarted.remove({video.id}), isEmpty);
  });

  test('cancelled writes and cancellation just before metadata commit leave no product', () async {
    final library = open();
    var cancelled = false;
    await expectLater(library.create(show, [1, 2], (output) async {
      await write(output);
      cancelled = true;
    }, cancelled: () => cancelled), throwsA(isA<AppFailure>()));
    expect(library.videos, isEmpty);
    expect(media().listSync(), isEmpty);
    expect(library.error, isNull);

    var checks = 0;
    await expectLater(library.create(show, [1, 2], write,
      // 最后一次检查发生在 index.tmp 已落盘、任何提交 rename 之前。
      cancelled: () => ++checks >= 6,
    ), throwsA(isA<AppFailure>()));
    expect(checks, 6);
    expect(library.videos, isEmpty);
    expect(media().listSync(), isEmpty);
    expect((jsonDecode(index().readAsStringSync()) as Map)['videos'], isEmpty);
    expect(index('.tmp').existsSync(), isFalse);
    expect(library.error, isNull);
    final recovered = await library.create(show, [3, 4], write);
    expect(File(await library.fileFor(recovered)).existsSync(), isTrue);
    expect(library.error, isNull);
  });

  test('executor cancellation errors do not leave a library health error', () async {
    final library = open();
    var cancelled = false;
    await expectLater(library.create(show, [1, 2], (output) async {
      await write(output);
      cancelled = true;
      throw AppFailure('执行器已取消');
    }, cancelled: () => cancelled), throwsA(isA<AppFailure>()));
    expect(library.videos, isEmpty);
    expect(media().listSync(), isEmpty);
    expect(library.error, isNull);
  });

  test('path traversal and oversized index are rejected without removing media', () async {
    final library = open();
    final video = await library.create(show, [1, 2], write);
    final data = jsonDecode(index().readAsStringSync()) as Map<String, dynamic>;
    (data['videos'] as List).single['file'] = '../episode.mp4';
    index().writeAsStringSync(jsonEncode(data));
    index('.bak').deleteSync();
    final unsafe = open();
    await unsafe.ensureInitialized();
    expect(unsafe.error, isNotNull);
    expect(folder(video).existsSync(), isTrue);
    index().writeAsStringSync(' ' * (4 * 1024 * 1024 + 1));
    final oversized = open();
    await oversized.ensureInitialized();
    expect(oversized.error, isNotNull);
    expect(folder(video).existsSync(), isTrue);
  });

  test('non-regular outputs are rejected without recursively deleting foreign contents', () async {
    final library = open();
    String? foreign;
    await expectLater(library.create(show, [1, 2], (output) async {
      Directory(output).createSync();
      foreign = path.join(output, 'foreign.txt');
      File(foreign!).writeAsStringSync('keep');
    }), throwsA(isA<AppFailure>()));
    expect(library.videos, isEmpty);
    expect(File(foreign!).readAsStringSync(), 'keep');
    expect(library.error, isNotNull);
  });

  test('concurrent creates are serialized without losing either metadata record', () async {
    final library = open();
    final results = await Future.wait([
      library.create(show, [1, 2], write),
      library.create(show, [3, 4], write),
    ]);
    expect(results.map((video) => video.id).toSet().length, 2);
    expect(library.videos.length, 2);
    final restarted = open();
    await restarted.ensureInitialized();
    expect(restarted.videos.map((video) => video.id),
      unorderedEquals(results.map((video) => video.id)));
  });

  test('media links are never followed or removed, and failed entries are retained', () async {
    final library = open();
    final video = await library.create(show, [1, 2], write);
    final managed = File(await library.fileFor(video));
    final outside = File(path.join(temporary.path, 'outside.mp4'))..writeAsBytesSync([9, 8, 7, 6]);
    managed.deleteSync();
    final link = Link(managed.path);
    try {
      await link.create(outside.path);
    } on FileSystemException {
      markTestSkipped('Windows 未授予符号链接权限，无法验证链接保护');
      return;
    }
    await expectLater(library.fileFor(video), throwsA(isA<AppFailure>()));
    expect(await library.remove({video.id}), contains(video.id));
    expect(library.videos.single.id, video.id);
    expect(await link.exists(), isTrue);
    expect(outside.readAsBytesSync(), [9, 8, 7, 6]);
  });
}

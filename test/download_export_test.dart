import 'package:duanju_app/app_device.dart';
import 'package:duanju_app/download_export.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _ExportRepository extends FakeRepository {
  @override
  Future<PlaybackPlan?> localPlayback(
    Drama drama,
    Episode episode, {
    bool playback = false,
  }) async => PlaybackPlan(url: '/local/episode.mp4', local: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('取到本地文件后权限失效，不进入系统导出', () async {
    var checks = 0;
    var copies = 0;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (_) async {
      copies++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(AppDevice.channel, null));
    await expectLater(
      exportDownload(_ExportRepository(), downloadJob(drama('stale'), 1),
        delete: false,
        checkAccess: () {
          checks++;
          if (checks == 2) throw StateError('用户已切换');
        },
      ),
      throwsStateError,
    );
    expect(checks, 2);
    expect(copies, 0);
  });

  test('导出期间分集被合并占用时，保留外部导出但不删除内部原分集', () async {
    final repository = _ExportRepository();
    final job = downloadJob(drama('export-busy'), 1);
    var merging = false;
    var exports = 0;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      expect(call.method, 'exportVideo');
      exports++;
      merging = true;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(AppDevice.channel, null));
    await expectLater(
      exportDownload(repository, job, delete: true, beforeDelete: () {
        if (merging) throw StateError('正在合并');
      }),
      throwsA(predicate((error) => '$error'.contains('已导出，但 App 内副本未删除'))),
    );
    expect(exports, 1);
    expect(repository.controls, isEmpty);
  });

  test('允许删除时先执行检查，再删除已导出的分集', () async {
    final repository = _ExportRepository();
    final job = downloadJob(drama('export-allowed'), 1);
    var checked = false;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(AppDevice.channel, null));
    await exportDownload(repository, job, delete: true, beforeDelete: () {
      expect(repository.controls, isEmpty);
      checked = true;
    });
    expect(checked, isTrue);
    expect(repository.controls, ['remove|${job.id}']);
  });

  test('导出不删除时无需执行删除前检查', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(AppDevice.channel, null));
    await exportDownload(_ExportRepository(), downloadJob(drama('copy'), 1),
      delete: false,
      beforeDelete: () => throw StateError('不应检查删除'),
    );
  });

  test('export names pad episode numbers to the episode count', () {
    expect(exportFileName(1, 0), '第01集.mp4');
    expect(exportFileName(7, 80), '第07集.mp4');
    expect(exportFileName(7, 120), '第007集.mp4');
    expect(exportFileName(105, 90), '第105集.mp4');
  });
}

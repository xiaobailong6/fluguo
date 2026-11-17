import 'dart:async';
import 'dart:io';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/cover_decoder.dart';
import 'package:duanju_app/media_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

class _ExitExecutor implements MediaExecutor, MediaExitAware {
  final started = Completer<void>();
  final exit = Completer<void>();
  bool failExit = false;
  int cancellations = 0;
  late File partial;

  @override
  Future<MediaProbe> probe(String file) => throw UnimplementedError();
  @override
  Future<void> run(
    List<String> arguments, {
    double duration = 0,
    void Function(double)? progress,
  }) async {
    partial = File(arguments.last);
    await partial.writeAsString('still writing');
    started.complete();
    // 模拟取消/超时结果先于真实进程退出返回。
    throw TimeoutException('synthetic cancellation');
  }

  @override
  Future<void> cancel() async {
    cancellations++;
  }

  @override
  Future<void> waitForIdle() {
    if (failExit) throw AppFailure('synthetic exit not confirmed');
    return exit.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final failFirst in [false, true]) {
    test(
      'cover cleanup waits for confirmed native exit (retry=$failFirst)',
      () async {
        final directory = await Directory.systemTemp.createTemp('cover-exit-');
        addTearDown(() => directory.delete(recursive: true));
        final original = File(path.join(directory.path, '${'a' * 64}.img'));
        final input = File(path.join(directory.path, '.decode-in-use.hevc'));
        await original.writeAsString('source');
        await input.writeAsString('native input');
        final executor = _ExitExecutor()..failExit = failFirst;
        final decoder = CoverDecoder(createExecutor: () => executor);
        final conversion = expectLater(
          decoder.convert(
            original.path,
            () async => {'heic': true, 'input': input.path},
          ),
          throwsA(isA<AppFailure>()),
        );
        await executor.started.future;
        await pumpEventQueue();
        expect(executor.cancellations, 1);
        expect(await input.exists(), isTrue);
        expect(await executor.partial.exists(), isTrue);
        if (failFirst) {
          await conversion;
          await expectLater(decoder.waitForIdle(), throwsA(isA<AppFailure>()));
          expect(await input.exists(), isTrue);
          executor.failExit = false;
        }
        var drained = false;
        final idle = decoder.waitForIdle().then((_) => drained = true);
        await pumpEventQueue();
        expect(drained, isFalse);
        executor.exit.complete();
        await conversion;
        await idle;
        expect(await input.exists(), isFalse);
        expect(await executor.partial.exists(), isFalse);
        expect(await original.exists(), isTrue);
      },
    );
  }
}

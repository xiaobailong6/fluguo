import 'dart:async';
import 'dart:io';

import 'package:duanju_app/playback_chroma_shader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fluguo-chroma-');
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test('并发播放器共用初始化，后续切集不重复写shader', () async {
    final directory = Completer<Directory>();
    var calls = 0;
    final shader = PlaybackChromaShader(
      directory: () {
        calls++;
        return directory.future;
      },
    );
    final first = shader.prepare();
    final second = shader.prepare();
    expect(first, same(second));
    directory.complete(temporary);
    final file = File(await first);
    expect(await file.readAsString(), playbackChromaShaderSource);
    final time = DateTime(2020);
    await file.setLastModified(time);
    expect(await shader.prepare(), file.path);
    expect(
      (await file.lastModified()).millisecondsSinceEpoch,
      time.millisecondsSinceEpoch,
    );
    expect(calls, 1);
    expect(playbackChromaShaderSource, contains('//!HOOK NATIVE'));
    expect(playbackChromaShaderSource, contains('.xzyw'));
  });

  test('旧文件损坏时修复，文件有效时不改写', () async {
    final first = PlaybackChromaShader(directory: () async => temporary);
    final file = File(await first.prepare());
    await file.writeAsString('invalid shader');
    final second = PlaybackChromaShader(directory: () async => temporary);
    expect(await second.prepare(), file.path);
    expect(await file.readAsString(), playbackChromaShaderSource);
  });

  test('初始化失败不缓存失败结果，后续重试可成功', () async {
    var calls = 0;
    final shader = PlaybackChromaShader(
      directory: () async {
        if (++calls == 1) throw const FileSystemException('not available yet');
        return temporary;
      },
    );
    await expectLater(shader.prepare(), throwsA(isA<FileSystemException>()));
    expect(
      await File(await shader.prepare()).readAsString(),
      playbackChromaShaderSource,
    );
    expect(calls, 2);
  });
}

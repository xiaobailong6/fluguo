import 'dart:async';

import 'package:duanju_app/ui/player/playback_video_ready.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/fake_player.dart';

class _Signal<T> extends ValueNotifier<T> {
  _Signal(super.value);
  bool get observed => hasListeners;
}

// 与NativePlayer.getProperty一致：不支持的属性返回空串，不能默认伪造yes。
class _Native extends Fake implements NativePlayer {
  String seeking = 'no';
  String pts = '0';
  final queries = <String>[];
  @override
  Future<String> getProperty(
    String name, {
    bool waitForInitialization = true,
  }) async {
    queries.add(name);
    return switch (name) {
      'seeking' => seeking,
      'video-pts' => pts,
      _ => '',
    };
  }
}

class _Video extends Fake implements VideoController {
  @override
  final FakePlayer player = FakePlayer();
  @override
  final _Signal<int?> id = _Signal<int?>(null);
  @override
  final _Signal<Rect?> rect = _Signal<Rect?>(null);
  final frame = Completer<void>();
  @override
  Future<void> get waitUntilFirstFrameRendered => frame.future;
  Completer<void>? surface;
  int generation = 0;
  @override
  Future<void> waitUntilSurfaceReady() async => await surface?.future;
  @override
  Future<int> surfaceGeneration() async => generation;
  void initialize() {
    id.value = 10;
    rect.value = const Rect.fromLTWH(0, 0, 720, 1280);
    player.state = player.state.copyWith(width: 720, height: 1280);
    frame.complete();
  }

  void dispose() {
    id.dispose();
    rect.dispose();
  }
}

void main() {
  testWidgets('前台回零只等待seek，不等待可选输出预热', (tester) async {
    final video = _Video();
    video.player.progress(const Duration(seconds: 20));
    await video.player.play();
    final work = resetPlaybackVideo(video, Duration.zero, warmOutput: false);
    await tester.pump();
    await work;
    expect(video.player.seeks, [Duration.zero]);
    expect(video.frame.isCompleted, isFalse);
    video.dispose();
  });

  Future<void> finish(WidgetTester tester, Future<void> work) async {
    var done = false;
    final result = work.then((_) => done = true);
    for (var i = 0; i < 10 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done, isTrue);
    await result;
  }

  testWidgets('原生缺少vo-configured属性不阻止已经出尺寸的视频', (tester) async {
    final video = _Video()..initialize();
    final native = _Native();
    video.player.platform = native;
    await finish(tester, preparePlaybackVideo(video));
    expect(native.queries, isNot(contains('vo-configured')));
    expect(video.id.observed, isFalse);
    expect(video.rect.observed, isFalse);
    video.dispose();
  });

  testWidgets('预览位置流滞后于video-pts不误判成未出画面', (tester) async {
    final video = _Video()..initialize();
    video.player.platform = _Native()..pts = '18.75';
    video.player.progress(const Duration(seconds: 17));
    await video.player.play();
    await finish(tester, preparePlaybackVideo(video));
    expect(video.player.state.playing, isTrue);
    expect(video.player.seeks, isEmpty);
    video.dispose();
  });

  testWidgets('可选原生属性为空仍可完成纹理预热，不调用像素复制探测', (tester) async {
    final video = _Video()..initialize();
    video.player.platform = _Native()
      ..pts = ''
      ..seeking = '';
    // Fake没有任何PixelCopy/缓冲探测实现，调用便会抛UnimplementedError。
    await finish(tester, preparePlaybackVideo(video));
    video.dispose();
  });

  testWidgets('明确回零目标仍等待Surface与seek结束', (tester) async {
    final video = _Video()..initialize();
    final native = _Native()
      ..pts = '80'
      ..seeking = 'yes';
    video.player.platform = native;
    video.surface = Completer<void>();
    var done = false;
    final work = resetPlaybackVideo(
      video,
      Duration.zero,
    ).then((_) => done = true);
    await tester.pump();
    expect(done, isFalse);
    video.surface!.complete();
    await tester.pump(const Duration(milliseconds: 20));
    expect(done, isFalse);
    native.seeking = 'no';
    await tester.pump(const Duration(milliseconds: 20));
    expect(done, isFalse, reason: '不能用旧集位置当作回零输出');
    native.pts = '0';
    await finish(tester, work);
    expect(video.player.seeks, [Duration.zero]);
    expect(video.player.state.playing, isFalse);
    video.dispose();
  });

  testWidgets('首次输出仍需有效纹理和初始化信号', (tester) async {
    final video = _Video();
    var done = false;
    final work = preparePlaybackVideo(video).then((_) => done = true);
    video.id.value = 10;
    video.rect.value = const Rect.fromLTWH(0, 0, 1, 1);
    await tester.pump();
    expect(done, isFalse);
    video.rect.value = const Rect.fromLTWH(0, 0, 720, 1280);
    await tester.pump();
    expect(done, isFalse);
    video.frame.complete();
    await finish(tester, work);
    video.dispose();
  });

  for (final sameId in [true, false]) {
    testWidgets('提交途中输出换代重新确认 sameId=$sameId', (tester) async {
      final video = _Video()..initialize();
      var done = false;
      final work = preparePlaybackVideo(video).then((_) => done = true);
      tester.binding.addPostFrameCallback((_) {
        video.generation++;
        if (!sameId) video.id.value = 20;
      });
      await tester.pump();
      expect(done, isFalse);
      await finish(tester, work);
      video.dispose();
    });
  }

  testWidgets('初始化超时移除监听，不把超时当成成功', (tester) async {
    final video = _Video();
    final work = preparePlaybackVideo(video);
    final checked = expectLater(work, throwsA(isA<TimeoutException>()));
    await tester.pump(const Duration(seconds: 5));
    await checked;
    expect(video.id.observed, isFalse);
    expect(video.rect.observed, isFalse);
    video.initialize();
    await tester.pump();
    video.dispose();
  });
}

import 'dart:async';

import 'package:duanju_app/ui/player/playback_video_ready.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit/media_kit.dart';
import 'support/fake_player.dart';

class _Signal<T> extends ValueNotifier<T> {
  _Signal(super.value);
  bool get observed => hasListeners;
}

class _Native extends Fake implements NativePlayer {
  String seeking = 'yes';
  String pts = '80';
  String configured = 'yes';
  @override
  Future<String> getProperty(
    String name, {
    bool waitForInitialization = true,
  }) async => switch (name) {
    'seeking' => seeking,
    'vo-configured' => configured,
    _ => pts,
  };
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
  @override
  Future<void> waitUntilSurfaceReady() async => await surface?.future;
  Completer<void>? bufferAvailable;
  int changedReplies = 0;
  @override
  Future<void> waitUntilFrameAvailable() async {
    if (changedReplies > 0) {
      changedReplies--;
      generation++;
      throw PlatformException(code: 'FRAME_SURFACE_CHANGED');
    }
    await bufferAvailable?.future;
  }

  int generation = 0;
  @override
  Future<int> surfaceGeneration() async => generation;
  void dispose() {
    id.dispose();
    rect.dispose();
  }
}

void main() {
  testWidgets('探测回复途中Surface换代按原截止时间重试', (tester) async {
    final video = _Video()..changedReplies = 1;
    video.id.value = 10;
    video.rect.value = const Rect.fromLTWH(0, 0, 720, 1280);
    video.frame.complete();
    var completed = false;
    final work = preparePlaybackVideo(video).then((_) => completed = true);
    for (var i = 0; i < 10 && !completed; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(completed, isTrue);
    expect(video.generation, 1);
    await work;
    video.dispose();
  });

  testWidgets('尺寸和PTS就绪仍须等Surface实际缓冲可用', (tester) async {
    final video = _Video();
    video.id.value = 10;
    video.rect.value = const Rect.fromLTWH(0, 0, 720, 1280);
    video.frame.complete();
    video.bufferAvailable = Completer<void>();
    var completed = false;
    final work = preparePlaybackVideo(video).then((_) => completed = true);
    await tester.pump();
    await tester.pump();
    expect(completed, isFalse);
    video.bufferAvailable!.complete();
    for (var i = 0; i < 5 && !completed; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(completed, isTrue);
    await work;
    video.dispose();
  });

  testWidgets('旧纹理尺寸和生命周期首帧不能跳过本次Surface与回零解码', (tester) async {
    final video = _Video();
    final native = _Native();
    video.player.platform = native;
    video.id.value = 10;
    video.rect.value = const Rect.fromLTWH(0, 0, 720, 1280);
    video.frame.complete();
    video.surface = Completer<void>();
    var completed = false;
    final work = resetPlaybackVideo(
      video,
      Duration.zero,
    ).then((_) => completed = true);
    await tester.pump();
    expect(completed, isFalse);
    video.surface!.complete();
    await tester.pump();
    expect(completed, isFalse);
    native.seeking = 'no';
    native.pts = '0';
    await tester.pump(const Duration(milliseconds: 20));
    expect(completed, isFalse, reason: '新文件的width/height尚未回报');
    video.player.state = video.player.state.copyWith(width: 720, height: 1280);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    await work;
    expect(completed, isTrue);
    expect(video.player.state.playing, isFalse);
    expect(video.player.seeks, [Duration.zero]);
    video.dispose();
  });

  testWidgets('回看复位到零先暂停再seek，不用旧位置/末帧代替零点', (tester) async {
    final video = _Video();
    video.id.value = 10;
    video.rect.value = const Rect.fromLTWH(0, 0, 720, 1280);
    video.frame.complete();
    video.player.progress(const Duration(seconds: 80));
    await video.player.play();
    final work = resetPlaybackVideo(video, Duration.zero);
    await tester.pump();
    await tester.pump();
    await work;
    expect(video.player.state.playing, isFalse);
    expect(video.player.state.position, Duration.zero);
    expect(video.player.seeks, [Duration.zero]);
    video.dispose();
  });

  testWidgets('首次输出必须同时有正常纹理尺寸和首帧信号', (tester) async {
    final video = _Video();
    var completed = false;
    final work = preparePlaybackVideo(video).then((_) => completed = true);
    video.id.value = 10;
    video.rect.value = const Rect.fromLTWH(0, 0, 1, 1);
    await tester.pump();
    expect(completed, isFalse);
    video.rect.value = const Rect.fromLTWH(0, 0, 720, 1280);
    await tester.pump();
    expect(completed, isFalse, reason: '输出尺寸变化不等于首帧就绪');
    video.frame.complete();
    await tester.pump();
    await tester.pump();
    await work;
    expect(completed, isTrue);
    expect(video.id.observed, isFalse);
    expect(video.rect.observed, isFalse);
    video.dispose();
  });
  testWidgets('复用已初始化控制器无需等待第二个生命周期首帧信号', (tester) async {
    final video = _Video();
    video.id.value = 10;
    video.rect.value = const Rect.fromLTWH(0, 0, 720, 1280);
    video.frame.complete();
    for (var episode = 0; episode < 2; episode++) {
      final work = preparePlaybackVideo(video);
      await tester.pump();
      await tester.pump();
      await work;
      expect(video.id.observed, isFalse);
      expect(video.rect.observed, isFalse);
    }
    video.dispose();
  });

  testWidgets('有PTS但vo尚未配置不能交接', (tester) async {
    final video = _Video();
    final native = _Native()
      ..seeking = 'no'
      ..pts = '0'
      ..configured = 'no';
    video.player.platform = native;
    video.player.state = video.player.state.copyWith(width: 720, height: 1280);
    video.id.value = 10;
    video.rect.value = const Rect.fromLTWH(0, 0, 720, 1280);
    video.frame.complete();
    var completed = false;
    final work = preparePlaybackVideo(video).then((_) => completed = true);
    await tester.pump();
    expect(completed, isFalse);
    native.configured = 'yes';
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    await work;
    expect(completed, isTrue);
    video.dispose();
  });

  testWidgets('同纹理同尺寸Surface重建也必须重新确认解码', (tester) async {
    final video = _Video();
    final native = _Native()
      ..seeking = 'no'
      ..pts = '0';
    video.player.platform = native;
    video.player.state = video.player.state.copyWith(width: 720, height: 1280);
    video.id.value = 10;
    video.rect.value = const Rect.fromLTWH(0, 0, 720, 1280);
    video.frame.complete();
    var completed = false;
    final work = preparePlaybackVideo(video).then((_) => completed = true);
    tester.binding.addPostFrameCallback((_) {
      video.generation++;
      native.configured = 'no';
    });
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(completed, isFalse);
    native.configured = 'yes';
    for (var i = 0; i < 10 && !completed; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(completed, isTrue);
    await work;
    video.dispose();
  });

  testWidgets('帧提交中替换纹理必须重新确认输出', (tester) async {
    final video = _Video();
    video.id.value = 10;
    video.rect.value = const Rect.fromLTWH(0, 0, 720, 1280);
    video.frame.complete();
    var completed = false;
    final work = preparePlaybackVideo(video).then((_) => completed = true);
    tester.binding.addPostFrameCallback((_) => video.id.value = 20);
    await tester.pump();
    expect(completed, isFalse);
    for (var i = 0; i < 10 && !completed; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(completed, isTrue, reason: '新纹理需要自己的提交帧，不能无限等待');
    await work;
    expect(completed, isTrue);
    video.dispose();
  });

  testWidgets('输出初始化超时不挂死，临时监听被移除', (tester) async {
    final video = _Video();
    final work = preparePlaybackVideo(video);
    final checked = expectLater(work, throwsA(isA<TimeoutException>()));
    await tester.pump(const Duration(seconds: 5));
    await checked;
    expect(video.id.observed, isFalse);
    expect(video.rect.observed, isFalse);
    // 迟到的渲染通知不会改写已经失败的就绪状态。
    video.frame.complete();
    video.id.value = 1;
    video.rect.value = const Rect.fromLTWH(0, 0, 720, 1280);
    await tester.pump();
    video.dispose();
  });
}

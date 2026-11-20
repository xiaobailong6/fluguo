import 'dart:async';

import 'package:duanju_app/ui/player/playback_video_ready.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'support/fake_player.dart';

class _Signal<T> extends ValueNotifier<T> {
  _Signal(super.value);
  bool get observed => hasListeners;
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
  void dispose() {
    id.dispose();
    rect.dispose();
  }
}

void main() {
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

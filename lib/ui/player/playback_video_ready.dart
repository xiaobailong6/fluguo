import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 生命周期首帧/纹理尺寸只表示输出初始化，不能代表复用后的本集首帧。
/// 再检查本次文件的尺寸、Surface 绑定和解码位置；不通过短暂 play 出帧。
Future<void> preparePlaybackVideo(
  VideoController controller, {
  Duration? position,
}) async {
  final ready = Completer<void>();
  void check() {
    final rect = controller.rect.value;
    final id = controller.id.value;
    if (!ready.isCompleted &&
        id != null &&
        id >= 0 &&
        rect != null &&
        rect.width > 1 &&
        rect.height > 1) {
      ready.complete();
    }
  }

  controller.id.addListener(check);
  controller.rect.addListener(check);
  try {
    check();
    await Future.wait([
      ready.future,
      controller.waitUntilFirstFrameRendered,
    ]).timeout(const Duration(seconds: 4));
    final player = controller.player;
    final platform = player.platform;
    if (platform is NativePlayer) {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (true) {
        var decoded = false;
        try {
          // Android resize 会异步重绑 vo；必须先等重绑/暂停重绘，再读 pts。
          await controller.waitUntilSurfaceReady().timeout(
            const Duration(milliseconds: 500),
          );
          final seeking = await platform
              .getProperty('seeking')
              .timeout(const Duration(milliseconds: 500));
          final pts = double.tryParse(
            await platform
                .getProperty('video-pts')
                .timeout(const Duration(milliseconds: 500)),
          );
          final at = position ?? player.state.position;
          decoded =
              (player.state.width ?? 0) > 1 &&
              (player.state.height ?? 0) > 1 &&
              seeking == 'no' &&
              pts != null &&
              pts.isFinite &&
              (pts - at.inMilliseconds / 1000).abs() < .25;
        } on TimeoutException {
          // Surface 尚未重建完时继续在同一个截止时间内等待。
        }
        if (decoded) break;
        if (!DateTime.now().isBefore(deadline)) {
          throw TimeoutException('current video output not ready');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    // 让已挂载的 Texture 消费本次通知；这是布局屏障，不声称是物理屏幕呈现确认。
    await SchedulerBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 1),
    );
  } finally {
    controller.id.removeListener(check);
    controller.rect.removeListener(check);
  }
}

/// 回看从零且保持暂停；只等待一次本次 seek 输出，不能复用旧的生命周期信号。
Future<void> resetPlaybackVideo(
  VideoController controller,
  Duration position,
) async {
  final player = controller.player;
  await player.pause();
  await player.seek(position);
  if (player.platform is! NativePlayer &&
      (player.state.position - position).abs() >
          const Duration(milliseconds: 150)) {
    await player.stream.position
        .firstWhere(
          (value) =>
              (value - position).abs() <= const Duration(milliseconds: 150),
        )
        .timeout(const Duration(seconds: 3));
  }
  await preparePlaybackVideo(controller, position: position);
}

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 预热检查，不是屏幕呈现证明，也不能成为用户切集的永久播放许可。
/// SurfaceProducer的缓冲由Flutter消费，不能用PixelCopy是否可读判断视频能否播放。
Future<void> preparePlaybackVideo(
  VideoController controller, {
  Duration? position,
}) async {
  bool hasOutput() {
    final rect = controller.rect.value;
    final id = controller.id.value;
    return id != null &&
        id >= 0 &&
        rect != null &&
        rect.width > 1 &&
        rect.height > 1;
  }

  final ready = Completer<void>();
  void check() {
    if (!ready.isCompleted && hasOutput()) ready.complete();
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
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (true) {
      final id = controller.id.value;
      final surface = await controller.surfaceGeneration();
      final rect = controller.rect.value;
      var decoded = hasOutput();
      try {
        await controller.waitUntilSurfaceReady().timeout(
          const Duration(milliseconds: 500),
        );
        if (platform is NativePlayer) {
          final seeking = await platform
              .getProperty('seeking')
              .timeout(const Duration(milliseconds: 500));
          final rawPts = await platform
              .getProperty('video-pts')
              .timeout(const Duration(milliseconds: 500));
          final pts = double.tryParse(rawPts);
          // mpv_get_property_string对不可用属性返回空串；不能把可选属性当成必需能力。
          // 只有明确seek目标才检查位置。预览播放中的Dart位置流可能落后多个视频帧。
          decoded =
              decoded &&
              (player.state.width ?? 0) > 1 &&
              (player.state.height ?? 0) > 1 &&
              seeking != 'yes' &&
              (rawPts.isEmpty || pts != null && pts.isFinite) &&
              (position == null ||
                  rawPts.isEmpty ||
                  pts != null &&
                      (pts - position.inMilliseconds / 1000).abs() < .5);
        }
        if (decoded) {
          await SchedulerBinding.instance.endOfFrame.timeout(
            const Duration(seconds: 1),
          );
          await controller.waitUntilSurfaceReady().timeout(
            const Duration(milliseconds: 500),
          );
          if (hasOutput() &&
              controller.id.value == id &&
              controller.rect.value == rect &&
              await controller.surfaceGeneration() == surface) {
            return;
          }
        }
      } on TimeoutException {
        // 重绑尚未完成则在原截止时间内等待，不延长等待，也不自行stop/open。
      }
      if (!DateTime.now().isBefore(deadline)) {
        throw TimeoutException('video warm-up pending');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  } finally {
    controller.id.removeListener(check);
    controller.rect.removeListener(check);
  }
}

/// 回看复位同一个播放器；seek本身清除mpv的completed状态。
Future<void> resetPlaybackVideo(
  VideoController controller,
  Duration position, {
  bool warmOutput = true,
}) async {
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
  if (warmOutput) await preparePlaybackVideo(controller, position: position);
}

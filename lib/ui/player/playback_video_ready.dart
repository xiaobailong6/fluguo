import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 生命周期首帧/尺寸只代表初始化。还须校验本次文件、Surface 与解码位置，
/// 并在提交后复核输出身份；不截图、不用固定延时假装已出帧。
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
          final configured = await platform
              .getProperty('vo-configured')
              .timeout(const Duration(milliseconds: 500));
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
              decoded &&
              configured == 'yes' &&
              (player.state.width ?? 0) > 1 &&
              (player.state.height ?? 0) > 1 &&
              seeking == 'no' &&
              pts != null &&
              pts.isFinite &&
              (pts - at.inMilliseconds / 1000).abs() < .25;
        }
        if (decoded) {
          // Android 在当前 Surface 上确认已有视频缓冲；只返回状态，不展示探测图片。
          await controller.waitUntilFrameAvailable().timeout(
            const Duration(seconds: 2),
          );
          // 帧提交过程中仍可能收到 resize/rebind，必须复核，不能沿用旧尺寸信号。
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
        // Surface 尚未完成重绑时继续等，但不延长总截止时间。
      } on PlatformException catch (error) {
        if (error.code != 'FRAME_SURFACE_CHANGED' &&
            error.code != 'FRAME_SURFACE_UNAVAILABLE' &&
            error.code != 'FRAME_PROBE_TIMEOUT') {
          rethrow;
        }
      }
      if (!DateTime.now().isBefore(deadline)) {
        throw TimeoutException('current video output not ready');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  } finally {
    controller.id.removeListener(check);
    controller.rect.removeListener(check);
  }
}

/// 回看从零且保持暂停；只等待本次 seek 输出，不能复用旧生命周期信号。
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

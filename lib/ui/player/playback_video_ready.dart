import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 首次预开必须等输出初始化；仅完成 loadfile 或取得缓存地址仍可能是 1x1 空纹理。
/// 使用控制器自己的首帧信号，不用固定延时、不提前播放声音。
Future<void> preparePlaybackVideo(VideoController controller) async {
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
    // 让已经挂载的 Video/Texture 消费通知并完成布局，再向会话报告可交换。
    await SchedulerBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 1),
    );
  } finally {
    controller.id.removeListener(check);
    controller.rect.removeListener(check);
  }
}

/// 已播放过的邻集暂停回零：等待这次 seek 的解码位置，而不是生命周期首帧。
Future<void> resetPlaybackVideo(
  VideoController controller,
  Duration position,
) async {
  final player = controller.player;
  await player.pause();
  await player.seek(position);
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  final platform = player.platform;
  if (platform is NativePlayer) {
    while (true) {
      final seeking = await platform.getProperty('seeking');
      final pts = double.tryParse(await platform.getProperty('video-pts'));
      if (seeking == 'no' &&
          pts != null &&
          (pts - position.inMilliseconds / 1000).abs() < .15) {
        break;
      }
      if (!DateTime.now().isBefore(deadline)) {
        throw TimeoutException('video seek not ready');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  } else if ((player.state.position - position).abs() >
      const Duration(milliseconds: 150)) {
    await player.stream.position
        .firstWhere(
          (value) =>
              (value - position).abs() <= const Duration(milliseconds: 150),
        )
        .timeout(const Duration(seconds: 3));
  }
  await preparePlaybackVideo(controller);
}

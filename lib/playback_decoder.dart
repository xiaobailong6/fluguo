import 'package:flutter/foundation.dart';

import 'playback_preferences.dart';

/// 只生成解码相关属性，保持其他播放/网络配置不变。
Map<String, String> playbackDecoderProperties(
  TelevisionDecoder decoder,
  TargetPlatform platform,
) {
  final compatible =
      decoder == TelevisionDecoder.hardware ||
      decoder == TelevisionDecoder.hardwareSwapUv;
  final hwdec = decoder == TelevisionDecoder.software
      ? 'no'
      : switch (platform) {
          TargetPlatform.android =>
            compatible ? 'mediacodec-copy' : 'auto-safe',
          TargetPlatform.iOS => compatible ? 'videotoolbox-copy' : null,
          TargetPlatform.macOS =>
            compatible ? 'videotoolbox-copy' : 'auto-safe',
          TargetPlatform.windows => 'd3d11va-copy',
          _ => null,
        };
  return {
    'hwdec': ?hwdec,
    // 复用播放器换集/更换设置时必须撤销上次修正；非 Android 不施加颜色滤镜。
    if (platform == TargetPlatform.android)
      'vf': decoder == TelevisionDecoder.hardwareSwapUv ? 'lavfi=[swapuv]' : '',
  };
}

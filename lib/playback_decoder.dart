import 'package:flutter/foundation.dart';

import 'playback_preferences.dart';

/// 只生成解码相关属性，保持其他播放/网络配置不变。
Map<String, String> playbackDecoderProperties(
  TelevisionDecoder decoder,
  TargetPlatform platform, {
  String chromaShader = '',
}) {
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
    // 硬解偏蓝修正改在GPU采样阶段执行；所有模式都撤销旧CPU滤镜与旧shader。
    if (platform == TargetPlatform.android) ...{
      'vf': '',
      'glsl-shaders': decoder == TelevisionDecoder.hardwareSwapUv
          ? chromaShader
          : '',
    },
  };
}

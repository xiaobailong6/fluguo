import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'playback_chroma_shader.dart';
import 'playback_decoder.dart';
import 'playback_preferences.dart';

/// 解码器与输出后端是同一份不可变配置，播放器交接时一起保留。
/// 直通必须配 mediacodec_embed，不能仅在下一次 open 时修改 hwdec。
class PlaybackVideoConfiguration {
  const PlaybackVideoConfiguration(this.decoder, this.platform);

  final TelevisionDecoder decoder;
  final TargetPlatform platform;
  static final _players = Expando<PlaybackVideoConfiguration>();

  static PlaybackVideoConfiguration? of(Player player) => _players[player];

  VideoControllerConfiguration videoConfiguration() =>
      platform == TargetPlatform.android &&
          decoder == TelevisionDecoder.hardwareDirect
      ? const VideoControllerConfiguration(
          vo: 'mediacodec_embed',
          hwdec: 'mediacodec',
        )
      : const VideoControllerConfiguration();

  VideoController createVideo(
    Player player, {
    VideoController Function(Player, VideoControllerConfiguration)? factory,
  }) {
    bind(player);
    final configuration = videoConfiguration();
    return factory?.call(player, configuration) ??
        VideoController(player, configuration: configuration);
  }

  /// 弱引用跟随 Player 生命周期；剧场 -> 全集 -> 剧场无需另传易失配的设置。
  void bind(Player player) {
    final previous = of(player);
    if (previous != null && !previous.matches(decoder, platform)) {
      throw StateError('播放器输出配置不可在交接时更换');
    }
    _players[player] = this;
  }

  bool matches(TelevisionDecoder requested, TargetPlatform target) =>
      target == platform &&
      effectivePlaybackDecoder(requested, target) ==
          effectivePlaybackDecoder(decoder, platform);

  Future<void> apply(NativePlayer player) async {
    // 等控制器初始化后再配置，避免其默认 hwdec 覆盖用户选项；不等首帧。
    if (player.isVideoControllerAttached) {
      await player.videoControllerCompleter.future;
    }
    final shader =
        platform == TargetPlatform.android &&
            decoder == TelevisionDecoder.hardwareSwapUv
        ? await playbackChromaShader.prepare()
        : '';
    for (final entry in playbackDecoderProperties(
      decoder,
      platform,
      chromaShader: shader,
    ).entries) {
      await player.setProperty(entry.key, entry.value);
    }
  }
}

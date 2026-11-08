import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'models.dart';
import 'theater_video_presentation.dart';

/// Narrow, injectable media boundary. No history, playlist or preloader.
abstract class PreviewBackend {
  Stream<bool> get completed;
  Stream<String> get errors;
  Duration get position;
  Widget buildVideo();
  Future<void> open(PlaybackPlan plan, Duration position);
  Future<void> play();
  Future<void> stop();
  Future<void> dispose();

  /// 可被正式播放页整体接管的底层播放器；不支持接管的实现返回 null。
  Player? get handoffPlayer => null;

  /// 与 [handoffPlayer] 配套的渲染控制器，接管后由新页面继续渲染同一画面。
  VideoController? get handoffVideo => null;
}

class MediaKitPreviewBackend implements PreviewBackend {
  MediaKitPreviewBackend() {
    // The rendering controller must exist before the first open.
    _video = VideoController(_player);
    _dimensions = _player.stream.videoParams.listen(
      _presentation.parametersChanged,
    );
    _video.rect.addListener(_textureChanged);
    _video.id.addListener(_textureChanged);
  }

  /// 用全集播放页交还的播放器与渲染控制器组装预览后端：
  /// 同一块纹理继续渲染，画面与声音都不重新开始。
  MediaKitPreviewBackend.adopted(Player player, VideoController video) {
    _adopted = player;
    _video = video;
    _dimensions = _player.stream.videoParams.listen(
      _presentation.parametersChanged,
    );
    _video.rect.addListener(_textureChanged);
    _video.id.addListener(_textureChanged);
    // 播放已在进行，videoParams 不一定再发事件，直接用当前状态铺一帧。
    _presentation.begin();
    _presentation.parametersChanged(_player.state.videoParams);
    _presentation.textureChanged(_video.rect.value, _video.id.value);
    _presentation.opened();
  }
  final Player _owned = Player(
    configuration: const PlayerConfiguration(
      bufferSize: 16 * 1024 * 1024,
      logLevel: MPVLogLevel.error,
    ),
  );
  Player? _adopted;
  Player get _player => _adopted ?? _owned;
  late final VideoController _video;
  final _presentation = TheaterVideoPresentation();
  late final StreamSubscription<VideoParams> _dimensions;

  void _textureChanged() =>
      _presentation.textureChanged(_video.rect.value, _video.id.value);

  @override
  Stream<bool> get completed => _player.stream.completed;
  @override
  Stream<String> get errors => _player.stream.error;
  @override
  Duration get position => _player.state.position;

  @override
  Player get handoffPlayer => _player;

  @override
  VideoController get handoffVideo => _video;

  @override
  Widget buildVideo() => StablePreviewSurface(
    key: ValueKey(this),
    presentation: _presentation,
    videoBuilder: (aspectRatio) => Video(
      controller: _video,
      aspectRatio: aspectRatio,
      fit: BoxFit.contain,
      controls: NoVideoControls,
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
    ),
  );
  @override
  Future<void> open(PlaybackPlan plan, Duration position) async {
    _presentation.begin();
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty(
        'demuxer-lavf-o',
        [
          'strict=experimental',
          'allowed_extensions=ALL',
          if (plan.decryptionKey.isNotEmpty)
            'decryption_key=${plan.decryptionKey}',
        ].join(','),
      );
    }
    // Never allow a stale open to start audio before generation validation.
    await _player.open(
      Media(plan.url, httpHeaders: plan.headers, start: position),
      play: false,
    );
    _textureChanged();
    _presentation.opened();
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> stop() {
    _presentation.stop();
    return _player.stop();
  }

  @override
  Future<void> dispose() async {
    _presentation.stop();
    await _dimensions.cancel();
    _video.rect.removeListener(_textureChanged);
    _video.id.removeListener(_textureChanged);
    try {
      await _player.dispose();
    } finally {
      _presentation.dispose();
    }
  }
}

/// Explicit dependency injection for hosts/tests; production defaults to media_kit.
class PreviewBackendScope extends InheritedWidget {
  const PreviewBackendScope({
    super.key,
    required this.factory,
    required super.child,
  });
  final PreviewBackend Function() factory;
  static PreviewBackend Function()? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PreviewBackendScope>()
      ?.factory;
  @override
  bool updateShouldNotify(PreviewBackendScope oldWidget) =>
      factory != oldWidget.factory;
}

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
  final _player = Player(
    configuration: const PlayerConfiguration(
      bufferSize: 16 * 1024 * 1024,
      logLevel: MPVLogLevel.error,
    ),
  );
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

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../playback_session.dart';

Player _player() => Player(
  configuration: const PlayerConfiguration(
    bufferSize: 32 * 1024 * 1024,
    logLevel: MPVLogLevel.error,
  ),
);

class PlaybackHandle {
  PlaybackHandle({
    required AppRepository repository,
    required LocalStore store,
    required DramaDetail detail,
    required int index,
    double position = 0,
    bool autoplay = true,
    bool preopen = true,
    Player? adoptedPlayer,
    VideoController? adoptedVideo,
    PlaybackPlan? adoptedPlan,
  }) {
    // 剧场预览等场景可直接接管正在播的播放器：复用同一 Player 和
    // VideoController，画面不重新缓冲；接管后播放器归本会话所有。
    final main = adoptedPlayer ?? _player();
    final standby = preopen ? _player() : null;
    _videos[main] = adoptedVideo ?? VideoController(main);
    if (standby != null) _videos[standby] = VideoController(standby);
    session = PlaybackSession(
      repository: repository,
      store: store,
      detail: detail,
      player: main,
      standby: standby,
      index: index,
      position: position,
      autoplay: autoplay,
      adoptedPlan: adoptedPlayer == null ? null : adoptedPlan,
    );
  }

  late final PlaybackSession session;
  final _videos = <Player, VideoController>{};

  VideoController video(Player player) => _videos[player]!;

  void dispose() => session.dispose();
}

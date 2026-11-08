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

/// 全集播放页退出时交还给来路的播放现场。
typedef PlaybackHandback = ({
  Player player,
  VideoController video,
  PlaybackPlan plan,
  Duration position,
});

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
    this.onHandback,
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

  /// 页面退出时回调：把仍在播的播放器与计划交还给来路（如剧场预览），
  /// 在会话真正销毁前触发，只有仍停留在首集且计划可用时才会回调。
  final void Function(PlaybackHandback handback)? onHandback;

  VideoController video(Player player) => _videos[player]!;

  void dispose() {
    // 只有仍停留在来路所预览的首集才有回传意义；否则按常规销毁，
    // 避免把换集后的计划丢给不再需要的预览端造成泄漏。
    if (onHandback != null && session.index == 0) {
      final taken = session.takeOver();
      if (taken != null) {
        final video = _videos.remove(taken.player);
        if (video != null) {
          onHandback!((
            player: taken.player,
            video: video,
            plan: taken.plan,
            position: taken.player.state.position,
          ));
        }
      }
    }
    session.dispose();
  }
}

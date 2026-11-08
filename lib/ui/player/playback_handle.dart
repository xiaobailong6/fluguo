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
    this.returnable = false,
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

  /// 页面销毁时是否应把播放现场交还给来路（如剧场预览）。
  /// 只有仍停留在首集且回传被索取时才会真正交接，避免泄漏。
  final bool returnable;

  /// dispose 时已捕获的现场；dispose 与路由返回的先后顺序不定，
  /// 调用方通过 [consumeHandback] 统一拉取，两种时序都能拿到。
  PlaybackHandback? _handback;

  VideoController video(Player player) => _videos[player]!;

  PlaybackHandback? _tryHandback() {
    if (!returnable || session.index != 0) return null;
    final taken = session.takeOver();
    if (taken == null) return null;
    final video = _videos.remove(taken.player);
    if (video == null) return null;
    return (
      player: taken.player,
      video: video,
      plan: taken.plan,
      position: taken.player.state.position,
    );
  }

  /// 索取回传的播放现场。
  ///
  /// dispose 已发生则返回其捕获的现场；尚未发生则当场主动回传，
  /// 之后 dispose 不会再重复交接。没有可回传内容时返回 null。
  PlaybackHandback? consumeHandback() {
    final stored = _handback;
    if (stored != null) {
      _handback = null;
      return stored;
    }
    return _tryHandback();
  }

  void dispose() {
    _handback ??= _tryHandback();
    session.dispose();
  }
}

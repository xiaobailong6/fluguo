import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'core_bridge.dart';
import 'danmaku_controller.dart';
import 'danmaku_style.dart';
import 'diary_service.dart';
import 'follow_state.dart';
import 'playback_decoder.dart';
import 'local_store.dart';
import 'media_controls.dart';
import 'models.dart';
import 'playback_loader.dart';
import 'playback_preferences.dart';
import 'playback_preloader.dart';
import 'playback_recovery.dart';
import 'playback_video_diagnostics.dart';
import 'playback_progress_writer.dart';
import 'playback_preload_policy.dart';
import 'playback_episode_window.dart';

Size? videoDisplaySize(VideoParams parameters) {
  final width = (parameters.dw ?? 0) > 0 ? parameters.dw! : parameters.w ?? 0;
  final height = (parameters.dh ?? 0) > 0 ? parameters.dh! : parameters.h ?? 0;
  if (width <= 0 || height <= 0) return null;
  final rotation = (parameters.rotate ?? 0) % 180;
  return rotation == 90
      ? Size(height.toDouble(), width.toDouble())
      : Size(width.toDouble(), height.toDouble());
}

String _diagnostic(Object error) {
  final text = error.toString().replaceAll(
    RegExp(r'[a-z]+://\S+', caseSensitive: false),
    '[地址]',
  );
  return text.length > 300 ? text.substring(0, 300) : text;
}

class PlaybackSession extends ChangeNotifier {
  PlaybackSession({
    required this.repository,
    required this.store,
    required this._detail,
    required Player player,
    Player? standby,
    required int index,
    double position = 0,
    bool autoplay = true,
    PlaybackPlan? adoptedPlan,
    this.mediaHistoryId,
    this.prepareVideo,
    this.createSparePlayer,
    this.disposeVideo,
    this.resetVideo,
  }) : _player = player,
       _engaged = autoplay,
       _index = index,
       _epoch = store.profileEpoch {
    final preferences = store.playbackPreferences;
    _speed = preferences.speed;
    _quality = preferences.quality;
    _danmakuEnabled = preferences.danmaku;
    _unmutedVolume = store.playerVolume.clamp(1.0, 100.0);
    unawaited(_player.setVolume(_unmutedVolume));
    _loader = PlaybackLoader(repository);
    _preloader = PlaybackPreloader(repository)..addListener(_prime);
    _pool.add(player);
    if (standby != null) _pool.add(standby);
    _maxPlayers = createSparePlayer != null ? 3 : (standby != null ? 2 : 1);
    _planIdentity = _identity(index);
    if (adoptedPlan != null) {
      _planExpires = playbackPlanExpiry(adoptedPlan, DateTime.now());
    }
    _emoji = preferences.danmakuEmoji;
    danmaku = DanmakuController(repository)
      ..setEnabled(_danmakuEnabled)
      ..setMergeWindow(preferences.danmakuMerge)
      ..setBlockedWords(preferences.danmakuWords);
    store.addListener(_accessChanged);
    store.addListener(_syncBlockedWords);
    _bind();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => saveProgress(quiet: true),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_closed || !_acceptErrors || _loading || _error != null) return;
      if (_health.stalled(
        position: _player.state.position,
        playing: _player.state.playing && _playIntent,
        foreground: _foreground,
        now: DateTime.now(),
      )) {
        unawaited(_recover('position_stalled_20s'));
      }
    });
    if (adoptedPlan == null || player.state.completed) {
      // 已结束的预览不是可直接续播的现场。保留旧计划供 play 释放，
      // 按入口给定的位置重新打开，不能只把 UI 标为 ready。
      _plan = adoptedPlan;
      unawaited(play(index, position: position, playWhenReady: autoplay));
      return;
    }
    // 剧场预览已用同一播放器打开同一媒体：直接接管现场，不重新 open，
    // 画面与声音都保持连续；换集、恢复等后续流程仍走常规 play()。
    _plan = adoptedPlan;
    _index = index;
    _openedIndex = index;
    // 接管的是已经在播的现场：装载即就绪，loading 不清会一直转圈并阻止挂载画面。
    _loading = false;
    _resumePosition = position;
    _openedAt = position;
    _acceptErrors = true;
    unawaited(
      _serialize(() async {
        await _configure(player, adoptedPlan);
        await _setRate(_rate);
      }).catchError((Object _) {}),
    );
    danmaku.setPlan(adoptedPlan);
    _syncDanmaku();
    _notify();
  }

  void _bind() {
    _videoDiagnostics.bind(
      player,
      allowed: () =>
          _usable && _foreground && _playIntent && ready && !_reopening,
    );
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final size = videoDisplaySize(player.state.videoParams);
    if (size != null) {
      _aspectRatio = size.width / size.height;
      _aspectKnown = true;
    }
    _buffering(player.state.buffering);
    final stream = player.stream;
    _subscriptions.addAll([
      stream.error.listen(_playerError),
      stream.completed.listen(_completed),
      stream.position.listen((position) {
        if (!_closed && _openedIndex == _index && position > Duration.zero) {
          _resumePosition = position.inMilliseconds / 1000;
        }
        _applySkip(position);
        _sync();
      }),
      stream.playing.listen((playing) {
        if (!playing) endBoost();
        _sync();
      }),
      stream.buffering.listen((buffering) {
        _buffering(buffering);
        _sync();
      }),
      for (final changes in [stream.duration, stream.buffer, stream.rate])
        changes.listen((_) => _sync()),
      stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (size == null || _closed) return;
        _aspectRatio = size.width / size.height;
        _aspectKnown = true;
        _notify();
      }),
    ]);
  }

  final AppRepository repository;
  final LocalStore store;

  /// 由渲染层确认备用输出就绪；无视频输出的宿主可不提供。
  final Future<void> Function(Player)? prepareVideo;
  final Player Function()? createSparePlayer;
  final Future<void> Function(Player)? disposeVideo;
  final Future<void> Function(Player, Duration)? resetVideo;
  late final _window = PlaybackEpisodeWindow(release: _retireEntry);
  final Set<Player> _pool = {};
  final Set<Player> _retiring = {};
  final Map<Player, Future<void>> _slotOperations = {};
  int _maxPlayers = 1;
  bool _syncingNeighbours = false;
  int? _prefetchIndex;
  DateTime _memoryCooldown = DateTime(2000);
  DateTime _planExpires = DateTime(2000);
  String _planIdentity = '';
  DramaDetail _detail;
  DramaDetail get detail => _detail;

  /// 合并成品独立记录位置，不覆盖原短剧的分集观看进度。
  final String? mediaHistoryId;
  Player _player;
  late final DanmakuController danmaku;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  final _preloadPolicy = PlaybackPreloadPolicy();
  int _playRequest = 0;
  int? _waitingNextRequest;
  bool _episodeGesture = false;
  final _recovery = PlaybackRecovery();
  final _videoDiagnostics = PlaybackVideoDiagnostics();
  final _health = PlaybackHealth();
  final int _epoch;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _saveTimer;
  Timer? _healthTimer;
  Timer? _errorTimer;
  Timer? _volumeTimer;
  Timer? _boostTimer;
  Timer? _stallTimer;
  Timer? _sleepTimer;
  Timer? _pauseTimer;
  Timer? _standbyIdleTimer;
  Timer? _resumeWatchdog;
  Timer? _seekWatchdog;
  bool _longPause = false;
  bool _standbySuspended = false;
  bool _reopening = false;
  int _interactionRevision = 0;
  DateTime? _sleepAt;
  int _sleepMinutes = 0;
  bool _sleepAtEpisodeEnd = false;
  bool _sleepStopped = false;
  Future<void> _operations = Future<void>.value();
  int _pendingMediaOperations = 0;
  Future<void>? _handoffPause;
  bool _accessInvalidated = false;
  Future<void> _rates = Future<void>.value();
  int _index;
  int _openedIndex = -1;
  int _generation = 0;
  bool _advancingSeason = false;
  Future<void>? _seasonLoad;
  String? _seasonLoadId;
  bool _screenLocked = false;
  bool _completionHandled = false;
  int _seekSequence = 0;
  bool _loading = true;
  bool _online = false;
  bool _localFailure = false;
  bool _loginRequired = false;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _handedOff = false;
  bool _foreground = true;
  bool _visible = true; // 包含画中画，与允许后台起播分开。
  bool _playIntent = true;
  int? _resumeInterruption;
  bool _pendingError = false;
  bool _boosting = false;
  bool _boostLocked = false;
  bool _engaged;
  bool _staleAudio = false;
  bool _stalled = false;
  bool _disownPlayer = false;
  String _loadingMessage = '正在准备播放';
  String? _error;
  late final _progressWriter = PlaybackProgressWriter(
    saveWatch: store.saveWatch,
    saveMediaWatch: store.saveMediaWatch,
    currentDrama: repository.catalogUpdates.current,
    onWarningChanged: _notify,
    mediaHistoryId: mediaHistoryId,
  );
  PlaybackPlan? _plan;
  double _openedAt = 0;

  /// 跳过片头/片尾每集只触发一次，避免和手动拖动相互拉扯。
  bool _introSkipped = false;
  bool _outroSkipped = false;
  double _speed = 1;
  int _quality = 0;
  bool _danmakuEnabled = true;

  /// 上次同步给弹幕的表情开关，只在真正切换时刷新绘制。
  bool _emoji = false;
  double _aspectRatio = 9 / 16;
  bool _aspectKnown = false;
  double _resumePosition = 0;
  double _unmutedVolume = 100;

  Player get player => _player;

  /// 把正在播的播放器连同当前计划交还给外部（如剧场预览）。
  ///
  /// 调用后本次 dispose 不再释放该播放器与计划，画面可被下一站无缝接管；
  /// 仍在加载或没有可用计划时返回 null。
  ({Player player, PlaybackPlan plan})? takeOver() {
    if (_closed ||
        _reopening ||
        _loading ||
        _openedIndex != _index ||
        _plan == null) {
      return null;
    }
    _cancelProgressWatchdogs();
    _cancelPauseTimers();
    _clearSleep();
    setLocked(false);
    final plan = _plan!;
    _plan = null;
    _disownPlayer = true;
    // 使尚未完成的会话操作失效，避免旧页面在交接后再次启动播放器。
    _handedOff = true;
    _generation++;
    _videoDiagnostics.dispose();
    _playIntent = false;
    MediaControls.instance.release(this);
    return (player: _player, plan: plan);
  }

  String _identity(int index) => playbackEpisodeIdentity(
    detail.drama,
    detail.episodes[index],
    _quality,
    _online,
    _epoch,
  );
  PlaybackEpisodeEntry? _neighbour(int index) =>
      index < 0 || index >= detail.episodes.length
      ? null
      : _window.find(index, _identity(index));
  Player? playerForEpisode(int index) =>
      index == _index ? player : _neighbour(index)?.player;
  bool episodeVideoReady(int index) =>
      index == _index ? ready : _neighbour(index)?.ready == true;
  bool episodeFrameRetained(int index) =>
      index == _index ? ready : _neighbour(index)?.frameRetained == true;
  List<Player> get videoPlayers => List.unmodifiable(
    _pool.where(
      (p) =>
          identical(p, player) ||
          _window.entries.any((e) => identical(e.player, p)),
    ),
  );
  Player? get standby => _neighbour(_index + 1)?.ready == true
      ? _neighbour(_index + 1)?.player
      : null;
  int get standbyIndex => standby == null ? -1 : _index + 1;
  Player? get preparingPlayer => _neighbour(_index + 1)?.player;
  int get preparingIndex => preparingPlayer == null ? -1 : _index + 1;
  int get retainedEpisodeCount => _window.length + (_plan == null ? 0 : 1);
  int get playerCount => _pool.length;
  bool get waitingForNext => _waitingNextRequest != null;

  Future<Uint8List?> Function(Player)? captureFullscreenSwitchFrame;
  ({int ticket, Uint8List bytes})? _fullscreenSwitchFrame;

  Uint8List? get fullscreenSwitchFrame {
    final frame = _fullscreenSwitchFrame;
    return frame != null && _current(frame.ticket) && _foreground && _visible
        ? frame.bytes
        : null;
  }

  bool canHoldEpisodeFrame(int target) =>
      (target - _index).abs() == 1 &&
      _maxPlayers > 1 &&
      _usable &&
      _visible &&
      _foreground &&
      ready &&
      _openedIndex == _index &&
      _plan != null;

  /// 切集请求开始就停旧声，不等网络/首帧；所有播放入口共用暂停屏障。
  Future<void> _pauseForEpisodeSwitch() {
    late final Future<void> paused;
    paused = Future.wait<void>([?_handoffPause, player.pause()])
        .then<void>((_) {})
        .whenComplete(() {
          // 失败仍传给本次等待者，但不能污染下一次独立的交接/重试。
          if (identical(_handoffPause, paused)) _handoffPause = null;
        });
    _handoffPause = paused;
    unawaited(paused.catchError((Object _) {}));
    return paused;
  }

  /// 翻页已露出邻页时暂停旧集，但保留用户原来的播放/暂停意图。
  void beginEpisodeGesture() {
    if (!_usable || _episodeGesture) return;
    cancelPendingEpisodeSwitch(resume: false);
    _episodeGesture = true;
    _pauseForEpisodeSwitch();
  }

  /// 撤回手势只恢复仍在显示的当前集；用户暂停和后台状态仍优先。
  void cancelPendingEpisodeSwitch({bool resume = true}) {
    final interrupted = _waitingNextRequest != null || _episodeGesture;
    if (interrupted) _playRequest++;
    _waitingNextRequest = null;
    _episodeGesture = false;
    final candidate = preparingPlayer;
    if (interrupted && candidate != null) unawaited(candidate.pause());
    if (interrupted && resume && ready) unawaited(_resumePlayer(player));
  }

  int get index => _index;
  Episode get episode => detail.episodes[_index];
  bool get loading => _loading;
  String get loadingMessage => _loadingMessage;
  String? get error => _error;
  bool get localFailure => _localFailure;
  bool get loginRequired => _loginRequired;
  String? get saveWarning => _progressWriter.warning;
  bool get ready => !_loading && _error == null;

  bool get stalled => _stalled;

  bool get paused => !_playIntent;
  bool get boosting => _boosting;
  bool get boostLocked => _boostLocked;
  bool get locked => _screenLocked;
  bool get switchingSeason => _advancingSeason;
  List<DramaSeason> get seasons => !_usable || mediaHistoryId != null
      ? const []
      : DramaSeason.associated(
          detail.drama,
          detail.seasons,
        ).where((season) => store.allowsSource(season.drama.source)).toList();

  void setLocked(bool value) {
    if (_closed || _screenLocked == value || value && !_usable) return;
    _screenLocked = value;
    if (value) {
      _boostLocked = false;
      endBoost();
    }
    _notify();
  }

  double get aspectRatio => _aspectRatio;
  bool get aspectKnown => _aspectKnown;
  double get speed => _speed;
  DateTime? get sleepAt => _sleepAt;
  int get sleepMinutes => _sleepMinutes;
  bool get sleepAtEpisodeEnd => _sleepAtEpisodeEnd;
  int get quality => _quality;
  bool get local => _plan?.local == true;
  List<int> get qualities => _plan?.qualities ?? const [];
  bool get danmakuSupported =>
      mediaHistoryId == null &&
      SourceSite.isKnown(detail.drama.source) &&
      SourceSite.byId(detail.drama.source).danmaku;
  bool get danmakuEnabled => _danmakuEnabled;
  PlaybackPreferences get preferences => _preferences;
  DanmakuStyle get danmakuStyle =>
      DanmakuStyle.of(store.playbackPreferences, source: detail.drama.source);
  bool get hasPrevious => _index > 0;
  bool get hasNext => _index + 1 < detail.episodes.length;
  String get qualityLabel {
    final plan = _plan;
    if (plan?.local == true) return '本地原画';
    if (_quality > 0) return '${_quality}P';
    return plan != null && plan.quality > 0 ? '自动（${plan.quality}P）' : '自动';
  }

  double get currentPosition =>
      _openedIndex == _index && player.state.position > Duration.zero
      ? player.state.position.inMilliseconds / 1000
      : _resumePosition;

  bool get _usable =>
      !_closed &&
      !_handedOff &&
      !store.locked &&
      store.allowsSource(detail.drama.source) &&
      store.profileEpoch == _epoch &&
      (mediaHistoryId == null ||
          store.canDownload && store.allowsSource(detail.drama.source));
  bool _current(int ticket) => _usable && ticket == _generation;

  PlaybackPreferences get _preferences => store.playbackPreferences.copyWith(
    speed: _speed,
    quality: _quality,
    danmaku: _danmakuEnabled,
    autoAdvance: store.playbackPreferences.autoAdvance,
    preload: true,
  );

  double get _rate => _boosting ? 2 : _speed;

  void _buffering(bool buffering) {
    _stallTimer?.cancel();
    if (buffering) {
      _stallTimer = Timer(const Duration(milliseconds: 500), () {
        if (_closed || !player.state.buffering) return;
        _stalled = true;
        _notify();
      });
    } else if (_stalled) {
      _stalled = false;
      _notify();
    }
  }

  void _notify() {
    if (_closed) return;
    notifyListeners();
    _syncMedia();
  }

  void _accessChanged() {
    if (_closed) return;
    if (store.profileEpoch != _epoch ||
        store.locked ||
        !store.allowsSource(detail.drama.source) ||
        mediaHistoryId != null && !store.canDownload) {
      if (!_accessInvalidated) {
        _accessInvalidated = true;
        _generation++;
        _playRequest++;
        _waitingNextRequest = null;
        _episodeGesture = false;
        _openedIndex = -1;
        final obsolete = _plan;
        _plan = null;
        if (obsolete != null) unawaited(_release(obsolete.session));
        unawaited(repository.cancelPlayback().catchError((Object _) {}));
        final target = player;
        unawaited(
          _serialize(() async {
            await target.stop();
          }),
        );
      }
      setLocked(false);
      _clearSleep();
      _cancelProgressWatchdogs();
      _cancelPauseTimers();
      _preloader.clear();
      _disposeNeighbourPlayers();
      _playIntent = false;
      endBoost();
      unawaited(player.pause());
    }
    if (store.profileEpoch != _epoch ||
        store.locked ||
        !store.allowsSource(detail.drama.source)) {
      danmaku.setPlan(null);
    }
    if (_usable) setForeground(_visible);
    if (_usable) _accessInvalidated = false;
    _syncMedia();
  }

  void _syncBlockedWords() {
    if (_closed) return;
    final preferences = store.playbackPreferences;
    danmaku.setMergeWindow(preferences.danmakuMerge);
    danmaku.setBlockedWords(preferences.danmakuWords);
    // 表情只改测宽与绘制，刷新弹幕自身而不向整个会话广播，
    // 避免存档等无关通知被放大成会话级重建。
    if (_emoji != preferences.danmakuEmoji) {
      _emoji = preferences.danmakuEmoji;
      danmaku.refreshStyle();
    }
  }

  void _sync() {
    _syncDanmaku();
    _syncPreload();
    _syncMedia();
  }

  bool get _backgroundPlayback =>
      MediaControls.supported && store.playbackPreferences.backgroundPlayback;

  void _syncMedia() {
    final controls = MediaControls.instance;
    if (!_usable ||
        !_backgroundPlayback ||
        !_engaged ||
        _sleepStopped ||
        !store.allowsSource(detail.drama.source)) {
      _cancelInterruptionResume();
      controls.release(this);
      return;
    }
    if (!_playIntent && !controls.owns(this)) return;
    final state = player.state;
    final opened = ready && _openedIndex == _index;
    controls.update(
      this,
      MediaState(
        title: detail.drama.title,
        subtitle: episode.title,
        artwork: repository.knownCover(detail.drama) ?? '',
        active: _playIntent && _error == null,
        playing: opened && _playIntent && state.playing,
        position: opened ? state.position : Duration.zero,
        duration: opened ? state.duration : Duration.zero,
        rate: state.rate,
        hasPrevious: !_screenLocked && hasPrevious,
        hasNext: !_screenLocked && hasNext,
      ),
      _mediaCommand,
    );
  }

  void _cancelInterruptionResume() {
    final id = _resumeInterruption;
    _resumeInterruption = null;
    if (id != null) MediaControls.instance.cancelResume(this, id);
  }

  void _mediaCommand(
    MediaCommand command,
    Duration? position, {
    int? interruptionId,
  }) {
    if (!_usable ||
        !_foreground ||
        !_backgroundPlayback ||
        _sleepStopped ||
        !store.allowsSource(detail.drama.source)) {
      return;
    }
    if (interruptionId != null) {
      if (command == MediaCommand.pause) {
        if (_playIntent) {
          _resumeInterruption = interruptionId;
          _setPlayback(false, interrupted: true);
        }
      } else if (command == MediaCommand.play &&
          _resumeInterruption == interruptionId) {
        _resumeInterruption = null;
        if (!_screenLocked) _setPlayback(true, interrupted: true);
      }
      return;
    }
    // 明确暂停即使已经暂停也要撤销自动恢复，迟到的编号不能重新起播。
    _cancelInterruptionResume();
    if (_screenLocked && command != MediaCommand.pause) return;
    switch (command) {
      case MediaCommand.play:
        if (paused) _setPlayback(true);
      case MediaCommand.pause:
        if (!paused) _setPlayback(false);
      case MediaCommand.toggle:
        _setPlayback(paused);
      case MediaCommand.next:
        if (hasNext) unawaited(next());
      case MediaCommand.previous:
        if (hasPrevious) unawaited(previous());
      case MediaCommand.seek:
        if (position != null) unawaited(seekTo(position));
    }
  }

  void _syncDanmaku() {
    if (_closed) return;
    final state = player.state;
    danmaku.update(
      position: state.position,
      duration: state.duration,
      speed: state.rate,
      playing: state.playing && _playIntent && !state.completed,
      buffering: state.buffering,
      foreground: _visible,
      available:
          ready &&
          danmakuSupported &&
          _openedIndex == _index &&
          _usable &&
          !store.locked &&
          store.allowsSource(detail.drama.source),
    );
  }

  ({bool prefetch, bool preopen, Duration remaining}) _preloadDecision() {
    final state = player.state;
    final preferences = store.playbackPreferences;
    return _preloadPolicy.evaluate(
      position: state.position,
      duration: state.duration,
      buffered: state.buffer,
      rate: _rate,
      playing: state.playing && _playIntent,
      buffering: state.buffering,
      local: local,
      skipIntroSeconds: skipSecondsOr(preferences.skipIntroSeconds),
      skipOutroSeconds: skipSecondsOr(preferences.skipOutroSeconds),
    );
  }

  void _syncPreload() {
    if (_closed || _syncingNeighbours) return;
    if (_sleepStopped ||
        _reopening ||
        _sleepAtEpisodeEnd ||
        !_foreground ||
        !_visible ||
        !_usable ||
        !_engaged ||
        _standbySuspended ||
        store.locked ||
        !store.allowsSource(detail.drama.source) ||
        DateTime.now().isBefore(_memoryCooldown)) {
      _preloadPolicy.reset();
      _preloader.clear();
      _dropStandby();
      return;
    }
    if (!ready || _openedIndex != _index) return;
    // 翻页/首帧等待造成的临时暂停不能取消目标预取；不是用户暂停。
    if (_episodeGesture || _waitingNextRequest != null) return;
    _syncingNeighbours = true;
    try {
      _window.move(detail, _index, _quality, _online, _epoch);
      final decision = _preloadDecision();
      if (decision.remaining == Duration.zero && !player.state.buffering) {
        return;
      }
      if (!decision.prefetch) {
        _preloader.pause();
        return;
      }
      _collectPreload();
      for (final index in [_index + 1, _index - 1]) {
        if (index < 0 || index >= detail.episodes.length) continue;
        final entry = _neighbour(index);
        if (entry != null) {
          if (decision.preopen) _prepareEntry(entry);
          continue;
        }
        // 同一预取器服务两侧；旧取消任务真正结束前不启动第二个网络任务。
        if (!_preloader.pending && !_preloader.ready) {
          _prefetchIndex = index;
          _preloader.prepare(
            detail.drama,
            detail.episodes[index],
            quality: _quality,
            online: _online,
          );
        }
        break;
      }
    } finally {
      _syncingNeighbours = false;
    }
  }

  void _collectPreload() {
    final index = _prefetchIndex;
    if (index == null || !_preloader.ready) return;
    if ((index - _index).abs() != 1 ||
        index < 0 ||
        index >= detail.episodes.length) {
      _preloader.clear();
      return;
    }
    final expiry = _preloader.expires;
    final plan = _preloader.take(
      detail.drama,
      detail.episodes[index],
      quality: _quality,
      online: _online,
    );
    _prefetchIndex = null;
    if (plan == null) return;
    _window.add(
      PlaybackEpisodeEntry(
        identity: _identity(index),
        index: index,
        plan: plan,
        expires: expiry,
      ),
    );
  }

  void _playerError(String error) {
    if (_closed || !_acceptErrors || error.trim().isEmpty) return;
    DiaryService.add('[Play] 播放器报错：${_diagnostic(error)}');
    _queueRecovery('player_error');
  }

  bool get _canAutoAdvance =>
      _usable &&
      _foreground &&
      _playIntent &&
      store.playbackPreferences.autoAdvance &&
      !_sleepStopped &&
      !_sleepAtEpisodeEnd &&
      (_sleepAt == null || DateTime.now().isBefore(_sleepAt!)) &&
      store.allowsSource(detail.drama.source);

  void _completed(bool completed) {
    if (!completed ||
        _sleepStopped ||
        _loading ||
        _closed ||
        !_acceptErrors ||
        _error != null ||
        _completionHandled) {
      return;
    }
    final duration = player.state.duration;
    if (duration <= Duration.zero ||
        player.state.position < duration - const Duration(seconds: 2)) {
      _queueRecovery('early_completion');
      return;
    }
    _completionHandled = true;
    if (_sleepAtEpisodeEnd ||
        (_sleepAt != null && !DateTime.now().isBefore(_sleepAt!))) {
      _stopForSleep();
    } else if (_canAutoAdvance && hasNext) {
      unawaited(play(_index + 1));
    } else if (_canAutoAdvance && mediaHistoryId == null) {
      unawaited(_advanceSeason());
    } else {
      _playIntent = false;
      endBoost();
      unawaited(player.pause());
      unawaited(saveProgress());
    }
  }

  /// 播放入口可能早于详情页的官方关联请求完成，选季面板可按需补载。
  Future<void> loadSeasons() {
    if (!_usable ||
        mediaHistoryId != null ||
        detail.seasons.isNotEmpty ||
        !store.allowsSource(detail.drama.source)) {
      return Future.value();
    }
    final requested = detail.drama;
    if (_seasonLoadId == requested.id && _seasonLoad != null) {
      return _seasonLoad!;
    }
    _seasonLoadId = requested.id;
    late Future<void> work;
    work =
        (() async {
          final rows = await repository.seasons(requested);
          if (!_usable ||
              detail.drama.id != requested.id ||
              detail.drama.source != requested.source ||
              !store.allowsSource(requested.source)) {
            return;
          }
          _detail = DramaDetail(
            detail.drama,
            detail.episodes,
            warning: detail.warning,
            seasons: DramaSeason.associated(requested, rows),
          );
          _notify();
        })().whenComplete(() {
          if (identical(_seasonLoad, work)) {
            _seasonLoad = null;
            _seasonLoadId = null;
          }
        });
    return _seasonLoad = work;
  }

  /// 手动切季使用该季自己的观看记录；自动续季仍保留原有首集语义。
  Future<bool> playSeason(DramaSeason choice) async {
    if (!_usable ||
        _screenLocked ||
        _advancingSeason ||
        _loading ||
        _reopening ||
        mediaHistoryId != null ||
        !_foreground) {
      return false;
    }
    final selected = seasons
        .where(
          (season) =>
              season.drama.id == choice.drama.id &&
              season.drama.source == choice.drama.source,
        )
        .firstOrNull;
    if (selected == null) return false;
    if (selected.drama.id == detail.drama.id) return true;
    _cancelProgressWatchdogs();
    final interaction = _interactionRevision;
    final ticket = ++_generation;
    final previous = detail;
    final wantedPlayback = _playIntent;
    final sleepStopped = _sleepStopped;
    final acceptedErrors = _acceptErrors;
    _advancingSeason = true;
    _loading = true;
    _loadingMessage = '正在切换${selected.label}';
    _acceptErrors = false;
    _errorTimer?.cancel();
    _pendingError = false;
    _preloader.clear();
    _dropStandby();
    endBoost();
    _notify();
    bool valid() =>
        _current(ticket) &&
        _foreground &&
        !_screenLocked &&
        interaction == _interactionRevision &&
        _sleepStopped == sleepStopped &&
        (_sleepAt == null || DateTime.now().isBefore(_sleepAt!)) &&
        store.allowsSource(selected.drama.source);
    try {
      await _serialize(() async {
        if (!valid()) return;
        await saveProgress();
        if (valid()) await player.pause();
      });
      if (!valid()) return false;
      final fresh = await repository.detail(selected.drama);
      if (!valid()) return false;
      if (fresh.drama.id != selected.drama.id ||
          fresh.drama.source != selected.drama.source) {
        throw AppFailure('站源返回的季信息不匹配');
      }
      if (fresh.episodes.isEmpty) throw AppFailure('${selected.label}暂无可播放的集数');
      final watch = store.watched(fresh.drama.id);
      final index = resumeEpisodeIndex(fresh.episodes, watch);
      final position =
          watch != null &&
              !watch.finished &&
              watch.episode == fresh.episodes[index].number
          ? watch.position
          : 0.0;
      _openedIndex = -1;
      _index = index;
      _resumePosition = position;
      _online = false;
      _detail = DramaDetail(
        fresh.drama,
        fresh.episodes,
        warning: fresh.warning,
        seasons: DramaSeason.associated(
          fresh.drama,
          fresh.seasons.isNotEmpty ? fresh.seasons : previous.seasons,
        ),
      );
      await play(
        index,
        position: position,
        playWhenReady: wantedPlayback && _playIntent,
      );
      return _usable && detail.drama.id == selected.drama.id && _error == null;
    } catch (error) {
      if (valid()) {
        throw AppFailure(error is AppFailure ? error.message : '切季失败，请稍后重试');
      }
      return false;
    } finally {
      if (!_closed && ticket == _generation) {
        // 尚未提交目标详情时保留原季，停在原位置供用户继续或重试。
        _advancingSeason = false;
        _loading = false;
        _playIntent = false;
        _acceptErrors = acceptedErrors;
        unawaited(player.pause().catchError((Object _) {}));
        _notify();
      }
    }
  }

  /// 最后一集自然完成才查官方关联；手动 next 仍只表示本季下一集。
  Future<void> _advanceSeason() async {
    _cancelProgressWatchdogs();
    final previous = detail;
    final ticket = ++_generation;
    _advancingSeason = true;
    _loading = true;
    _loadingMessage = '正在加载下一季';
    _acceptErrors = false;
    _errorTimer?.cancel();
    _pendingError = false;
    _preloader.clear();
    _dropStandby();
    endBoost();
    _notify();
    bool valid() => _current(ticket) && _canAutoAdvance;
    try {
      // 在安装新详情前保存旧季，避免用新季 id/首集标记旧播放器的位置。
      await saveProgress();
      if (!valid()) return;
      await player.pause();
      if (!valid()) return;
      final seasons = previous.seasons.isNotEmpty
          ? previous.seasons
          : await repository.seasons(previous.drama);
      if (!valid()) return;
      final linked = DramaDetail(
        previous.drama,
        previous.episodes,
        warning: previous.warning,
        seasons: DramaSeason.associated(previous.drama, seasons),
      );
      final next = linked.nextSeason;
      if (next == null || !store.allowsSource(next.drama.source)) return;
      final fresh = await repository.detail(next.drama);
      if (!valid() || !store.allowsSource(next.drama.source)) return;
      if (fresh.drama.id != next.drama.id ||
          fresh.drama.source != next.drama.source) {
        throw AppFailure('下一季信息不匹配，请返回详情重试。');
      }
      if (fresh.episodes.isEmpty) {
        throw AppFailure('下一季暂无可播放的集数，请返回详情重试。');
      }
      // 只有详情校验成功才提交。失败/取消时旧详情、索引和播放计划保持一致。
      _openedIndex = -1;
      _index = 0;
      _resumePosition = 0;
      _online = false;
      _detail = DramaDetail(
        fresh.drama,
        fresh.episodes,
        warning: fresh.warning,
        seasons: DramaSeason.associated(
          fresh.drama,
          fresh.seasons.isNotEmpty ? fresh.seasons : linked.seasons,
        ),
      );
      await play(0, seasonAdvance: true);
    } catch (_) {
      if (valid()) _error = '下一季加载失败或暂无可播放的集数，请返回详情重试。';
    } finally {
      if (!_closed && ticket == _generation) {
        _advancingSeason = false;
        _loading = false;
        _playIntent = false;
        unawaited(player.pause().catchError((Object _) {}));
        _notify();
      }
    }
  }

  /// 跳过片头/片尾：每集各触发一次，手动拖回后不会被再次拽走。
  void _applySkip(Duration position) {
    if (!_usable || _loading || _error != null) return;
    if (_openedIndex != _index) return;
    final total = player.state.duration;
    if (total <= const Duration(seconds: 2)) return;
    final preferences = store.playbackPreferences;
    final introSeconds = skipSecondsOr(preferences.skipIntroSeconds);
    final outroSeconds = skipSecondsOr(preferences.skipOutroSeconds);
    final intro = Duration(seconds: introSeconds);
    // 只有从第 0 秒起播才跳片头；续播进度本来就在片头之后，不能再往前拽。
    if (introSeconds > 0 && !_introSkipped && _openedAt < .5) {
      if (intro >= total - const Duration(seconds: 1)) {
        _introSkipped = true;
      } else if (position >= intro) {
        // 已经越过片头（含手动拖动），本集不再介入。
        _introSkipped = true;
      } else if (position > Duration.zero) {
        _introSkipped = true;
        unawaited(seekTo(intro));
      }
    }
    if (outroSeconds <= 0 || _outroSkipped) return;
    // 暂停时不介入，避免把停在结尾的画面直接替换掉。
    if (!player.state.playing || !_playIntent) return;
    final end = total - Duration(seconds: outroSeconds);
    // 片头片尾区间重叠时以片头为准，避免一开播就被送到结尾。
    if (end <= intro + const Duration(seconds: 1)) return;
    if (position < end) return;
    _outroSkipped = true;
    // 留一点余量再交给既有的播放完成/自动连播流程，不直接跳到 EOF。
    unawaited(seekTo(total - const Duration(milliseconds: 300)));
  }

  void _clearSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepAt = null;
    _sleepMinutes = 0;
    _sleepAtEpisodeEnd = false;
  }

  /// 仅当前会话有效，切集不重置；关闭、交接现场或切换用户时清理。
  void setSleepTimer({int minutes = 0, bool episodeEnd = false}) {
    if (!_usable) return;
    if (!episodeEnd && !const [0, 15, 30, 60, 90].contains(minutes)) {
      throw ArgumentError.value(minutes, 'minutes', '不支持的定时停止时长');
    }
    _clearSleep();
    if (episodeEnd) {
      _sleepAtEpisodeEnd = true;
      _preloader.clear();
      _dropStandby();
    } else if (minutes > 0) {
      final duration = Duration(minutes: minutes);
      _sleepMinutes = minutes;
      _sleepAt = DateTime.now().add(duration);
      _sleepTimer = Timer(duration, _stopForSleep);
    }
    _notify();
  }

  void _stopForSleep() {
    _clearSleep();
    if (!_usable) return;
    _cancelInterruptionResume();
    _sleepStopped = true;
    _playRequest++;
    _cancelProgressWatchdogs();
    _cancelPauseTimers();
    _playIntent = false;
    _boostLocked = false;
    endBoost();
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    _preloader.clear();
    _dropStandby();
    // 立即暂停，再排到已在进行的 open/play 后暂停，防止异步起播覆盖停止意图。
    final target = player;
    unawaited(target.pause().catchError((Object _) {}));
    unawaited(
      _serialize(() async {
        if (_usable && _sleepStopped && identical(target, player)) {
          await target.pause();
        }
      }).catchError((Object _) {}),
    );
    unawaited(saveProgress());
    _syncDanmaku();
    _notify();
  }

  void _queueRecovery(String reason) {
    if (_closed || _sleepStopped || !_acceptErrors || _error != null) return;
    _pendingError = true;
    if (!_foreground || (_errorTimer?.isActive ?? false)) return;
    final ticket = _generation;
    final position = player.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (!_current(ticket) || !_foreground || !_acceptErrors) return;
      _pendingError = false;
      final state = player.state;
      if (state.playing &&
          !state.buffering &&
          (state.width ?? 0) > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        return;
      }
      unawaited(_recover(reason));
    });
  }

  Future<void> _recover(String reason) async {
    final current = _plan;
    if (_closed ||
        _sleepStopped ||
        !_acceptErrors ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    danmaku.setPlan(null);
    _errorTimer?.cancel();
    _pendingError = false;
    final position = currentPosition;
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    DiaryService.add(
      '[Play] 自动恢复 原因=$reason 处理=${action.name} 线路=${current.routeIndex + 1}/${current.routeCount}',
    );
    if (action != PlaybackRecoveryAction.stop) {
      await play(_index, position: position, recovery: action);
      return;
    }
    _resumePosition = position;
    final ticket = _generation;
    try {
      await _serialize(() async {
        if (!_current(ticket)) return;
        try {
          await saveProgress();
          _openedIndex = -1;
          await player.stop();
        } finally {
          await _release(current.session);
        }
      });
    } catch (_) {}
    if (!_current(ticket)) return;
    _loading = false;
    _localFailure = current.local;
    _loginRequired = false;
    _error = current.local
        ? '本地视频读取失败，请重试或重新下载；也可以改为在线播放。'
        : '自动恢复未成功，请检查网络后重试，也可换一集或选择其他清晰度。';
    _notify();
  }

  Future<void> _release(String session) async {
    if (session.isEmpty) return;
    await repository.release(session).catchError((Object _) {});
  }

  Future<void> _serialize(Future<void> Function() operation) {
    _pendingMediaOperations++;
    final next = _operations
        .catchError((Object _) {})
        .then((_) => operation())
        .whenComplete(() {
          _pendingMediaOperations--;
        });
    _operations = next;
    return next;
  }

  Future<void> _configure(Player target, PlaybackPlan plan) async {
    final platform = target.platform;
    if (platform is! NativePlayer) return;
    for (final entry in playbackDecoderProperties(
      store.playbackPreferences.televisionDecoder,
      defaultTargetPlatform,
    ).entries) {
      await platform.setProperty(entry.key, entry.value);
    }
    if (Platform.isAndroid) {
      await platform.setProperty('hwdec-codecs', 'all');
      await platform.setProperty('vd-lavc-skiploopfilter', 'nonkey');
      await platform.setProperty('vd-lavc-threads', '4');
      await platform.setProperty('vd-lavc-fast', 'yes');
      await platform.setProperty('video-sync', 'audio');
      await platform.setProperty('framedrop', 'vo');
    }
    await platform.setProperty(
      'demuxer-lavf-o',
      [
        'seg_max_retry=3',
        'strict=experimental',
        'allowed_extensions=ALL',
        plan.local
            ? 'protocol_whitelist=[file,crypto,data]'
            : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
        if (plan.decryptionKey.isNotEmpty)
          'decryption_key=${plan.decryptionKey}',
      ].join(','),
    );
    await platform.setProperty('network-timeout', '20');
    if (Platform.isIOS) {
      await platform.setProperty(
        'vid',
        !_visible && _backgroundPlayback ? 'no' : 'auto',
      );
    }
  }

  Future<void> play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recovery,
    bool playWhenReady = true,
    bool seasonAdvance = false,
  }) async {
    if (!_usable || index < 0 || index >= detail.episodes.length) return;
    final request = ++_playRequest;
    _episodeGesture = index != _index;
    if (_episodeGesture) _pauseForEpisodeSwitch();
    final beforeWait = _generation;
    final retainFullscreenFrame =
        recovery == null && canHoldEpisodeFrame(index) && prepareVideo != null;
    if (index != _index) _online = false;
    bool stillWaiting() =>
        _usable &&
        request == _playRequest &&
        beforeWait == _generation &&
        _foreground &&
        _visible &&
        !_sleepStopped;
    var preparationTimedOut = false;
    if (recovery == null && position == 0 && canHoldEpisodeFrame(index)) {
      final pending = _preloader.waitForPreparation(
        detail.drama,
        detail.episodes[index],
        quality: _quality,
        online: _online,
      );
      final candidate = _neighbour(index);
      if (candidate?.ready != true && (candidate != null || pending != null)) {
        _playIntent = playWhenReady;
        _waitingNextRequest = request;
        try {
          await (() async {
            if (pending != null) await pending;
            if (preparationTimedOut || !stillWaiting()) return;
            _collectPreload();
            final entry = _neighbour(index);
            if (entry == null || entry.ready) return;
            _prepareEntry(entry);
            await entry.preparing;
          })().timeout(const Duration(milliseconds: 1500));
        } on TimeoutException {
          preparationTimedOut = true;
        } finally {
          if (_waitingNextRequest == request) _waitingNextRequest = null;
        }
        if (!stillWaiting()) return;
        playWhenReady = _playIntent;
      }
    }
    if (recovery == null) _cancelInterruptionResume();
    _episodeGesture = false;
    _cancelProgressWatchdogs();
    _cancelPauseTimers();
    _standbySuspended = false;
    _longPause = false;
    _videoDiagnostics.reset();
    _advancingSeason = false;
    _completionHandled = false;
    endBoost();
    _staleAudio = false;
    final target = recovery == null ? _neighbour(index) : null;
    if (position == 0 &&
        target != null &&
        target.ready &&
        target.player != null) {
      return _swap(index, playWhenReady, target);
    }
    final cached = target == null
        ? null
        : _window.take(index, _identity(index));
    if (cached != null) _detachEntryPlayer(cached);
    final warming = cached != null
        ? Future<PlaybackPlan?>.value(cached.plan)
        : recovery == null && !preparationTimedOut
        ? _preloader.takeOrWait(
            detail.drama,
            detail.episodes[index],
            quality: _quality,
            online: _online,
          )
        : null;
    _window.move(detail, index, _quality, _online, _epoch);
    if (warming == null) _preloader.clear();
    final oldIndex = _openedIndex;
    _preloadPolicy.reset();
    final ticket = ++_generation;
    _seekSequence++;
    _introSkipped = false;
    _outroSkipped = false;
    danmaku.setPlan(null);
    _acceptErrors = false;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    if (recovery == null) {
      _recovery.reset();
      _sleepStopped = false;
      _playIntent = playWhenReady;
    }
    _resumePosition = position;
    _openedAt = position;
    _index = index;
    _loading = true;
    _error = null;
    _localFailure = false;
    _loginRequired = false;
    _loadingMessage = switch (recovery) {
      PlaybackRecoveryAction.alternative => '正在切换备用线路',
      PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
      _ => '正在准备播放',
    };
    _notify();
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    PlaybackPlan? warmed;
    var installed = false;
    try {
      if (warming != null) warmed = await warming;
      if (!_current(ticket)) return;
      if (warmed != null &&
          warmed.expiresAt > 0 &&
          DateTime.now().millisecondsSinceEpoch >= warmed.expiresAt - 5000) {
        await _release(warmed.session);
        warmed = null;
      }
      await _serialize(() async {
        if (!_current(ticket)) return;
        await saveProgress();
        if (!_current(ticket)) return;
        final stopped = player;
        final previous = _plan;
        final capture = captureFullscreenSwitchFrame;
        if (retainFullscreenFrame &&
            capture != null &&
            _foreground &&
            _visible) {
          try {
            final bytes = await capture(
              stopped,
            ).timeout(const Duration(milliseconds: 350));
            if (!_current(ticket) || request != _playRequest) return;
            if (bytes != null &&
                bytes.isNotEmpty &&
                _foreground &&
                _visible &&
                identical(capture, captureFullscreenSwitchFrame)) {
              _fullscreenSwitchFrame = (ticket: ticket, bytes: bytes);
              _notify();
            }
          } catch (_) {
            // 截图不可用时仍走原来的加载流程。
          }
          if (!_current(ticket) || request != _playRequest) return;
        }
        _openedIndex = -1;
        await stopped.stop();
        if (!_current(ticket) ||
            !identical(stopped, player) ||
            !identical(previous, _plan)) {
          return;
        }
        _plan = null;
        if (recovery == PlaybackRecoveryAction.alternative) {
          retained = previous;
        } else if (previous != null) {
          _keepPrevious(previous, oldIndex, null, index);
        }
      });
      if (!_current(ticket)) return;
      if (retainFullscreenFrame && request != _playRequest) return;
      prepared = retained != null
          ? await _loader.fallback(retained!)
          : warmed != null
          ? await _loader.use(warmed)
          : await _loader.load(
              detail.drama,
              detail.episodes[index],
              quality: _quality,
              online: _online,
            );
      if (prepared == null) return;
      final plan = prepared;
      await _serialize(() async {
        if (!_current(ticket)) {
          return;
        }
        if (plan.url.isEmpty) throw AppFailure('站源未返回播放地址，请重试');
        await _configure(player, plan);
        final pauseBarrier = _handoffPause;
        if (pauseBarrier != null) await pauseBarrier;
        if (!_current(ticket)) return;
        await _limitCache(player, !_engaged);
        if (!_current(ticket)) {
          return;
        }
        if (seasonAdvance && !_canAutoAdvance) _playIntent = false;
        _plan = plan;
        _planIdentity = _identity(index);
        _planExpires = warmed != null
            ? (cached?.expires ?? _preloader.expires)
            : playbackPlanExpiry(plan, DateTime.now());
        installed = true;
        _acceptErrors = true;
        await player.open(
          Media(
            plan.url,
            httpHeaders: plan.headers,
            start: position > 0
                ? Duration(milliseconds: (position * 1000).round())
                : null,
          ),
          play: _foreground && _playIntent,
        );
        // open 也可能跨越退出、切用户或定时停止；先静音现场，再丢弃过期结果。
        if (!_handedOff &&
            (!_current(ticket) ||
                !_foreground ||
                !_playIntent ||
                (seasonAdvance && !_canAutoAdvance))) {
          if (_current(ticket)) _playIntent = false;
          await player.pause();
        }
        if (!_current(ticket)) return;
        _openedIndex = index;
        _health.reset();
        await _setRate(_rate);
        // open 的参数在 await 前确定；途中再次收到 play 时需补起播，
        // _resumePlayer 会再次校验暂停、后台和交接，不能越过新意图。
        if (_current(ticket) &&
            _foreground &&
            _playIntent &&
            !player.state.playing) {
          await _resumePlayer(player);
        }
        if (!_current(ticket)) return;
        if (_fullscreenSwitchFrame?.ticket == ticket &&
            _foreground &&
            _visible) {
          try {
            // prepareVideo 自身带输出就绪截止时间；不再用更短的外层计时抢先撤帧。
            await prepareVideo!(player);
          } catch (_) {
            // 交给外层已安装播放计划的恢复分支，不能把无首帧输出报告为成功。
            rethrow;
          }
          if (!_current(ticket)) return;
          _fullscreenSwitchFrame = null;
        }
        _loading = false;
        _notify();
        danmaku.setPlan(plan);
        _syncDanmaku();
      });
    } catch (error) {
      if (_current(ticket)) {
        if (prepared != null && identical(_plan, prepared)) {
          _acceptErrors = true;
          _queueRecovery('open_exception');
        } else {
          if (_current(ticket)) {
            DiaryService.add('[Play] 无法播放：${_diagnostic(error)}');
            _loading = false;
            _localFailure = error is AppFailure && error.code == 'local_media';
            _loginRequired =
                error is AppFailure && error.code == 'source_login';
            _error = error is AppFailure ? error.message : '无法播放这一集，请重试或换一集。';
            _notify();
          }
        }
      }
    } finally {
      if (_fullscreenSwitchFrame?.ticket == ticket) {
        _fullscreenSwitchFrame = null;
        if (_current(ticket)) _notify();
      }
      if (!installed) {
        final abandoned = prepared ?? warmed;
        if (abandoned != null) await _release(abandoned.session);
      }
      if (retained != null) await _release(retained!.session);
    }
  }

  Future<void> _swap(
    int index,
    bool playWhenReady,
    PlaybackEpisodeEntry entry,
  ) async {
    final request = _playRequest;
    if (_pendingMediaOperations > 0) {
      _playIntent = playWhenReady;
      _waitingNextRequest = request;
      try {
        await _operations.catchError((Object _) {});
      } finally {
        if (_waitingNextRequest == request) _waitingNextRequest = null;
      }
      if (!_usable ||
          request != _playRequest ||
          !_window.owns(entry) ||
          !_window.valid(entry)) {
        return;
      }
      playWhenReady = _playIntent;
    }
    final previous = _player;
    final previousPlan = _plan;
    final oldIndex = _openedIndex;
    final next = entry.player!;
    final volume = previous.state.volume;
    // 先记真实进度并停声，再改变当前角色；后台回零不能写进观看记录。
    unawaited(saveProgress());
    final pausedPrevious = _pauseForEpisodeSwitch();
    if (!_usable ||
        request != _playRequest ||
        !_window.owns(entry) ||
        !_window.valid(entry)) {
      unawaited(pausedPrevious.catchError((Object _) {}));
      return;
    }
    _window.take(index, _identity(index));
    unawaited(entry.errors?.cancel());
    entry.errors = null;
    _cancelPauseTimers();
    _completionHandled = false;
    _preloader.clear();
    _prefetchIndex = null;
    final ticket = ++_generation;
    _seekSequence++;
    _introSkipped = false;
    _outroSkipped = false;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    _recovery.reset();
    _sleepStopped = false;
    _playIntent = playWhenReady;
    _resumePosition = 0;
    _openedAt = 0;
    _index = index;
    _error = null;
    _localFailure = false;
    _loginRequired = false;
    _loading = false;
    _preloadPolicy.reset();
    _player = next;
    _plan = entry.plan;
    _window.move(detail, index, _quality, _online, _epoch);
    if (previousPlan != null) {
      _keepPrevious(previousPlan, oldIndex, previous, index);
    }
    _planIdentity = entry.identity;
    _planExpires = entry.expires;
    _bind();
    _openedIndex = index;
    _acceptErrors = true;
    danmaku.setPlan(entry.plan);
    _notify();
    _syncDanmaku();
    try {
      await _limitCache(previous, true);
      if (!_current(ticket)) return;
      await pausedPrevious;
      await _limitCache(next, false);
      if (!_playIntent) await next.pause();
      await next.setVolume(volume);
      await _setRate(_rate);
      if (_current(ticket) && _playIntent) await _resumePlayer(next);
    } catch (_) {
      if (_current(ticket)) _queueRecovery('open_exception');
    }
  }

  void _keepPrevious(
    PlaybackPlan plan,
    int oldIndex,
    Player? oldPlayer,
    int target,
  ) {
    if (oldIndex < 0 ||
        oldIndex >= detail.episodes.length ||
        oldIndex == target ||
        (oldIndex - target).abs() != 1 ||
        _planIdentity != _identity(oldIndex) ||
        !_visible ||
        _standbySuspended ||
        DateTime.now().isBefore(_memoryCooldown)) {
      unawaited(_release(plan.session));
      if (oldPlayer != null) unawaited(_slot(oldPlayer, oldPlayer.stop));
      return;
    }
    final entry = PlaybackEpisodeEntry(
      identity: _planIdentity,
      index: oldIndex,
      plan: plan,
      expires: _planExpires,
    )..player = oldPlayer;
    entry.frameRetained = oldPlayer != null;
    if (_window.add(entry) && oldPlayer != null) {
      _prepareEntry(entry, rewind: true);
    }
  }

  void _prime() {
    if (!_closed && ready && _preloader.ready && !_syncingNeighbours) {
      _syncPreload();
    }
  }

  Future<void> _slot(Player target, Future<void> Function() action) {
    final work = (_slotOperations[target] ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) => action());
    _slotOperations[target] = work.catchError((Object _) {});
    return work.catchError((Object _) {});
  }

  Player? _spare(PlaybackEpisodeEntry entry) {
    for (final candidate in _pool) {
      if (!identical(candidate, player) &&
          !_retiring.contains(candidate) &&
          !_window.entries.any((e) => identical(e.player, candidate))) {
        return candidate;
      }
    }
    if (_pool.length < _maxPlayers && createSparePlayer != null) {
      try {
        final created = createSparePlayer!();
        _pool.add(created);
        return created;
      } catch (_) {
        _maxPlayers = _pool.length;
      }
    }
    // 低资源模式仅预开下一集，但上一集数据仍留在窗口中。
    if (entry.index > _index) {
      for (final old in _window.entries) {
        if (old.index < _index && old.player != null) {
          final candidate = old.player;
          _detachEntryPlayer(old);
          return candidate;
        }
      }
    }
    return null;
  }

  void _prepareEntry(PlaybackEpisodeEntry entry, {bool rewind = false}) {
    if (!_window.owns(entry) ||
        entry.ready ||
        entry.outputUnavailable ||
        entry.preparing != null ||
        !_usable ||
        !_visible ||
        _standbySuspended ||
        _maxPlayers < 2) {
      return;
    }
    final target = entry.player ?? _spare(entry);
    if (target == null) return;
    entry.player = target;
    final outputCancelled = entry.outputCancelled = Completer<void>();
    final preparation = ++entry.preparation;
    entry.preparing = _slot(target, () async {
      bool current() =>
          _usable &&
          _visible &&
          !_standbySuspended &&
          _window.owns(entry) &&
          _window.valid(entry) &&
          preparation == entry.preparation &&
          identical(entry.player, target);
      if (!current()) {
        if (entry.preparation == preparation) entry.preparing = null;
        return;
      }
      entry.errors = target.stream.error.listen((message) {
        if (message.trim().isNotEmpty && _window.owns(entry)) {
          entry.failed = true;
        }
      });
      try {
        await target.pause();
        await _limitCache(target, true);
        if (!current()) return;
        if (rewind) {
          if (resetVideo != null) {
            await resetVideo!(
              target,
              Duration.zero,
            ).timeout(const Duration(seconds: 5));
          } else {
            await target.seek(Duration.zero);
          }
        } else {
          await _configure(target, entry.plan);
          if (!current()) return;
          // 候选集静音解码并继续播放，使切换时交接真实动态图像，而非空纹理。
          await target.setVolume(0);
          await target.open(
            Media(entry.plan.url, httpHeaders: entry.plan.headers),
            play: true,
          );
          if (!current()) return;
          if (prepareVideo != null) {
            await Future.any<void>([
              prepareVideo!(target),
              outputCancelled.future,
            ]).timeout(const Duration(seconds: 5));
          }
        }
        if (!current()) return;
        entry.ready = true;
        entry.frameRetained = true;
      } catch (error) {
        if (_window.owns(entry) && entry.preparation == preparation) {
          entry.outputUnavailable = true;
          // 网络/Surface 暂时超时只放弃该集预开，不能把整个会话降成单播放器。
          // 真正初始化失败仍按原策略缩减资源，避免反复创建解码器。
          if (error is! TimeoutException) {
            _maxPlayers = _maxPlayers > 2 ? 2 : 1;
          }
          DiaryService.add(
            '[Play] 邻集输出未就绪 index=${entry.index} '
            'reason=${error is TimeoutException ? 'timeout' : 'output_error'} '
            'players=$_maxPlayers',
          );
          _detachEntryPlayer(entry);
          _trimPlayers();
        }
      } finally {
        if (entry.preparation == preparation) entry.preparing = null;
        if (entry.failed && _window.owns(entry)) _window.evict(entry);
        _notify();
      }
    });
    _notify();
  }

  void _detachEntryPlayer(PlaybackEpisodeEntry entry) {
    final target = entry.player;
    entry.preparation++;
    entry.preparing = null;
    if (entry.outputCancelled?.isCompleted == false) {
      entry.outputCancelled!.complete();
    }
    entry.player = null;
    entry.ready = false;
    entry.frameRetained = false;
    unawaited(entry.errors?.cancel());
    entry.errors = null;
    if (target != null && !identical(target, player)) {
      unawaited(_slot(target, target.stop));
    }
  }

  void _retireEntry(PlaybackEpisodeEntry entry) {
    final target = entry.player;
    entry.player = null;
    unawaited(entry.errors?.cancel());
    if (target != null && !identical(target, player)) {
      unawaited(
        _slot(target, () async {
          try {
            await target.stop();
          } finally {
            await _release(entry.plan.session);
          }
        }),
      );
    } else {
      unawaited(_release(entry.plan.session));
    }
  }

  void _dropStandby() {
    _window.clear();
    _prefetchIndex = null;
  }

  void _disposeNeighbourPlayers() {
    _dropStandby();
    for (final target in _pool.toList()) {
      if (identical(target, player) || !_retiring.add(target)) continue;
      unawaited(
        _slot(target, () async {
          try {
            await target.dispose();
          } finally {
            _pool.remove(target);
            _retiring.remove(target);
            _slotOperations.remove(target);
            await disposeVideo?.call(target);
          }
        }),
      );
    }
  }

  void _trimPlayers() {
    var count = _pool.length - _retiring.length;
    for (final target in _pool.toList().reversed) {
      if (count <= _maxPlayers) break;
      if (identical(target, player) || _retiring.contains(target)) continue;
      for (final entry in _window.entries) {
        if (identical(entry.player, target)) _detachEntryPlayer(entry);
      }
      _retiring.add(target);
      count--;
      unawaited(
        _slot(target, () async {
          try {
            await target.dispose();
          } finally {
            _pool.remove(target);
            _retiring.remove(target);
            _slotOperations.remove(target);
            await disposeVideo?.call(target);
          }
        }),
      );
    }
  }

  void memoryPressure() {
    if (_closed) return;
    _maxPlayers = _maxPlayers > 1 ? 2 : 1;
    _memoryCooldown = DateTime.now().add(const Duration(minutes: 1));
    _preloader.clear();
    _disposeNeighbourPlayers();
    _notify();
  }

  Future<void> _limitCache(Player target, bool limited) async {
    final platform = target.platform;
    if (platform is! NativePlayer) return;
    await platform.setProperty(
      'demuxer-max-bytes',
      '${(limited ? 4 : 32) * 1024 * 1024}',
    );
    await platform.setProperty('demuxer-max-back-bytes', '0');
    await platform.setProperty('cache-on-disk', 'no');
  }

  void start(int index, {double position = 0}) {
    if (!_usable) return;
    _cancelInterruptionResume();
    _sleepStopped = false;
    final wasEngaged = _engaged;
    _engaged = true;
    if (index != _index ||
        (position - _openedAt).abs() > .5 ||
        _error != null) {
      // 未开始播放的预开集不是观看记录。切到别集时，不能把它的起始位置
      // 当作旧集进度存档（play 会在停止旧播放器前调用 saveProgress）。
      if (!wasEngaged) _openedIndex = -1;
      unawaited(play(index, position: position));
      return;
    }
    _playIntent = true;
    if (!wasEngaged) unawaited(_limitCache(player, false));
    if (ready) unawaited(_resumePlayer(player));
  }

  /// 原生 play 可能异步完成；完成时再次尊重定时停止、后台及用户暂停意图。
  Future<void> _resumePlayer(Player target) async {
    final request = _playRequest;
    final generation = _generation;
    final pauseBarrier = _handoffPause;
    try {
      if (pauseBarrier != null) await pauseBarrier;
    } catch (_) {
      return; // 本次停声失败不能启动，但新的显式请求可重新建立屏障。
    }
    if (!_usable ||
        request != _playRequest ||
        generation != _generation ||
        (_handoffPause != null && !identical(_handoffPause, pauseBarrier)) ||
        _openedIndex != _index ||
        !_foreground ||
        _episodeGesture ||
        _waitingNextRequest != null ||
        !_playIntent ||
        !identical(target, player)) {
      return;
    }
    await target.play();
    if (_usable &&
        identical(target, player) &&
        (!_foreground || !_playIntent || _episodeGesture || waitingForNext)) {
      await target.pause();
    }
  }

  Future<void> retry() =>
      play(_index, position: currentPosition, playWhenReady: true);

  /// 显式从本集开头重试，仍走正常取流、权限和最新播放意图检查。
  Future<void> retryFromStart() => play(_index);

  Future<void> switchOnline() {
    _online = true;
    return retry();
  }

  Future<bool> next() async {
    if (!hasNext) return false;
    await play(_index + 1);
    return true;
  }

  Future<bool> previous() async {
    if (!hasPrevious) return false;
    await play(_index - 1);
    return true;
  }

  void _cancelPauseTimers() {
    _pauseTimer?.cancel();
    _standbyIdleTimer?.cancel();
  }

  void _schedulePauseCleanup() {
    _cancelPauseTimers();
    _pauseTimer = Timer(const Duration(seconds: 5), () {
      if (!_closed && !_playIntent) _longPause = true;
    });
    _standbyIdleTimer = Timer(const Duration(minutes: 1), () {
      if (!_usable || _playIntent) return;
      // 暂停后的缓冲回报仍会触发 _syncPreload；回收后要阻止它重新预开。
      _standbySuspended = true;
      _preloader.clear();
      _disposeNeighbourPlayers();
    });
  }

  void _cancelProgressWatchdogs() {
    _interactionRevision++;
    _resumeWatchdog?.cancel();
    _seekWatchdog?.cancel();
  }

  bool _watchCurrent(int generation, int interaction) =>
      _current(generation) &&
      interaction == _interactionRevision &&
      _foreground &&
      _playIntent &&
      !_sleepStopped &&
      ready &&
      (_sleepAt == null || DateTime.now().isBefore(_sleepAt!)) &&
      store.allowsSource(detail.drama.source);

  void _watchResume() {
    _cancelProgressWatchdogs();
    final generation = _generation;
    final interaction = _interactionRevision;
    final position = player.state.position;
    _resumeWatchdog = Timer(const Duration(seconds: 5), () {
      if (!_watchCurrent(generation, interaction) ||
          player.state.position >
              position + const Duration(milliseconds: 300)) {
        return;
      }
      unawaited(_reopenCurrent(position, generation, interaction));
    });
  }

  void _watchSeek(Duration target) {
    final generation = _generation;
    final interaction = _interactionRevision;
    // 两次采样区分尚未到达目标与已正常前进，避免大跨度 seek 重开正常播放。
    _seekWatchdog = Timer(const Duration(milliseconds: 2500), () {
      if (!_watchCurrent(generation, interaction)) return;
      final settled = player.state.position;
      _seekWatchdog = Timer(const Duration(milliseconds: 2500), () {
        if (!_watchCurrent(generation, interaction)) return;
        final position = player.state.position;
        if ((position - target).abs() <= const Duration(seconds: 2) ||
            position > settled + const Duration(milliseconds: 800)) {
          return;
        }
        unawaited(_reopenCurrent(target, generation, interaction));
      });
    });
  }

  Future<void> _reopenCurrent(
    Duration position,
    int generation,
    int interaction,
  ) async {
    final plan = _plan;
    final target = player;
    if (_reopening ||
        !_watchCurrent(generation, interaction) ||
        plan == null ||
        plan.local ||
        plan.url.isEmpty) {
      return;
    }
    _reopening = true;
    var failed = false;
    var completed = false;
    bool current() =>
        _watchCurrent(generation, interaction) &&
        identical(plan, _plan) &&
        identical(target, player);
    try {
      await _serialize(() async {
        if (!current()) return;
        _resumeWatchdog?.cancel();
        _seekWatchdog?.cancel();
        _errorTimer?.cancel();
        _pendingError = false;
        _acceptErrors = false;
        _health.reset();
        _preloader.clear();
        _dropStandby();
        _videoDiagnostics.reset();
        _completionHandled = false;
        _staleAudio = false;
        DiaryService.trace(() => '[Play] 进度恢复：重新打开当前线路');
        // 原生错误/完成通过事件流回报，不一定让 open Future 失败。
        // 此窗口内先暂存，离开队列后再交给正常恢复/续播，避免递归争用队列。
        final errors = target.stream.error.listen((error) {
          if (current() && error.trim().isNotEmpty) failed = true;
        });
        final completions = target.stream.completed.listen((value) {
          if (current() && value) completed = true;
        });
        try {
          await target.open(
            Media(
              plan.url,
              httpHeaders: plan.headers,
              start: position > Duration.zero ? position : null,
            ),
            play: true,
          );
          // open 期间可能暂停、切用户、切集或交接。只让新意图的现场决定继续播放。
          if (!_handedOff &&
              (!_current(generation) ||
                  !_foreground ||
                  !_playIntent ||
                  _sleepStopped ||
                  !store.allowsSource(detail.drama.source))) {
            await target.pause();
          }
          if (!current()) return;
          _resumePosition = position.inMilliseconds / 1000;
          _openedAt = _resumePosition;
          _openedIndex = _index;
          await _setRate(_rate);
          if (current()) _syncDanmaku();
        } catch (_) {
          failed = current();
        } finally {
          await errors.cancel();
          await completions.cancel();
          if (!_closed && generation == _generation && identical(plan, _plan)) {
            _acceptErrors = true;
            _health.reset();
          }
        }
      });
    } finally {
      _reopening = false;
    }
    // 不在串行队列内递归调用 play；失败才使用原有有界换线/刷新流程。
    if (current()) {
      if (completed && target.state.completed) {
        _completed(true);
      } else if (failed) {
        _queueRecovery('progress_reopen_failed');
      }
    }
  }

  void togglePlayback() {
    _setPlayback(
      (_advancingSeason ||
              _loading ||
              _reopening ||
              _episodeGesture ||
              _waitingNextRequest != null)
          ? paused
          : !player.state.playing,
    );
  }

  void _setPlayback(bool playIntent, {bool interrupted = false}) {
    if (!_usable) return;
    if (!interrupted) _cancelInterruptionResume();
    if (_advancingSeason ||
        _loading ||
        _reopening ||
        _episodeGesture ||
        _waitingNextRequest != null) {
      // 加载时只记录最新意图；不能播放仍停留在上一集的播放器。
      _playIntent = playIntent;
      if (playIntent) {
        _sleepStopped = false;
        _cancelPauseTimers();
        _standbySuspended = false;
        _longPause = false;
        _health.reset();
      } else {
        _cancelProgressWatchdogs();
        _schedulePauseCleanup();
        unawaited(player.pause().catchError((Object _) {}));
      }
      _notify();
      return;
    }
    if (!ready) return;
    endBoost();
    _sleepStopped = false;
    _playIntent = playIntent;
    _health.reset();
    if (_playIntent) {
      final longPause = _longPause;
      _cancelPauseTimers();
      _standbySuspended = false;
      _longPause = false;
      if (longPause && !local) _watchResume();
    } else {
      _cancelProgressWatchdogs();
      _schedulePauseCleanup();
    }
    if (_playIntent && player.state.completed) {
      unawaited(play(_index));
      return;
    }
    if (_playIntent && _staleAudio) {
      _staleAudio = false;
      final target = player;
      unawaited(
        target
            .seek(target.state.position)
            .then((_) => _resumePlayer(target))
            .catchError((Object _) {}),
      );
    } else if (_playIntent) {
      unawaited(_resumePlayer(player));
    } else {
      unawaited(player.pause());
    }
    if (!_playIntent) unawaited(saveProgress());
    _syncDanmaku();
    _syncMedia();
    _syncPreload();
  }

  Future<bool> seekTo(Duration target) async {
    if (!_usable || !ready) return false;
    _cancelProgressWatchdogs();
    final ticket = ++_seekSequence;
    final generation = _generation;
    danmaku.beginSeek();
    var succeeded = false;
    try {
      final targetPlayer = player;
      await _serialize(() async {
        if (!_current(generation) ||
            ticket != _seekSequence ||
            !identical(targetPlayer, player)) {
          return;
        }
        await targetPlayer.seek(target);
        succeeded = true;
      });
    } catch (_) {
    } finally {
      if (!_closed && ticket == _seekSequence && generation == _generation) {
        danmaku.endSeek(succeeded ? target : player.state.position);
      }
    }
    if (succeeded && generation == _generation && ticket == _seekSequence) {
      _watchSeek(target);
    }
    return succeeded;
  }

  Duration? seekBy(int seconds) {
    final duration = player.state.duration;
    if (!ready || duration <= Duration.zero) return null;
    final target = Duration(
      milliseconds: (player.state.position.inMilliseconds + seconds * 1000)
          .clamp(0, duration.inMilliseconds),
    );
    unawaited(seekTo(target));
    return target;
  }

  Future<void> _setRate(double value) {
    _rates = _rates
        .catchError((Object _) {})
        .then((_) => player.setRate(value));
    return _rates.catchError((Object _) {});
  }

  void beginBoost() {
    if (_screenLocked || !ready || _boostTimer != null || _boosting) return;
    _boostTimer = Timer(const Duration(milliseconds: 350), () {
      _boostTimer = null;
      if (_closed ||
          !ready ||
          !player.state.playing ||
          player.state.completed) {
        return;
      }
      _boosting = true;
      unawaited(_setRate(2));
      _notify();
    });
  }

  void holdBoost() {
    if (_screenLocked || !_usable || _boosting) return;
    _boostTimer?.cancel();
    _boostTimer = null;
    _boosting = true;
    unawaited(_setRate(2));
    _notify();
  }

  void setBoostLocked(bool locked) {
    if (_boostLocked == locked || _screenLocked && locked) return;
    if (locked) {
      holdBoost();
      _boostLocked = true;
      _notify();
    } else {
      _boostLocked = false;
      endBoost();
      _notify();
    }
  }

  bool endBoost() {
    if (_boostLocked) return false;
    final boosted = _boosting;
    _boostTimer?.cancel();
    _boostTimer = null;
    _boosting = false;
    if (boosted) {
      unawaited(_setRate(_speed));
      _notify();
    }
    return boosted;
  }

  void setVolume(double value) {
    final volume = value.clamp(0.0, 100.0);
    if (volume > 0) {
      _unmutedVolume = volume;
      _volumeTimer?.cancel();
      _volumeTimer = Timer(const Duration(milliseconds: 500), _saveVolume);
    }
    _applyVolume(volume);
  }

  void _saveVolume() {
    _volumeTimer = null;
    unawaited(store.setPlayerVolume(_unmutedVolume).catchError((Object _) {}));
  }

  void _applyVolume(double volume) {
    if (!player.state.playing) _staleAudio = true;
    unawaited(player.setVolume(volume));
  }

  double changeVolume(double delta) {
    final volume = (player.state.volume + delta).clamp(0.0, 100.0);
    setVolume(volume);
    return volume;
  }

  double toggleMute() {
    final current = player.state.volume;
    if (current > 0) _unmutedVolume = current;
    final target = current > 0 ? 0.0 : _unmutedVolume;
    _applyVolume(target);
    return target;
  }

  Future<void> _savePreferences(PlaybackPreferences preferences) async {
    if (!_usable) throw StateError('当前用户已变更');
    await store.setPlaybackPreferences(preferences);
    if (!_usable) throw StateError('当前用户已变更');
  }

  Future<void> setSpeed(double value) async {
    if (value == _speed) return;
    await _savePreferences(_preferences.copyWith(speed: value));
    _speed = value;
    _notify();
    if (!_boosting) await _setRate(value);
  }

  Future<void> setQuality(int value) async {
    if (value == _quality) return;
    await _savePreferences(_preferences.copyWith(quality: value));
    _quality = value;
    _preloader.clear();
    _notify();
    if (_plan?.local == true) return;
    await play(
      _index,
      position: currentPosition,
      playWhenReady: _error != null || player.state.playing,
    );
  }

  Future<void> toggleDanmaku() async {
    if (!danmakuSupported) return;
    final enabled = !_danmakuEnabled;
    await _savePreferences(_preferences.copyWith(danmaku: enabled));
    _danmakuEnabled = enabled;
    danmaku.setEnabled(enabled);
    _syncDanmaku();
    _notify();
  }

  Future<void> setDanmakuScale(double value) async {
    final scale = value.clamp(danmakuScaleMin, danmakuScaleMax);
    await _savePreferences(_preferences.copyWith(danmakuScale: scale));
    _notify();
  }

  Future<void> setDanmakuColor(int value) async {
    await _savePreferences(_preferences.copyWith(danmakuColor: value));
    _notify();
  }

  Future<void> setDanmakuOpacity(double value) async {
    final opacity = value.clamp(.1, 1.0);
    await _savePreferences(_preferences.copyWith(danmakuOpacity: opacity));
    _notify();
  }

  Future<void> setDanmakuBold(bool value) async {
    await _savePreferences(_preferences.copyWith(danmakuBold: value));
    _notify();
  }

  Future<void> setDanmakuStroke(double value) async {
    final stroke = value.clamp(danmakuStrokeMin, danmakuStrokeMax);
    await _savePreferences(_preferences.copyWith(danmakuStroke: stroke));
    _notify();
  }

  Future<void> setDanmakuShadow(double value) async {
    final shadow = value.clamp(danmakuShadowMin, danmakuShadowMax);
    await _savePreferences(_preferences.copyWith(danmakuShadow: shadow));
    _notify();
  }

  Future<void> setDanmakuCoverage(DanmakuCoverage value) async {
    await _savePreferences(_preferences.copyWith(danmakuCoverage: value));
    _notify();
  }

  Future<void> setDanmakuWords(List<String> words) async {
    final normalized = normalizeDanmakuWords(words);
    await _savePreferences(_preferences.copyWith(danmakuWords: normalized));
    _notify();
  }

  void setForeground(bool visible) {
    if (_closed || _handedOff) return;
    final foreground = visible || _backgroundPlayback;
    if (_visible == visible && _foreground == foreground) return;
    DiaryService.trace(
      () => visible
          ? '[Play] 应用回到前台'
          : foreground
          ? '[Play] 应用不可见，后台继续播放'
          : '[Play] 应用不可见，暂停播放',
    );
    final hidVideo = !_visible && _foreground;
    final interruptedSwitch = waitingForNext || _episodeGesture;
    _visible = visible;
    if (!visible) {
      _preloader.clear();
      _playRequest++;
      _waitingNextRequest = null;
      _episodeGesture = false;
      _disposeNeighbourPlayers();
    }
    final hideVideo = !visible && foreground;
    if (Platform.isIOS && hideVideo != hidVideo) {
      for (final target in _pool) {
        final platform = target.platform;
        if (platform is NativePlayer) {
          unawaited(
            platform
                .setProperty('vid', hideVideo ? 'no' : 'auto')
                .catchError((Object _) {}),
          );
        }
      }
    }
    // 平台挂起期间 Timer 可能延迟，恢复可见时按原截止时间补做停止。
    if (visible && _sleepAt != null && !DateTime.now().isBefore(_sleepAt!)) {
      _stopForSleep();
    }
    if (_foreground == foreground) {
      // 后台听音时播放许可不变，但要立即停止弹幕；回到画面时按当前位置恢复。
      _syncDanmaku();
      _syncPreload();
      if (!visible && foreground && interruptedSwitch && ready) {
        unawaited(_resumePlayer(player));
      }
      return;
    }
    _foreground = foreground;
    _health.reset();
    _sync();
    if (!foreground) {
      _cancelInterruptionResume();
      _cancelProgressWatchdogs();
      _schedulePauseCleanup();
      _preloader.clear();
      _dropStandby();
      endBoost();
      _playIntent = false;
      unawaited(player.pause());
      unawaited(saveProgress());
    } else if (_pendingError) {
      _queueRecovery('foreground_pending_error');
    }
  }

  /// 保存观看进度。
  ///
  /// [quiet] 供播放中每 5 秒一次的定时保存使用：写入照旧，但列表内容没有
  /// 实质变化时不通知监听者，避免被遮挡的页面跟着整棵重建。
  Future<void> saveProgress({bool quiet = false}) async {
    if (!_engaged || _openedIndex < 0 || store.profileEpoch != _epoch) return;
    final position = player.state.position.inMilliseconds / 1000;
    final duration = player.state.duration.inMilliseconds / 1000;
    await _progressWriter.save(
      detail: detail,
      openedIndex: _openedIndex,
      position: position,
      duration: duration,
      quiet: quiet,
    );
  }

  @override
  void dispose() {
    _fullscreenSwitchFrame = null;
    setLocked(false);
    unawaited(saveProgress());
    _clearSleep();
    _cancelProgressWatchdogs();
    _cancelPauseTimers();
    _closed = true;
    // 输出准备可能仍在等待首帧，退出时声音不能等待备用通道排空。
    if (!_disownPlayer) unawaited(player.pause().catchError((Object _) {}));
    MediaControls.instance.release(this);
    _videoDiagnostics.dispose();
    _generation++;
    store.removeListener(_accessChanged);
    store.removeListener(_syncBlockedWords);
    _saveTimer?.cancel();
    _healthTimer?.cancel();
    _errorTimer?.cancel();
    _boostTimer?.cancel();
    _stallTimer?.cancel();
    _volumeTimer?.cancel();
    if (_volumeTimer != null) _saveVolume();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    danmaku.dispose();
    _preloader.dispose();
    final session = _plan?.session ?? '';
    unawaited(_release(session));
    _disposeNeighbourPlayers();
    unawaited(_loader.close().catchError((Object _) {}));
    unawaited(
      _operations.catchError((Object _) {}).then((_) async {
        await _rates.catchError((Object _) {});
        if (!_disownPlayer) {
          await player.dispose();
          await disposeVideo?.call(player);
          _pool.remove(player);
        }
        await Future.wait(_slotOperations.values.toList());
      }),
    );
    super.dispose();
  }
}

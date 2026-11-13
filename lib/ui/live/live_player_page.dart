import 'live_playback_controls.dart';
import 'live_screen_lock.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_device.dart';
import '../../live_bilibili.dart';
import '../../live_feed.dart';
import '../../live_player_policy.dart';
import '../../picture_in_picture.dart';
import '../app_scope.dart';
import '../player/mini_player.dart' show playerVisible;
import '../player/player_stats_label.dart';
import '../player/window_fullscreen.dart';
import '../../local_store.dart';
import 'live_favorite_button.dart';
import 'live_player_gestures.dart';
import '../widgets/glass/glass_dialog.dart';

/// 直播不 seek，也不强制 seekable；切换清晰度重新解析并打开直播地址。
class LivePlayerPage extends StatefulWidget {
  const LivePlayerPage({
    super.key,
    required this.platform,
    required this.room,
    required this.store,
    this.defaultQuality = 0,
  });

  final LivePlatform platform;
  final LiveRoom room;
  final int defaultQuality;
  final LocalStore store;

  @override
  State<LivePlayerPage> createState() => _LivePlayerPageState();
}

class _LivePlayerPageState extends State<LivePlayerPage>
    with WidgetsBindingObserver {
  final _player = Player();
  late final VideoController _video;
  final _pip = PictureInPicture.instance;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Future<void> _playerTail = Future<void>.value();
  Future<void> _displayTail = Future<void>.value();
  Future<void>? _miniTask;
  LiveStream? _stream;
  FormFactor _form = FormFactor.phone;
  ModalRoute<dynamic>? _route;
  int? _width;
  int? _height;
  int _requestedQuality = 10000;
  int _generation = 0;
  Timer? _renewTimer;

  /// 隐藏期间被跳过的续期：回到可见时立刻补一次，避免用过期地址恢复播放。
  bool _renewPending = false;
  Timer? _controlsTimer;
  bool _controlsVisible = true;
  String _requestedLine = '';
  String _error = '';
  bool _loading = true;
  bool _opening = false;
  bool _buffering = false;
  bool _disposed = false;
  bool _full = false;
  bool _screenLocked = false;
  bool _displayBusy = false;
  bool _choosing = false;
  bool _resume = false;
  bool _playOnOpen = true;
  bool _hidden = false;
  bool _shown = false;
  late final int _historyEpoch;
  bool _historyRecorded = false;
  bool _historyReady = false;
  bool _historyFirstFrame = false;

  @override
  void initState() {
    super.initState();
    _historyEpoch = widget.store.profileEpoch;
    // 先挂接视频输出再允许 open，避免快速取流时先启动音频、后创建纹理。
    _video = VideoController(_player);
    unawaited(
      _video.waitUntilFirstFrameRendered
          .then((_) {
            if (_disposed) return;
            _historyFirstFrame = true;
            _recordHistoryIfReady();
          })
          .catchError((Object _) {
            // 输出失败不能记为成功观看，也不影响播放器本身的错误处理。
          }),
    );
    _requestedQuality = widget.defaultQuality;
    WidgetsBinding.instance.addObserver(this);
    _pip.addListener(_pipChanged);
    _pip.onAction = _action;
    _subscriptions.add(
      _player.stream.buffering.listen((value) {
        if (_disposed) return;
        setState(() => _buffering = value);
        _recordHistoryIfReady();
      }),
    );
    _subscriptions.add(
      _player.stream.playing.listen((playing) {
        if (_disposed) return;
        setState(() {
          // open 完成不等于播放成功；真正播放时再清除旧错误。
          if (playing) _error = '';
        });
        _syncPip();
        _recordHistoryIfReady();
      }),
    );
    _subscriptions.add(
      _player.stream.width.listen((value) {
        if (_disposed || value == null || value <= 0) return;
        setState(() => _width = value);
        _dimensionsChanged();
      }),
    );
    _subscriptions.add(
      _player.stream.height.listen((value) {
        if (_disposed || value == null || value <= 0) return;
        setState(() => _height = value);
        _dimensionsChanged();
      }),
    );
    _subscriptions.add(
      _player.stream.error.listen((message) {
        if (_disposed) return;
        final error = livePlaybackError(message);
        if (error.isNotEmpty) setState(() => _error = error);
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((_) => _recordHistoryIfReady()),
    );
    unawaited(_open());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    // PiP 的小窗口尺寸不能反过来改变应用的自动 formFactor。
    if (!_full && !_pip.shown && !_pip.leaving) {
      _form = AppScope.formFactorOf(context);
    } else {
      _form = AppScope.of(context).formFactor ?? _form;
    }
    _syncPip();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncVisibility();
    if (state == AppLifecycleState.resumed) _queueDisplay();
  }

  void _syncVisibility() {
    if (_disposed) return;
    final hidden = !playerVisible(WidgetsBinding.instance.lifecycleState);
    if (hidden == _hidden) return;
    _hidden = hidden;
    if (hidden) {
      _resume = _player.state.playing || (_loading && _playOnOpen);
      unawaited(_command(() => _player.pause()));
    } else {
      final resume = _resume;
      _resume = false;
      if (_renewPending) {
        // 隐藏期间跳过的续期在这里补上：过期的地址没法直接恢复播放。
        _renewPending = false;
        unawaited(_open(renew: true, resume: resume));
      } else if (resume) {
        unawaited(_command(() => _player.play()));
      }
    }
  }

  /// 所有播放器命令串行；销毁只能在已开始的 open/操作之后执行。
  Future<void> _command(Future<void> Function() operation) {
    final task = _playerTail.then((_) async {
      if (!_disposed) await operation();
    });
    _playerTail = task.catchError((Object failure) {
      final error = livePlaybackError(liveErrorText(failure));
      if (!_disposed && error.isNotEmpty) setState(() => _error = error);
    });
    return _playerTail;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _renewTimer?.cancel();
    _controlsTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _pip.removeListener(_pipChanged);
    if (_pip.onAction == _action) {
      _pip.onAction = null;
      _pip.clear();
    }
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(
      _playerTail.then((_) => _player.dispose()).catchError((Object _) {}),
    );
    // 进入 mini 与销毁可能交错，等进入结束再退出，避免窗口遗留。
    unawaited(_cleanupDisplay().catchError((Object _) {}));
    super.dispose();
  }

  Future<void> _cleanupDisplay() async {
    await _miniTask;
    if (_pip.window) await _pip.exit();
    await _displayTail;
    if (desktopPlatform && _full) await setWindowFullScreen(false);
    await _restoreAppDisplay();
  }

  Future<void> _open({
    int? quality,
    String? line,
    bool renew = false,
    bool? resume,
  }) async {
    if (_disposed || _opening) return;
    _opening = true;
    _historyReady = false;
    _renewTimer?.cancel();
    // 隐藏期间跳过的续期在恢复时同样要接着播，因此允许调用方指定播放意图。
    _renewPending = false;
    _playOnOpen =
        resume ?? (!renew || _player.state.playing || (_hidden && _resume));
    final generation = ++_generation;
    _requestedQuality = quality ?? _requestedQuality;
    _requestedLine = line ?? _requestedLine;
    setState(() {
      _loading = true;
      _error = '';
      _width = null;
      _height = null;
    });
    try {
      final stream = await widget.platform
          .resolveLine(
            widget.room,
            quality: _requestedQuality,
            line: _requestedLine,
          )
          .timeout(const Duration(seconds: 25));
      if (_disposed || generation != _generation) return;
      // 解析只允许一个在途请求，且 open 与 dispose 串行。
      var opened = false;
      await _command(() async {
        await _player.open(
          Media(stream.url, httpHeaders: stream.headers),
          play: !_hidden && _playOnOpen,
        );
        opened = true;
      });
      if (_disposed || generation != _generation || !opened) return;
      _historyReady = true;
      setState(() {
        _stream = stream;
        _requestedLine = stream.lineId;
        _width = _player.state.width ?? _width;
        _height = _player.state.height ?? _height;
      });
      if (_hidden) _resume = _playOnOpen;
      if (stream.renewAfter case final interval?) {
        _renewTimer = Timer(interval, () {
          if (_disposed || generation != _generation) return;
          // 不可见时让路：暂停中的直播没人看，不必每分钟再取一次地址；
          // 回到可见时由 _syncVisibility 立刻补一次。
          if (_hidden) {
            _renewPending = true;
            return;
          }
          unawaited(_open(renew: true));
        });
      }
    } catch (failure) {
      if (_disposed || generation != _generation) return;
      final error = livePlaybackError(liveErrorText(failure));
      if (error.isNotEmpty) setState(() => _error = error);
    } finally {
      if (!_disposed && generation == _generation) {
        setState(() {
          _loading = false;
          _opening = false;
        });
        _syncPip();
        _syncVisibility();
        _recordHistoryIfReady();
        if (_full) _queueDisplay();
      }
    }
  }

  void _toggle() {
    if (_disposed || _loading || _screenLocked) return;
    unawaited(_command(() => _player.playOrPause()));
  }

  void _toggleControls() {
    if (!_full || _screenLocked) return;
    _controlsTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
    _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (!_full || !_controlsVisible || _choosing || _screenLocked) return;
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _full && !_choosing) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleScreenLock() {
    if (!_full ||
        _pip.shown ||
        _pip.leaving ||
        _displayBusy ||
        _miniTask != null) {
      return;
    }
    _controlsTimer?.cancel();
    setState(() {
      _screenLocked = !_screenLocked;
      _controlsVisible = !_screenLocked;
    });
    if (!_screenLocked) _scheduleControlsHide();
  }

  Future<void> _chooseLine() async {
    final stream = _stream;
    if (_screenLocked ||
        _choosing ||
        _loading ||
        stream == null ||
        stream.lines.length < 2) {
      return;
    }
    _choosing = true;
    _controlsTimer?.cancel();
    try {
      final selected = await showGlassDialog<String>(
        context,
        builder: (context) => GlassDialogBody(
          title: '播放线路',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in stream.lines)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  onTap: () => Navigator.pop(context, item.id),
                  title: Row(
                    children: [
                      Expanded(child: Text(item.label)),
                      if (item.id == stream.lineId)
                        const Icon(Icons.check_rounded),
                    ],
                  ),
                ),
            ],
          ),
          actions: const [],
        ),
      );
      if (!_disposed &&
          selected != null &&
          (selected != stream.lineId || _error.isNotEmpty)) {
        await _open(line: selected, renew: true);
      }
    } finally {
      _choosing = false;
      if (!_disposed) _scheduleControlsHide();
    }
  }

  void _action(String action) {
    if (action == 'toggle') _toggle();
  }

  void _dimensionsChanged() {
    _recordHistoryIfReady();
    _syncPip();
    if (_full && !_loading) _queueDisplay();
  }

  // 首帧真正绘制后还须本次 open 成功、有效尺寸与 playing 确认。
  // 非缓冲且播放时钟前进。一个页面会话只记一次，切线路/续签不反复写盘。
  void _recordHistoryIfReady() {
    if (_disposed ||
        _historyRecorded ||
        !_historyReady ||
        !_historyFirstFrame ||
        _opening ||
        widget.store.locked ||
        widget.store.profileEpoch != _historyEpoch ||
        _error.isNotEmpty ||
        _buffering ||
        !_player.state.playing ||
        (_width ?? 0) <= 0 ||
        (_height ?? 0) <= 0 ||
        _player.state.position <= Duration.zero) {
      return;
    }
    _historyRecorded = true;
    unawaited(
      widget.store
          .recordLiveWatch(
            widget.platform.id,
            widget.room,
            profileEpoch: _historyEpoch,
          )
          .catchError((Object _) {
            // 历史保存失败不改变播放状态，也不通过重试/续签制造写入循环。
          }),
    );
  }

  void _syncPip() {
    if (_disposed) return;
    final shape = liveVideoShape(_width, _height);
    final ratio = shape == null ? 16 / 9 : _width! / _height!;
    _pip.update(
      aspectRatio: ratio,
      playing: _player.state.playing,
      hasPrevious: false,
      hasNext: false,
      // 直播显式进入 PiP；不继承点播页留下的自动进入设置。
      autoEnter: false,
    );
    if (shape != null) _pip.resize(ratio);
  }

  void _pipChanged() {
    if (_disposed) return;
    if (_pip.shown && !_shown) {
      final route = _route;
      if (route != null && !route.isCurrent) {
        Navigator.of(context).popUntil((other) => other == route);
      }
    }
    _shown = _pip.shown;
    _syncVisibility();
    // Android pending/active/leaving 期间绝不恢复方向，避免打断 PiP。
    if (!_pip.shown && !_pip.leaving) _queueDisplay();
    setState(() {});
    _syncPip();
  }

  Future<void> _enterMini() async {
    if (_disposed ||
        _screenLocked ||
        _miniTask != null ||
        _displayBusy ||
        !_pip.available ||
        _pip.shown ||
        _loading ||
        liveVideoShape(_width, _height) == null) {
      return;
    }
    final task = _doEnterMini(_width! / _height!);
    _miniTask = task;
    setState(() {});
    try {
      await task;
    } finally {
      _miniTask = null;
      if (!_disposed) {
        setState(() {});
        if (!_pip.shown && !_pip.leaving) _queueDisplay();
      }
    }
  }

  Future<void> _doEnterMini(double ratio) async {
    // 等已开始的方向/UI操作完成后才请求 PiP；进入期间的新请求会跳过。
    await _displayTail;
    if (_disposed) return;
    // 桌面先离开本页全屏，防止 mini 恢复时还原到错误窗口状态。
    if (desktopPlatform && _full) {
      _full = false;
      await setWindowFullScreen(false);
    }
    if (_disposed) return;
    await _pip.enter(ratio);
  }

  Future<void> _restoreMini() async {
    if (_miniTask != null || !_pip.window) return;
    final task = _pip.exit().then<void>((_) {});
    _miniTask = task;
    setState(() {});
    try {
      await task;
    } finally {
      _miniTask = null;
      if (!_disposed) {
        setState(() {});
        _queueDisplay();
      }
    }
  }

  Future<void> _restoreAppDisplay() async {
    if (!desktopPlatform) {
      await AppDevice.setPlayerOrientation(switch (_form) {
        FormFactor.phone => PlayerOrientation.lockedPortrait,
        FormFactor.television => PlayerOrientation.lockedLandscape,
        FormFactor.pad || FormFactor.window => PlayerOrientation.auto,
      });
    }
    if (!_disposed && (_pip.shown || _pip.leaving || _miniTask != null)) return;
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    ).catchError((Object _) {});
  }

  Future<void> _queueDisplay() {
    _displayTail = _displayTail
        .then((_) async {
          if (_disposed || _pip.shown || _pip.leaving || _miniTask != null) {
            return;
          }
          if (desktopPlatform) {
            await setWindowFullScreen(_full);
            return;
          }
          final shape = liveVideoShape(_width, _height);
          if (!_full) {
            await _restoreAppDisplay();
          } else if (shape != null) {
            await AppDevice.setPlayerOrientation(
              shape == LiveVideoShape.portrait
                  ? PlayerOrientation.lockedPortrait
                  : PlayerOrientation.lockedLandscape,
            );
            // 原生方向请求等待期间也可能开始 PiP，此时不再切换系统 UI。
            if (_disposed || _pip.shown || _pip.leaving) return;
            await SystemChrome.setEnabledSystemUIMode(
              SystemUiMode.immersiveSticky,
            );
          }
        })
        .catchError((Object _) {});
    return _displayTail;
  }

  Future<void> _toggleFull() async {
    if (_screenLocked ||
        _displayBusy ||
        _miniTask != null ||
        _pip.shown ||
        (!_full && (_loading || liveVideoShape(_width, _height) == null))) {
      return;
    }
    setState(() {
      _full = !_full;
      _screenLocked = false;
      _controlsVisible = !_full;
      _controlsTimer?.cancel();
      _displayBusy = true;
    });
    try {
      await _queueDisplay();
    } finally {
      if (!_disposed) setState(() => _displayBusy = false);
    }
  }

  Future<void> _back() async {
    if (_disposed || _screenLocked || _displayBusy || _miniTask != null) return;
    if ((_pip.shown && !_pip.window) || _pip.leaving) return;
    if (_pip.window) {
      await _restoreMini();
    } else if (_full) {
      await _toggleFull();
    } else {
      await Navigator.maybePop(context);
    }
  }

  Future<void> _chooseQuality() async {
    if (_screenLocked ||
        _choosing ||
        _loading ||
        _stream == null ||
        _miniTask != null) {
      return;
    }
    _choosing = true;
    _controlsTimer?.cancel();
    final stream = _stream!;
    try {
      final quality = await showGlassDialog<int>(
        context,
        builder: (context) => GlassDialogBody(
          title: '清晰度',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in stream.qualities)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  onTap: () => Navigator.pop(context, item.id),
                  title: Row(
                    children: [
                      Expanded(child: Text(item.label)),
                      if (item.id == stream.qualityId)
                        const Icon(Icons.check_rounded),
                    ],
                  ),
                ),
            ],
          ),
          actions: const [],
        ),
      );
      if (_disposed || quality == null) return;
      if (quality != stream.qualityId || _error.isNotEmpty) {
        await _open(quality: quality, renew: true);
      }
    } finally {
      _choosing = false;
      if (!_disposed) _scheduleControlsHide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final playing = _player.state.playing;
    final mini = _pip.shown || _pip.leaving;
    return PopScope(
      canPop: !_full && !mini && _miniTask == null && !_displayBusy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          top: !mini && !_full,
          bottom: !mini && !_full,
          child: LiveScreenLock(
            enabled: _full && !mini,
            locked: _screenLocked,
            onToggle: _toggleScreenLock,
            child: Stack(
              fit: StackFit.expand,
              children: [
                LivePlayerGestures(
                  full: _full,
                  mini: _pip.window,
                  controlsVisible: _controlsVisible,
                  onToggleControls: _toggleControls,
                  onTogglePlayback: _toggle,
                  onRestoreMini: () => unawaited(_restoreMini()),
                  onDragMini: () => unawaited(windowManager.startDragging()),
                  onToggleFull: () => unawaited(_toggleFull()),
                  onBack: () => unawaited(_back()),
                  child: Video(
                    controller: _video,
                    controls: NoVideoControls,
                    fill: Colors.black,
                    pauseUponEnteringBackgroundMode: false,
                  ),
                ),
                if (!mini &&
                    !_screenLocked &&
                    (!_full || _controlsVisible)) ...[
                  Positioned(
                    left: 4,
                    right: 12,
                    top: 0,
                    child: _header(context),
                  ),
                  if (!_full &&
                      MediaQuery.orientationOf(context) == Orientation.portrait)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 64,
                      child: Center(
                        child: PlayerStatsLabel(
                          player: _player,
                          store: widget.store,
                          compact: false,
                          clock: false,
                        ),
                      ),
                    ),
                  Positioned(
                    left:
                        8 +
                        (_full ? MediaQuery.viewPaddingOf(context).left : 0),
                    right:
                        8 +
                        (_full ? MediaQuery.viewPaddingOf(context).right : 0),
                    bottom:
                        8 +
                        (_full ? MediaQuery.viewPaddingOf(context).bottom : 0),
                    child: _controls(),
                  ),
                ],
                if (_pip.window)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '还原',
                          onPressed: _miniTask == null
                              ? () => unawaited(_restoreMini())
                              : null,
                          icon: const Icon(
                            Icons.open_in_full_rounded,
                            color: Colors.white,
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭直播',
                          onPressed: _miniTask == null
                              ? () => unawaited(_closeMini())
                              : null,
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_loading || _buffering)
                  const IgnorePointer(
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (!_loading && !playing && _error.isEmpty && !mini)
                  const IgnorePointer(
                    child: Center(
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: 72,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                if (_error.isNotEmpty && !mini) _failure(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _closeMini() async {
    await _restoreMini();
    // 等 PopScope 以还原后的状态重建，否则关闭会被旧的 mini 状态拦截。
    await WidgetsBinding.instance.endOfFrame;
    if (!_disposed && mounted) await Navigator.maybePop(context);
  }

  Widget _controls() {
    final known = liveVideoShape(_width, _height) != null;
    return LivePlaybackControls(
      key: const ValueKey('live-controls-bar'),
      playing: _player.state.playing,
      full: _full,
      quality: _stream?.quality ?? '清晰度',
      onTogglePlayback: _loading ? null : _toggle,
      showLine: (_stream?.lines.length ?? 0) > 1,
      onLine: _loading ? null : () => unawaited(_chooseLine()),
      onQuality: !_loading && (_stream?.qualities.isNotEmpty ?? false)
          ? () => unawaited(_chooseQuality())
          : null,
      showMini: _pip.available,
      onMini: known && !_loading && _miniTask == null && !_displayBusy
          ? () => unawaited(_enterMini())
          : null,
      fullscreenTooltip: _full
          ? '退出全屏'
          : known
          ? '全屏'
          : '等待视频尺寸',
      onFullscreen:
          !_displayBusy && _miniTask == null && (_full || known && !_loading)
          ? () => unawaited(_toggleFull())
          : null,
    );
  }

  Widget _header(BuildContext context) {
    const shadow = [Shadow(color: Color(0x66000000), blurRadius: 2)];
    final room = widget.room;
    return SizedBox(
      height: 56,
      child: Row(
        spacing: 2,
        children: [
          IconButton(
            onPressed: () => unawaited(_back()),
            icon: const Icon(Icons.arrow_back_rounded),
            color: Colors.white,
            tooltip: '返回',
            style: IconButton.styleFrom(fixedSize: const Size.square(48)),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  room.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    shadows: shadow,
                  ),
                ),
                Text(
                  [
                    if (room.anchor.isNotEmpty) room.anchor,
                    if (_stream != null) _stream!.quality,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .78),
                    fontSize: 12,
                    shadows: shadow,
                  ),
                ),
              ],
            ),
          ),
          PlayerStatsLabel(
            player: _player,
            store: widget.store,
            compact: false,
            cacheSpeed:
                _full ||
                MediaQuery.orientationOf(context) != Orientation.portrait,
          ),
          LiveFavoriteButton(
            store: widget.store,
            platformId: widget.platform.id,
            room: widget.room,
            color: Colors.white,
          ),
        ],
      ),
    );
  }

  Widget _failure(BuildContext context) => Center(
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .78),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, color: Colors.white70, size: 36),
          const SizedBox(height: 12),
          Text(
            _error,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 8,
            children: [
              TextButton(
                onPressed: _loading ? null : () => unawaited(_open()),
                child: const Text('重试'),
              ),
              TextButton(
                onPressed: () => unawaited(_back()),
                child: const Text('返回'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

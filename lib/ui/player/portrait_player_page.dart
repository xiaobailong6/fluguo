import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../widgets/app_notice.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../../playback_session.dart';
import '../app_scope.dart';
import '../app_motion.dart';
import '../downloads/download_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/follow_button.dart';
import 'danmaku_overlay.dart';
import 'episode_grid.dart';
import 'mini_player.dart';
import 'playback_sheets.dart';
import 'playback_handle.dart';
import 'player_surface.dart';
import 'playback_seek_controller.dart';
import 'swipe_controls.dart';
import 'player_video.dart';
import 'wide_video_fullscreen_button.dart';

const _maskHeight = 68.0;

String _status(Drama drama) =>
    drama.releaseLabel == '状态未知' ? '' : '${drama.releaseLabel} · ';

class PortraitPlayerPage extends StatefulWidget {
  const PortraitPlayerPage({
    super.key,
    required this.store,
    required this.handle,
    this.onMiniWindow,
    this.onFullscreen,
  });
  final LocalStore store;
  final PlaybackHandle handle;
  final VoidCallback? onMiniWindow;
  final VoidCallback? onFullscreen;

  @override
  State<PortraitPlayerPage> createState() => _PortraitPlayerPageState();
}

class _PortraitPlayerPageState extends State<PortraitPlayerPage>
    with WidgetsBindingObserver {
  late final _pages = PageController(initialPage: _session.index);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Player? _bound;
  Timer? _hintTimer;
  String _hint = '';
  bool _scrolling = false;
  bool _edgeHinted = false;
  bool _holding = false;
  bool _overMask = false;
  int _heldIndex = -1;
  final _seek = PlaybackSeekController();
  int _seekIndex = -1;
  final _pointers = <int, Offset>{};
  double? _pinchFrom;
  double _pinchBase = 1;
  bool _userPausedWhileZoomed = false;
  double _zoom = 1;

  PlaybackSession get _session => widget.handle.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.addListener(_changed);
    _bind();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_changed);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _hintTimer?.cancel();
    _seek.dispose();
    _pages.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _session.setForeground(playerVisible(state));

  void _bind() {
    final player = _session.player;
    if (_seekIndex != _session.index || !identical(player, _bound)) {
      _seekIndex = _session.index;
      _seek.reset();
    }
    if (identical(player, _bound)) return;
    _bound = player;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final stream = player.stream;
    _subscriptions.add(stream.position.listen(_seek.acceptPosition));
    for (final changes in [stream.duration, stream.buffering, stream.playing]) {
      _subscriptions.add(changes.listen((_) => _refresh()));
    }
  }

  void _changed() {
    final index = _session.index;
    if (index != _lastSessionIndex) {
      _lastSessionIndex = index;
      _userPausedWhileZoomed = false;
    }
    _bind();
    if (_holding && _session.index != _heldIndex) _pressEnd();
    if (!_scrolling &&
        _pages.hasClients &&
        _pages.page?.round() != _session.index) {
      _pages.jumpToPage(_session.index);
    }
    _refresh();
  }

  int _lastSessionIndex = -1;

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _say(String text) {
    _hintTimer?.cancel();
    setState(() => _hint = text);
    _hintTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _hint = '');
    });
  }

  bool _scrolled(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final metrics = notification.metrics;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _edgeHinted = false;
      setState(() => _scrolling = true);
    } else if (notification is ScrollUpdateNotification && _scrolling) {
      if (!_edgeHinted && metrics.pixels < metrics.minScrollExtent - 40) {
        _edgeHinted = true;
        _say('已经是第一集');
      } else if (!_edgeHinted &&
          metrics.pixels > metrics.maxScrollExtent + 40) {
        _edgeHinted = true;
        _say('已经是最后一集');
      }
    } else if (notification is ScrollEndNotification) {
      final page = (metrics.pixels / metrics.viewportDimension).round();
      if (_scrolling) setState(() => _scrolling = false);
      if (page != _session.index &&
          page >= 0 &&
          page < _session.detail.episodes.length) {
        unawaited(_session.play(page));
      }
    }
    return false;
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (_scrolling) return;
      final target = _session.index + (event.scrollDelta.dy > 0 ? 1 : -1);
      if (target < 0) return _say('已经是第一集');
      if (target >= _session.detail.episodes.length) {
        return _say('已经是最后一集');
      }
      setState(() => _scrolling = true);
      unawaited(
        _pages.animateToPage(
          target,
          duration: const Duration(milliseconds: 250),
          curve: AppMotion.navigationCurve,
        ),
      );
    });
  }

  /// 铺满屏幕所需的缩放倍率：把画面按「屏幕比例 / 视频比例」放大到填满。
  double get _fillZoom {
    final size = MediaQuery.sizeOf(context);
    if (size.isEmpty) return 1;
    final screen = size.width / size.height;
    final video = _session.aspectRatio;
    if (!video.isFinite || video <= 0) return 1;
    return math.max(screen / video, video / screen);
  }

  /// 双指正在缩放：此时锁住翻页与单击/长按，避免手势互相抢。
  bool get _pinching => _pinchFrom != null;

  /// 全屏裁切模式的控制栏只跟随显式用户意图，不跟随新播放器的初始化状态。
  /// 切集时 active player 会短暂处于 paused/loading，若读 player.state.playing
  /// 会把这一帧误判成用户暂停，从而让控制栏在切集瞬间闪现。
  bool get _chromeShown => _zoom <= 1.01 || _userPausedWhileZoomed;

  /// 两指之间的距离，只有恰好两指时才有意义。
  double get _span {
    final values = _pointers.values.toList();
    return (values[0] - values[1]).distance;
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.position;
    if (_pointers.length != 2) return;
    if (_holding) _pressEnd();
    setState(() {
      _pinchFrom = math.max(_span, 1);
      _pinchBase = _zoom;
    });
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;
    final from = _pinchFrom;
    if (from == null || _pointers.length != 2) return;
    setState(() => _zoom = (_pinchBase * _span / from).clamp(1.0, _fillZoom));
  }

  void _pointerUp(PointerEvent event) {
    final from = _pinchFrom;
    if (from != null && _pointers.length == 2) _settleZoom();
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty && from != null) setState(() => _pinchFrom = null);
  }

  /// 松手吸附到「铺满」或「完整画面」，不停在中间态；跨过档位时给一次提示。
  void _settleZoom() {
    final fill = _fillZoom;
    final filled = _pinchBase > 1
        ? _zoom > fill - (fill - 1) * .3
        : _zoom > 1 + (fill - 1) * .3;
    setState(() {
      _zoom = filled ? fill : 1;
      _userPausedWhileZoomed = false;
    });
    if (filled == (_pinchBase > 1) || fill <= 1.01) return;
    unawaited(HapticFeedback.selectionClick());
    _say(filled ? '已铺满屏幕，双指捏合恢复' : '已恢复完整画面');
  }

  void _togglePlayback() {
    if (_zoom > 1.01) {
      setState(() => _userPausedWhileZoomed = !_session.paused);
    }
    _session.togglePlayback();
  }

  /// 长按只保留左边缘的五分之一区域：按住 2 倍速、下滑锁速。
  void _pressStart(LongPressStartDetails details, double width) {
    if (details.localPosition.dx >= width / 5) return;
    if (!_session.boostLocked) _session.holdBoost();
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _holding = true;
      _heldIndex = _session.index;
      _overMask = false;
    });
  }

  void _pressMove(LongPressMoveUpdateDetails details) {
    if (!_holding) return;
    final media = MediaQuery.of(context);
    final over =
        details.globalPosition.dy >=
        media.size.height - media.padding.bottom - _maskHeight;
    if (over != _overMask) {
      unawaited(HapticFeedback.selectionClick());
      setState(() => _overMask = over);
    }
  }

  void _pressEnd() {
    if (!_holding) return;
    if (_overMask) {
      _session.setBoostLocked(!_session.boostLocked);
    } else if (!_session.boostLocked) {
      _session.endBoost();
    }
    setState(() {
      _holding = false;
      _overMask = false;
    });
  }

  Future<void> _openSettings() => showPlayerPanel(
    context,
    (_) => PlaybackSettings(session: _session, onFailure: _saveFailed),
  );

  Future<void> _openEpisodes() => showPlayerSheet(
    context,
    (_) => _EpisodeSheet(
      session: _session,
      canDownload:
          AppScope.of(context).repository.supportsDownloads &&
          widget.store.canDownload,
      onDownload: (indexes) => unawaited(
        downloadEpisodes(context, widget.store, _session.detail, [
          for (final index in indexes) _session.detail.episodes[index],
        ]),
      ),
    ),
  );

  void _saveFailed() {
    if (!mounted) return;
    showAppNotice(context, '播放偏好未能保存，请重试');
  }

  /// 右侧按钮统一为 36dp，减少间距并为剧名留出空间。
  static const _actionExtent = 36.0;

  Widget _headerIcon({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color? color,
  }) => IconButton(
    onPressed: onPressed,
    icon: Icon(icon),
    color: color ?? Colors.white,
    tooltip: label,
    style: IconButton.styleFrom(
      fixedSize: const Size.square(_actionExtent),
      minimumSize: const Size.square(_actionExtent),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );

  Future<void> _toggleDanmaku() async {
    try {
      await _session.toggleDanmaku();
    } catch (_) {
      _saveFailed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = playerTheme(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.systemBars(Brightness.dark),
      child: Theme(
        data: dark,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Listener(
                onPointerDown: _pointerDown,
                onPointerMove: _pointerMove,
                onPointerUp: _pointerUp,
                onPointerCancel: _pointerUp,
                child: NotificationListener<ScrollNotification>(
                  onNotification: _scrolled,
                  child: PageView.builder(
                    controller: _pages,
                    scrollDirection: Axis.vertical,
                    // 双指缩放期间锁住翻页，否则第二根手指会被当成上下滑。
                    physics: _pinching
                        ? const NeverScrollableScrollPhysics()
                        : const _PagePhysics(),
                    itemCount: _session.detail.episodes.length,
                    itemBuilder: _page,
                  ),
                ),
              ),
              // 系统手势区不参与 PageView 翻页；置于控件下层，保留原有按钮点击。
              if (MediaQuery.viewPaddingOf(context).bottom > 0)
                Positioned(
                  key: const ValueKey('system-gesture-guard'),
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: MediaQuery.viewPaddingOf(context).bottom,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _togglePlayback,
                    onVerticalDragStart: (_) {},
                  ),
                ),
              IgnorePointer(
                ignoring: _scrolling || !_chromeShown,
                child: AnimatedOpacity(
                  opacity: _chromeShown ? 1 : 0,
                  duration: AppMotion.duration(context, AppMotion.state),
                  curve: AppMotion.curve,
                  child: _controls(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _page(BuildContext context, int index) {
    final session = _session;
    final current = index == session.index;
    final player = current
        ? session.player
        : index == session.standbyIndex
        ? session.standby
        : null;
    final waiting = player == null || current && session.loading;
    return Listener(
      onPointerSignal: _wheel,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!waiting)
            Positioned.fill(
              child: ClipRect(
                child: AnimatedScale(
                  scale: _zoom,
                  duration: _pinching
                      ? Duration.zero
                      : AppMotion.duration(context, AppMotion.state),
                  curve: AppMotion.curve,
                  child: PlayerVideo(
                    key: ValueKey(player),
                    handle: widget.handle,
                    player: player,
                  ),
                ),
              ),
            ),
          if (waiting)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 16,
                children: [
                  Text(
                    '第 ${session.detail.episodes[index].number} 集',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (current) const CircularProgressIndicator(),
                ],
              ),
            ),
          if (current) ...[
            DanmakuOverlay(
              key: const ValueKey('danmaku'),
              controller: session.danmaku,
              aspectRatio: session.aspectRatio,
              style: session.danmakuStyle,
            ),
            SwipeControls(
              key: const ValueKey('gestures'),
              session: session,
              enabled: !_pinching,
              child: LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _pinching ? null : _togglePlayback,
                  onLongPressStart: _pinching
                      ? null
                      : (details) => _pressStart(details, constraints.maxWidth),
                  onLongPressMoveUpdate: _pressMove,
                  onLongPressEnd: (_) => _pressEnd(),
                  onLongPressCancel: _pressEnd,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final session = _session;
    final padding = MediaQuery.paddingOf(context);
    final bottom = padding.bottom;
    final locked = session.boostLocked;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (session.aspectKnown &&
            session.aspectRatio > 1 &&
            widget.onFullscreen != null)
          Positioned(
            left: 0,
            right: 0,
            // 在视频下方留出 20dp 黑边，入口不覆盖剧集画面。
            top:
                (MediaQuery.sizeOf(context).height +
                        MediaQuery.sizeOf(context).width /
                            session.aspectRatio) /
                    2 +
                20,
            child: Center(
              child: WideVideoFullscreenButton(
                aspectKnown: session.aspectKnown,
                aspectRatio: session.aspectRatio,
                onPressed: widget.onFullscreen,
              ),
            ),
          ),
        const IgnorePointer(
          child: Align(
            alignment: Alignment.topCenter,
            child: _Shade(height: 110, top: true),
          ),
        ),
        const IgnorePointer(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: _Shade(height: 180, top: false),
          ),
        ),
        if (session.ready && session.paused)
          Center(
            child: IgnorePointer(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .35),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: 44,
                  color: Colors.white.withValues(alpha: .9),
                ),
              ),
            ),
          ),
        if (session.ready && session.stalled)
          const IgnorePointer(
            child: Center(child: CircularProgressIndicator()),
          ),
        if (session.error case final error?)
          PlaybackFailure(session: session, error: error),
        Positioned(
          key: const ValueKey('header'),
          left: 4,
          right: 12,
          top: padding.top,
          height: 56,
          child: _header(),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: bottom + 128,
          child: ListenableBuilder(
            listenable: _seek,
            builder: (context, _) => _seek.value.dragging
                ? IgnorePointer(
                    child: Center(
                      child: _seekBubble(_seek.value.milliseconds ?? 0),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
        Positioned(
          key: const ValueKey('progress'),
          left: 16,
          right: 16,
          bottom: bottom + 48,
          height: 32,
          child: _progress(context),
        ),
        Positioned(
          key: const ValueKey('episodes'),
          left: 16,
          right: 16,
          bottom: bottom + 4,
          height: 44,
          child: _episodeStrip(),
        ),
        if (_holding) ...[
          Positioned(
            left: 0,
            right: 0,
            top: padding.top + 76,
            child: IgnorePointer(child: Center(child: _boostBadge())),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: bottom + _maskHeight,
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black,
                child: Padding(
                  padding: EdgeInsets.only(bottom: bottom),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 8,
                    children: [
                      Icon(
                        !_overMask
                            ? Icons.fast_forward_rounded
                            : locked
                            ? Icons.lock_open_rounded
                            : Icons.lock_rounded,
                        size: 20,
                        color: Colors.white,
                      ),
                      Text(
                        '${_overMask ? '' : '下滑'}松手${locked ? '取消' : '锁定'} 2 倍速',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
        if (_hint.isNotEmpty)
          IgnorePointer(
            child: Align(
              alignment: const Alignment(0, -.5),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .72),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _hint,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),
        if (session.saveWarning case final warning?)
          Positioned(
            top: padding.top + 64,
            left: 12,
            right: 12,
            child: Material(
              color: const Color(0xE6322424),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        warning,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: session.saveProgress,
                      child: const Text('重试保存'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _header() {
    final session = _session;
    const shadow = [Shadow(color: Color(0x66000000), blurRadius: 2)];
    return Row(
      spacing: 0,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          onPressed: () => unawaited(Navigator.maybePop(context)),
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
              SizedBox(
                height: _actionExtent,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    session.detail.drama.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      shadows: shadow,
                    ),
                  ),
                ),
              ),
              Text(
                '第 ${session.episode.number} 集',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: .78),
                  fontSize: 12,
                  shadows: shadow,
                ),
              ),
            ],
          ),
        ),
        // 右上角顺序固定为：画中画（小窗）、弹幕开关、追剧、三点菜单。
        if (widget.onMiniWindow case final onMiniWindow?)
          _headerIcon(
            icon: Icons.picture_in_picture_alt_rounded,
            label: '小窗播放',
            onPressed: onMiniWindow,
          ),
        if (session.danmakuSupported)
          _headerIcon(
            icon: session.danmakuEnabled
                ? Icons.subtitles_rounded
                : Icons.subtitles_off_rounded,
            label: session.danmakuEnabled ? '关闭弹幕' : '打开弹幕',
            color: session.danmakuEnabled
                ? Theme.of(context).colorScheme.primaryFixedDim
                : null,
            onPressed: () => unawaited(_toggleDanmaku()),
          ),
        SizedBox.square(
          dimension: _actionExtent,
          child: Theme(
            data: Theme.of(
              context,
            ).copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
            child: FollowIcon(
              store: widget.store,
              drama: session.detail.drama,
              color: Colors.white,
              activeColor: Theme.of(context).colorScheme.primaryFixedDim,
              extent: _actionExtent,
              size: 22,
            ),
          ),
        ),
        _headerIcon(
          icon: Icons.more_vert_rounded,
          label: '播放设置',
          onPressed: () => unawaited(_openSettings()),
        ),
      ],
    );
  }

  Widget _seekBubble(double value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text.rich(
      TextSpan(
        text: formatClock(Duration(milliseconds: value.round())),
        children: [
          TextSpan(
            text: ' / ${formatClock(_session.player.state.duration)}',
            style: TextStyle(color: Colors.white.withValues(alpha: .6)),
          ),
        ],
      ),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    ),
  );

  /// 进度条右侧的「已播放 / 全部」。
  ///
  /// 字号压到 11、行高 1，高度仍收在进度条那一行里：竖屏下不往画面上多占
  /// 一像素，显隐也跟着进度条一起走。
  Widget _progressClock() {
    final state = _session.player.state;
    final duration = state.duration;
    final max = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final played =
        (_seek.value.milliseconds ?? state.position.inMilliseconds.toDouble())
            .clamp(0.0, max);
    return Text.rich(
      TextSpan(
        text: formatClock(Duration(milliseconds: played.round())),
        children: [
          TextSpan(
            text: ' / ${formatClock(duration)}',
            style: TextStyle(color: Colors.white.withValues(alpha: .55)),
          ),
        ],
      ),
      maxLines: 1,
      softWrap: false,
      style: TextStyle(
        fontSize: 11,
        height: 1,
        color: Colors.white.withValues(alpha: .85),
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  Widget _progress(BuildContext context) => ListenableBuilder(
    listenable: _seek,
    builder: (context, _) => PlaybackProgressBuilder(
      player: _session.player,
      builder: (context) => Row(
        children: [
          Expanded(child: _progressBar(context)),
          const SizedBox(width: 10),
          _progressClock(),
        ],
      ),
    ),
  );

  Widget _progressBar(BuildContext context) {
    final session = _session;
    final state = session.player.state;
    final duration = state.duration;
    final seekable = session.ready && duration > Duration.zero;
    final max = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final position =
        (_seek.value.milliseconds ?? state.position.inMilliseconds.toDouble())
            .clamp(0.0, max);
    final dragging = _seek.value.dragging;
    final colors = Theme.of(context).colorScheme;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: dragging ? 6 : 3,
        padding: EdgeInsets.zero,
        activeTrackColor: colors.primary,
        thumbColor: colors.primary,
        inactiveTrackColor: Colors.white.withValues(alpha: .25),
        secondaryActiveTrackColor: Colors.white.withValues(alpha: .4),
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: dragging ? 10 : 6,
        ),
        overlayShape: SliderComponentShape.noOverlay,
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      child: Slider(
        value: position,
        max: max,
        secondaryTrackValue: state.buffer.inMilliseconds.toDouble().clamp(
          0.0,
          max,
        ),
        semanticFormatterCallback: (value) =>
            formatClock(Duration(milliseconds: value.round())),
        onChangeStart: seekable ? _seek.start : null,
        onChanged: seekable ? _seek.update : null,
        onChangeEnd: (value) {
          if (seekable) {
            _seek.finish(value);
            unawaited(session.seekTo(Duration(milliseconds: value.round())));
          } else {
            _seek.reset();
          }
        },
      ),
    );
  }

  Widget _episodeStrip() {
    final drama = _session.detail.drama;
    final count = _session.detail.episodes.length;
    final status = _status(drama);
    return Material(
      color: Colors.white.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openEpisodes,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
          child: Row(
            spacing: 8,
            children: [
              const Icon(
                Icons.view_list_rounded,
                size: 18,
                color: Colors.white,
              ),
              const Text(
                '选集',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Expanded(
                child: Text(
                  '· $status共 $count 集',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .72),
                    fontSize: 14,
                  ),
                ),
              ),
              const Icon(
                Icons.keyboard_arrow_up_rounded,
                size: 20,
                color: Colors.white,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _boostBadge() => Container(
    height: 32,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(16),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        Icon(Icons.fast_forward_rounded, size: 16, color: Colors.white),
        Text(
          '2 倍速播放中',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _PagePhysics extends BouncingScrollPhysics {
  const _PagePhysics({super.parent});

  @override
  _PagePhysics applyTo(ScrollPhysics? ancestor) =>
      _PagePhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: .5, stiffness: 400, ratio: 1);
}

class _Shade extends StatelessWidget {
  const _Shade({required this.height, required this.top});
  final double height;
  final bool top;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: height,
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: top ? Alignment.topCenter : Alignment.bottomCenter,
          end: top ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [
            Color(top ? 0x8C000000 : 0xA6000000),
            const Color(0x00000000),
          ],
        ),
      ),
    ),
  );
}

class _EpisodeSheet extends StatefulWidget {
  const _EpisodeSheet({
    required this.session,
    required this.canDownload,
    required this.onDownload,
  });
  final PlaybackSession session;
  final bool canDownload;
  final ValueChanged<List<int>> onDownload;

  @override
  State<_EpisodeSheet> createState() => _EpisodeSheetState();
}

class _EpisodeSheetState extends State<_EpisodeSheet> {
  final _selected = <int>{};
  bool _selecting = false;

  PlaybackSession get _session => widget.session;

  void _select(bool selecting) => setState(() {
    _selecting = selecting;
    _selected.clear();
  });

  @override
  Widget build(BuildContext context) {
    final episodes = _session.detail.episodes;
    final drama = _session.detail.drama;
    final colors = Theme.of(context).colorScheme;
    final all = _selected.length == episodes.length;
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(false);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            children: _selecting
                ? [
                    Expanded(
                      child: Text(
                        '已选 ${_selected.length} 集',
                        style: sheetTitle,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _select(false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        all
                            ? _selected.clear()
                            : _selected.addAll(
                                List.generate(episodes.length, (i) => i),
                              );
                      }),
                      child: Text(all ? '取消全选' : '全选'),
                    ),
                    FilledButton(
                      onPressed: _selected.isEmpty
                          ? null
                          : () {
                              final indexes = _selected.toList()..sort();
                              Navigator.pop(context);
                              widget.onDownload(indexes);
                            },
                      child: const Text('下载'),
                    ),
                  ]
                : [
                    const Text('选集', style: sheetTitle),
                    Expanded(
                      child: Text(
                        '${_status(drama)}共 ${episodes.length} 集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (widget.canDownload)
                      IconButton(
                        onPressed: () => _select(true),
                        icon: const Icon(Icons.download_rounded),
                        tooltip: '下载选集',
                      ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                      tooltip: '关闭',
                    ),
                  ],
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: _session,
              builder: (context, _) => EpisodeGrid(
                episodes: episodes,
                current: _session.index,
                selecting: _selecting,
                selected: _selected,
                touch: true,
                onSelectionChanged: () => setState(() {}),
                onPick: (index) {
                  Navigator.pop(context);
                  if (index != _session.index) {
                    unawaited(_session.play(index));
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

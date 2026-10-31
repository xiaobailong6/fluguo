import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app_device.dart';
import '../../playback_session.dart';
import 'player_surface.dart';

const _seekSpan = 120000;

enum _Level { brightness, volume }

class SwipeControls extends StatefulWidget {
  const SwipeControls({
    super.key,
    required this.session,
    this.enabled = true,
    this.levels = false,
    this.episodes = false,
    required this.child,
  });
  final PlaybackSession session;
  final bool enabled;
  final bool levels;

  /// 中间一半区域上下滑切集；独立于全屏进度/音量手势开关。
  final bool episodes;
  final Widget child;

  @override
  State<SwipeControls> createState() => _SwipeControlsState();
}

class _SwipeControlsState extends State<SwipeControls> {
  int? _seekFrom;
  double _seekOffset = 0;
  _Level? _level;
  double? _value;
  double _pending = 0;
  int _levelRequest = 0;
  int? _episodeFrom;
  Object? _episodePlayer;
  double _episodeOffset = 0;
  String? _hint;
  Timer? _hintTimer;

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  void _verticalStart(DragStartDetails details) {
    final x = details.localPosition.dx / context.size!.width;
    // 开启调节时按起点分区；关闭时整幅画面都用于切集。
    if (widget.episodes && (!widget.levels || x >= .25 && x <= .75)) {
      if (!_session.ready) return;
      _episodeFrom = _session.index;
      _episodePlayer = _session.player;
      _episodeOffset = 0;
    } else if (widget.enabled && widget.levels) {
      unawaited(_levelStart(details));
    }
  }

  void _verticalUpdate(DragUpdateDetails details) {
    if (_episodeFrom != null) {
      _episodeOffset += details.delta.dy;
    } else {
      _levelUpdate(details);
    }
  }

  void _verticalEnd(DragEndDetails _) {
    final from = _episodeFrom;
    final offset = _episodeOffset;
    final player = _episodePlayer;
    _verticalCancel();
    // 只在松手且位移足够时切一次；加载、自动切集或换播放器后丢弃旧手势。
    if (from == null ||
        !widget.episodes ||
        !_session.ready ||
        _session.index != from ||
        !identical(_session.player, player) ||
        offset.abs() < 60) {
      return;
    }
    final target = from + (offset < 0 ? 1 : -1);
    if (target < 0 || target >= _session.detail.episodes.length) {
      _hintTimer?.cancel();
      setState(() => _hint = target < 0 ? '已经是第一集' : '已经是最后一集');
      _hintTimer = Timer(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _hint = null);
      });
      return;
    }
    unawaited(_session.play(target));
  }

  void _verticalCancel() {
    _episodeFrom = null;
    _episodePlayer = null;
    _episodeOffset = 0;
    _levelEnd();
  }

  PlaybackSession get _session => widget.session;

  int get _duration => _session.player.state.duration.inMilliseconds;

  int get _seekTarget => (_seekFrom! + _seekOffset).round().clamp(0, _duration);

  void _seekStart(DragStartDetails _) {
    if (!_session.ready || _duration <= 0) return;
    setState(() {
      _seekFrom = _session.player.state.position.inMilliseconds;
      _seekOffset = 0;
    });
  }

  void _seekUpdate(DragUpdateDetails details) {
    final from = _seekFrom;
    if (from == null) return;
    final span = math.min(_duration, _seekSpan);
    final offset = _seekOffset + details.delta.dx / context.size!.width * span;
    setState(
      () => _seekOffset = offset.clamp(-from, _duration - from).toDouble(),
    );
  }

  void _seekEnd(DragEndDetails _) {
    if (_seekFrom == null) return;
    final target = _seekTarget;
    setState(() => _seekFrom = null);
    unawaited(_session.seekTo(Duration(milliseconds: target)));
  }

  void _seekCancel() {
    if (_seekFrom != null) setState(() => _seekFrom = null);
  }

  Future<void> _levelStart(DragStartDetails details) async {
    final request = ++_levelRequest;
    final level = details.localPosition.dx < context.size!.width / 2
        ? _Level.brightness
        : _Level.volume;
    setState(() {
      _level = level;
      _value = null;
      _pending = 0;
    });
    final value = await (level == _Level.brightness
        ? AppDevice.brightness()
        : AppDevice.volume());
    if (!mounted ||
        request != _levelRequest ||
        _level != level ||
        _value != null) {
      return;
    }
    if (value == null) return setState(() => _level = null);
    _apply(value + _pending);
  }

  void _levelUpdate(DragUpdateDetails details) {
    if (_level == null) return;
    final delta = -details.delta.dy / context.size!.height;
    if (_value case final value?) {
      _apply(value + delta);
    } else {
      _pending += delta;
    }
  }

  void _apply(double value) {
    final next = value.clamp(0.0, 1.0);
    setState(() => _value = next);
    unawaited(
      _level == _Level.brightness
          ? AppDevice.setBrightness(next)
          : AppDevice.setVolume(next),
    );
  }

  void _levelEnd() {
    _levelRequest++;
    if (_level != null) setState(() => _level = null);
  }

  @override
  Widget build(BuildContext context) {
    final seek =
        widget.enabled &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final levels = seek && widget.levels;
    final vertical =
        levels ||
        (widget.episodes &&
            (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS));
    final level = _level;
    final value = _value;
    return Stack(
      fit: StackFit.expand,
      children: [
        Listener(
          // 已识别的拖动在 PointerCancel 时也可能收到 onEnd，先清理以免误切。
          onPointerCancel: (_) => _verticalCancel(),
          child: GestureDetector(
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: seek ? _seekStart : null,
            onHorizontalDragUpdate: seek ? _seekUpdate : null,
            onHorizontalDragEnd: seek ? _seekEnd : null,
            onHorizontalDragCancel: seek ? _seekCancel : null,
            onVerticalDragStart: vertical ? _verticalStart : null,
            onVerticalDragUpdate: vertical ? _verticalUpdate : null,
            onVerticalDragEnd: vertical ? _verticalEnd : null,
            onVerticalDragCancel: vertical ? _verticalCancel : null,
            child: widget.child,
          ),
        ),
        if (_seekFrom != null)
          _badge(_seekLabel())
        else if (level != null && value != null)
          _badge(_levelBar(level, value))
        else if (_hint case final hint?)
          _badge(Text(hint, style: const TextStyle(color: Colors.white))),
      ],
    );
  }

  Widget _badge(Widget child) => IgnorePointer(
    child: Align(
      alignment: const Alignment(0, -.4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      ),
    ),
  );

  Widget _seekLabel() => Text.rich(
    TextSpan(
      text: formatClock(Duration(milliseconds: _seekTarget)),
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
  );

  Widget _levelBar(_Level level, double value) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 10,
    children: [
      Icon(
        level == _Level.brightness
            ? Icons.brightness_6_rounded
            : value == 0
            ? Icons.volume_off_rounded
            : Icons.volume_up_rounded,
        size: 22,
        color: Colors.white,
      ),
      SizedBox(
        width: 120,
        child: LinearProgressIndicator(
          value: value,
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
          color: Colors.white,
          backgroundColor: Colors.white.withValues(alpha: .25),
        ),
      ),
    ],
  );
}

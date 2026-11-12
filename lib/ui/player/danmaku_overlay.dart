import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../danmaku_controller.dart';
import '../../danmaku_models.dart';
import '../../danmaku_style.dart';

const danmakuMaxRows = 64;

class DanmakuFlight {
  const DanmakuFlight(this.item, this.text, this.lane, this.width);
  final DanmakuItem item;
  final String text;
  final int lane;
  final double width;
}

List<DanmakuFlight> planDanmaku(
  List<DanmakuItem> items, {
  required double width,
  required int rows,
  required double Function(String) measure,
}) {
  if (!width.isFinite || width <= 0 || rows < 1) return const [];
  final lanes = List<DanmakuFlight?>.filled(
    rows.clamp(1, danmakuMaxRows),
    null,
  );
  final sorted = items.toList()..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  final seen = <String>{};
  final flights = <DanmakuFlight>[];
  for (final item in sorted) {
    if (item.id.isEmpty ||
        item.text.trim().isEmpty ||
        item.timeMs < 0 ||
        !seen.add(item.id)) {
      continue;
    }
    if (flights.reversed
            .takeWhile(
              (flight) => item.timeMs - flight.item.timeMs < danmakuLifetimeMs,
            )
            .length >=
        24) {
      continue;
    }
    final runes = item.text.runes;
    final text =
        String.fromCharCodes(runes.take(100)) + (runes.length > 100 ? '…' : '');
    final size = measure(text).ceilToDouble() + 8;
    final lane = lanes.indexWhere((previous) {
      if (previous == null) return true;
      final gap = item.timeMs - previous.item.timeMs;
      if (gap >= danmakuLifetimeMs) return true;
      return (width + previous.width) * gap / danmakuLifetimeMs -
                  previous.width >=
              24 &&
          width -
                  (width + size) *
                      (danmakuLifetimeMs - gap) /
                      danmakuLifetimeMs >=
              24;
    });
    if (lane < 0) continue;
    final flight = DanmakuFlight(item, text, lane, size);
    lanes[lane] = flight;
    flights.add(flight);
  }
  return flights;
}

/// 计算某一时刻在屏的弹幕，并推进扫描游标。
///
/// 排期按 `timeMs` 升序，`cursor` 表示「这之前的都已经结束」。回拖或重新
/// 排期后调用方把 `cursor` 传 0 从头重扫即可。可见区间与旧实现逐字相同：
/// `timeMs <= ms < timeMs + danmakuLifetimeMs`。
({List<DanmakuFlight> visible, int cursor}) danmakuWindow(
  List<DanmakuFlight> schedule,
  double ms, {
  int cursor = 0,
}) {
  var start = cursor;
  while (start < schedule.length &&
      schedule[start].item.timeMs + danmakuLifetimeMs <= ms) {
    start++;
  }
  final visible = <DanmakuFlight>[];
  for (var index = start; index < schedule.length; index++) {
    final flight = schedule[index];
    if (flight.item.timeMs > ms) break;
    visible.add(flight);
  }
  return (visible: visible, cursor: start);
}

TextStyle danmakuTextStyle({
  required double fontSize,
  required DanmakuStyle style,
  bool stroke = false,
}) {
  final weight = style.bold ? FontWeight.w700 : FontWeight.w500;
  final alpha = style.opacity;
  if (stroke) {
    return TextStyle(
      fontSize: fontSize,
      height: 1.2,
      fontWeight: weight,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = style.stroke
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.black.withValues(alpha: alpha),
    );
  }
  return TextStyle(
    fontSize: fontSize,
    height: 1.2,
    fontWeight: weight,
    color: style.color.withValues(alpha: alpha),
    shadows: style.hasShadow
        ? [
            Shadow(
              color: Colors.black.withValues(alpha: .72 * alpha),
              blurRadius: style.shadow,
              offset: Offset(style.shadow * .3, style.shadow * .3),
            ),
          ]
        : null,
  );
}

class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.controller,
    required this.aspectRatio,
    this.style = const DanmakuStyle(),
  });
  final DanmakuController controller;
  final double aspectRatio;
  final DanmakuStyle style;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

/// 弹幕层：整层只有**一个** Ticker。
///
/// 旧实现对每条在屏弹幕各建一个 `AnimationController`，播放时 N 个 ticker
/// 每帧同时推进，外层还跟着位置通知重建整棵 Stack。这里改成：控制器每给出
/// 新位置就重设锚点，单 Ticker 按「锚点位置 + 真实经过时间 × 倍速」插值，
/// 所有弹幕读同一个时钟；外层只在显隐、排期、尺寸变化时重建，在屏集合变化
/// 时才重新组装 Stack。
///
/// 位移公式与入/退场判据与旧实现逐字一致：
/// `x = width - (width + 文本宽) * 已播时长 / danmakuLifetimeMs`，
/// 可见区间仍是 `[timeMs, timeMs + danmakuLifetimeMs)`。
class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  Object? _layout;
  List<DanmakuFlight> _schedule = const [];
  List<DanmakuFlight> _visible = const [];

  /// 唯一时钟：当前播放位置（毫秒，用 double 便于亚毫秒插值）。
  final _clock = ValueNotifier<double>(0);

  /// 单调时钟，不受系统时间调整影响。
  final Stopwatch _monotonic = Stopwatch()..start();

  late final Ticker _ticker = createTicker(_tick);

  int _anchorMs = 0;
  double _anchorWallMs = 0;
  double _lastMs = 0;
  int _scanFrom = 0;
  bool _shown = false;
  int _revision = -1;
  int _motion = -1;

  @override
  void initState() {
    super.initState();
    _shown = widget.controller.visible;
    _revision = widget.controller.dataRevision;
    _motion = widget.controller.motionRevision;
    widget.controller.addListener(_changed);
    _anchor();
    _follow();
  }

  @override
  void didUpdateWidget(DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_changed);
    widget.controller.addListener(_changed);
    _motion = widget.controller.motionRevision;
    _anchor();
    _follow();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _ticker
      ..stop()
      ..dispose();
    _clock.dispose();
    super.dispose();
  }

  double get _wallMs => _monotonic.elapsedMicroseconds / 1000;

  double get _rate {
    final rate = widget.controller.rate;
    return rate.isFinite && rate > 0 ? rate : 1;
  }

  /// 控制器给出新位置就重设锚点：此前按真实时间估算，此后从新位置继续走。
  void _anchor() {
    _anchorMs = widget.controller.positionMs;
    _anchorWallMs = _wallMs;
    _clock.value = _anchorMs.toDouble();
  }

  /// 只在播放中转动 Ticker：暂停、缓冲、隐藏时一律停住，不空转。
  void _follow() {
    final run = widget.controller.visible && widget.controller.moving;
    if (run && !_ticker.isActive) {
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _changed() {
    final controller = widget.controller;
    // 只在控制器真正重置运动时改锚点（切集、拖动、暂停、倍速、追帧）：
    // 普通位置回报只用来让时钟继续跑，避免每 250ms 把弹幕拽一下。
    if (controller.motionRevision != _motion) {
      _motion = controller.motionRevision;
      _anchor();
    }
    _follow();
    if (!mounted) return;
    if (controller.visible == _shown && controller.dataRevision == _revision) {
      return;
    }
    _shown = controller.visible;
    _revision = controller.dataRevision;
    setState(() {});
  }

  void _tick(Duration _) {
    if (!mounted) return;
    final live = widget.controller.moving
        ? _rate * (_wallMs - _anchorWallMs) + _anchorMs
        : _anchorMs.toDouble();
    _clock.value = live;
    final next = _visibleAt(live);
    if (!_sameFlights(next, _visible)) {
      setState(() => _visible = next);
    }
  }

  /// 只扫「可能还在屏」的窗口：排期按时间升序，回拖时从头重扫。
  List<DanmakuFlight> _visibleAt(double ms) {
    if (ms < _lastMs) _scanFrom = 0;
    _lastMs = ms;
    final window = danmakuWindow(_schedule, ms, cursor: _scanFrom);
    _scanFrom = window.cursor;
    return window.visible;
  }

  bool _sameFlights(List<DanmakuFlight> first, List<DanmakuFlight> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (!identical(first[index], second[index])) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.hasBoundedWidth ||
              !constraints.hasBoundedHeight ||
              constraints.maxWidth <= 0 ||
              constraints.maxHeight <= 0) {
            return const SizedBox.shrink();
          }
          final aspect = widget.aspectRatio.isFinite && widget.aspectRatio > 0
              ? widget.aspectRatio
              : 16 / 9;
          final width = math.min(
            constraints.maxWidth,
            constraints.maxHeight * aspect,
          );
          final height = math.min(
            constraints.maxHeight,
            constraints.maxWidth / aspect,
          );
          final style = widget.style;
          final fontSize = (width < 600 ? 16.0 : 20.0) * style.scale;
          final scaler = MediaQuery.textScalerOf(context);
          final rowHeight = scaler.scale(fontSize) * 1.5;
          final rows = ((height * style.coverage.fraction - 8) / rowHeight)
              .floor()
              .clamp(0, danmakuMaxRows);
          final fill = danmakuTextStyle(fontSize: fontSize, style: style);
          final outline = style.hasStroke
              ? danmakuTextStyle(fontSize: fontSize, style: style, stroke: true)
              : null;
          final controller = widget.controller;
          final layout = (
            controller,
            controller.dataRevision,
            width,
            rows,
            fontSize,
            scaler,
            style,
          );
          if (_layout != layout) {
            _layout = layout;
            _schedule = planDanmaku(
              controller.items,
              width: width,
              rows: rows,
              measure: (text) {
                final painter = TextPainter(
                  text: TextSpan(text: text, style: fill),
                  textDirection: TextDirection.ltr,
                  textScaler: scaler,
                  maxLines: 1,
                )..layout();
                final measured = painter.width;
                painter.dispose();
                return measured;
              },
            );
            // 重新排期后旧的下标没有意义，从头扫一遍当前窗口。
            _scanFrom = 0;
            _visible = _visibleAt(_clock.value);
          }
          if (!_shown || rows == 0) return const SizedBox.shrink();
          return Center(
            child: SizedBox(
              width: width,
              height: height,
              child: ClipRect(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final flight in _visible)
                      Positioned(
                        key: ValueKey('danmaku-item-${flight.item.id}'),
                        left: 0,
                        top: 8 + flight.lane * rowHeight,
                        width: flight.width,
                        height: rowHeight,
                        child: _DanmakuMotion(
                          flight: flight,
                          width: width,
                          clock: _clock,
                          style: fill,
                          outline: outline,
                          scaler: scaler,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// 单条弹幕的位移：从共享时钟换算进度，只重建 `Transform` 这一层。
///
/// 文本包在 `RepaintBoundary` 里，逐帧只更新位移，不重排文字。
class _DanmakuMotion extends StatelessWidget {
  const _DanmakuMotion({
    required this.flight,
    required this.width,
    required this.clock,
    required this.style,
    required this.outline,
    required this.scaler,
  });
  final DanmakuFlight flight;
  final double width;
  final ValueListenable<double> clock;
  final TextStyle style;
  final TextStyle? outline;
  final TextScaler scaler;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: clock,
    child: RepaintBoundary(
      child: _DanmakuText(
        text: flight.text,
        style: style,
        outline: outline,
        scaler: scaler,
      ),
    ),
    builder: (context, child) {
      final elapsed = (clock.value - flight.item.timeMs).clamp(
        0.0,
        danmakuLifetimeMs.toDouble(),
      );
      final value = elapsed / danmakuLifetimeMs;
      return Transform.translate(
        key: ValueKey('danmaku-motion-${flight.item.id}'),
        offset: Offset(width - (width + flight.width) * value, 0),
        child: child,
      );
    },
  );
}

class _DanmakuText extends StatelessWidget {
  const _DanmakuText({
    required this.text,
    required this.style,
    required this.outline,
    required this.scaler,
  });
  final String text;
  final TextStyle style;
  final TextStyle? outline;
  final TextScaler scaler;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      style: style,
      textScaler: scaler,
      textDirection: TextDirection.ltr,
      maxLines: 1,
      softWrap: false,
    );
    final outline = this.outline;
    if (outline == null) return label;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Text(
          text,
          style: outline,
          textScaler: scaler,
          textDirection: TextDirection.ltr,
          maxLines: 1,
          softWrap: false,
        ),
        label,
      ],
    );
  }
}

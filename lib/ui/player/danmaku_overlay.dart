import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../danmaku_controller.dart';
import '../../danmaku_emoji.dart';
import '../../danmaku_models.dart';
import '../../danmaku_style.dart';
import '../../local_store.dart';
import '../../playback_preferences.dart';
import 'danmaku_emoji_text.dart';

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
        String.fromCharCodes(runes.take(100)) +
        (runes.length > 100 ? '…' : '') +
        (item.count > 1 ? ' ×${item.count}' : '');
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

/// 直接监听设置：切换显示样式不依赖播放器再次上报进度或加载弹幕。
class StoredDanmakuOverlay extends StatefulWidget {
  const StoredDanmakuOverlay({
    super.key,
    required this.store,
    required this.source,
    required this.controller,
    required this.aspectRatio,
    this.topLimit,
  });

  final LocalStore store;
  final String source;
  final DanmakuController controller;
  final double aspectRatio;
  final double? topLimit;

  @override
  State<StoredDanmakuOverlay> createState() => _StoredDanmakuOverlayState();
}

class _StoredDanmakuOverlayState extends State<StoredDanmakuOverlay> {
  late (int, DanmakuStyle, double?) _selection;
  late PlaybackPreferences _preferences;

  (int, DanmakuStyle, double?) _select() => (
    widget.store.profileEpoch,
    DanmakuStyle.of(_preferences, source: widget.source),
    _preferences.danmakuUpperBar ? widget.topLimit : null,
  );

  @override
  void initState() {
    super.initState();
    _preferences = widget.store.playbackPreferences;
    _selection = _select();
    widget.store.addListener(_storeChanged);
  }

  void _storeChanged() {
    final next = widget.store.playbackPreferences;
    if (identical(next, _preferences) &&
        widget.store.profileEpoch == _selection.$1) {
      return;
    }
    _preferences = next;
    final selection = _select();
    if (selection != _selection) setState(() => _selection = selection);
  }

  @override
  void didUpdateWidget(StoredDanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.store != oldWidget.store) {
      oldWidget.store.removeListener(_storeChanged);
      widget.store.addListener(_storeChanged);
    }
    _preferences = widget.store.playbackPreferences;
    _selection = _select();
  }

  @override
  void dispose() {
    widget.store.removeListener(_storeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DanmakuOverlay(
    controller: widget.controller,
    aspectRatio: widget.aspectRatio,
    style: _selection.$2,
    topLimit: _selection.$3,
  );
}

class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.controller,
    required this.aspectRatio,
    this.style = const DanmakuStyle(),
    this.topLimit,
  });
  final DanmakuController controller;
  final double aspectRatio;
  final DanmakuStyle style;
  final double? topLimit;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

/// 弹幕层：整层只有**一个** Ticker。
///
/// 旧实现对每条在屏弹幕各建一个 `AnimationController`，播放时 N 个 ticker
/// 每帧同时推进，外层还跟着位置通知重建整棵 Stack。这里只在 motionRevision
/// 变化时重设锚点，单 Ticker 按「锚点位置 + 真实经过时间 × 倍速」插值，
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

  // 仅保存本次有限页排期的测宽/图文布局；revision/样式/尺寸变动即释放。
  final _widths = <String, double>{};
  final _emojiLayouts = <String, DanmakuEmojiLayout>{};

  void _clearMeasurements() {
    for (final layout in _emojiLayouts.values) {
      layout.dispose();
    }
    _emojiLayouts.clear();
    _widths.clear();
  }

  /// 唯一时钟：当前播放位置（毫秒，用 double 便于亚毫秒插值）。
  final _clock = ValueNotifier<double>(0);

  /// 生产环境仍用单调 Stopwatch；测试时跟随 binding 的虚拟时钟，避免真实等待。
  final Stopwatch _monotonic = WidgetsBinding.instance.samplingClock.stopwatch()
    ..start();

  late final Ticker _ticker = createTicker(_tick);
  Timer? _nextFlight;
  bool _hasViewport = false;

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
    registerDanmakuEmojiLicense();
    _shown = widget.controller.visible;
    _revision = widget.controller.dataRevision;
    _motion = widget.controller.motionRevision;
    widget.controller.addListener(_changed);
    _anchor();
    _drive();
  }

  @override
  void didUpdateWidget(DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_changed);
    widget.controller.addListener(_changed);
    _shown = widget.controller.visible;
    _revision = widget.controller.dataRevision;
    _motion = widget.controller.motionRevision;
    _layout = null;
    _schedule = const [];
    _visible = const [];
    _scanFrom = 0;
    _halt();
    _anchor();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _clearMeasurements();
    _halt();
    _ticker.dispose();
    _monotonic.stop();
    _clock.dispose();
    super.dispose();
  }

  double get _wallMs => _monotonic.elapsedMicroseconds / 1000;

  double get _rate {
    final rate = widget.controller.rate;
    return rate.isFinite && rate > 0 ? rate : 1;
  }

  /// 运动状态改变时重设锚点；普通位置回报不打断真实时间插值。
  void _anchor() {
    _anchorMs = widget.controller.positionMs;
    _anchorWallMs = _wallMs;
    _clock.value = _anchorMs.toDouble();
  }

  double get _nowMs => widget.controller.moving
      ? _rate * (_wallMs - _anchorWallMs) + _anchorMs
      : _anchorMs.toDouble();

  void _halt() {
    _ticker.stop();
    _nextFlight?.cancel();
    _nextFlight = null;
  }

  /// 有在屏弹幕时才按原生刷新率运动；空档只预约下一条，不逐帧扫描。
  void _drive() {
    final run =
        _hasViewport && widget.controller.visible && widget.controller.moving;
    if (run && _visible.isNotEmpty) {
      _nextFlight?.cancel();
      _nextFlight = null;
      if (!_ticker.isActive) _ticker.start();
      return;
    }
    _halt();
    if (!run || _scanFrom >= _schedule.length) return;
    // 空窗口的游标正好指向下一条；用当前锚点及倍速换算墙钟等待时间。
    final wait = (_schedule[_scanFrom].item.timeMs - _nowMs) / _rate;
    _nextFlight = Timer(
      Duration(milliseconds: math.max(0, wait.ceil())),
      () => _tick(Duration.zero),
    );
  }

  void _changed() {
    if (!mounted) return;
    final controller = widget.controller;
    var rebuild = false;
    // 普通位置回报不重设锚点；seek、暂停、倍速等立即同步窗口与唤醒时间。
    if (controller.motionRevision != _motion) {
      _motion = controller.motionRevision;
      _anchor();
      rebuild = _moveWindow();
    }
    if (controller.visible != _shown || controller.dataRevision != _revision) {
      _shown = controller.visible;
      _revision = controller.dataRevision;
      rebuild = true;
      // 新数据交给下一次布局重新排期，不能继续用旧排期预约唤醒。
      _halt();
    } else {
      _drive();
    }
    if (rebuild) setState(() {});
  }

  bool _moveWindow() {
    final next = _visibleAt(_clock.value);
    if (_sameFlights(next, _visible)) return false;
    _visible = next;
    return true;
  }

  void _tick(Duration _) {
    if (!mounted) return;
    _clock.value = _nowMs;
    if (_moveWindow()) setState(() {});
    _drive();
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
            _hasViewport = false;
            _clearMeasurements();
            _layout = null;
            _schedule = const [];
            _visible = const [];
            _scanFrom = 0;
            _halt();
            return const SizedBox.shrink();
          }
          _hasViewport = true;
          final aspect = widget.aspectRatio.isFinite && widget.aspectRatio > 0
              ? widget.aspectRatio
              : 16 / 9;
          final width = math.min(
            constraints.maxWidth,
            constraints.maxHeight * aspect,
          );
          final videoHeight = math.min(
            constraints.maxHeight,
            constraints.maxWidth / aspect,
          );
          final videoTop = (constraints.maxHeight - videoHeight) / 2;
          final top = math.min(videoTop, widget.topLimit ?? videoTop);
          final height = videoHeight + (videoTop - top);
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
            _clearMeasurements();
            _schedule = planDanmaku(
              controller.items,
              width: width,
              rows: rows,
              measure: (text) {
                final cached = _widths[text];
                if (cached != null) return cached;
                if (style.emoji && text.contains('[')) {
                  final segments = parseDanmakuSegments(text);
                  if (segments.any((segment) => segment.asset != null)) {
                    final layout = DanmakuEmojiLayout(
                      segments,
                      style: fill,
                      outline: outline,
                      scaler: scaler,
                    );
                    _emojiLayouts[text] = layout;
                    return _widths[text] = layout.width;
                  }
                }
                final painter = TextPainter(
                  text: TextSpan(text: text, style: fill),
                  textDirection: TextDirection.ltr,
                  textScaler: scaler,
                  maxLines: 1,
                )..layout();
                final measured = painter.width;
                painter.dispose();
                return _widths[text] = measured;
              },
            );
            // 重新排期后旧的下标没有意义，从头扫一遍当前窗口。
            _scanFrom = 0;
          }
          // 空档期间没有帧回调；新数据或尺寸改变时先追到当前时钟，再启动调度。
          _clock.value = _nowMs;
          _visible = _visibleAt(_clock.value);
          _drive();
          if (!_shown || rows == 0) return const SizedBox.shrink();
          return Align(
            alignment: Alignment.topCenter,
            child: Container(
              margin: EdgeInsets.only(top: top),
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
                          emojiLayout: _emojiLayouts[flight.text],
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

/// 每帧只通知渲染层重绘；文字、描边及 RepaintBoundary 保持不变。
class _DanmakuMotion extends StatelessWidget {
  const _DanmakuMotion({
    required this.flight,
    required this.width,
    required this.clock,
    required this.style,
    required this.outline,
    required this.scaler,
    required this.emojiLayout,
  });
  final DanmakuFlight flight;
  final double width;
  final ValueListenable<double> clock;
  final TextStyle style;
  final TextStyle? outline;
  final TextScaler scaler;
  final DanmakuEmojiLayout? emojiLayout;

  @override
  Widget build(BuildContext context) => _DanmakuSlide(
    key: ValueKey('danmaku-motion-${flight.item.id}'),
    clock: clock,
    startMs: flight.item.timeMs,
    travel: width + flight.width,
    origin: width,
    child: RepaintBoundary(
      child: emojiLayout != null
          ? DanmakuEmojiText(layout: emojiLayout!)
          : _DanmakuText(
              text: flight.text,
              style: style,
              outline: outline,
              scaler: scaler,
            ),
    ),
  );
}

class _DanmakuSlide extends SingleChildRenderObjectWidget {
  const _DanmakuSlide({
    super.key,
    required this.clock,
    required this.startMs,
    required this.travel,
    required this.origin,
    required super.child,
  });

  final ValueListenable<double> clock;
  final int startMs;
  final double travel;
  final double origin;

  @override
  _RenderDanmakuSlide createRenderObject(BuildContext context) =>
      _RenderDanmakuSlide(clock, startMs, travel, origin);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderDanmakuSlide renderObject,
  ) {
    renderObject
      ..clock = clock
      ..startMs = startMs
      ..travel = travel
      ..origin = origin;
  }
}

class _RenderDanmakuSlide extends RenderProxyBox {
  _RenderDanmakuSlide(this._clock, this._startMs, this._travel, this._origin);

  ValueListenable<double> _clock;
  set clock(ValueListenable<double> value) {
    if (identical(value, _clock)) return;
    if (attached) _clock.removeListener(markNeedsPaint);
    _clock = value;
    if (attached) _clock.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  int _startMs;
  set startMs(int value) {
    if (value == _startMs) return;
    _startMs = value;
    markNeedsPaint();
  }

  double _travel;
  set travel(double value) {
    if (value == _travel) return;
    _travel = value;
    markNeedsPaint();
  }

  double _origin;
  set origin(double value) {
    if (value == _origin) return;
    _origin = value;
    markNeedsPaint();
  }

  Offset get _translation {
    final elapsed = (_clock.value - _startMs).clamp(
      0.0,
      danmakuLifetimeMs.toDouble(),
    );
    return Offset(_origin - _travel * (elapsed / danmakuLifetimeMs), 0);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _clock.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _clock.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child != null) context.paintChild(child, offset + _translation);
  }

  // 与 Transform.translate 一样只改变绘制坐标，不改变文字布局。
  // 坐标换算与命中测试也使用同一偏移，外层仍忽略指针并排除语义。
  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_translation.dx, 0, 0, 1);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      hitTestChildren(result, position: position);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
        offset: _translation,
        position: position,
        hitTest: (result, position) =>
            super.hitTestChildren(result, position: position),
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

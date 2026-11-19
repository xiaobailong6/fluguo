import 'dart:async';
import 'dart:io';
import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 运行时性能面板的编译期开关。
///
/// 只在 `flutter run/build --dart-define=PERF_HUD=true` 时打开；默认 false 时
/// [PerfHud] 直接返回 child，不注册任何回调、不绘制、不产生额外 Element。
const perfHudEnabled = bool.fromEnvironment('PERF_HUD');

/// 挂在 MaterialApp 之上的性能面板外壳。
///
/// 用途：真机上量「播放页/列表页到底掉不掉帧」的基线，以及改动前后对比。
/// 关闭时是纯透传，不参与任何计时。
class PerfHud extends StatelessWidget {
  const PerfHud({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      perfHudEnabled ? _PerfHudOverlay(child: child) : child;
}

/// 显示器没有报告有效刷新率时，保留 60 Hz 基准。
int frameBudgetMicros(double refreshRate) =>
    (Duration.microsecondsPerSecond /
            (refreshRate.isFinite && refreshRate >= 1 ? refreshRate : 60))
        .round();

class _PerfHudOverlay extends StatefulWidget {
  const _PerfHudOverlay({required this.child});

  final Widget child;

  @override
  State<_PerfHudOverlay> createState() => _PerfHudOverlayState();
}

class _PerfHudOverlayState extends State<_PerfHudOverlay> {
  int? _lastBudget;
  late FlutterView _view;

  /// 统计窗口：只留最近若干帧，避免长时间运行把内存撑大。
  static const _window = 180;

  final _spans = <int>[];
  final _builds = <int>[];
  final _rasters = <int>[];

  Timer? _timer;
  int _fps = 0;
  int _frames = 0;
  int _rss = 0;
  bool _detail = false;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_timings);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _fps = _frames;
        _frames = 0;
        _rss = ProcessInfo.currentRss;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
  }

  void _timings(List<FrameTiming> timings) {
    final budget = frameBudgetMicros(_view.display.refreshRate);
    if (_lastBudget != budget) {
      // 换屏或切换刷新率后，不按新阈值重新解释上一块屏幕的样本。
      _spans.clear();
      _builds.clear();
      _rasters.clear();
      _lastBudget = budget;
    }
    for (final timing in timings) {
      _spans.add(timing.totalSpan.inMicroseconds);
      _builds.add(timing.buildDuration.inMicroseconds);
      _rasters.add(timing.rasterDuration.inMicroseconds);
      _frames++;
    }
    while (_spans.length > _window) {
      _spans.removeAt(0);
      _builds.removeAt(0);
      _rasters.removeAt(0);
    }
  }

  void _reset() {
    setState(() {
      _spans.clear();
      _builds.clear();
      _rasters.clear();
      _frames = 0;
      _fps = 0;
    });
  }

  int _percentile(List<int> values, double ratio) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    return sorted[((sorted.length - 1) * ratio).round()];
  }

  double _jank() {
    if (_spans.isEmpty) return 0;
    final budget = _lastBudget!;
    final slow = _spans.where((span) => span > budget).length;
    return slow * 100 / _spans.length;
  }

  String _ms(int micros) => (micros / 1000).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final jank = _jank().toStringAsFixed(0);
    final head =
        '$_fps fps  ${_ms(_percentile(_spans, .5))}/'
        '${_ms(_percentile(_spans, .95))}ms  jank $jank%  '
        '${(_rss / 1048576).toStringAsFixed(0)}MB';
    final detail =
        'build ${_ms(_percentile(_builds, .95))}  '
        'raster ${_ms(_percentile(_rasters, .95))}  '
        'n ${_spans.length}  预算 ${_ms(_lastBudget ?? frameBudgetMicros(60))}ms';
    return Stack(
      children: [
        widget.child,
        Positioned(
          right: 8,
          bottom: 96,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: GestureDetector(
              onTap: () => setState(() => _detail = !_detail),
              onLongPress: _reset,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xCC000000),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: DefaultTextStyle(
                    style: const TextStyle(
                      color: Color(0xFF9BE39B),
                      fontSize: 10,
                      height: 1.3,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [Text(head), if (_detail) Text(detail)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

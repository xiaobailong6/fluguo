import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Android 预测式返回：页面跟手缩小、向右让出一条缝，松手后交给路由完成退出。
///
/// 只在系统真正下发 [PredictiveBackEvent] 时参与（Android 13+ 且清单开启
/// `android:enableOnBackInvokedCallback`）；其它平台、旧系统、以及当前路由
/// 不可返回时 [handleStartBackGesture] 直接返回 false，界面保持原样，
/// 不改变任何现有布局。
///
/// 时长与曲线由调用方注入，避免和 `AppMotion` 形成循环依赖。
class BackGesture extends StatefulWidget {
  const BackGesture({
    super.key,
    required this.route,
    required this.child,
    required this.duration,
    required this.curve,
  });

  final PageRoute<dynamic> route;
  final Widget child;

  /// 手势取消后的回弹时长（调用方已处理减少动画与电视端压缩）。
  final Duration duration;

  /// 回弹曲线。
  final Curve curve;

  @override
  State<BackGesture> createState() => _BackGestureState();
}

class _BackGestureState extends State<BackGesture>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// 手势已开始但系统尚未把路由动画推进到 1 时的占位进度。
  static const _held = .9999;

  late final _progress = AnimationController(vsync: this);
  var _edge = SwipeEdge.left;
  var _active = false;
  var _committed = false;

  PageRoute<dynamic> get _route => widget.route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _route.animation?.removeStatusListener(_opened);
    _progress.dispose();
    super.dispose();
  }

  bool get _canPop {
    final route = _route;
    final navigator = route.navigator;
    return navigator != null &&
        !navigator.userGestureInProgress &&
        route.isCurrent &&
        !route.isFirst &&
        !route.fullscreenDialog &&
        !route.willHandlePopInternally &&
        route.popDisposition != RoutePopDisposition.doNotPop;
  }

  /// 路由已经完整打开后回调：把占位进度推给路由，避免松手瞬间回跳。
  void _opened(AnimationStatus status) {
    if (!status.isCompleted) return;
    _route.animation?.removeStatusListener(_opened);
    if (_active && !_committed) {
      _route.handleUpdateBackGestureProgress(progress: _held);
    }
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent) return false;
    if (_active && !_committed) {
      _progress.value = backEvent.progress;
      return true;
    }
    if (!_canPop) return false;
    _route.navigator!.didStartUserGesture();
    final animation = _route.animation!;
    if (animation.isCompleted) {
      _route.handleUpdateBackGestureProgress(progress: _held);
    } else {
      animation.addStatusListener(_opened);
    }
    _active = true;
    _committed = false;
    setState(() => _edge = backEvent.swipeEdge);
    _progress.value = backEvent.progress;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_active && !_committed) _progress.value = backEvent.progress;
  }

  @override
  void handleCancelBackGesture() {
    if (!_active || _committed) return;
    _progress
        .animateTo(0, duration: widget.duration, curve: widget.curve)
        .whenCompleteOrCancel(() {
          if (!mounted || !_active || _committed || _progress.value > 0) {
            return;
          }
          _route.animation?.removeStatusListener(_opened);
          _active = false;
          _route.handleCancelBackGesture();
        });
  }

  @override
  void handleCommitBackGesture() {
    if (!_active || _committed) return;
    _route.animation?.removeStatusListener(_opened);
    _committed = true;
    final navigator = _route.navigator!;
    final animation = _route.animation!;
    // 手势进行中被别的路由盖住时，不能把新的顶层页弹掉，只结束手势状态。
    if (!_route.isCurrent) {
      _active = false;
      navigator.didStopUserGesture();
      return;
    }
    navigator.pop();
    if (!animation.isAnimating) return navigator.didStopUserGesture();
    late final AnimationStatusListener closed;
    closed = (status) {
      if (status.isAnimating) return;
      animation.removeStatusListener(closed);
      navigator.didStopUserGesture();
    };
    animation.addStatusListener(closed);
  }

  @override
  Widget build(BuildContext context) => _BackGestureTransition(
    progress: _progress,
    edge: _edge,
    child: widget.child,
  );
}

class _BackGestureTransition extends AnimatedWidget {
  const _BackGestureTransition({
    required Animation<double> progress,
    required this.edge,
    required this.child,
  }) : super(listenable: progress);

  final SwipeEdge edge;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final progress = (listenable as Animation<double>).value;
    final width = MediaQuery.sizeOf(context).width;
    final shift = (width / 20 - 8) * progress;
    return Transform.translate(
      offset: Offset(edge == SwipeEdge.left ? shift : -shift, 0),
      child: Transform.scale(
        scale: 1 - 0.1 * progress,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32 * progress),
          clipBehavior: progress > 0 ? Clip.antiAlias : Clip.none,
          child: child,
        ),
      ),
    );
  }
}

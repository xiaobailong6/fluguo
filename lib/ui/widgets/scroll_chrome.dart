import 'package:flutter/material.dart';

import '../app_motion.dart';

/// 累计同向位移而非逐帧速度；慢滑也能触发，回弹不让浮栏来回闪。
class ScrollChromeController extends ValueNotifier<bool> {
  ScrollChromeController({required this.hideAfter, this.showAt = 12})
    : super(false);

  final double hideAfter;
  final double showAt;
  double _last = 0;
  double _travel = 0;

  void track(
    double pixels, {
    double minExtent = 0,
    double maxExtent = double.infinity,
  }) {
    if (!pixels.isFinite) return;
    final current = pixels.clamp(minExtent, maxExtent);
    final delta = current - _last;
    _last = current;
    if (current <= minExtent + showAt) {
      _travel = 0;
      value = false;
      return;
    }
    if (delta == 0) return;
    if (_travel.sign != delta.sign) _travel = 0;
    _travel += delta;
    if (current > minExtent + hideAfter && _travel >= 18) {
      value = true;
      _travel = 0;
    } else if (_travel <= -12) {
      value = false;
      _travel = 0;
    }
  }

  void reset({double pixels = 0, bool hidden = false}) {
    _last = pixels;
    _travel = 0;
    value = hidden;
  }
}

/// 隐藏只改变绘制，保留动画和子树；输入、焦点及语义立即停用。
///
/// 首次挂载也走一次入场：卡片和底栏出现时淡入并从藏匿方向滑回，
/// 不会在页面切换或首帧时突兀地直接出现。
class ScrollChromeVisibility extends StatefulWidget {
  const ScrollChromeVisibility({
    super.key,
    required this.hidden,
    required this.hiddenOffset,
    required this.child,
  });

  final bool hidden;
  final Offset hiddenOffset;
  final Widget child;

  @override
  State<ScrollChromeVisibility> createState() => _ScrollChromeVisibilityState();
}

class _ScrollChromeVisibilityState extends State<ScrollChromeVisibility> {
  late bool _settled = widget.hidden;

  @override
  void initState() {
    super.initState();
    if (!_settled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _settled = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hidden = widget.hidden || !_settled;
    return IgnorePointer(
      ignoring: widget.hidden,
      child: ExcludeFocus(
        excluding: widget.hidden,
        child: ExcludeSemantics(
          excluding: widget.hidden,
          child: AnimatedSlide(
            offset: hidden ? widget.hiddenOffset : Offset.zero,
            duration: AppMotion.duration(context, AppMotion.chrome),
            curve: hidden ? AppMotion.exitCurve : AppMotion.curve,
            child: AnimatedOpacity(
              opacity: hidden ? 0 : 1,
              duration: AppMotion.duration(context, AppMotion.chrome),
              curve: hidden ? AppMotion.exitCurve : AppMotion.curve,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

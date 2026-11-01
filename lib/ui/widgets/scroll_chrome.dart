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
class ScrollChromeVisibility extends StatelessWidget {
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
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: hidden,
    child: ExcludeFocus(
      excluding: hidden,
      child: ExcludeSemantics(
        excluding: hidden,
        child: AnimatedSlide(
          offset: hidden ? hiddenOffset : Offset.zero,
          duration: AppMotion.duration(context, AppMotion.chrome),
          curve: Curves.easeInOutCubic,
          child: AnimatedOpacity(
            opacity: hidden ? 0 : 1,
            duration: AppMotion.duration(context, AppMotion.chrome),
            curve: Curves.easeInOutCubic,
            child: child,
          ),
        ),
      ),
    ),
  );
}

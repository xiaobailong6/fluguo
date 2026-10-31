import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_scope.dart';

/// 站源与直播平台共用标题尺寸、间距及触控区域，页面只提供各自的操作。
class SourceHeader extends StatelessWidget {
  const SourceHeader({
    super.key,
    required this.title,
    required this.tooltip,
    required this.onSwitch,
    required this.actions,
    this.televisionLeading,
  });

  final String title;
  final String tooltip;
  final ValueChanged<BuildContext> onSwitch;
  final List<Widget> actions;
  final Widget? televisionLeading;

  static double heightOf(BuildContext context) {
    final television = AppScope.formFactorOf(context) == FormFactor.television;
    // 放大字体时同步扩展标题行，直播浮动头也使用同一高度计算占位。
    return math.max(
      television ? 48 : 52,
      MediaQuery.textScalerOf(context).scale(television ? 16 : 28) + 20,
    );
  }

  @override
  Widget build(BuildContext context) {
    final television = AppScope.formFactorOf(context) == FormFactor.television;
    final selector = Builder(
      builder: (anchor) => Tooltip(
        message: tooltip,
        child: TextButton(
          onPressed: () => onSwitch(anchor),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            minimumSize: const Size(48, 48),
            foregroundColor: Theme.of(context).colorScheme.onSurface,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: television ? 16 : 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Icon(Icons.arrow_drop_down_rounded, size: television ? 24 : 26),
            ],
          ),
        ),
      ),
    );
    return SizedBox(
      height: heightOf(context),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          television ? 0 : 12,
          0,
          television ? 0 : 8,
          0,
        ),
        child: Row(
          spacing: television ? 10 : 4,
          children: [
            if (television) ...[?televisionLeading, const Spacer()],
            if (television)
              Flexible(child: selector)
            else
              Expanded(
                child: Align(alignment: Alignment.centerLeft, child: selector),
              ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

/// 明确点击回顶时按距离留足过渡时间；屏幕阅读器导航本身不禁用此动画。
/// 使用 position 的原生活动，让手势、重复点击和销毁自然取消，不保留完成回调。
Future<void> smoothScrollToTop(
  BuildContext context,
  ScrollPosition position,
) async {
  if (!context.mounted ||
      position.context.notificationContext?.mounted != true ||
      !position.hasContentDimensions ||
      !position.hasPixels) {
    return;
  }
  final target = position.minScrollExtent;
  final distance = (position.pixels - target).abs();
  if (!distance.isFinite || distance == 0) return;
  // 尊重减少动态效果：只在明确禁用动画时直接到达，不播放位移动画。
  if (MediaQuery.disableAnimationsOf(context)) {
    position.jumpTo(target);
    return;
  }
  final milliseconds = (450 + distance / 6).clamp(450, 850).round();
  await position.animateTo(
    target,
    duration: Duration(milliseconds: milliseconds),
    curve: Curves.easeInOutCubic,
  );
}

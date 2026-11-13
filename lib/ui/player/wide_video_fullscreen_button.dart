import 'package:flutter/material.dart';

/// 元数据尚未知和竖屏/正方形视频都不显示，避免误导用户旋转竖屏剧集。
class WideVideoFullscreenButton extends StatelessWidget {
  const WideVideoFullscreenButton({
    super.key,
    required this.aspectKnown,
    required this.aspectRatio,
    required this.onPressed,
  });
  final bool aspectKnown;
  final double aspectRatio;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (!aspectKnown ||
        !aspectRatio.isFinite ||
        aspectRatio <= 1 ||
        onPressed == null) {
      return const SizedBox.shrink();
    }
    return TextButton(
      key: const ValueKey('wide-video-fullscreen'),
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: const Color(0x66000000),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
        shape: const StadiumBorder(),
        side: const BorderSide(color: Color(0x33FFFFFF)),
      ),
      child: const Text('全屏播放'),
    );
  }
}

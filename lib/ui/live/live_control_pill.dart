import 'package:flutter/material.dart';

/// 视频全屏菜单使用固定深色底保证亮画面上仍有边界，不增加背景模糊。
class LiveControlPill extends StatelessWidget {
  const LiveControlPill({
    super.key,
    required this.label,
    required this.onPressed,
  });
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white54,
        backgroundColor: const Color(0xC2000000),
        side: const BorderSide(color: Color(0x66FFFFFF)),
        shape: const StadiumBorder(),
        minimumSize: const Size(48, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );
}

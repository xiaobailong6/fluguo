import 'package:flutter/material.dart';
import '../theme/glass_style.dart';
import '../widgets/glass/glass_feedback.dart';

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
  Widget build(BuildContext context) {
    final style = GlassStyleResolver.tier(
      context,
      MediaQuery.highContrastOf(context) ? GlassTier.none : GlassTier.full,
      role: GlassRole.playback,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: GlassFeedback(
        radius: 999,
        enabled: onPressed != null,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white54,
            backgroundColor: style.tint,
            side: BorderSide(color: style.rimHighlight),
            shape: const StadiumBorder(),
            minimumSize: const Size(48, 36),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 画面单击只显隐菜单，双击才播放/暂停；桌面小窗双击仍用于还原。
class LivePlayerGestures extends StatelessWidget {
  const LivePlayerGestures({
    super.key,
    required this.child,
    required this.full,
    required this.mini,
    required this.controlsVisible,
    required this.onTogglePlayback,
    required this.onToggleControls,
    required this.onRestoreMini,
    required this.onDragMini,
    required this.onToggleFull,
    required this.onBack,
  });
  final Widget child;
  final bool full;
  final bool mini;
  final bool controlsVisible;
  final VoidCallback onTogglePlayback;
  final VoidCallback onToggleControls;
  final VoidCallback onRestoreMini;
  final VoidCallback onDragMini;
  final VoidCallback onToggleFull;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.escape) {
        onBack();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.mediaPlayPause) {
        onTogglePlayback();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.f11) {
        onToggleFull();
        return KeyEventResult.handled;
      }
      if (full &&
          !mini &&
          !controlsVisible &&
          {
            LogicalKeyboardKey.enter,
            LogicalKeyboardKey.select,
            LogicalKeyboardKey.arrowLeft,
            LogicalKeyboardKey.arrowRight,
            LogicalKeyboardKey.arrowUp,
            LogicalKeyboardKey.arrowDown,
          }.contains(key)) {
        onToggleControls();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: GestureDetector(
      key: const ValueKey('live-video-gestures'),
      behavior: HitTestBehavior.opaque,
      onTap: full && !mini ? onToggleControls : null,
      onDoubleTap: mini ? onRestoreMini : onTogglePlayback,
      onPanStart: mini ? (_) => onDragMini() : null,
      child: child,
    ),
  );
}

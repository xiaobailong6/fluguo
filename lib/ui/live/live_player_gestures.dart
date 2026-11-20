import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 画面单击只显隐菜单，双击才播放/暂停；桌面小窗双击仍用于还原。
class LivePlayerGestures extends StatefulWidget {
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
    this.onToggleMute,
    this.surfaceBuilder,
    this.focusNode,
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
  final VoidCallback? onToggleMute;
  final FocusNode? focusNode;

  /// 键盘包住整个播控区域，手势只包画面；避免点击按钮后快捷键失联。
  final Widget Function(BuildContext context, Widget video)? surfaceBuilder;

  @override
  State<LivePlayerGestures> createState() => _LivePlayerGesturesState();
}

class _LivePlayerGesturesState extends State<LivePlayerGestures>
    with WidgetsBindingObserver {
  final _ownedFocus = FocusNode(debugLabel: 'live-video-keys');
  FocusNode get _focus => widget.focusNode ?? _ownedFocus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(LivePlayerGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.full != oldWidget.full || widget.mini != oldWidget.mini) {
      _restoreFocus();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _restoreFocus();
  }

  void _restoreFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focus.canRequestFocus || _focus.hasFocus) return;
      // 只接管空的路由焦点；弹窗、按钮、输入框和锁屏的焦点都由原持有者处理。
      if (ModalRoute.of(context)?.isCurrent != true) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary != null && primary is! FocusScopeNode) return;
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ownedFocus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent || ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (primary?.context?.widget is EditableText ||
        primary?.context?.findAncestorWidgetOfExactType<EditableText>() !=
            null) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onBack();
    } else if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      widget.onTogglePlayback();
    } else if (key == LogicalKeyboardKey.f11 ||
        key == LogicalKeyboardKey.keyF) {
      widget.onToggleFull();
    } else if (key == LogicalKeyboardKey.keyM && widget.onToggleMute != null) {
      widget.onToggleMute!();
    } else if (widget.full &&
        !widget.mini &&
        !widget.controlsVisible &&
        {
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.select,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
        }.contains(key)) {
      widget.onToggleControls();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final video = GestureDetector(
      key: const ValueKey('live-video-gestures'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _restoreFocus();
        if (widget.full && !widget.mini) widget.onToggleControls();
      },
      onDoubleTap: widget.mini ? widget.onRestoreMini : widget.onTogglePlayback,
      onPanStart: widget.mini ? (_) => widget.onDragMini() : null,
      child: widget.child,
    );
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: widget.surfaceBuilder?.call(context, video) ?? video,
    );
  }
}

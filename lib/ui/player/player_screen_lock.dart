import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/control_presence.dart';

/// 保留同一棵播放器树，只隔离输入、焦点和语义；锁屏不暂停视频。
class PlayerScreenLock extends StatefulWidget {
  const PlayerScreenLock({
    super.key,
    required this.locked,
    required this.onUnlock,
    required this.child,
  });

  final bool locked;
  final VoidCallback onUnlock;
  final Widget child;

  @override
  State<PlayerScreenLock> createState() => _PlayerScreenLockState();
}

class _PlayerScreenLockState extends State<PlayerScreenLock> {
  final _focus = FocusNode(debugLabel: 'playerScreenLock');
  final _pointers = <int>{};
  Timer? _hideTimer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    if (widget.locked) _activate();
  }

  @override
  void didUpdateWidget(PlayerScreenLock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.locked == oldWidget.locked) return;
    if (widget.locked) {
      _activate();
    } else {
      _hideTimer?.cancel();
      _focus.unfocus();
    }
  }

  void _activate() {
    // 取消锁屏前已经开始的拖动，防止旧手势松手后继续切集或快进。
    for (final pointer in _pointers.toList()) {
      GestureBinding.instance.cancelPointer(pointer);
    }
    _pointers.clear();
    _visible = true;
    _scheduleHide();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.locked) _focus.requestFocus();
    });
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !widget.locked) return;
      setState(() => _visible = false);
      _focus.requestFocus();
    });
  }

  void _reveal() {
    if (!widget.locked) return;
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (!widget.locked) return KeyEventResult.ignored;
    if (event is KeyDownEvent) _reveal();
    // 只允许遍历及激活解锁按钮，不让按键传播至播放器快捷键。
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.tab ||
        (!_focus.hasPrimaryFocus &&
            (key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter ||
                key == LogicalKeyboardKey.space))) {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  Widget _unlock(String side) => IconButton(
    key: ValueKey('player-unlock-$side'),
    tooltip: '解锁屏幕',
    onPressed: widget.onUnlock,
    icon: const Icon(Icons.lock_open_rounded),
    style: IconButton.styleFrom(
      foregroundColor: Colors.white,
      backgroundColor: Colors.black54,
      fixedSize: const Size.square(48),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !widget.locked,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && widget.locked) _reveal();
    },
    child: Listener(
      onPointerDown: (event) => _pointers.add(event.pointer),
      onPointerUp: (event) => _pointers.remove(event.pointer),
      onPointerCancel: (event) => _pointers.remove(event.pointer),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(
            excluding: widget.locked,
            child: ExcludeFocus(
              excluding: widget.locked,
              child: AbsorbPointer(
                absorbing: widget.locked,
                child: widget.child,
              ),
            ),
          ),
          if (widget.locked)
            Positioned.fill(
              child: FocusScope(
                child: Focus(
                  focusNode: _focus,
                  onKeyEvent: _key,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (_) => _reveal(),
                    onPointerSignal: (_) => _reveal(),
                    child: Material(
                      type: MaterialType.transparency,
                      child: SafeArea(
                        minimum: const EdgeInsets.all(12),
                        child: Stack(
                          children: [
                            if (!_visible)
                              Semantics(
                                label: '屏幕已锁定，显示解锁按钮',
                                button: true,
                                onTap: _reveal,
                                child: const SizedBox.expand(),
                              ),
                            for (final side in ['left', 'right'])
                              Align(
                                key: ValueKey('unlock-presence-$side'),
                                alignment: side == 'left'
                                    ? Alignment.centerLeft
                                    : Alignment.centerRight,
                                child: ControlPresence(
                                  visible: _visible,
                                  child: _unlock(side),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

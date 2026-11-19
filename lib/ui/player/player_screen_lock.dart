import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/control_presence.dart';

/// 锁定与解锁共用安全区和按钮尺寸；隐藏时立即退出点击、焦点及语义。
class PlayerLockControls extends StatelessWidget {
  const PlayerLockControls({
    super.key,
    required this.locked,
    required this.visible,
    required this.onPressed,
  });

  final bool locked;
  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final remaining = MediaQuery.paddingOf(context);
    final original =
        context
            .dependOnInheritedWidgetOfExactType<_PlayerLockInsets>()
            ?.padding ??
        remaining;
    // PlayerSurface 已在页面 SafeArea 内，解锁层则在外；只补尚未留出的
    // 12dp 最小边距，避免刘海/手势区被重复计算而使锁前锁后位置跳动。
    double minimum(double before, double after) =>
        (12 - before + after).clamp(0, 12);
    return SafeArea(
      minimum: EdgeInsets.fromLTRB(
        minimum(original.left, remaining.left),
        minimum(original.top, remaining.top),
        minimum(original.right, remaining.right),
        minimum(original.bottom, remaining.bottom),
      ),
      child: Stack(
        children: [
          for (final side in ['left', 'right'])
            Align(
              key: ValueKey('${locked ? 'unlock' : 'lock'}-presence-$side'),
              alignment: side == 'left'
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: ControlPresence(
                visible: visible,
                child: IconButton(
                  key: ValueKey('player-${locked ? 'unlock' : 'lock'}-$side'),
                  tooltip: locked ? '解锁屏幕' : '锁定屏幕',
                  onPressed: onPressed,
                  icon: Icon(
                    locked
                        ? Icons.lock_open_rounded
                        : Icons.lock_outline_rounded,
                  ),
                  style: IconButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.black54,
                    fixedSize: const Size.square(48),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlayerLockInsets extends InheritedWidget {
  const _PlayerLockInsets({required this.padding, required super.child});

  final EdgeInsets padding;

  @override
  bool updateShouldNotify(_PlayerLockInsets oldWidget) =>
      padding != oldWidget.padding;
}

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

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !widget.locked,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && widget.locked) _reveal();
    },
    child: _PlayerLockInsets(
      padding: MediaQuery.paddingOf(context),
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
                        child: Stack(
                          children: [
                            if (!_visible)
                              Semantics(
                                label: '屏幕已锁定，显示解锁按钮',
                                button: true,
                                onTap: _reveal,
                                child: const SizedBox.expand(),
                              ),
                            PlayerLockControls(
                              locked: true,
                              visible: _visible,
                              onPressed: widget.onUnlock,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

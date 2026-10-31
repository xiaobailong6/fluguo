import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/focus_ring.dart';

/// 锁定的是输入而不是播放生命周期；视频、续签和后台暂停仍照常处理。
class LiveScreenLock extends StatefulWidget {
  const LiveScreenLock({
    super.key,
    required this.enabled,
    required this.locked,
    required this.onToggle,
    required this.child,
  });
  final bool enabled;
  final bool locked;
  final VoidCallback onToggle;
  final Widget child;

  @override
  State<LiveScreenLock> createState() => _LiveScreenLockState();
}

class _LiveScreenLockState extends State<LiveScreenLock> {
  final _lockFocus = FocusNode(debugLabel: 'liveScreenLock');
  bool get _locked => widget.enabled && widget.locked;

  @override
  void initState() {
    super.initState();
    if (_locked) _focusLock();
  }

  void _focusLock() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && _locked) _lockFocus.requestFocus();
  });

  @override
  void didUpdateWidget(covariant LiveScreenLock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_locked && !(oldWidget.enabled && oldWidget.locked)) _focusLock();
  }

  @override
  void dispose() {
    _lockFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KeyboardControls(
    child: Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (!_locked) return KeyEventResult.ignored;
        // 只允许焦点在小锁时用确认键解锁，其余按键不能传给播放或外层导航。
        if (event is KeyDownEvent &&
            _lockFocus.hasFocus &&
            {
              LogicalKeyboardKey.enter,
              LogicalKeyboardKey.numpadEnter,
              LogicalKeyboardKey.select,
              LogicalKeyboardKey.space,
            }.contains(event.logicalKey)) {
          widget.onToggle();
        }
        return KeyEventResult.handled;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: _locked,
            child: ExcludeSemantics(
              excluding: _locked,
              child: AbsorbPointer(absorbing: _locked, child: widget.child),
            ),
          ),
          if (widget.enabled)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: MediaQuery.viewPaddingOf(context).left + 12,
                  ),
                  child: Semantics(
                    toggled: _locked,
                    child: IconButton(
                      key: const ValueKey('live-screen-lock'),
                      focusNode: _lockFocus,
                      tooltip: _locked ? '解锁屏幕' : '锁定屏幕',
                      onPressed: widget.onToggle,
                      style: IconButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: const Color(0x66000000),
                        fixedSize: const Size.square(44),
                        side: const BorderSide(color: Color(0x33FFFFFF)),
                      ),
                      icon: Icon(
                        _locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                        size: 20,
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

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/glass_style.dart';
import 'glass/glass_surface.dart';
import 'search_field.dart';

/// 保留原输入框样式，只在空输入框获得焦点时展示最近搜索。
class RecentSearchField extends StatefulWidget {
  const RecentSearchField({
    super.key,
    required this.width,
    required this.hint,
    required this.recent,
    required this.onSubmitted,
    this.controller,
    this.onForget,
    this.enabled = true,
  });

  final double width;
  final String hint;
  final List<String> recent;
  final ValueChanged<String> onSubmitted;
  final TextEditingController? controller;
  final ValueChanged<String>? onForget;
  final bool enabled;

  @override
  State<RecentSearchField> createState() => _RecentSearchFieldState();
}

class _RecentSearchFieldState extends State<RecentSearchField> {
  final _ownController = TextEditingController();
  final _fieldFocus = FocusNode();
  final _groupFocus = FocusNode(skipTraversal: true, canRequestFocus: false);
  // OverlayPortal 管理生命周期，关闭时不保留历史列表或独立 OverlayEntry。
  final _overlay = OverlayPortalController()..show();
  bool _active = false;
  bool _visible = true;

  TextEditingController get _controller => widget.controller ?? _ownController;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (!_visible) {
      _active = false;
      _groupFocus.unfocus();
    }
  }

  @override
  void didUpdateWidget(RecentSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || oldWidget.controller != widget.controller) {
      _active = false;
      _groupFocus.unfocus();
    }
  }

  @override
  void dispose() {
    _ownController.dispose();
    _fieldFocus.dispose();
    _groupFocus.dispose();
    super.dispose();
  }

  void _close() {
    if (_active) setState(() => _active = false);
    _groupFocus.unfocus();
  }

  void _submit(String query) {
    if (!widget.enabled || !_visible) return;
    _close();
    widget.onSubmitted(query);
  }

  Widget _options(
    BuildContext context,
    OverlayChildLayoutInfo info,
  ) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      if (!_active ||
          !_visible ||
          !widget.enabled ||
          _controller.text.isNotEmpty ||
          widget.recent.isEmpty) {
        return const SizedBox.shrink();
      }
      // 锚点与目标 Overlay 使用同一坐标；内层 Scaffold 已避让键盘时
      // viewInsets 为零，不再次扣减。窗口变窄时同步限制宽高。
      final anchor = MatrixUtils.transformRect(
        info.childPaintTransform,
        Offset.zero & info.childSize,
      );
      final padding = MediaQuery.paddingOf(context);
      final insets = MediaQuery.viewInsetsOf(context);
      final leftEdge = math.max(8.0, padding.left);
      final rightEdge = info.overlaySize.width - math.max(8.0, padding.right);
      final bottom =
          info.overlaySize.height -
          math.max(8.0, math.max(padding.bottom, insets.bottom));
      final topEdge = math.max(8.0, padding.top);
      final below = math.max(0.0, bottom - anchor.bottom - 4);
      final above = math.max(0.0, anchor.top - topEdge - 4);
      final down = below >= 144 || below >= above;
      final width = math.min(widget.width, math.max(0.0, rightEdge - leftEdge));
      final height = math.min(360.0, down ? below : above);
      if (width == 0 || height == 0) return const SizedBox.shrink();
      final rtl = Directionality.of(context) == TextDirection.rtl;
      final left = (rtl ? anchor.right - width : anchor.left).clamp(
        leftEdge,
        math.max(leftEdge, rightEdge - width),
      );
      return Positioned(
        left: left.toDouble(),
        width: width,
        top: down ? anchor.bottom + 4 : null,
        bottom: down ? null : info.overlaySize.height - anchor.top + 4,
        child: TextFieldTapRegion(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height),
            child: GlassSurface(
              key: const ValueKey('recent-search-options'),
              role: GlassRole.panel,
              radius: 12,
              child: ListView(
                primary: false,
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  for (final query in widget.recent)
                    GestureDetector(
                      onSecondaryTap: widget.onForget == null
                          ? null
                          : () => widget.onForget!(query),
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.history_rounded, size: 18),
                        title: Text(
                          query,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _submit(query),
                        onLongPress: widget.onForget == null
                            ? null
                            : () => widget.onForget!(query),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _groupFocus,
    onFocusChange: (value) {
      if (_active != value) setState(() => _active = value);
    },
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape &&
          _active) {
        _close();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: TextFieldTapRegion(
      onTapOutside: (_) => _close(),
      child: OverlayPortal.overlayChildLayoutBuilder(
        controller: _overlay,
        overlayChildBuilder: _options,
        child: SizedBox(
          width: widget.width,
          child: SearchField(
            hint: widget.hint,
            controller: _controller,
            focusNode: _fieldFocus,
            onSubmitted: _submit,
          ),
        ),
      ),
    ),
  );
}

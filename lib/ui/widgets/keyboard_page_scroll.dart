import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../app_motion.dart';
import 'focus_ring.dart';

/// Focus wins in split panes. Only use a hit-tested viewport when the route's
/// focus is on its chrome rather than inside a list.
KeyEventResult keyboardPageScroll(KeyEvent event, {required bool television}) {
  final key = event.logicalKey;
  final keys = HardwareKeyboard.instance;
  if (television ||
      event is KeyUpEvent ||
      (key != LogicalKeyboardKey.pageUp &&
          key != LogicalKeyboardKey.pageDown) ||
      keys.isAltPressed ||
      keys.isControlPressed ||
      keys.isMetaPressed ||
      keys.isShiftPressed ||
      keyboardControlsFocused() ||
      focusedTextField() != null) {
    return KeyEventResult.ignored;
  }
  final focus = FocusManager.instance.primaryFocus?.context;
  if (focus == null || !focus.mounted) return KeyEventResult.ignored;
  final route = ModalRoute.of(focus);
  if (route is PopupRoute || route?.isCurrent == false) {
    return KeyEventResult.ignored;
  }
  ScrollPosition? position = Scrollable.maybeOf(
    focus,
    axis: Axis.vertical,
  )?.position;
  if (position == null) {
    final view = View.maybeOf(focus);
    if (view == null) return KeyEventResult.ignored;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      view.physicalSize.center(Offset.zero) / view.devicePixelRatio,
      view.viewId,
    );
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderViewportBase && target.offset is ScrollPosition) {
        final candidate = target.offset as ScrollPosition;
        if (candidate.axis != Axis.vertical) continue;
        final context = candidate.context.notificationContext;
        if (context == null ||
            !context.mounted ||
            context.getInheritedWidgetOfExactType<KeyboardControls>() != null ||
            ModalRoute.of(context) is PopupRoute ||
            ModalRoute.of(context)?.isCurrent == false) {
          return KeyEventResult.ignored;
        }
        position = candidate;
        break;
      }
    }
  }
  if (position == null ||
      !position.hasContentDimensions ||
      !position.hasViewportDimension ||
      position.maxScrollExtent <= position.minScrollExtent) {
    return KeyEventResult.ignored;
  }
  final forward =
      (key == LogicalKeyboardKey.pageDown) !=
      (position.axisDirection == AxisDirection.up);
  final target =
      (position.pixels + (forward ? .8 : -.8) * position.viewportDimension)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
  if (target != position.pixels) {
    if (AppMotion.reduced(focus)) {
      position.jumpTo(target);
    } else {
      unawaited(
        position.animateTo(
          target,
          duration: AppMotion.press,
          curve: AppMotion.curve,
        ),
      );
    }
  }
  return KeyEventResult.handled;
}

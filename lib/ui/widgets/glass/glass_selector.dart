import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/glass_style.dart';
import '../choice_panel.dart';
import 'glass_popup_transition.dart';
import 'glass_surface.dart';
import 'glass_feedback.dart';

/// 平台/站源共用的锚定玻璃下拉。长列表在面板内部滚动，不撑出安全区。
Future<T?> showGlassSelector<T>({
  required BuildContext anchor,
  required List<ChoiceOption<T>> options,
  required T selected,
  ChoiceAction? action,
  Key? menuKey,
}) {
  final box = anchor.findRenderObject() as RenderBox;
  final navigator = Navigator.of(anchor, rootNavigator: true);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final desired = math.min(
    360.0,
    12.0 + (options.length + (action == null ? 0 : 1)) * 48,
  );
  return navigator.push(
    GlassPopupRoute<T>(
      context: anchor,
      builder: (context, animation) => GlassAnchoredPopup(
        anchor: rect,
        width: 188,
        maxHeight: desired,
        animation: animation,
        child: GlassSurface(
          role: GlassRole.panel,
          key: menuKey,
          radius: GlassRadius.card,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (final option in options)
                  GlassFeedback(
                    radius: 12,
                    child: ListTile(
                      dense: true,
                      title: Text(
                        option.label,
                        style: const TextStyle(fontSize: 16),
                      ),
                      selected: option.value == selected,
                      trailing: option.value == selected
                          ? const Icon(Icons.check_rounded, size: 16)
                          : null,
                      onTap: () => Navigator.pop(context, option.value),
                    ),
                  ),
                if (action case final action?)
                  GlassFeedback(
                    radius: 12,
                    child: ListTile(
                      dense: true,
                      title: Text(
                        action.label,
                        style: const TextStyle(fontSize: 16),
                      ),
                      trailing: Icon(action.icon, size: 16),
                      onTap: () {
                        Navigator.pop(context);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (anchor.mounted) action.onPressed();
                        });
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

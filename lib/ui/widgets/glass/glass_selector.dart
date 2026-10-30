import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/glass_style.dart';
import '../choice_panel.dart';
import 'glass_surface.dart';

/// 平台/站源共用的锚定玻璃下拉。长列表在面板内部滚动，不撑出安全区。
Future<T?> showGlassSelector<T>({
  required BuildContext anchor,
  required List<ChoiceOption<T>> options,
  required T selected,
  ChoiceAction? action,
  Key? menuKey,
}) {
  final box = anchor.findRenderObject() as RenderBox;
  final origin = box.localToGlobal(Offset.zero);
  final media = MediaQuery.of(anchor);
  final width = math.min(188.0, math.max(0.0, media.size.width - 32));
  final safeTop = media.padding.top + 8;
  final safeBottom = media.size.height - media.padding.bottom - 8;
  final below = origin.dy + box.size.height + 6;
  final desired = math.min(
    360.0,
    12.0 + (options.length + (action == null ? 0 : 1)) * 48,
  );
  final availableBelow = safeBottom - below;
  final useBelow = availableBelow >= math.min(desired, 144);
  final available = math.max(
    0.0,
    useBelow ? availableBelow : origin.dy - safeTop - 6,
  );
  final height = math.min(desired, available);
  final top = useBelow ? below : math.max(safeTop, origin.dy - height - 6);
  return showDialog<T>(
    context: anchor,
    barrierColor: Colors.black26,
    useSafeArea: false,
    builder: (context) => Stack(
      children: [
        Positioned(
          left: origin.dx.clamp(16.0, media.size.width - width - 16).toDouble(),
          top: top,
          width: width,
          child: GlassSurface(
            key: menuKey,
            radius: GlassRadius.card,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: height),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  for (final option in options)
                    ListTile(
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
                  if (action case final action?)
                    ListTile(
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
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

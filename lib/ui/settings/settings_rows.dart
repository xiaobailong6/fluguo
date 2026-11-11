import 'package:flutter/material.dart';
import '../widgets/app_notice.dart';

import '../app_scope.dart';
import '../widgets/focus_ring.dart';
import '../widgets/glass/glass_dialog.dart';
import '../widgets/group_card.dart';

bool settingsSplit(BuildContext context) =>
    switch (AppScope.formFactorOf(context)) {
      FormFactor.phone => false,
      FormFactor.television => true,
      FormFactor.pad ||
      FormFactor.window => MediaQuery.sizeOf(context).width >= 840,
    };

Future<void> saveSetting(
  BuildContext context,
  Future<void> Function() change,
) => change().catchError((Object failure) {
  if (context.mounted) {
    showAppNotice(context, '$failure');
  }
});

Future<T?> showOptionDialog<T>(
  BuildContext context, {
  required String title,
  required Map<T, String> options,
  required T? selected,
}) => showGlassDialog<T>(
  context,
  maxWidth: 340,
  builder: (context) {
    final text = Theme.of(context).textTheme;
    // 玻璃容器、居中与最大宽度都由 showGlassDialog 提供，这里只管选项列表。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Text(title, style: text.headlineSmall),
        ),
        // 选项多时在弹窗内部滚动，而不是把弹窗顶出屏幕。
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final option in options.entries)
                  TileFocus(
                    builder: (focusNode) => ListTile(
                      focusNode: focusNode,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 24,
                      ),
                      autofocus: option.key == selected,
                      selected: option.key == selected,
                      title: Text(option.value),
                      trailing: option.key == selected
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => Navigator.pop(context, option.key),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  },
);

class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => GroupCard(
    children: [
      for (final (index, child) in children.indexed) ...[
        if (index > 0) const Divider(indent: 16, endIndent: 16),
        child,
      ],
    ],
  );
}

class SwitchTile extends StatelessWidget {
  const SwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => TileFocus(
    builder: (focusNode) => SwitchListTile(
      focusNode: focusNode,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      value: value,
      onChanged: onChanged,
    ),
  );
}

class ValueTile<T> extends StatelessWidget {
  const ValueTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.options,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final String? subtitle;
  final Map<T, String> options;
  final T? value;
  final ValueChanged<T>? onChanged;

  Future<void> _choose(BuildContext context) async {
    final selection = await showOptionDialog<T>(
      context,
      title: title,
      options: options,
      selected: value,
    );
    if (selection != null && selection != value) onChanged?.call(selection);
  }

  @override
  Widget build(BuildContext context) {
    final label = options[value];
    final enabled = onChanged != null;
    final onTap = enabled ? () => _choose(context) : null;
    if (!settingsSplit(context)) {
      return SettingsTile(
        title: title,
        subtitle: subtitle,
        value: label,
        enabled: enabled,
        onTap: onTap,
      );
    }
    final colors = Theme.of(context).colorScheme;
    return SettingsTile(
      title: title,
      subtitle: subtitle,
      enabled: enabled,
      onTap: onTap,
      trailing: label == null
          ? null
          : Container(
              height: 40,
              padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
              decoration: BoxDecoration(
                border: Border.all(
                  color: enabled ? colors.outline : colors.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: enabled
                          ? colors.onSurface
                          : colors.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: enabled
                        ? colors.onSurface
                        : colors.onSurface.withValues(alpha: 0.38),
                  ),
                ],
              ),
            ),
    );
  }
}

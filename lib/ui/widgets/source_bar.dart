import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'bar_button.dart';
import 'search_field.dart';
import 'source_header.dart';

class SourceBar extends StatelessWidget {
  const SourceBar({
    super.key,
    required this.source,
    required this.onSwitchSource,
    required this.onOpenSearch,
    required this.onSearchSubmitted,
    this.searchController,
    this.televisionLeading,
    this.actions = const [],
  });
  final String source;
  final void Function(BuildContext anchor) onSwitchSource;
  final VoidCallback onOpenSearch;
  final ValueChanged<String> onSearchSubmitted;
  final TextEditingController? searchController;
  final Widget? televisionLeading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final form = AppScope.formFactorOf(context);
    final wide = form == FormFactor.pad || form == FormFactor.window;
    final hint = '在 $source 中搜索';
    return LayoutBuilder(
      builder: (context, constraints) => SourceHeader(
        title: source,
        tooltip: '切换站源',
        onSwitch: onSwitchSource,
        televisionLeading: televisionLeading,
        actions: [
          // 窄桌面窗口退回搜索按钮，避免输入框挤没站源标题。
          if (wide && constraints.maxWidth >= 640)
            SizedBox(
              width: constraints.maxWidth >= 900 ? 320 : 240,
              child: SearchField(
                hint: hint,
                controller: searchController,
                onSubmitted: onSearchSubmitted,
              ),
            )
          else
            BarButton(
              icon: Icons.search_rounded,
              tooltip: hint,
              onPressed: onOpenSearch,
            ),
          ...actions,
        ],
      ),
    );
  }
}

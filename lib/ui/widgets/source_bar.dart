import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'bar_button.dart';
import 'search_field.dart';

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
    final television = form == FormFactor.television;
    final wide = form == FormFactor.pad || form == FormFactor.window;
    final hint = '在 $source 中搜索';
    final title = Builder(
      builder: (anchor) => Tooltip(
        message: '切换站源',
        child: TextButton(
          onPressed: () => onSwitchSource(anchor),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  source,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: television ? 16 : 28,
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              const Icon(Icons.arrow_drop_down_rounded),
            ],
          ),
        ),
      ),
    );
    return SizedBox(
      height: television ? 48 : 52,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          television ? 0 : 12,
          0,
          television ? 0 : 8,
          0,
        ),
        child: Row(
          spacing: television ? 10 : 4,
          children: [
            if (television) ...[?televisionLeading, const Spacer()],
            if (television)
              Flexible(child: title)
            else
              Expanded(
                child: Align(alignment: Alignment.centerLeft, child: title),
              ),
            if (wide)
              SizedBox(
                width: MediaQuery.sizeOf(context).width >= 900 ? 320 : 240,
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
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../widgets/app_notice.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../search/search_page.dart';
import '../shell/app_shell.dart';
import '../widgets/choice_panel.dart';
import '../widgets/glass/glass_selector.dart';

Future<void> pickSource(BuildContext anchor, LocalStore store) async {
  final value = await showGlassSelector<String>(
    anchor: anchor,
    options: [
      for (final source in store.sources) ChoiceOption(source.id, source.name),
    ],
    selected: store.source,
    menuKey: const ValueKey('short-source-menu'),
  );
  if (value == null || value == store.source) return;
  try {
    await store.setCatalogSource(value);
  } catch (_) {
    if (!anchor.mounted) return;
    showAppNotice(anchor, '未能切换站源，请重试');
  }
}

Future<void> openSearch(
  BuildContext context,
  LocalStore store,
  SourceSite source, {
  String query = '',
}) => openPage<void>(
  context,
  (_) => SearchPage(store: store, source: source, query: query),
);

import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../live_history.dart';
import '../../recent_history.dart';
import '../../history_retention.dart';
import '../widgets/recent_poster.dart';
import '../../watch_history.dart';
import '../app_scope.dart';
import '../settings/settings_rows.dart';
import '../widgets/drama_grid.dart';
import '../widgets/drama_tile.dart';
import '../widgets/focus_ring.dart';
import '../widgets/search_field.dart';
import '../widgets/status_view.dart';

typedef _View = ({
  List<RecentEntry> history,
  List<({String id, String name})> sources,
  String source,
  List<RecentEntry> shown,
  Set<String>? selection,
});

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.store, this.onOpenLive});
  final LocalStore store;
  final void Function(LiveHistoryEntry)? onOpenLive;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _query = TextEditingController();
  final _firstPoster = FocusNode();
  final _editButton = FocusNode();
  final _searchField = FocusNode();
  var _source = '';
  var _kind = HistoryKind.all;
  late int _profileEpoch;
  late List<RecentEntry> _history;
  Set<String>? _selection;

  @override
  void initState() {
    super.initState();
    _profileEpoch = widget.store.profileEpoch;
    _refreshHistory();
    widget.store.addListener(_refreshHistory);
    _keepFocus(_firstPoster);
  }

  void _refreshHistory() {
    // 输入和筛选只读排序快照；Store 通知（含跨日清理/权限变化）才重新核对内容。
    _history = recentHistory(widget.store);
  }

  @override
  void didUpdateWidget(covariant HistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store == widget.store) return;
    oldWidget.store.removeListener(_refreshHistory);
    widget.store.addListener(_refreshHistory);
    _refreshHistory();
    _profileEpoch = widget.store.profileEpoch;
    _selection = null;
    _source = '';
  }

  @override
  void dispose() {
    widget.store.removeListener(_refreshHistory);
    _query.dispose();
    _firstPoster.dispose();
    _editButton.dispose();
    _searchField.dispose();
    super.dispose();
  }

  void _keepFocus(FocusNode target, [FocusNode? fallback]) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !AppScope.of(context).television) return;
        final focused = FocusManager.instance.primaryFocus;
        if (focused != null && focused is! FocusScopeNode) return;
        for (final node in [target, ?fallback]) {
          if (node.context?.mounted ?? false) {
            revealFocus(node);
            return;
          }
        }
      });

  void _startEditing() {
    setState(() => _selection = {});
    _keepFocus(_firstPoster);
  }

  void _finishEditing() {
    setState(() => _selection = null);
    _keepFocus(_editButton);
  }

  void _toggle(String id) => setState(() {
    final selection = {...?_selection};
    if (!selection.remove(id)) selection.add(id);
    _selection = selection;
  });

  Future<void> _remove(Set<String> ids, {required bool clear}) async {
    if (ids.isEmpty) return;
    final epoch = widget.store.profileEpoch;
    final colors = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(clear ? '清空观看记录？' : '删除 ${ids.length} 条观看记录？'),
        content: Text(
          clear ? '将删除当前列出的 ${ids.length} 条观看记录，追剧不受影响。' : '追剧不受影响。',
        ),
        actions: [
          FocusRing(
            radius: 20,
            child: TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
          ),
          FocusRing(
            radius: 20,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(clear ? '清空' : '删除'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await saveSetting(
      context,
      () => widget.store.removeRecentHistory(ids, profileEpoch: epoch),
    );
    if (!mounted) return;
    setState(() => _selection = null);
    _keepFocus(_firstPoster, _searchField);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.store, _query]),
    builder: (context, _) {
      if (_profileEpoch != widget.store.profileEpoch) {
        _profileEpoch = widget.store.profileEpoch;
        _selection = null;
        _source = '';
      }
      // 输入时仍按当前时钟过滤过期项，但不重新读取或排序 Store。
      final now = widget.store.recentHistoryState().now;
      final history = _history
          .where((entry) => retainedWatchTime(entry.updatedAt, now))
          .toList(growable: false);
      final filtered = history.where(
        (entry) => matchesHistoryKind(entry, _kind),
      );
      final labels = <String, String>{
        for (final entry in filtered) entry.sourceKey: recentSourceLabel(entry),
      };
      final sources = [
        for (final entry in labels.entries) (id: entry.key, name: entry.value),
      ];
      final source = labels.containsKey(_source) ? _source : '';
      final shown = [
        for (final entry in filtered)
          if ((source.isEmpty || entry.sourceKey == source) &&
              entry.matches(_query.text))
            entry,
      ];
      final view = (
        history: history,
        sources: sources,
        source: source,
        shown: shown,
        selection: _selection?.intersection({
          for (final entry in shown) entry.key,
        }),
      );
      return PopScope(
        canPop: _selection == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _finishEditing();
        },
        child: switch (AppScope.formFactorOf(context)) {
          FormFactor.phone => _phone(context, view),
          FormFactor.pad || FormFactor.window => _wide(context, view),
          FormFactor.television => _television(context, view),
        },
      );
    },
  );

  Set<String> _ids(_View view) => {for (final entry in view.shown) entry.key};

  Widget _search({double height = 40, FocusNode? focusNode}) => SearchField(
    hint: '搜索观看记录',
    controller: _query,
    focusNode: focusNode,
    height: height,
    onSubmitted: (_) {},
    letterKeyboard: widget.store.televisionKeyboard,
    matches: (query) async {
      final now = widget.store.recentHistoryState().now;
      return {
        for (final entry in _history)
          if (retainedWatchTime(entry.updatedAt, now) && entry.matches(query))
            entry.title,
      }.toList();
    },
  );

  Widget _textButton(
    String label,
    VoidCallback? onPressed, {
    IconData? icon,
    FocusNode? focusNode,
  }) => FocusRing(
    radius: 20,
    child: icon == null
        ? TextButton(
            focusNode: focusNode,
            onPressed: onPressed,
            child: Text(label),
          )
        : TextButton.icon(
            focusNode: focusNode,
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
  );

  List<Widget> _browseActions(_View view, {bool icons = true}) => [
    _textButton(
      '编辑',
      view.shown.isEmpty ? null : _startEditing,
      icon: icons ? Icons.check_box_outlined : null,
      focusNode: _editButton,
    ),
    _textButton(
      '清空',
      view.shown.isEmpty ? null : () => _remove(_ids(view), clear: true),
      icon: icons ? Icons.delete_outline_rounded : null,
    ),
  ];

  Widget _selectAll(_View view) {
    final all = _ids(view);
    final everything = view.selection!.length == all.length;
    return _textButton(
      everything ? '取消全选' : '全选',
      () => setState(() => _selection = everything ? {} : all),
    );
  }

  Widget _deleteButton(_View view) {
    final colors = Theme.of(context).colorScheme;
    final selection = view.selection!;
    return FocusRing(
      radius: 20,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: colors.error,
          foregroundColor: colors.onError,
        ),
        onPressed: selection.isEmpty
            ? null
            : () => _remove(selection, clear: false),
        icon: const Icon(Icons.delete_outline_rounded, size: 18),
        label: const Text('删除'),
      ),
    );
  }

  List<Widget> _editActions(_View view) => [
    _selectAll(view),
    _deleteButton(view),
    _textButton('完成', _finishEditing),
  ];

  Widget _title(_View view, double size) => Semantics(
    header: true,
    child: Text(
      view.selection == null ? '观看记录' : '已选择 ${view.selection!.length} 部',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: size, fontWeight: FontWeight.w800),
    ),
  );

  Widget _sourceChip(String id, String label, _View view) => FocusRing(
    radius: 8,
    child: ChoiceChip(
      key: ValueKey('history-source-$id'),
      label: Text(label),
      showCheckmark: false,
      selected: view.source == id,
      onSelected: (_) => setState(() => _source = id),
    ),
  );

  Widget _sources(_View view, {required double inset}) {
    final text = Theme.of(context).textTheme;
    final sourceLabel = switch (_kind) {
      HistoryKind.drama => '站源',
      HistoryKind.live => '直播平台',
      HistoryKind.all => '站源 / 平台',
    };
    final kinds = DropdownButton<HistoryKind>(
      key: const ValueKey('history-kind-selector'),
      value: _kind,
      underline: const SizedBox.shrink(),
      borderRadius: BorderRadius.circular(16),
      items: [
        for (final (kind, label) in [
          (HistoryKind.all, '全部内容'),
          (HistoryKind.drama, '短剧'),
          (HistoryKind.live, '直播'),
        ])
          DropdownMenuItem(
            key: ValueKey('history-kind-${kind.name}'),
            value: kind,
            child: Text(label),
          ),
      ],
      onChanged: (kind) {
        if (kind == null || kind == _kind) return;
        setState(() {
          _kind = kind;
          _source = '';
          _selection = _selection == null ? null : {};
        });
      },
    );
    final platforms = SingleChildScrollView(
      key: const ValueKey('history-source-filters'),
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 8,
        children: [
          _sourceChip('', '不限', view),
          for (final site in view.sources)
            _sourceChip(site.id, site.name, view),
        ],
      ),
    );
    final type = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('内容类型', style: text.labelMedium),
        kinds,
      ],
    );
    final sources = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(sourceLabel, style: text.labelMedium),
        platforms,
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 4, inset, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 大字体/窄窗改成上下两层，类型下拉与来源平铺仍保持清晰层级。
          if (constraints.maxWidth < 340 ||
              MediaQuery.textScalerOf(context).scale(14) > 22) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [type, sources],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 20,
            children: [
              type,
              Expanded(child: sources),
            ],
          );
        },
      ),
    );
  }

  Widget _phone(BuildContext context, _View view) {
    final selection = view.selection;
    return Scaffold(
      appBar: selection == null
          ? AppBar(
              title: const Text('观看记录'),
              actions: [
                ..._browseActions(view, icons: false),
                const SizedBox(width: 8),
              ],
            )
          : AppBar(
              leading: IconButton(
                tooltip: '退出编辑',
                onPressed: _finishEditing,
                icon: const Icon(Icons.close_rounded),
              ),
              title: Text('已选择 ${selection.length} 部'),
              actions: [_selectAll(view), const SizedBox(width: 8)],
            ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: _content(
          context,
          view,
          inset: 16,
          header: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: _search(),
            ),
            _sources(view, inset: 16),
          ],
        ),
      ),
      bottomNavigationBar: selection == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(height: 48, child: _deleteButton(view)),
              ),
            ),
    );
  }

  Widget _wide(BuildContext context, _View view) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: _content(
        context,
        view,
        inset: 24,
        header: [
          LayoutBuilder(
            builder: (context, constraints) => Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 24, 8),
              child: SizedBox(
                height: 48,
                child: Row(
                  spacing: 8,
                  children: [
                    if (view.selection == null)
                      const BackButton()
                    else
                      IconButton(
                        tooltip: '退出编辑',
                        onPressed: _finishEditing,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    Expanded(child: _title(view, 28)),
                    if (view.selection == null) ...[
                      SizedBox(
                        width: (constraints.maxWidth - 400).clamp(160.0, 280.0),
                        child: _search(),
                      ),
                      ..._browseActions(view),
                    ] else
                      ..._editActions(view),
                  ],
                ),
              ),
            ),
          ),
          _sources(view, inset: 24),
        ],
      ),
    ),
  );

  Widget _television(BuildContext context, _View view) => Scaffold(
    body: SafeArea(
      child: _content(
        context,
        view,
        inset: televisionInset,
        top: 27,
        header: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              televisionInset,
              0,
              televisionInset,
              8,
            ),
            child: SizedBox(
              height: 48,
              child: Row(
                spacing: 12,
                children: [
                  Expanded(child: _title(view, 24)),
                  if (view.selection == null) ...[
                    SizedBox(
                      width: 260,
                      child: _search(focusNode: _searchField),
                    ),
                    ..._browseActions(view),
                  ] else
                    ..._editActions(view),
                ],
              ),
            ),
          ),
          _sources(view, inset: televisionInset),
        ],
      ),
    ),
  );

  (int, double, double) _grid(BuildContext context, double width) {
    switch (AppScope.formFactorOf(context)) {
      case FormFactor.phone:
        return (3, 10, 20);
      case FormFactor.television:
        return (6, 20, 24);
      case FormFactor.pad || FormFactor.window:
        final desktop = AppScope.formFactorOf(context) == FormFactor.window;
        final minimum = desktop ? 140.0 : 120.0;
        final gap = desktop ? 18.0 : 16.0;
        final columns = ((width + gap) / (minimum + gap)).floor().clamp(1, 99);
        return (columns, gap, desktop ? 22 : 20);
    }
  }

  Widget _content(
    BuildContext context,
    _View view, {
    required double inset,
    double top = 0,
    required List<Widget> header,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth - inset * 2;
      final (columns, gap, runGap) = _grid(context, width);
      final tile = (width - gap * (columns - 1)) / columns;
      final now = DateTime.now();
      final periods = <WatchPeriod, List<RecentEntry>>{};
      for (final entry in view.shown) {
        periods
            .putIfAbsent(WatchPeriod.of(entry.updatedAt, now), () => [])
            .add(entry);
      }
      final first = view.shown.firstOrNull;
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.only(top: top),
            sliver: SliverList.list(children: header),
          ),
          if (view.shown.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: StatusView(
                title: view.history.isEmpty ? '还没有观看记录' : '没有匹配的记录',
                icon: view.history.isEmpty
                    ? Icons.history_rounded
                    : Icons.search_off_rounded,
              ),
            )
          else
            for (final MapEntry(key: period, value: entries)
                in periods.entries) ...[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset + 4, 12, inset, 10),
                sliver: SliverToBoxAdapter(
                  child: Semantics(
                    header: true,
                    child: Text(
                      period.label,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: gap,
                    mainAxisSpacing: runGap,
                    mainAxisExtent: ProgressPoster.extentFor(context, tile),
                  ),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return Focus(
                      key: ValueKey(entry.key),
                      canRequestFocus: false,
                      skipTraversal: true,
                      onKeyEvent: (_, event) =>
                          wrapGridRow(index, columns, entries.length, event),
                      child: _poster(
                        context,
                        entry,
                        tile,
                        view.selection,
                        focusNode: entry == first ? _firstPoster : null,
                      ),
                    );
                  },
                ),
              ),
            ],
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: AppScope.of(context).television ? 27 : 32,
            ),
          ),
        ],
      );
    },
  );

  Widget _poster(
    BuildContext context,
    RecentEntry entry,
    double width,
    Set<String>? selection, {
    FocusNode? focusNode,
  }) => RecentPoster(
    store: widget.store,
    entry: entry,
    width: width,
    focusNode: focusNode,
    selected: selection?.contains(entry.key),
    onToggle: selection == null ? null : () => _toggle(entry.key),
    onMore: selection == null
        ? () => setState(() => _selection = {entry.key})
        : null,
    onOpenLive: widget.onOpenLive,
  );
}

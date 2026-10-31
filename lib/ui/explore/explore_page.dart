import 'package:flutter/material.dart';

import '../../explore_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../shell/app_shell.dart';
import '../detail/detail_page.dart';
import '../widgets/bar_button.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';
import '../widgets/drama_grid.dart';
import '../widgets/glass/glass_header.dart';
import '../widgets/page_header.dart';
import '../widgets/source_bar.dart';
import '../widgets/status_view.dart';
import 'explore_hero.dart';
import 'source_actions.dart';

class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key, required this.store});
  final LocalStore store;

  @override
  State<ExplorePage> createState() => ExplorePageState();
}

class ExplorePageState extends State<ExplorePage> {
  ExploreFeed? _explore;
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _tabsKey = GlobalKey();
  String _shown = '';

  /// 悬浮顶栏量出来的高度，作为滚动内容顶部的占位。
  double _headerHeight = 108;

  /// 顶栏尺寸回填。变化小于半像素直接忽略，避免反复 setState。
  void _headerSized(double height) {
    if (!mounted || (height - _headerHeight).abs() < 0.5) return;
    setState(() => _headerHeight = height);
  }

  /// 顶栏是否已收起（上滑收起、下滑露出）。
  final _headerHidden = ValueNotifier(false);
  double _lastPixels = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_trackHeader);
  }

  /// 上滑收起顶栏、下滑露出来。
  ///
  /// 位移小于 3px 直接忽略：手势回落和惯性末端会产生方向抖动，
  /// 不设阈值的话顶栏会来回闪。
  void _trackHeader() {
    if (!_scroll.hasClients) return;
    final pixels = _scroll.position.pixels;
    final delta = pixels - _lastPixels;
    _lastPixels = pixels;
    if (pixels <= 12) {
      _setHeaderHidden(false);
    } else if (delta > 3 && pixels > 96) {
      _setHeaderHidden(true);
    } else if (delta < -3) {
      _setHeaderHidden(false);
    }
  }

  void _setHeaderHidden(bool hidden) {
    if (hidden == _headerHidden.value) return;
    // 滚动方向改变只更新顶栏，避免重建整页海报网格。
    _headerHidden.value = hidden;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _explore ??= ExploreFeed(AppScope.of(context).repository, widget.store);
  }

  @override
  void dispose() {
    _explore?.dispose();
    _headerHidden.dispose();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _explore?.refresh();
  }

  /// 供底栏「回到顶部」调用。
  void scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _open(Drama drama) => openPage<void>(
    context,
    (_) => DetailPage(store: widget.store, drama: drama),
  );

  Future<void> _pickCategory(BuildContext anchor) async {
    final explore = _explore!;
    final value = await showChoicePanel<String>(
      context: anchor,
      title: '全部分类',
      options: [for (final tab in explore.tabs) ChoiceOption(tab.id, tab.name)],
      selected: explore.tab.id,
      grid: ChoiceGrid.categories,
    );
    if (value != null) explore.select(value);
  }

  void _searchSubmitted(SourceSite source, String query) {
    if (query.trim().isEmpty) return;
    _search.clear();
    openSearch(context, widget.store, source, query: query);
  }

  void _resetScroll(ExploreFeed explore) {
    final shown = '${explore.source?.id}|${explore.tab.id}';
    if (shown == _shown) return;
    _shown = shown;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _explore!,
    builder: (context, _) {
      final explore = _explore!;
      final source = explore.source;
      final form = AppScope.formFactorOf(context);
      final television = form == FormFactor.television;
      final desktop = form == FormFactor.window;
      _resetScroll(explore);
      if (source == null) {
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (!television) const PageHeader(title: '短剧'),
                const Expanded(
                  child: StatusView(
                    title: '暂无可用站源',
                    message: '请在站源管理中开启站源，或联系管理员开放权限。',
                    icon: Icons.public_off_rounded,
                  ),
                ),
              ],
            ),
          ),
        );
      }
      final inset = switch (form) {
        FormFactor.phone => 16.0,
        FormFactor.pad || FormFactor.window => 24.0,
        FormFactor.television => televisionInset,
      };
      final tabs = Padding(
        padding: EdgeInsets.symmetric(
          horizontal: form == FormFactor.phone ? 0 : inset,
        ),
        child: CategoryTabs<String>(
          key: _tabsKey,
          options: [
            for (final tab in explore.tabs) ChoiceOption(tab.id, tab.name),
          ],
          selected: explore.tab.id,
          onSelected: explore.select,
          onShowAll: _pickCategory,
        ),
      );
      final content = _content(
        explore,
        inset,
        television,
        tabs,
        television ? 0 : _headerHeight,
      );
      final sourceBar = SourceBar(
        source: source.name,
        searchController: _search,
        onSwitchSource: (anchor) => pickSource(anchor, widget.store),
        onOpenSearch: () => openSearch(context, widget.store, source),
        onSearchSubmitted: (query) => _searchSubmitted(source, query),
        actions: [
          if (desktop)
            BarButton(
              icon: Icons.refresh_rounded,
              tooltip: '刷新',
              onPressed: explore.refresh,
            ),
        ],
      );
      // 顶栏浮在内容之上：玻璃背后得有内容滚过去，材质才成立。
      final body = Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ValueListenableBuilder<bool>(
              valueListenable: _headerHidden,
              builder: (context, hidden, child) {
                final reduceMotion = MediaQuery.disableAnimationsOf(context);
                return AnimatedSlide(
                  offset: hidden ? const Offset(0, -1) : Offset.zero,
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: IgnorePointer(
                    ignoring: hidden,
                    child: AnimatedOpacity(
                      opacity: hidden ? 0 : 1,
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      child: child,
                    ),
                  ),
                );
              },
              child: GlassHeader(
                onHeight: _headerSized,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [sourceBar, tabs],
                ),
              ),
            ),
          ),
        ],
      );
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: television
              ? Column(
                  children: [
                    if (explore.feed!.items.isEmpty) tabs,
                    Expanded(child: content),
                  ],
                )
              // 下拉指示器要压在顶栏之上：RefreshIndicator 包住整个 Stack 之后，
              // 它自己的指示器才会盖在悬浮玻璃卡片上，不再被卡片挡住。
              : RefreshIndicator(onRefresh: explore.refresh, child: body),
        ),
      );
    },
  );

  Widget _content(
    ExploreFeed explore,
    double inset,
    bool television,
    Widget tabs,
    double topInset,
  ) {
    final feed = explore.feed!;
    final hero = _hero(explore);
    final items = explore.items;
    if (feed.items.isEmpty) {
      if (feed.loading) return const StatusView.loading();
      if (feed.error.isNotEmpty) {
        return StatusView(
          title: '暂时无法加载',
          message: feed.error,
          icon: Icons.cloud_off_rounded,
          action: '重试',
          onAction: () => feed.reload(force: true),
        );
      }
      return StatusView(
        title: '这里还没有剧',
        message: '换一个分类看看',
        icon: Icons.inbox_outlined,
        action: '刷新',
        onAction: () => feed.reload(force: true),
      );
    }
    final phone = AppScope.formFactorOf(context) == FormFactor.phone;
    final desktop = AppScope.formFactorOf(context) == FormFactor.window;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scroll = CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (topInset > 0)
              SliverToBoxAdapter(child: SizedBox(height: topInset)),
            if (television)
              SliverPadding(
                padding: const EdgeInsets.only(top: 8),
                sliver: SliverToBoxAdapter(child: tabs),
              ),
            if (hero != null)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, phone ? 12 : 16, inset, 0),
                sliver: SliverToBoxAdapter(child: hero),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, desktop ? 20 : 16, inset, 0),
              sliver: DramaSliverGrid(
                width: constraints.maxWidth - inset * 2,
                items: items,
                rankOf: explore.rankOf,
                autofocus: television && hero == null,
                onOpen: _open,
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                inset,
                8,
                inset,
                (television ? 27 : 16) + bottomBarInset(context),
              ),
              sliver: SliverToBoxAdapter(child: FeedFooter(feed: feed)),
            ),
          ],
        );
        return Stack(
          children: [
            // 下拉刷新由外层 RefreshIndicator 统一接管，这里只负责自动加载下一页。
            AutoLoadMore(feed: feed, child: scroll),
            if (feed.loading)
              const Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        );
      },
    );
  }

  Widget? _hero(ExploreFeed explore) {
    if (explore.resume case final entry?) {
      final drama = entry.drama;
      final total = drama.episodes;
      final next = entry.finished && entry.episode < total
          ? entry.episode + 1
          : entry.episode;
      return ExploreHero(
        drama: drama,
        kicker: '继续观看',
        meta: total > 0
            ? '看到第 ${entry.episode} 集 · 共 $total 集'
            : '看到第 ${entry.episode} 集',
        progress: total > 0 ? entry.episode / total : null,
        action: '继续第 $next 集',
        onPlay: () => _open(drama),
        onDetail: () => _open(drama),
      );
    }
    if (explore.featured case final drama?) {
      return ExploreHero(
        drama: drama,
        kicker: '今日推荐',
        meta: [
          if (drama.category.isNotEmpty) drama.category,
          if (drama.episodes > 0) '共 ${drama.episodes} 集',
        ].join(' · '),
        action: '立即观看',
        onPlay: () => _open(drama),
        onDetail: () => _open(drama),
      );
    }
    return null;
  }
}

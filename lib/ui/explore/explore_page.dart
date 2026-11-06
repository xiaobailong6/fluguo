import 'package:flutter/material.dart';
import '../widgets/smooth_scroll.dart';

import '../../explore_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_motion.dart';
import '../app_scope.dart';
import '../shell/app_shell.dart';
import '../detail/detail_page.dart';
import '../player/direct_playback_page.dart';
import '../widgets/bar_button.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';
import '../widgets/drama_grid.dart';
import '../widgets/glass/glass_header.dart';
import '../widgets/page_header.dart';
import '../widgets/source_bar.dart';
import '../widgets/status_view.dart';
import '../widgets/scroll_chrome.dart';
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
  bool _opening = false;

  /// 悬浮顶栏量出来的高度，作为滚动内容顶部的占位。
  double _headerHeight = 108;

  /// 顶栏尺寸回填。变化小于半像素直接忽略，避免反复 setState。
  void _headerSized(double height) {
    if (!mounted || (height - _headerHeight).abs() < 0.5) return;
    setState(() => _headerHeight = height);
  }

  /// 顶栏是否已收起（上滑收起、下滑露出）。
  final _headerHidden = ScrollChromeController(hideAfter: 96);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_trackHeader);
  }

  /// 上滑收起顶栏、下滑露出来。
  ///
  /// 累计同向位移，小幅回弹不会反复切态，慢滑也不会因单帧过小失效。
  void _trackHeader() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    _headerHidden.track(
      position.pixels,
      minExtent: position.minScrollExtent,
      maxExtent: position.maxScrollExtent,
    );
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
  Future<void> scrollToTop() async {
    if (!_scroll.hasClients) return;
    _headerHidden.reset(pixels: _scroll.position.pixels);
    await smoothScrollToTop(context, _scroll.position);
  }

  Future<void> _open(Drama drama) async {
    if (_opening || !widget.store.allowsSource(drama.source)) return;
    _opening = true;
    final showDetails = widget.store.showDramaDetails;
    try {
      await openPage<void>(
        context,
        (_) => showDetails
            ? DetailPage(store: widget.store, drama: drama)
            : DirectPlaybackPage(store: widget.store, drama: drama),
      );
    } finally {
      _opening = false;
    }
  }

  void _openDetails(Drama drama) => openPage<void>(
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
              builder: (context, hidden, child) => ScrollChromeVisibility(
                key: const ValueKey('explore-chrome-motion'),
                hidden: hidden,
                hiddenOffset: const Offset(0, -1.15),
                child: child!,
              ),
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
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, phone ? 12 : 16, inset, 0),
              sliver: SliverToBoxAdapter(
                // 大卡片的出现、消失和内容切换共用一套过渡：Fade + 上滑 + 微缩放，
                // 高度变化交给 AnimatedSize，整块卡片不再“啪”地插入或消失。
                child: AnimatedSize(
                  duration: AppMotion.duration(context, AppMotion.chrome),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 560),
                    reverseDuration: const Duration(milliseconds: 400),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInOutCubic,
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topCenter,
                      children: [
                        for (final child in previous) child,
                        if (current != null) current,
                      ],
                    ),
                    transitionBuilder: (child, animation) {
                      final curved = CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                        reverseCurve: Curves.easeInOutCubic,
                      );
                      return FadeTransition(
                        opacity: curved,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, .12),
                            end: Offset.zero,
                          ).animate(curved),
                          child: ScaleTransition(
                            scale: Tween(begin: .97, end: 1.0).animate(curved),
                            alignment: Alignment.topCenter,
                            child: child,
                          ),
                        ),
                      );
                    },
                    child: hero ?? const SizedBox(width: double.infinity),
                  ),
                ),
              ),
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
      return KeyedSubtree(
        // 集数与看完状态也进 key：进度变化同样走一次过渡，不会静默换内容。
        key: ValueKey('resume-${drama.id}-${entry.episode}-${entry.finished}'),
        child: ExploreHero(
          drama: drama,
          kicker: '继续观看',
          meta: total > 0
              ? '看到第 ${entry.episode} 集 · 共 $total 集'
              : '看到第 ${entry.episode} 集',
          progress: total > 0 ? entry.episode / total : null,
          action: '继续第 $next 集',
          onPlay: () => _open(drama),
          onDetail: () => _openDetails(drama),
        ),
      );
    }
    if (explore.featured case final drama?) {
      return KeyedSubtree(
        key: ValueKey('featured-${drama.id}'),
        child: ExploreHero(
          drama: drama,
          kicker: '今日推荐',
          meta: [
            if (drama.category.isNotEmpty) drama.category,
            if (drama.episodes > 0) '共 ${drama.episodes} 集',
          ].join(' · '),
          action: '立即观看',
          onPlay: () => _open(drama),
          onDetail: () => _openDetails(drama),
        ),
      );
    }
    return null;
  }
}

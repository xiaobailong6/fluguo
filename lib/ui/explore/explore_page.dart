import 'package:flutter/material.dart';
import '../widgets/smooth_scroll.dart';

import '../../explore_feed.dart';
import '../../drama_feed.dart';
import '../widgets/follow_pager.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_motion.dart';
import '../app_scope.dart';
import '../shell/app_shell.dart';
import '../detail/detail_page.dart';
import '../player/direct_playback_page.dart';
import '../widgets/app_notice.dart';
import '../widgets/bar_button.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';
import '../widgets/drama_grid.dart';
import '../widgets/follow_button.dart';
import '../widgets/glass/glass_header.dart';
import '../widgets/page_header.dart';
import '../widgets/source_bar.dart';
import '../widgets/status_view.dart';
import '../widgets/local_content_transition.dart';
import '../widgets/failure_recovery.dart';
import '../widgets/scroll_chrome.dart';
import 'explore_hero.dart';
import 'source_actions.dart';

class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key, required this.store});
  final LocalStore store;

  @override
  State<ExplorePage> createState() => ExplorePageState();
}

class ExplorePageState extends State<ExplorePage> with WidgetsBindingObserver {
  ExploreFeed? _explore;
  final _scroll = ScrollController();
  final _search = TextEditingController();
  String _shown = '';
  bool _opening = false;
  PageController _pager = PageController();
  String _pageIdentity = '';
  bool _paged = false;
  final _pageKeys = <String, GlobalKey<PagerScrollPageState>>{};
  bool _foreground = true;
  bool _routeActive = true;
  bool _tabActive = true;

  void _syncPrefetchVisibility() =>
      _explore?.setPrefetchActive(_foreground && _routeActive && _tabActive);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _syncPrefetchVisibility();
  }

  ScrollController? get _activeScroll =>
      _paged ? _pageKeys[_explore?.tab.id]?.currentState?.scroll : _scroll;

  void _syncPages() {
    final explore = _explore!;
    final identity =
        '${widget.store.profileEpoch}|${explore.source?.id}|${explore.tabs.map((tab) => tab.id).join('|')}';
    if (identity == _pageIdentity) return;
    _pageIdentity = identity;
    final old = _pager;
    _pager = PageController(
      initialPage: explore.tabs
          .indexWhere((tab) => tab.id == explore.tab.id)
          .clamp(0, explore.tabs.length),
    );
    _pageKeys.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  final _headerKey = GlobalKey();
  bool _measurementPending = false;

  // 首次布局不发尺寸通知；后续通知发生在布局期间，统一在帧末读取外框。
  void _measureHeader() {
    if (_measurementPending) return;
    _measurementPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementPending = false;
      final size = _headerKey.currentContext?.size;
      if (size != null) _headerSized(size.height);
    });
  }

  /// 悬浮顶栏量出来的高度，作为滚动内容顶部的占位。
  double _headerHeight = 108;

  /// 顶栏尺寸回填。变化小于半像素直接忽略，避免反复 setState。
  void _headerSized(double height) {
    if (!mounted || (height - _headerHeight).abs() < 0.5) return;
    setState(() => _headerHeight = height);
  }

  Widget _heroSize(BuildContext context, Widget child) {
    // 零时长 AnimatedSize 在隐藏 sliver 布局时可能同步触发重新布局。
    // 减少动画本就需要最终尺寸；正常模式继续使用原来的尺寸过渡。
    if (AppMotion.reduced(context)) return child;
    return AnimatedSize(
      duration: AppMotion.duration(context, AppMotion.chrome),
      curve: AppMotion.curve,
      alignment: Alignment.topCenter,
      child: child,
    );
  }

  /// 顶栏是否已收起（上滑收起、下滑露出）。
  final _headerHidden = ScrollChromeController(hideAfter: 96);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_trackHeader);
  }

  /// 上滑收起顶栏、下滑露出来。
  ///
  /// 累计同向位移，小幅回弹不会反复切态，慢滑也不会因单帧过小失效。
  void _trackHeader() {
    final scroll = _activeScroll;
    if (scroll == null || !scroll.hasClients) return;
    final position = scroll.position;
    _headerHidden.track(
      position.pixels,
      minExtent: position.minScrollExtent,
      maxExtent: position.maxScrollExtent,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_explore == null) {
      _explore = ExploreFeed(AppScope.of(context).repository, widget.store);
      _explore!.addListener(_syncPages);
      _syncPages();
    }
    final form = AppScope.formFactorOf(context);
    _paged = form == FormFactor.phone || form == FormFactor.pad;
    _tabActive = TickerMode.valuesOf(context).enabled;
    _routeActive = ModalRoute.isCurrentOf(context) ?? true;
    _syncPrefetchVisibility();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _explore?.dispose();
    _pager.dispose();
    _headerHidden.dispose();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    final scroll = _activeScroll;
    if (scroll != null && scroll.hasClients) scroll.jumpTo(0);
    await _explore?.refresh();
  }

  /// 供底栏「回到顶部」调用。
  Future<void> scrollToTop() async {
    final scroll = _activeScroll;
    if (scroll == null || !scroll.hasClients) return;
    _headerHidden.reset(pixels: scroll.position.pixels);
    await smoothScrollToTop(context, scroll.position);
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

  Future<void> _pickCategory(
    BuildContext anchor,
    List<ChoiceOption<String>> options,
  ) async {
    final explore = _explore!;
    final value = await showChoicePanel<String>(
      context: anchor,
      title: '全部分类',
      options: options,
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
      if (!_paged) _resetScroll(explore);
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
      final categories = explore.tabs;
      final options = [
        for (final tab in categories) ChoiceOption(tab.id, tab.name),
      ];
      final tabs = Padding(
        padding: EdgeInsets.symmetric(
          horizontal: form == FormFactor.phone ? 0 : inset,
        ),
        child: CategoryTabs<String>(
          options: options,
          selected: explore.tab.id,
          pager: _paged ? _pager : null,
          onSelected: explore.select,
          onShowAll: (anchor) => _pickCategory(anchor, options),
        ),
      );
      final content = _paged
          ? FollowPager(
              key: ValueKey(_pageIdentity),
              controller: _pager,
              index: categories.indexWhere((tab) => tab.id == explore.tab.id),
              count: categories.length,
              onSelected: (index) => explore.select(categories[index].id),
              itemBuilder: (context, index) {
                final tab = categories[index];
                return PagerScrollPage(
                  key: _pageKeys.putIfAbsent(
                    tab.id,
                    () => GlobalKey<PagerScrollPageState>(),
                  ),
                  onScroll: (_) {
                    if (tab.id == explore.tab.id) _trackHeader();
                  },
                  builder: (context, scroll) =>
                      _categoryContent(explore, tab, inset, scroll),
                );
              },
            )
          : _categoryContent(
              explore,
              explore.tab,
              inset,
              _scroll,
              televisionTabs: television ? tabs : null,
            );
      if (television) {
        return Scaffold(body: SafeArea(bottom: false, child: content));
      }
      // 历史写入只刷新顶栏；ExploreFeed 有意忽略无关 store 通知，
      // 不应为历史下拉把整页列表重新挂到 store 上。
      final sourceBar = ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final epoch = widget.store.profileEpoch;
          bool current() =>
              mounted &&
              !widget.store.locked &&
              widget.store.profileEpoch == epoch &&
              widget.store.source == source.id;
          return ValueListenableBuilder<bool>(
            valueListenable: _headerHidden,
            builder: (context, hidden, _) => SourceBar(
              key: ValueKey(('search', epoch, source.id, widget.store.locked)),
              source: source.name,
              searchController: _search,
              searchEnabled: !hidden && current(),
              recentSearches: current()
                  ? widget.store.recentSearches
                  : const [],
              onForgetSearch: (query) async {
                if (!current()) return;
                try {
                  await widget.store.forgetSearch(query);
                } catch (_) {
                  if (current() && context.mounted) {
                    showAppNotice(context, '搜索记录未能删除，请重试');
                  }
                }
              },
              onSwitchSource: (anchor) => pickSource(anchor, widget.store),
              onOpenSearch: () => openSearch(context, widget.store, source),
              onSearchSubmitted: (query) {
                if (current()) _searchSubmitted(source, query);
              },
              actions: [
                if (desktop)
                  BarButton(
                    icon: Icons.refresh_rounded,
                    tooltip: '刷新',
                    onPressed: explore.refresh,
                  ),
              ],
            ),
          );
        },
      );
      // 顶栏浮在内容之上：玻璃背后得有内容滚过去，材质才成立。
      _measureHeader();
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
              child: NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (_) {
                  _measureHeader();
                  return false;
                },
                child: GlassHeader(
                  key: _headerKey,
                  onHeight: (_) => _measureHeader(),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [sourceBar, tabs],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
      return Scaffold(
        body: SafeArea(
          bottom: false,
          // 下拉指示器要压在悬浮顶栏之上。
          child: RefreshIndicator(
            onRefresh: explore.refresh,
            notificationPredicate: (event) =>
                event.metrics.axis == Axis.vertical &&
                event.depth == (_paged ? 1 : 0),
            child: body,
          ),
        ),
      );
    },
  );

  Widget _categoryContent(
    ExploreFeed explore,
    CatalogCategory tab,
    double inset,
    ScrollController scroll, {
    Widget? televisionTabs,
  }) {
    final feed = explore.feedOf(tab);
    final hero = feed == null ? null : _hero(explore, tab);
    final phase = feed == null
        ? 'loading'
        : feed.items.isNotEmpty || hero != null
        ? 'content'
        : feed.loading
        ? 'loading'
        : feed.error.isNotEmpty
        ? 'error'
        : 'empty';
    if (feed == null) return const StatusView.loading();
    return LocalContentTransition(
      identity: (tab.id, phase),
      ready: phase != 'loading',
      child: _content(
        explore,
        inset,
        tab: tab,
        feed: feed,
        controller: scroll,
        hero: hero,
        status: switch (phase) {
          'loading' => const StatusView.loading(),
          'error' => SingleChildScrollView(
            primary: false,
            padding: const EdgeInsets.all(28),
            child: FailureRecovery(
              title: '暂时无法加载',
              failure: feed.failure!,
              store: widget.store,
              source: explore.source!,
              onRetry: () => feed.reload(force: true),
            ),
          ),
          'empty' => StatusView(
            title: '这里还没有剧',
            message: '换一个分类看看',
            icon: Icons.inbox_outlined,
            action: '刷新',
            onAction: () => feed.reload(force: true),
          ),
          _ => null,
        },
        televisionTabs: televisionTabs,
        topInset: televisionTabs != null ? 0 : _headerHeight,
      ),
    );
  }

  Widget _content(
    ExploreFeed explore,
    double inset, {
    required CatalogCategory tab,
    required DramaFeed feed,
    required ScrollController controller,
    required Widget? hero,
    required Widget? status,
    required Widget? televisionTabs,
    required double topInset,
  }) {
    if (status != null && televisionTabs == null) return status;
    final items = explore.itemsIn(tab);
    final television = televisionTabs != null;
    final phone = AppScope.formFactorOf(context) == FormFactor.phone;
    final desktop = AppScope.formFactorOf(context) == FormFactor.window;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scroll = CustomScrollView(
          key: PageStorageKey((
            widget.store.profileEpoch,
            explore.source?.id,
            television ? 'television' : tab.id,
          )),
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (topInset > 0)
              SliverToBoxAdapter(child: SizedBox(height: topInset)),
            // 电视的分类始终占据同一个 sliver；加载结果或续看卡变化不迁移焦点。
            if (televisionTabs != null)
              SliverPadding(
                padding: const EdgeInsets.only(top: 8),
                sliver: SliverToBoxAdapter(child: televisionTabs),
              ),
            if (status != null)
              SliverFillRemaining(hasScrollBody: false, child: status)
            else ...[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, phone ? 12 : 16, inset, 0),
                sliver: SliverToBoxAdapter(
                  // 大卡片的出现、消失和内容切换共用一套过渡：Fade + 上滑 + 微缩放，
                  // 高度变化交给 AnimatedSize，整块卡片不再“啪”地插入或消失。
                  child: _heroSize(
                    context,
                    AnimatedSwitcher(
                      key: const ValueKey('explore-hero-motion'),
                      duration: AppMotion.duration(
                        context,
                        AppMotion.heroEnter,
                      ),
                      reverseDuration: AppMotion.duration(
                        context,
                        AppMotion.heroExit,
                      ),
                      switchInCurve: AppMotion.curve,
                      switchOutCurve: AppMotion.exitCurve,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.topCenter,
                        children: [
                          for (final child in previous) child,
                          ?current,
                        ],
                      ),
                      transitionBuilder: (child, animation) {
                        if (AppMotion.reduced(context)) return child;
                        final curved = CurvedAnimation(
                          parent: animation,
                          curve: AppMotion.curve,
                          reverseCurve: AppMotion.exitCurve,
                        );
                        return FadeTransition(
                          opacity: curved,
                          child: SlideTransition(
                            position: Tween(
                              begin: const Offset(0, .12),
                              end: Offset.zero,
                            ).animate(curved),
                            child: ScaleTransition(
                              scale: Tween(
                                begin: .97,
                                end: 1.0,
                              ).animate(curved),
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
                padding: EdgeInsets.fromLTRB(
                  inset,
                  desktop ? 20 : 16,
                  inset,
                  0,
                ),
                sliver: DramaSliverGrid(
                  store: widget.store,
                  width: constraints.maxWidth - inset * 2,
                  items: items,
                  rankOf: (drama) => explore.rankIn(tab, drama),
                  autofocus: television && hero == null,
                  onOpen: _open,
                  onMore: (entry) =>
                      showFollowMenu(context, widget.store, entry.$1, entry.$2),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  inset,
                  8,
                  inset,
                  (television ? 27 : 16) + bottomBarInset(context),
                ),
                sliver: SliverToBoxAdapter(
                  child: FeedFooter(
                    feed: feed,
                    store: widget.store,
                    source: explore.source,
                  ),
                ),
              ),
            ],
          ],
        );
        return Stack(
          children: [
            // 下拉刷新由外层 RefreshIndicator 统一接管，这里只负责自动加载下一页。
            if (tab.id == explore.tab.id)
              AutoLoadMore(feed: feed, child: scroll)
            else
              scroll,
            if (status == null && feed.loading)
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

  Widget? _hero(ExploreFeed explore, CatalogCategory tab) {
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
    if (explore.featuredIn(tab) case final drama?) {
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

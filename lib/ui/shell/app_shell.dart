import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../download_converter.dart';
import '../../download_overview.dart';
import '../../follow_updater.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../explore/explore_page.dart';
import '../explore/source_actions.dart';
import '../live/live_page.dart';
import '../follow/follow_page.dart';
import '../mine/mine_page.dart';
import '../theme/glass_style.dart';
import '../widgets/bar_button.dart';
import '../widgets/focus_ring.dart';
import '../widgets/glass/glass_surface.dart';
import '../widgets/source_bar.dart';

enum AppTab {
  explore('短剧', Icons.explore_outlined, Icons.explore),
  live('直播', Icons.live_tv_outlined, Icons.live_tv_rounded),
  follow('追剧', Icons.bookmark_border_rounded, Icons.bookmark_rounded),
  mine('我的', Icons.person_outline_rounded, Icons.person_rounded);

  const AppTab(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

Future<T?> openPage<T>(BuildContext context, WidgetBuilder builder) =>
    Navigator.of(
      context,
      rootNavigator: switch (AppScope.formFactorOf(context)) {
        FormFactor.phone || FormFactor.television => true,
        FormFactor.pad || FormFactor.window => false,
      },
    ).push(MaterialPageRoute<T>(builder: builder));

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.store});
  final LocalStore store;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _navigators = [
    for (final _ in AppTab.values) GlobalKey<NavigatorState>(),
  ];
  final _tabFocus = [for (final _ in AppTab.values) FocusNode()];
  final _followEntry = FocusNode();
  final _mineEntry = FocusNode();
  final _header = FocusNode();
  final _televisionTabs = GlobalKey();
  final _explore = GlobalKey<ExplorePageState>();

  /// 每个 tab 一条主滚动控制器。
  ///
  /// 「回到顶部」要作用在页面自身的滚动视图上。探索页持有自己的控制器，
  /// 走它的 state；追剧 / 我的页面没传控制器，靠 `PrimaryScrollController`
  /// 兜底接管。
  final _topScroll = [for (final _ in AppTab.values) ScrollController()];
  final _scrolled = ValueNotifier(false);
  static const _fade = Duration(milliseconds: 180);
  static const _scrollTopDuration = Duration(milliseconds: 320);

  /// 底栏收起、露出用的时长。
  static const _barSlide = Duration(milliseconds: 220);

  /// 上滑越过这个位置就收起底栏。
  static const _barHideAt = 240.0;

  /// 回到这个位置以内立刻露出底栏。
  static const _barShowAt = 60.0;

  /// 底栏是否随上滑收起。收起时下移并淡出，下滑时回到原位。
  var _barHidden = false;
  var _tab = AppTab.explore;
  var _headerFocused = false;
  FocusNode? _lastFocus;
  Timer? _exitWindow;
  DownloadOverview? _downloads;
  DownloadConverter? _converter;
  FollowUpdater? _followUpdater;
  bool _handlingBack = false;

  Future<void> _popTab(AppTab tab) async {
    if (_handlingBack || tab != _tab) return;
    _handlingBack = true;
    try {
      // 子路由拒绝返回（全屏/PiP）也视为已消费，绝不继续切换 Tab。
      await _navigators[tab.index].currentState?.maybePop();
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      _handlingBack = false;
    }
  }

  NavigatorState? get _navigator => _navigators[_tab.index].currentState;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_followFocus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _downloads ??= DownloadOverview(
      AppScope.of(context).repository,
      widget.store,
    );
    _converter ??= DownloadConverter(
      AppScope.of(context).repository,
      _downloads!,
    );
    _followUpdater ??= FollowUpdater(
      AppScope.of(context).repository,
      widget.store,
    )..start();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_followFocus);
    for (final node in _tabFocus) {
      node.dispose();
    }
    _followEntry.dispose();
    _mineEntry.dispose();
    _header.dispose();
    _exitWindow?.cancel();
    _converter?.dispose();
    _downloads?.dispose();
    _followUpdater?.dispose();
    for (final controller in _topScroll) {
      controller.dispose();
    }
    _scrolled.dispose();
    super.dispose();
  }

  void _select(AppTab tab) {
    // 换 tab 后滚动位置未知，先收起回到顶部按钮、露出底栏，等下一次滚动再判。
    _scrolled.value = false;
    setState(() {
      _tab = tab;
      _barHidden = false;
    });
  }

  void _followFocus() {
    final previous = _lastFocus;
    final focused = _lastFocus = FocusManager.instance.primaryFocus;
    final index = _tabFocus.indexWhere((node) => node == focused);
    if (index < 0) return;
    if (previous?.ancestors.contains(_header) ?? false) {
      _select(AppTab.values[index]);
    } else if (index != _tab.index) {
      _tabFocus[_tab.index].requestFocus();
    }
  }

  Future<void> _back() async {
    final navigator = _navigator;
    if (_handlingBack) return;
    if (navigator?.canPop() ?? false) {
      await _popTab(_tab);
      return;
    }
    if (!mounted) return;
    final television = AppScope.of(context).television;
    if (_tab == AppTab.explore && (!television || _headerFocused)) {
      _armExit();
      return;
    }
    if (_tab == AppTab.explore) _explore.currentState?.refresh();
    _select(AppTab.explore);
    if (television) _tabFocus.first.requestFocus();
  }

  void _armExit() {
    const window = Duration(seconds: 2);
    setState(() {
      _exitWindow = Timer(window, () {
        if (mounted) setState(() => _exitWindow = null);
      });
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('再按一次返回退出应用'), duration: window),
      );
  }

  Widget _root(AppTab tab) => switch (tab) {
    AppTab.live => LivePage(store: widget.store),
    AppTab.explore => ExplorePage(key: _explore, store: widget.store),
    AppTab.follow => FollowPage(
      store: widget.store,
      entryFocus: _followEntry,
      onExitUp: _tabFocus[AppTab.follow.index].requestFocus,
    ),
    AppTab.mine => MinePage(
      store: widget.store,
      downloads: _downloads!,
      converter: _converter!,
      entryFocus: _mineEntry,
      onExitUp: _tabFocus[AppTab.mine.index].requestFocus,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final pages = NotificationListener<NavigationNotification>(
      onNotification: (_) {
        setState(() {});
        return false;
      },
      child: IndexedStack(
        index: _tab.index,
        children: [
          for (final tab in AppTab.values)
            NavigatorPopHandler<Object?>(
              enabled: tab == _tab,
              onPopWithResult: (_) => unawaited(_popTab(tab)),
              child: Navigator(
                key: _navigators[tab.index],
                routeTraversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
                routeDirectionalTraversalEdgeBehavior:
                    TraversalEdgeBehavior.parentScope,
                onGenerateInitialRoutes: (_, _) => [
                  MaterialPageRoute<void>(
                    builder: (_) => PrimaryScrollController(
                      controller: _topScroll[tab.index],
                      child: _root(tab),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    final television = AppScope.of(context).television;
    final covered = _navigator?.canPop() ?? false;
    // 悬浮栏贴底用的系统安全区。必须取 build 的 context：body 内部的
    // MediaQuery 会被 extendBody 改写，拿来定位会算偏。
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return PopScope(
      canPop:
          _exitWindow != null &&
          _tab == AppTab.explore &&
          !covered &&
          (!television || _headerFocused),
      onPopInvokedWithResult: (didPop, _) {
        // 当前 Tab 有子页时交给 NavigatorPopHandler；不能和子页同时返回。
        if (!didPop && !covered && !_handlingBack) _back();
      },
      child: switch (AppScope.formFactorOf(context)) {
        FormFactor.phone => Scaffold(
          // 内容穿透到浮动底栏下方：玻璃背后必须有内容在滚动，材质才成立。
          extendBody: true,
          body: NotificationListener<ScrollNotification>(
            onNotification: _trackScroll,
            child: Stack(
              children: [
                Positioned.fill(child: pages),
                if (!covered) ...[
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: safeBottom + tabBarGap,
                    child: _bottomBar(),
                  ),
                  Positioned(
                    right: 16,
                    bottom: safeBottom + tabBarGap + tabBarHeight + 12,
                    child: _backToTop(),
                  ),
                ],
              ],
            ),
          ),
        ),
        FormFactor.pad || FormFactor.window => _wide(pages),
        FormFactor.television => Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                if (!covered)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      televisionInset,
                      27,
                      televisionInset,
                      8,
                    ),
                    child: Focus(
                      focusNode: _header,
                      canRequestFocus: false,
                      skipTraversal: true,
                      onFocusChange: (focused) =>
                          setState(() => _headerFocused = focused),
                      onKeyEvent: (_, event) {
                        final entry = switch (_tab) {
                          AppTab.follow => _followEntry,
                          AppTab.mine => _mineEntry,
                          AppTab.explore || AppTab.live => null,
                        };
                        if (event is KeyUpEvent ||
                            event.logicalKey != LogicalKeyboardKey.arrowDown ||
                            entry?.context == null) {
                          return KeyEventResult.ignored;
                        }
                        revealFocus(entry!);
                        return KeyEventResult.handled;
                      },
                      child: _televisionHeader(),
                    ),
                  ),
                Expanded(child: pages),
              ],
            ),
          ),
        ),
      },
    );
  }

  Widget _badged(AppTab tab, Widget icon) => tab == AppTab.mine
      ? _DownloadBadge(downloads: _downloads!, child: icon)
      : icon;

  /// 底栏外壳：上滑到一定位置后整条下移淡出，往回下滑再回到原位。
  ///
  /// 收起时必须用 [IgnorePointer] 关掉点击，否则看不见的胶囊会吃掉
  /// 背后内容的点击和纵向滚动。
  Widget _bottomBar() => IgnorePointer(
    ignoring: _barHidden,
    child: AnimatedSlide(
      // 位移按自身高度的倍率算：胶囊离屏幕底边还有留白加安全区，
      // 只挪 100% 会剩半截卡在底边，取 200% 保证整条出屏，淡出再兜一层。
      offset: _barHidden ? const Offset(0, 2) : Offset.zero,
      duration: _barSlide,
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: _barHidden ? 0 : 1,
        duration: _barSlide,
        curve: Curves.easeOut,
        child: _glassTabBar(),
      ),
    ),
  );

  /// 手机端底部导航：浮动玻璃胶囊。
  ///
  /// 位置由外层的 [Stack] 决定（贴底 + 左右 16），这里只负责胶囊本身，
  /// 所以不再自带 `SafeArea`——安全区在最外层算一次就够了。
  Widget _glassTabBar() => GlassSurface(
    radius: GlassRadius.pill,
    padding: const EdgeInsets.all(tabBarPadding),
    child: Row(
      children: [
        for (final tab in AppTab.values)
          Expanded(
            child: _GlassTab(
              tab: tab,
              selected: tab == _tab,
              badged: _badged,
              onTap: () => _select(tab),
            ),
          ),
      ],
    ),
  );

  /// 悬浮在底栏右侧上方的「回到顶部」。
  ///
  /// 隐藏时必须用 [IgnorePointer] 关掉点击，否则这个看不见的圆盘会
  /// 吃掉背后内容的点击与滚动。
  Widget _backToTop() => ValueListenableBuilder<bool>(
    valueListenable: _scrolled,
    builder: (context, scrolled, child) {
      // 底栏收起时不单独留在半空，等下滑把底栏带回来再一起出现。
      final show = scrolled && !_barHidden;
      return IgnorePointer(
        ignoring: !show,
        child: AnimatedScale(
          scale: show ? 1 : 0.7,
          duration: _fade,
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: show ? 1 : 0,
            duration: _fade,
            child: child,
          ),
        ),
      );
    },
    child: SizedBox(
      width: 48,
      height: 48,
      child: GlassSurface(
        radius: GlassRadius.pill,
        child: IconButton(
          tooltip: '回到顶部',
          onPressed: _scrollToTop,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          icon: const Icon(Icons.arrow_upward_rounded, size: 22),
        ),
      ),
    ),
  );

  /// 只认纵向滚动：页面里的横向分类条、选集条不该触发回到顶部和底栏收起。
  bool _trackScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    final pixels = notification.metrics.pixels;
    final scrolled = pixels > 320;
    if (scrolled != _scrolled.value) _scrolled.value = scrolled;
    // 只有真正在拖 / 滑的时候才有方向，惯性末端和回弹会来回抖，靠 2px 阈值滤掉。
    if (notification is ScrollUpdateNotification) {
      _trackBar(pixels, notification.scrollDelta ?? 0);
    } else if (pixels <= 0) {
      _setBarHidden(false);
    }
    return false;
  }

  /// 上滑越过 [_barHideAt] 收起底栏，往回下滑就重新出现。
  void _trackBar(double pixels, double delta) {
    if (pixels <= _barShowAt) {
      _setBarHidden(false);
    } else if (delta > 2 && pixels > _barHideAt) {
      _setBarHidden(true);
    } else if (delta < -2) {
      _setBarHidden(false);
    }
  }

  void _setBarHidden(bool hidden) {
    if (hidden == _barHidden || !mounted) return;
    setState(() => _barHidden = hidden);
  }

  void _scrollToTop() {
    if (_tab == AppTab.explore) {
      _explore.currentState?.scrollToTop();
      return;
    }
    final controller = _topScroll[_tab.index];
    // 页面若自带 ScrollController，这里就没挂上 position：按钮不生效但不崩。
    if (controller.positions.length != 1) return;
    unawaited(
      controller.position.animateTo(
        0,
        duration: _scrollTopDuration,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  Widget _televisionHeader() {
    final tabs = Row(
      key: _televisionTabs,
      spacing: 6,
      children: [
        for (final tab in AppTab.values)
          _TelevisionTab(
            tab: tab,
            selected: tab == _tab,
            focusNode: _tabFocus[tab.index],
            onTap: () => _select(tab),
          ),
      ],
    );
    final store = widget.store;
    if (store.source.isEmpty) {
      return SizedBox(height: 48, child: tabs);
    }
    final source = SourceSite.byId(store.source);
    return SourceBar(
      source: source.name,
      televisionLeading: tabs,
      onSwitchSource: (anchor) => pickSource(anchor, store),
      onOpenSearch: () => openSearch(context, store, source),
      onSearchSubmitted: (query) =>
          openSearch(context, store, source, query: query),
    );
  }

  Widget _wide(Widget pages) {
    final roomy = MediaQuery.sizeOf(context).width >= 840;
    final expanded = roomy && widget.store.sideBarExpanded;
    return Scaffold(
      body: Row(
        children: [
          _SideBar(
            selected: _tab,
            expanded: expanded,
            badged: _badged,
            onSelect: _select,
            onToggle: roomy
                ? () => widget.store.setSideBarExpanded(!expanded)
                : null,
          ),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeLeft: true,
              child: pages,
            ),
          ),
        ],
      ),
    );
  }
}

typedef _SideMetrics = ({
  double width,
  double inset,
  double top,
  double menuGap,
  double spacing,
  double itemHeight,
  double iconSize,
  double labelSize,
  EdgeInsets labelPadding,
});

_SideMetrics _sideMetrics({required bool desktop, required bool expanded}) =>
    desktop
    ? (
        width: expanded ? 240 : 80,
        inset: 12,
        top: 12,
        menuGap: 8,
        spacing: 4,
        itemHeight: 48,
        iconSize: 22,
        labelSize: 14,
        labelPadding: const EdgeInsets.fromLTRB(17, 0, 16, 0),
      )
    : (
        width: expanded ? 232 : 88,
        inset: 16,
        top: 8,
        menuGap: 12,
        spacing: 4,
        itemHeight: 56,
        iconSize: 24,
        labelSize: 15,
        labelPadding: const EdgeInsets.fromLTRB(16, 0, 20, 0),
      );

class _SideBar extends StatelessWidget {
  const _SideBar({
    required this.selected,
    required this.expanded,
    required this.badged,
    required this.onSelect,
    this.onToggle,
  });
  final AppTab selected;
  final bool expanded;
  final Widget Function(AppTab tab, Widget icon) badged;
  final ValueChanged<AppTab> onSelect;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final metrics = _sideMetrics(
      desktop: AppScope.formFactorOf(context) == FormFactor.window,
      expanded: expanded,
    );
    return SafeArea(
      right: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
        child: GlassSurface(
          radius: GlassRadius.bar,
          child: SizedBox(
            key: const ValueKey('side-bar'),
            width: metrics.width,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                metrics.inset,
                metrics.top,
                metrics.inset,
                12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: metrics.spacing,
                children: [
                  Padding(
                    padding: EdgeInsets.only(bottom: metrics.menuGap),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 56,
                        height: 48,
                        child: onToggle == null
                            ? null
                            : Center(
                                child: BarButton(
                                  icon: Icons.menu_rounded,
                                  tooltip: expanded ? '收起侧栏' : '展开侧栏',
                                  onPressed: onToggle,
                                ),
                              ),
                      ),
                    ),
                  ),
                  for (final tab in AppTab.values)
                    _SideItem(
                      tab: tab,
                      selected: tab == selected,
                      expanded: expanded,
                      metrics: metrics,
                      badged: badged,
                      onTap: () => onSelect(tab),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SideItem extends StatelessWidget {
  const _SideItem({
    required this.tab,
    required this.selected,
    required this.expanded,
    required this.metrics,
    required this.badged,
    required this.onTap,
  });
  final AppTab tab;
  final bool selected;
  final bool expanded;
  final _SideMetrics metrics;
  final Widget Function(AppTab tab, Widget icon) badged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final color = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    final icon = badged(
      tab,
      Icon(
        selected ? tab.selectedIcon : tab.icon,
        color: color,
        size: metrics.iconSize,
      ),
    );
    final item = Material(
      color: selected ? colors.secondaryContainer : Colors.transparent,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('nav-${tab.name}'),
        onTap: onTap,
        child: SizedBox(
          height: metrics.itemHeight,
          child: expanded
              ? Padding(
                  padding: metrics.labelPadding,
                  child: Row(
                    spacing: 12,
                    children: [
                      icon,
                      Expanded(
                        child: Text(
                          tab.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontSize: metrics.labelSize,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: color,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : Center(child: icon),
        ),
      ),
    );
    return Semantics(
      selected: selected,
      child: FocusRing(
        radius: metrics.itemHeight / 2,
        child: expanded ? item : Tooltip(message: tab.label, child: item),
      ),
    );
  }
}

class _DownloadBadge extends StatelessWidget {
  const _DownloadBadge({required this.downloads, required this.child});
  final DownloadOverview downloads;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: downloads,
    builder: (context, child) {
      final count = downloads.active;
      return Badge(
        isLabelVisible: count > 0,
        label: Text(count > 99 ? '99+' : '$count'),
        child: child,
      );
    },
    child: child,
  );
}

class _TelevisionTab extends StatelessWidget {
  const _TelevisionTab({
    required this.tab,
    required this.selected,
    required this.focusNode,
    required this.onTap,
  });
  final AppTab tab;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      selected: selected,
      child: FocusPill(
        focusNode: focusNode,
        selected: selected,
        textStyle: theme.textTheme.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        child: InkWell(
          key: ValueKey('nav-${tab.name}'),
          focusNode: focusNode,
          autofocus: tab == AppTab.explore,
          focusColor: Colors.transparent,
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            alignment: Alignment.center,
            child: Text(tab.label),
          ),
        ),
      ),
    );
  }
}

/// 玻璃底栏里的单个 tab。
///
/// 与 [NavigationDestination] 的差别：选中态是「胶囊底色 + 加粗标签」的
/// 渐变过渡，而不是系统默认的指示器位移，这样在磨砂底上层次才不会糊。
class _GlassTab extends StatelessWidget {
  const _GlassTab({
    required this.tab,
    required this.selected,
    required this.badged,
    required this.onTap,
  });
  final AppTab tab;
  final bool selected;
  final Widget Function(AppTab tab, Widget icon) badged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final color = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    final icon = Icon(
      selected ? tab.selectedIcon : tab.icon,
      size: 22,
      color: color,
    );
    // 先算好文字样式，避免 copyWith 链过长触发格式化换行。
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      color: color,
    );
    // 系统开启「减少动态效果」时直接切态，不做过渡。
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 240);
    return Semantics(
      selected: selected,
      child: FocusRing(
        radius: GlassRadius.pill,
        child: Material(
          color: selected ? colors.secondaryContainer : Colors.transparent,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          animationDuration: duration,
          child: InkWell(
            key: ValueKey('nav-${tab.name}'),
            onTap: onTap,
            child: SizedBox(
              height: tabItemHeight,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: 2,
                children: [
                  badged(tab, icon),
                  Text(
                    tab.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

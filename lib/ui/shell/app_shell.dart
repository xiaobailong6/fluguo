import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/app_notice.dart';
import 'package:flutter/services.dart';

import '../../diary_service.dart';
import '../../download_converter.dart';
import '../../download_overview.dart';
import '../../follow_updater.dart';
import '../../local_store.dart';
import '../../merge_queue.dart';
import '../../models.dart';
import '../app_motion.dart';
import '../app_scope.dart';
import '../back_intent.dart';
import '../widgets/glass/glass_feedback.dart';
import '../widgets/glass/glass_selection_track.dart';
import '../explore/explore_page.dart';
import '../explore/source_actions.dart';
import '../live/live_page.dart';
import '../follow/follow_page.dart';
import '../mine/mine_page.dart';
import '../theater/theater_page.dart';
import '../theme/glass_style.dart';
import '../widgets/bar_button.dart';
import '../widgets/focus_ring.dart';
import '../widgets/glass/glass_surface.dart';
import '../widgets/source_bar.dart';
import '../widgets/scroll_chrome.dart';
import '../widgets/smooth_scroll.dart';
import 'tab_page_transition.dart';

enum AppTab {
  explore('短剧', Icons.explore_outlined, Icons.explore),
  theater('剧场', Icons.theaters_outlined, Icons.theaters_rounded),
  live('直播', Icons.live_tv_outlined, Icons.live_tv_rounded),
  follow('追剧', Icons.bookmark_border_rounded, Icons.bookmark_rounded),
  mine('我的', Icons.person_outline_rounded, Icons.person_rounded);

  const AppTab(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

Future<T?> openPage<T>(
  BuildContext context,
  WidgetBuilder builder, {
  String? debugName,
}) {
  final formFactor = AppScope.formFactorOf(context);
  final root =
      formFactor == FormFactor.phone || formFactor == FormFactor.television;
  DiaryService.add('[Nav] push "$debugName" root=$root');
  return Navigator.of(
    context,
    rootNavigator: root,
  ).push(AppMotion.page<T>(context, builder, name: debugName));
}

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
  final _theaterEntry = FocusNode();
  final _mineEntry = FocusNode();
  final _header = FocusNode();
  final _televisionTabs = GlobalKey();
  final _explore = GlobalKey<ExplorePageState>();
  final _followPage = GlobalKey<FollowPageState>();

  /// 每个 tab 一条主滚动控制器。
  ///
  /// 「回到顶部」要作用在页面自身的滚动视图上。探索页持有自己的控制器，
  /// 走它的 state；追剧 / 我的页面没传控制器，靠 `PrimaryScrollController`
  /// 兜底接管。
  final _topScroll = [for (final _ in AppTab.values) ScrollController()];
  final _visibleScroll = <AppTab, ScrollableState>{};
  final _barScroll = ScrollChromeController(
    hideAfter: _barHideAt,
    showAt: _barShowAt,
  );
  double _tabDirection = 1;
  final _scrolled = ValueNotifier(false);

  /// 上滑越过这个位置就收起底栏。
  static const _barHideAt = 240.0;

  /// 回到这个位置以内立刻露出底栏。
  static const _barShowAt = 60.0;

  /// 底栏是否随上滑收起。收起时下移并淡出，下滑时回到原位。
  ///
  /// 用 notifier 而不是普通字段：显隐在一次滑动手势里会来回翻转，走
  /// `setState` 会把 IndexedStack 里全部已创建的页面连同各自的 Navigator
  /// 一起重建，正是滑动时掉帧的来源之一。只让底栏和「回到顶部」两处监听，
  /// 画面与之前完全一致。
  final _barHidden = ValueNotifier<bool>(false);

  /// 「回到顶部」同时取决于滚动位置和底栏显隐；合并监听实例避免每次重建
  /// 都重新挂载监听器。
  late final _chrome = Listenable.merge([_scrolled, _barHidden]);
  var _tab = AppTab.explore;
  final _visited = <AppTab>{};
  var _headerFocused = false;
  FocusNode? _lastFocus;
  Timer? _exitWindow;
  DownloadOverview? _downloads;
  DownloadConverter? _converter;
  MergeQueue? _merges;
  FollowUpdater? _followUpdater;
  bool _handlingBack = false;

  Future<void> _popTab(AppTab tab) async {
    if (_handlingBack || tab != _tab) return;
    if (tab == AppTab.follow &&
        !(_navigator?.canPop() ?? false) &&
        (_followPage.currentState?.consumeSelectionBack() ?? false)) {
      return;
    }
    _handlingBack = true;
    try {
      // 子路由拒绝返回（全屏/PiP）也视为已消费，绝不继续切换 Tab。
      final popped =
          await _navigators[tab.index].currentState?.maybePop() ?? false;
      DiaryService.add('[Nav] popTab tab=${tab.name} popped=$popped');
      if (popped) BackIntent.recordPop();
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      _handlingBack = false;
    }
  }

  NavigatorState? get _navigator => _navigators[_tab.index].currentState;

  // 仅渲染菜单使用配置；页面、焦点和滚动控制器始终按枚举身份索引。
  List<AppTab> get _orderedTabs => widget.store.navigationOrder
      .where(widget.store.navigationVisible.contains)
      .map(AppTab.values.byName)
      .toList();
  AppTab get _homeTab => _orderedTabs.contains(AppTab.explore)
      ? AppTab.explore
      : _orderedTabs.first;
  String get _navigationSignature =>
      '${widget.store.navigationOrder.join(',')}|${widget.store.navigationVisible.join(',')}';
  String _orderSignature = '';

  void _ensureVisibleTab() {
    if (_orderedTabs.contains(_tab)) return;
    final hadFocus = _tabFocus.any((node) => node.hasFocus);
    _tab = _orderedTabs.first;
    _visited.add(_tab);
    _barHidden.value = _tab == AppTab.theater;
    _scrolled.value = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (hadFocus || AppScope.of(context).television)) {
        _tabFocus[_tab.index].requestFocus();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _orderSignature = _navigationSignature;
    _ensureVisibleTab();
    _visited.add(_tab);
    FocusManager.instance.addListener(_followFocus);
    widget.store.addListener(_storeChanged);
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
      inUse: (id) => _merges?.usesDownload(id) ?? false,
    );
    _merges ??= MergeQueue(
      AppScope.of(context).repository,
      store: widget.store,
    );
    _followUpdater ??= FollowUpdater(
      AppScope.of(context).repository,
      widget.store,
    )..start();
  }

  void _storeChanged() {
    final order = _navigationSignature;
    if (!mounted || order == _orderSignature) return;
    _orderSignature = order;
    setState(_ensureVisibleTab);
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_storeChanged);
      _orderSignature = _navigationSignature;
      _ensureVisibleTab();
      widget.store.addListener(_storeChanged);
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_followFocus);
    widget.store.removeListener(_storeChanged);
    for (final node in _tabFocus) {
      node.dispose();
    }
    _followEntry.dispose();
    _theaterEntry.dispose();
    _mineEntry.dispose();
    _header.dispose();
    _exitWindow?.cancel();
    _converter?.dispose();
    _merges?.dispose();
    _downloads?.dispose();
    _followUpdater?.dispose();
    _barScroll.dispose();
    for (final controller in _topScroll) {
      controller.dispose();
    }
    _scrolled.dispose();
    _barHidden.dispose();
    super.dispose();
  }

  void _select(AppTab tab) {
    // 剧场手机导航始终隐藏；切换时不重建已经访问的 Navigator。
    if (!_orderedTabs.contains(tab)) return;
    if (tab == _tab) {
      _scrollToTop();
      return;
    }
    _followPage.currentState?.clearSelection();
    DiaryService.add('[Nav] select ${_tab.name} -> ${tab.name}');
    _exitWindow?.cancel();
    _exitWindow = null;
    final focusMenu = _headerFocused;
    _tabDirection = (_orderedTabs.indexOf(tab) - _orderedTabs.indexOf(_tab))
        .sign
        .toDouble();
    if (Directionality.of(context) == TextDirection.rtl) _tabDirection *= -1;
    _scrolled.value = false;
    setState(() {
      _tab = tab;
      _visited.add(tab);
      _barHidden.value = tab == AppTab.theater;
    });
    _barScroll.reset(pixels: _scrollFor(tab)?.pixels ?? 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _tab == tab) {
        _scrolled.value = (_scrollFor(tab)?.pixels ?? 0) > 320;
      }
    });
    if (focusMenu) {
      // 首次进入页面的 autofocus 不能抢走正在左右切换菜单的遥控焦点。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tab == tab) _tabFocus[tab.index].requestFocus();
      });
    }
  }

  void _followFocus() {
    final previous = _lastFocus;
    final focused = _lastFocus = FocusManager.instance.primaryFocus;
    final index = _tabFocus.indexWhere((node) => node == focused);
    if (index < 0 || !_orderedTabs.contains(AppTab.values[index])) return;
    if (previous?.ancestors.contains(_header) ?? false) {
      // 焦点移动不是点击，不能因重新聚焦当前菜单而滚动页面。
      if (index != _tab.index) _select(AppTab.values[index]);
    } else if (index != _tab.index) {
      _tabFocus[_tab.index].requestFocus();
    }
  }

  /// UI 返回与系统返回共用分层处理，子路由只消费自己的返回。
  void _leaveTheater() {
    if (_tab == AppTab.theater) unawaited(_back());
  }

  AppTab? _theaterReturnTab() {
    if (_orderedTabs.contains(AppTab.explore)) return AppTab.explore;
    for (final tab in _orderedTabs) {
      if (tab != AppTab.theater) return tab;
    }
    return null;
  }

  Future<void> _back() async {
    final navigator = _navigator;
    if (_handlingBack) return;
    final rootNavigator = Navigator.maybeOf(context, rootNavigator: true);
    if (navigator?.canPop() ?? false) {
      DiaryService.add(
        '[Nav] back: tab=${_tab.name} nested-pop '
        '(rootCanPop=${rootNavigator?.canPop()})',
      );
      await _popTab(_tab);
      return;
    }
    // 手机端搜索、详情等子页压在根导航器上（covered 只看 Tab 内层导航器），
    // 返回必须先关掉它们：任何页面打开时都不能武装“退出应用”。
    if (rootNavigator?.canPop() ?? false) {
      // 同一次返回事件里已经关掉一层时不能再连关，避免一次键关两层。
      if (!BackIntent.quietSincePop) {
        DiaryService.add('[Nav] back: root-pop skipped (quiet window)');
        return;
      }
      _handlingBack = true;
      try {
        final popped = await rootNavigator!.maybePop();
        DiaryService.add('[Nav] back: root-pop popped=$popped');
        if (popped) BackIntent.recordPop();
        await WidgetsBinding.instance.endOfFrame;
      } finally {
        _handlingBack = false;
      }
      return;
    }
    // 多选的返回只取消选择，不再继续执行切换首页的兜底逻辑。
    if (_tab == AppTab.follow &&
        (_followPage.currentState?.consumeSelectionBack() ?? false)) {
      return;
    }
    if (_tab == AppTab.theater) {
      final target = _theaterReturnTab();
      if (target != null) {
        // 系统返回会遍历所有 PopScope；切换后旧的短剧 handler 不能在
        // 同一次事件中再弹出它保留的子路由，锁持续到本帧派发结束。
        _handlingBack = true;
        try {
          _select(target);
          if (AppScope.of(context).television) {
            _tabFocus[target.index].requestFocus();
          }
          await WidgetsBinding.instance.endOfFrame;
        } finally {
          _handlingBack = false;
        }
      } else if (_exitWindow != null) {
        // 仅剩剧场时 UI 返回也能退出，不依赖已经隐藏的手机菜单。
        await SystemNavigator.pop();
      } else {
        _armExit();
      }
      return;
    }
    // 直播返回不可兜底切到短剧。内层弹出与外层 PopScope 回调可能处于
    // 同一输入的不同阶段，此时 canPop 已变为 false 也必须留在直播 Tab。
    if (_tab == AppTab.live) return;
    if (!mounted) return;
    final television = AppScope.of(context).television;
    if (_tab == _homeTab && (!television || _headerFocused)) {
      _armExit();
      return;
    }
    if (_tab == AppTab.explore) _explore.currentState?.refresh();
    _select(_homeTab);
    if (television) _tabFocus[_tab.index].requestFocus();
  }

  /// 只有“真正停在主页根层级”才武装退出：同一次返回事件里可能还有子页面在
  /// 出栈（搜索、详情等压在本 Tab 或根导航器上），所以推迟到帧末复查状态，
  /// 并且刚有页面出栈时直接放弃，避免一次返回既关页面又弹退出提示。
  void _armExit() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 这一帧里有关过页面、或仍停留在子页面：撤销上一轮的退出窗口，
      // 既不弹提示也不留下“下一次返回直接退出”的隐患。
      final blocked =
          !BackIntent.quietSincePop ||
          !(ModalRoute.of(context)?.isCurrent ?? true) ||
          (_navigator?.canPop() ?? false) ||
          (Navigator.maybeOf(context, rootNavigator: true)?.canPop() ?? false);
      if (blocked) {
        if (_exitWindow != null) {
          setState(() {
            _exitWindow?.cancel();
            _exitWindow = null;
          });
        }
        return;
      }
      final window = const Duration(seconds: 2);
      setState(() {
        _exitWindow?.cancel();
        _exitWindow = Timer(window, () {
          if (mounted) setState(() => _exitWindow = null);
        });
      });
      showAppNotice(context, '再按一次返回退出应用', duration: window);
    });
  }

  Widget _root(AppTab tab) => switch (tab) {
    AppTab.live => LivePage(store: widget.store),
    AppTab.explore => ExplorePage(key: _explore, store: widget.store),
    AppTab.theater => TheaterPage(
      store: widget.store,
      entryFocus: _theaterEntry,
      onExitUp: _tabFocus[AppTab.theater.index].requestFocus,
      onExit: _leaveTheater,
    ),
    AppTab.follow => FollowPage(
      key: _followPage,
      store: widget.store,
      entryFocus: _followEntry,
      onExitUp: _tabFocus[AppTab.follow.index].requestFocus,
    ),
    AppTab.mine => MinePage(
      store: widget.store,
      downloads: _downloads!,
      converter: _converter!,
      merges: _merges!,
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
            NotificationListener<ScrollNotification>(
              onNotification: (notification) => _trackScroll(tab, notification),
              child: TabPageTransition(
                active: tab == _tab,
                direction: _tabDirection,
                child: ExcludeFocus(
                  // Offstage 本身不阻止焦点，保留页面状态但禁止隐藏页接收遥控键。
                  excluding: tab != _tab,
                  child: TickerMode(
                    enabled: tab == _tab,
                    child: !_visited.contains(tab)
                        ? const SizedBox.shrink()
                        : NavigatorPopHandler<Object?>(
                            enabled: tab == _tab,
                            onPopWithResult: (_) => unawaited(_popTab(tab)),
                            child: Navigator(
                              key: _navigators[tab.index],
                              routeTraversalEdgeBehavior:
                                  TraversalEdgeBehavior.parentScope,
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
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    final television = AppScope.of(context).television;
    final covered = _navigator?.canPop() ?? false;
    // 根导航器上还有子页时（手机端搜索/详情等），返回一律先关子页。
    final rootCovered =
        Navigator.maybeOf(context, rootNavigator: true)?.canPop() ?? false;
    // 悬浮栏贴底用的系统安全区。必须取 build 的 context：body 内部的
    // MediaQuery 会被 extendBody 改写，拿来定位会算偏。
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return PopScope(
      canPop:
          _exitWindow != null &&
          (_tab == AppTab.theater
              ? _theaterReturnTab() == null
              : _tab == _homeTab) &&
          !covered &&
          !rootCovered &&
          (_tab == AppTab.theater || !television || _headerFocused),
      onPopInvokedWithResult: (didPop, _) {
        // 当前 Tab 有子页时交给 NavigatorPopHandler；不能和子页同时返回。
        if (!didPop && !covered && !_handlingBack) _back();
      },
      child: switch (AppScope.formFactorOf(context)) {
        FormFactor.phone => Scaffold(
          // 内容穿透到浮动底栏下方：玻璃背后必须有内容在滚动，材质才成立。
          extendBody: true,
          body: Stack(
            children: [
              Positioned.fill(child: pages),
              // 滚动收起保留实例才能执行反向动画；剧场和子路由仍不构建导航。
              if (!covered && _tab != AppTab.theater) ...[
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
        FormFactor.pad || FormFactor.window => _wide(pages),
        FormFactor.television => Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                // 电视端顶栏在进入子页时淡出并收起高度，返回时淡入展开，不硬切。
                ClipRect(
                  child: IgnorePointer(
                    ignoring: covered,
                    child: ExcludeFocus(
                      excluding: covered,
                      child: ExcludeSemantics(
                        excluding: covered,
                        child: AnimatedOpacity(
                          opacity: covered ? 0 : 1,
                          duration: AppMotion.duration(
                            context,
                            AppMotion.chrome,
                          ),
                          curve: covered
                              ? AppMotion.exitCurve
                              : AppMotion.curve,
                          child: AnimatedAlign(
                            alignment: Alignment.topCenter,
                            heightFactor: covered ? 0 : 1,
                            duration: AppMotion.duration(
                              context,
                              AppMotion.chrome,
                            ),
                            curve: covered
                                ? AppMotion.exitCurve
                                : AppMotion.curve,
                            child: Padding(
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
                                    AppTab.theater => _theaterEntry,
                                    AppTab.mine => _mineEntry,
                                    AppTab.explore || AppTab.live => null,
                                  };
                                  if (event is KeyUpEvent ||
                                      event.logicalKey !=
                                          LogicalKeyboardKey.arrowDown ||
                                      entry?.context == null) {
                                    return KeyEventResult.ignored;
                                  }
                                  revealFocus(entry!);
                                  return KeyEventResult.handled;
                                },
                                child: _televisionHeader(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
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
  Widget _bottomBar() => ValueListenableBuilder<bool>(
    valueListenable: _barHidden,
    // 只有底栏自己跟着显隐重建，外层页面和 Navigator 不参与。
    builder: (context, hidden, _) => ScrollChromeVisibility(
      key: const ValueKey('bottom-chrome-motion'),
      hidden: hidden,
      hiddenOffset: const Offset(0, 1.6),
      child: _glassTabBar(),
    ),
  );

  /// 手机端底部导航：浮动玻璃胶囊。
  ///
  /// 位置由外层的 [Stack] 决定（贴底 + 左右 16），这里只负责胶囊本身，
  /// 所以不再自带 `SafeArea`——安全区在最外层算一次就够了。
  Widget _glassTabBar() => GlassSurface(
    role: GlassRole.chrome,
    radius: GlassRadius.pill,
    padding: const EdgeInsets.all(tabBarPadding),
    child: GlassSelectionTrack(
      context: context,
      selectedIndex: _orderedTabs.indexOf(_tab),
      height: tabItemHeight,
      children: [
        for (final tab in _orderedTabs)
          _GlassTab(
            key: ValueKey(tab),
            tab: tab,
            selected: tab == _tab,
            badged: _badged,
            onTap: () => _select(tab),
          ),
      ],
    ),
  );

  /// 悬浮在底栏右侧上方的「回到顶部」。
  ///
  /// 隐藏时必须用 [IgnorePointer] 关掉点击，否则这个看不见的圆盘会
  /// 吃掉背后内容的点击与滚动。
  Widget _backToTop() => AnimatedBuilder(
    animation: _chrome,
    builder: (context, child) {
      // 底栏收起时不单独留在半空，等下滑把底栏带回来再一起出现。
      final show = _scrolled.value && !_barHidden.value;
      return IgnorePointer(
        ignoring: !show,
        child: AnimatedScale(
          scale: show ? 1 : 0.7,
          duration: AppMotion.duration(context, AppMotion.state),
          curve: show ? AppMotion.curve : AppMotion.exitCurve,
          child: AnimatedOpacity(
            opacity: show ? 1 : 0,
            duration: AppMotion.duration(context, AppMotion.state),
            child: child,
          ),
        ),
      );
    },
    child: SizedBox(
      width: 48,
      height: 48,
      child: GlassSurface(
        role: GlassRole.chrome,
        interactive: true,
        radius: GlassRadius.pill,
        child: IconButton(
          tooltip: '回到顶部',
          key: const ValueKey('shell-back-to-top'),
          onPressed: _scrollToTop,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          icon: const Icon(Icons.arrow_upward_rounded, size: 22),
        ),
      ),
    ),
  );

  /// 只认纵向滚动：页面里的横向分类条、选集条不该触发回到顶部和底栏收起。
  bool _trackScroll(AppTab tab, ScrollNotification notification) {
    if (tab != _tab ||
        tab == AppTab.theater ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final source = notification.context;
    final route = source != null && source.mounted
        ? ModalRoute.of(source)
        : null;
    if (source == null ||
        !source.mounted ||
        route?.isCurrent == false ||
        route?.isFirst == false) {
      return false;
    }
    final scrollable =
        source is StatefulElement && source.state is ScrollableState
        ? source.state as ScrollableState
        : Scrollable.maybeOf(source);
    if (scrollable != null) _visibleScroll[tab] = scrollable;
    final metrics = notification.metrics;
    _scrolled.value = metrics.pixels > 320;
    _barScroll.track(
      metrics.pixels,
      minExtent: metrics.minScrollExtent,
      maxExtent: metrics.maxScrollExtent,
    );
    _setBarHidden(_barScroll.value);
    return false;
  }

  /// 只翻转底栏显隐，不触发整棵壳层重建。
  void _setBarHidden(bool hidden) {
    if (!mounted || hidden == _barHidden.value) return;
    _barHidden.value = hidden;
  }

  ScrollPosition? _scrollFor(AppTab tab) {
    final scrollable = _visibleScroll[tab];
    return scrollable != null && scrollable.mounted
        ? scrollable.position
        : null;
  }

  Future<void> _scrollToTop() async {
    if (_tab == AppTab.theater || (_navigator?.canPop() ?? false)) return;
    _setBarHidden(false);
    final controller = _topScroll[_tab.index];
    final position =
        _scrollFor(_tab) ??
        (controller.positions.length == 1 ? controller.position : null);
    _barScroll.reset(pixels: position?.pixels ?? 0);
    // 短剧页同时展开自己的顶栏，避免等待动画积累反向位移后才展开。
    if (_tab == AppTab.explore && _explore.currentState != null) {
      await _explore.currentState!.scrollToTop();
      return;
    }
    if (position != null) await smoothScrollToTop(context, position);
  }

  Widget _televisionHeader() {
    final tabs = Row(
      key: _televisionTabs,
      spacing: 6,
      children: [
        for (final tab in _orderedTabs)
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
            tabs: _orderedTabs,
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
    required this.tabs,
    required this.expanded,
    required this.badged,
    required this.onSelect,
    this.onToggle,
  });
  final AppTab selected;
  final List<AppTab> tabs;
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
          role: GlassRole.chrome,
          radius: GlassRadius.bar,
          // 侧栏与内容并排，背后只有页面底色，不必模糊整个窗口高度。
          blur: false,
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
                  for (final tab in tabs)
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
          autofocus: selected,
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

/// 玻璃底栏的点击项；选中底色由共享轨道绘制，保持单个连续胶囊。
class _GlassTab extends StatelessWidget {
  const _GlassTab({
    super.key,
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
    final duration = AppMotion.duration(context, AppMotion.state);
    final icon = AnimatedSwitcher(
      duration: duration,
      child: Icon(
        selected ? tab.selectedIcon : tab.icon,
        key: ValueKey(selected),
        size: 22,
        color: color,
      ),
    );
    // 先算好文字样式，避免 copyWith 链过长触发格式化换行。
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      color: color,
    );
    // 共用压感，不改变 Tab 的点击回调和导航身份。
    return Semantics(
      selected: selected,
      child: GlassFeedback(
        radius: GlassRadius.pill,
        child: FocusRing(
          radius: GlassRadius.pill,
          child: Material(
            color: Colors.transparent,
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
                    AnimatedDefaultTextStyle(
                      duration: duration,
                      curve: AppMotion.curve,
                      style: labelStyle ?? const TextStyle(),
                      child: Text(
                        tab.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

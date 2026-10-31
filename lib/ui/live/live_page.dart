import 'live_room_card.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show FloatingHeaderSnapConfiguration;

import '../../live_bilibili.dart';
import '../../live_feed.dart';
import '../../local_store.dart';
import '../app_scope.dart';
import '../theme/glass_style.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';
import '../widgets/glass/glass_header.dart';
import '../widgets/glass/glass_surface.dart';
import 'live_navigation.dart';
import 'live_favorites_page.dart';
import '../widgets/glass/glass_selector.dart';
import '../widgets/status_view.dart';

class LivePage extends StatefulWidget {
  const LivePage({super.key, required this.store, this.platform});
  final LocalStore store;
  final LivePlatform? platform;

  @override
  State<LivePage> createState() => LivePageState();
}

class LivePageState extends State<LivePage>
    with SingleTickerProviderStateMixin {
  late final LiveFeed _feed;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _fallbackScroll = ScrollController();
  bool _searching = false;

  ScrollController get _scroll =>
      PrimaryScrollController.maybeOf(context) ?? _fallbackScroll;

  @override
  void initState() {
    super.initState();
    _feed = LiveFeed(widget.platform ?? livePlatforms.first);
    unawaited(_feed.start());
  }

  @override
  void dispose() {
    _feed.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _fallbackScroll.dispose();
    super.dispose();
  }

  /// 换列表时回到顶端，避免旧列表的偏移让新分区标题直接处于收起状态。
  void _resetScroll() {
    final controller = _scroll;
    if (controller.positions.length == 1) controller.jumpTo(0);
  }

  void _backToAreas() {
    _search.clear();
    _searchFocus.unfocus();
    _resetScroll();
    _feed.backToAreas();
  }

  void _submitSearch(String value) {
    _searchFocus.unfocus();
    _resetScroll();
    unawaited(_feed.search(value));
  }

  void _toggleSearch() {
    setState(() => _searching = !_searching);
    if (_searching) {
      _resetScroll();
      _searchFocus.requestFocus();
    } else {
      _backToAreas();
    }
  }

  Future<void> _pickPlatform(BuildContext anchor) async {
    final selected = await showGlassSelector<String>(
      anchor: anchor,
      options: [
        for (final platform in livePlatforms)
          ChoiceOption(platform.id, platform.name),
      ],
      selected: _feed.platform.id,
      menuKey: const ValueKey('live-platform-menu'),
    );
    if (!mounted || selected == null || selected == _feed.platform.id) return;
    final platform = livePlatformById(selected);
    if (platform == null) return;
    _search.clear();
    _resetScroll();
    await _feed.switchPlatform(platform);
  }

  void _openRoom(LiveRoom room) =>
      unawaited(openLivePlayer(context, widget.store, _feed.platform, room));

  void _openFavorites() => unawaited(
    pushLivePage<void>(context, (_) => LiveFavoritesPage(store: widget.store)),
  );

  Future<void> _showAllAreas(BuildContext anchor) async {
    final areas = _feed.areas;
    if (areas.isEmpty) return;
    final selected = await showChoicePanel<LiveCategory>(
      context: anchor,
      title: '全部二级分区',
      options: [for (final area in areas) ChoiceOption(area, area.name)],
      selected: _feed.area,
      grid: ChoiceGrid.categories,
    );
    if (!mounted || selected == null || !_feed.areas.contains(selected)) return;
    _resetScroll();
    await _feed.selectArea(selected);
  }

  Widget _allAreasButton() => Builder(
    builder: (anchor) => IconButton(
      key: const ValueKey('live-all-areas'),
      tooltip: '全部二级分区',
      onPressed: () => unawaited(_showAllAreas(anchor)),
      icon: const Icon(Icons.grid_view_rounded),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _feed,
    builder: (context, _) {
      final feed = _feed;
      final hasResults = feed.area != null || feed.query.isNotEmpty;
      // 一个滚动布局管理浮动大卡片与固定导航，避免两个叠层各做动画而相撞。
      final headerHeight =
          60.0 + (feed.category == null ? 0 : 48) + (_searching ? 64 : 0);
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: feed.refresh,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.depth == 0 &&
                    notification.metrics.axis == Axis.vertical &&
                    notification.metrics.extentAfter < 500 &&
                    feed.rooms.isNotEmpty) {
                  unawaited(feed.loadMore());
                }
                return false;
              },
              child: CustomScrollView(
                key: const ValueKey('live-scroll'),
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPersistentHeader(
                    key: const ValueKey('live-floating-header'),
                    floating: true,
                    pinned: hasResults,
                    delegate: _LiveChromeHeader(
                      ticker: this,
                      reduceMotion: MediaQuery.disableAnimationsOf(context),
                      headerHeight: headerHeight,
                      navigation: hasResults ? _navigation(feed) : null,
                      header: GlassHeader(
                        key: const ValueKey('live-header-card'),
                        showShadow: false,
                        onHeight: (_) {},
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _header(context),
                            if (_searching) _searchField(),
                            if (feed.category case final category?)
                              CategoryTabs<LiveCategory>(
                                options: [
                                  for (final item in feed.categories)
                                    ChoiceOption(item, item.name),
                                ],
                                selected: category,
                                onSelected: (item) {
                                  _search.clear();
                                  _resetScroll();
                                  unawaited(feed.select(item));
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  ..._slivers(context, feed, hasResults),
                  SliverToBoxAdapter(
                    child: SizedBox(height: 24 + bottomBarInset(context)),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _header(BuildContext context) => SizedBox(
    height: 52,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Builder(
                builder: (anchor) => TextButton(
                  onPressed: () => unawaited(_pickPlatform(anchor)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          _feed.platform.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down_rounded, size: 26),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '直播收藏',
            onPressed: _openFavorites,
            icon: const Icon(Icons.bookmarks_outlined),
          ),
          IconButton(
            tooltip: _searching ? '关闭直播搜索' : '搜索直播',
            onPressed: _toggleSearch,
            icon: Icon(
              _searching ? Icons.search_off_rounded : Icons.search_rounded,
            ),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _feed.loadingRooms || _feed.loadingCategories
                ? null
                : () => unawaited(_feed.refresh()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    ),
  );

  Widget _searchField() => SizedBox(
    height: 64,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        key: const ValueKey('live-search-field'),
        controller: _search,
        focusNode: _searchFocus,
        textInputAction: TextInputAction.search,
        onSubmitted: _submitSearch,
        decoration: InputDecoration(
          hintText: '搜索${_feed.platform.name}直播名称',
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: IconButton(
            tooltip: '搜索',
            onPressed: () => _submitSearch(_search.text),
            icon: const Icon(Icons.arrow_forward_rounded),
          ),
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
          ),
          isDense: true,
        ),
      ),
    ),
  );

  Widget _navigation(LiveFeed feed) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
    child: GlassSurface(
      radius: 18,
      showShadow: false,
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                feed.query.isNotEmpty
                    ? '搜索 / ${feed.query}'
                    : '${feed.category?.name ?? ''} / ${feed.area?.name ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (feed.query.isEmpty) _allAreasButton(),
            TextButton.icon(
              onPressed: _backToAreas,
              icon: const Icon(Icons.grid_view_rounded, size: 18),
              label: const Text('返回分区'),
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> _slivers(BuildContext context, LiveFeed feed, bool hasResults) {
    if (feed.loadingCategories || feed.loadingRooms && feed.rooms.isEmpty) {
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: StatusView.loading(title: '正在加载直播'),
        ),
      ];
    }
    if (feed.error.isNotEmpty && feed.rooms.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StatusView(
            title: feed.query.isEmpty ? '暂时无法加载' : '搜索暂时不可用',
            message: feed.error,
            action: '重试',
            onAction: () => unawaited(feed.refresh()),
          ),
        ),
      ];
    }
    if (!hasResults) {
      if (feed.areas.isEmpty) {
        return [
          const SliverFillRemaining(
            hasScrollBody: false,
            child: StatusView(title: '暂无二级分区', message: '请选择其他一级分区'),
          ),
        ];
      }
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${feed.category?.name ?? ''} · 二级分区',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                _allAreasButton(),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisExtent: 146,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: feed.areas.length,
            itemBuilder: (context, index) {
              final area = feed.areas[index];
              return _AreaCard(
                area: area,
                onTap: () {
                  _resetScroll();
                  unawaited(feed.selectArea(area));
                },
              );
            },
          ),
        ),
      ];
    }
    return [
      if (feed.rooms.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: StatusView(
            title: feed.query.isEmpty ? '这个分区暂时没有直播' : '没有找到相关直播',
            message: feed.query.isEmpty ? '换一个分区看看' : '换个名称或关键词试试',
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        sliver: SliverGrid.builder(
          gridDelegate: LiveRoomCard.gridDelegate(context),
          itemCount: feed.rooms.length,
          itemBuilder: (context, index) {
            final room = feed.rooms[index];
            return LiveRoomCard(room: room, onTap: () => _openRoom(room));
          },
        ),
      ),
      if (feed.rooms.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: feed.loadingMore
                  ? const CircularProgressIndicator()
                  : feed.error.isNotEmpty
                  ? TextButton(
                      onPressed: () => unawaited(feed.retryMore()),
                      child: Text('${feed.error} · 重试'),
                    )
                  : TextButton(
                      onPressed: feed.end
                          ? null
                          : () => unawaited(feed.loadMore()),
                      child: Text(feed.end ? '已经到底了' : '加载更多'),
                    ),
            ),
          ),
        ),
    ];
  }
}

/// 大卡片和吸顶导航共享一个几何布局；浮动展开时也不会盖住导航。
class _LiveChromeHeader extends SliverPersistentHeaderDelegate {
  _LiveChromeHeader({
    required this.header,
    required this.headerHeight,
    required this.ticker,
    required this.reduceMotion,
    this.navigation,
  });
  final Widget header;
  final double headerHeight;
  final Widget? navigation;
  final TickerProvider ticker;
  final bool reduceMotion;

  @override
  double get minExtent => navigation == null ? 0 : 56;
  @override
  double get maxExtent => headerHeight + minExtent;
  @override
  TickerProvider get vsync => ticker;
  @override
  FloatingHeaderSnapConfiguration? get snapConfiguration => reduceMotion
      ? null
      : FloatingHeaderSnapConfiguration(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final visible = (headerHeight - shrinkOffset)
        .clamp(0.0, headerHeight)
        .toDouble();
    return Column(
      children: [
        SizedBox(
          height: visible,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.bottomCenter,
              minHeight: headerHeight,
              maxHeight: headerHeight,
              child: IgnorePointer(
                ignoring: visible == 0,
                child: ExcludeSemantics(excluding: visible == 0, child: header),
              ),
            ),
          ),
        ),
        if (navigation case final child?) SizedBox(height: 56, child: child),
      ],
    );
  }

  @override
  bool shouldRebuild(covariant _LiveChromeHeader oldDelegate) =>
      oldDelegate.headerHeight != headerHeight ||
      oldDelegate.header != header ||
      oldDelegate.navigation != navigation ||
      oldDelegate.reduceMotion != reduceMotion;
}

class _AreaCard extends StatelessWidget {
  const _AreaCard({required this.area, required this.onTap});
  final LiveCategory area;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(GlassRadius.card),
      child: GlassSurface(
        blur: false,
        showShadow: false,
        child: InkWell(
          key: ValueKey('live-area-${area.areaId}'),
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 平台图片与卡片共享圆角和底部文字层，不额外叠一个独立小图标。
              if (area.picture.isNotEmpty &&
                  !const bool.fromEnvironment('DISABLE_REMOTE_IMAGES'))
                Image.network(
                  area.picture,
                  fit: BoxFit.cover,
                  cacheWidth: (180 * MediaQuery.devicePixelRatioOf(context))
                      .ceil()
                      .clamp(1, 1200),
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => _fallback(colors),
                )
              else
                _fallback(colors),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xBB000000)],
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 10,
                bottom: 12,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        area.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fallback(ColorScheme colors) => ColoredBox(
    color: colors.primaryContainer,
    child: Center(
      child: Icon(
        area.hot ? Icons.local_fire_department_rounded : Icons.live_tv_rounded,
        size: 52,
        color: colors.onPrimaryContainer,
      ),
    ),
  );
}

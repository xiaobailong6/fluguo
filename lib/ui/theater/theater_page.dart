import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../local_store.dart';
import '../../theater_feed.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../shell/app_shell.dart';
import '../widgets/drama_tile.dart';
import '../widgets/glass/glass_header.dart';
import '../widgets/glass/glass_surface.dart';

class TheaterPage extends StatefulWidget {
  const TheaterPage({
    super.key,
    required this.store,
    this.entryFocus,
    this.onExitUp,
  });
  final LocalStore store;
  final FocusNode? entryFocus;
  final VoidCallback? onExitUp;

  @override
  State<TheaterPage> createState() => _TheaterPageState();
}

class _TheaterPageState extends State<TheaterPage> {
  TheaterFeed? _feed;
  double _headerHeight = 72;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _feed ??= TheaterFeed(AppScope.of(context).repository, widget.store);
  }

  @override
  void dispose() {
    _feed?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feed = _feed!;
    final television = AppScope.of(context).television;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: feed,
          builder: (context, _) => Stack(
            children: [
              RefreshIndicator(
                onRefresh: feed.reload,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final inset = television ? televisionInset : 20.0;
                    final columns = math.max(
                      2,
                      ((constraints.maxWidth - inset * 2) /
                              (television ? 190 : 155))
                          .floor(),
                    );
                    final width =
                        (constraints.maxWidth -
                            inset * 2 -
                            (columns - 1) * 16) /
                        columns;
                    return CustomScrollView(
                      key: const PageStorageKey('theater-scroll'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            inset,
                            _headerHeight + 20,
                            inset,
                            16,
                          ),
                          sliver: SliverToBoxAdapter(
                            child: GlassSurface(
                              blur: false,
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '为你推荐',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.headlineSmall,
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    '本地推荐：根据此用户最近 30 部短剧的题材与观看进度，约 70% 兴趣匹配 + 30% 随机探索。不会上传观看历史；点击海报查看，不自动播放。',
                                  ),
                                  if (feed.notice != null) ...[
                                    const SizedBox(height: 8),
                                    Text(feed.notice!),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (feed.loading)
                          const SliverToBoxAdapter(
                            child: Center(
                              child: Padding(
                                padding: EdgeInsets.all(32),
                                child: CircularProgressIndicator(),
                              ),
                            ),
                          )
                        else if (feed.items.isEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                children: [
                                  Text(
                                    feed.error ??
                                        (widget.store.sources.isEmpty
                                            ? '暂无已开启且有权限的短剧来源'
                                            : '暂无新推荐，近期曝光、已看完和不感兴趣的内容已排除。稍后刷新试试。'),
                                  ),
                                  const SizedBox(height: 12),
                                  OutlinedButton.icon(
                                    onPressed: feed.reload,
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('重试'),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          SliverPadding(
                            padding: EdgeInsets.symmetric(horizontal: inset),
                            sliver: SliverGrid.builder(
                              itemCount: feed.items.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: 16,
                                    mainAxisSpacing: 20,
                                    mainAxisExtent:
                                        DramaTile.extentFor(context, width) +
                                        56,
                                  ),
                              itemBuilder: (context, index) {
                                final pick = feed.items[index];
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    DramaTile(
                                      drama: pick.drama,
                                      subtitle: pick.reason,
                                      onTap: () {
                                        if (!widget.store.allowsSource(
                                          pick.drama.source,
                                        )) {
                                          return;
                                        }
                                        // push 而不是替换路由，保留剧场滚动位置和批次。
                                        openPage(
                                          context,
                                          (_) => DetailPage(
                                            store: widget.store,
                                            drama: pick.drama,
                                          ),
                                        );
                                      },
                                    ),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: TextButton(
                                        onPressed: () =>
                                            unawaited(feed.hide(pick.drama)),
                                        child: const Text('不感兴趣'),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        SliverToBoxAdapter(
                          child: SizedBox(height: bottomBarInset(context) + 32),
                        ),
                      ],
                    );
                  },
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassHeader(
                  onHeight: (height) {
                    if (mounted && height != _headerHeight) {
                      setState(() => _headerHeight = height);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '剧场',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        Focus(
                          onKeyEvent: (_, event) {
                            if (television &&
                                event is KeyDownEvent &&
                                event.logicalKey ==
                                    LogicalKeyboardKey.arrowUp) {
                              widget.onExitUp?.call();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: IconButton(
                            focusNode: widget.entryFocus,
                            tooltip: '刷新推荐',
                            onPressed: feed.loading ? null : feed.reload,
                            icon: const Icon(Icons.refresh),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: feed.loading ? null : feed.nextBatch,
                          icon: const Icon(Icons.shuffle),
                          label: const Text('换一批'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

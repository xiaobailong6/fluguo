import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../../theater_feed.dart';
import '../../theater_preview.dart';
import '../../theater_preview_backend.dart';
import '../../theater_recommendations.dart';
import '../app_scope.dart';
import '../player/playback_handle.dart';
import '../player/playback_page.dart';
import '../shell/theater_navigation_notification.dart';
import '../widgets/glass/glass_surface.dart';

class TheaterPage extends StatefulWidget {
  const TheaterPage({
    super.key,
    required this.store,
    this.entryFocus,
    this.onExitUp,
    this.previewBackend,
    this.onOpenFull,
  });
  final LocalStore store;
  final FocusNode? entryFocus;
  final VoidCallback? onExitUp;
  final PreviewBackend Function()? previewBackend;
  final Future<void> Function(BuildContext, DramaDetail, Duration)? onOpenFull;
  @override
  State<TheaterPage> createState() => _TheaterPageState();
}

class _TheaterPageState extends State<TheaterPage> with WidgetsBindingObserver {
  TheaterFeed? _feed;
  TheaterPreview? _preview;
  final _pages = PageController();
  ValueListenable<TickerModeData>? _ticker;
  int _index = 0;
  bool _opening = false;
  bool _foreground = true;
  String _batch = '';
  List<TheaterPick> _items = [];
  int? _openedEpoch;
  String? _completedEntry;
  bool _autoScheduled = false;
  TheaterPick? _activePick;

  void _selectPick(TheaterPick? pick) {
    if (!identical(_activePick, pick)) {
      _completedEntry = null;
      if (pick != null &&
          _preview!.drama != null &&
          theaterIdentity(pick.drama) == theaterIdentity(_preview!.drama!)) {
        // 有限片库循环的下一次出现，也应从首集零点重新预览。
        _preview!.select(null);
      }
      _activePick = pick;
    }
    _preview!.select(pick?.drama);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_feed == null) {
      final repository = AppScope.of(context).repository;
      _preview = TheaterPreview(
        repository,
        widget.store,
        backend: widget.previewBackend ?? PreviewBackendScope.maybeOf(context),
      )..addListener(_changed);
      _feed = TheaterFeed(repository, widget.store)..addListener(_feedChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _feedChanged();
      });
    }
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_visibility);
      _ticker = ticker..addListener(_visibility);
    }
    // Subscribe to both tab visibility and route-current changes.
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _visibility();
      }
    });
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _autoOpen();
  }

  void _autoOpen() {
    final preview = _preview!;
    final drama = preview.drama;
    if (!preview.ended ||
        drama == null ||
        _opening ||
        _autoScheduled ||
        !_foreground ||
        !(_ticker?.value.enabled ?? true) ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    final identity = '${widget.store.profileEpoch}:${theaterIdentity(drama)}';
    if (_completedEntry == identity) return;
    _autoScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScheduled = false;
      if (!mounted ||
          !identical(preview.drama, drama) ||
          !preview.ended ||
          !_foreground ||
          !(_ticker?.value.enabled ?? true) ||
          !(ModalRoute.of(context)?.isCurrent ?? true)) {
        return;
      }
      _completedEntry = identity;
      unawaited(_openFull(completed: true));
    });
  }

  void _visibility() {
    if (!mounted) return;
    _preview!.setVisible(
      _foreground &&
          !_opening &&
          !widget.store.locked &&
          (_ticker?.value.enabled ?? true) &&
          (ModalRoute.of(context)?.isCurrent ?? true),
    );
    _autoOpen();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _visibility();
  }

  void _feedChanged() {
    if (!mounted) return;
    // Full playback writes real history. Keep the originating batch stable,
    // but never preserve data across access/user changes.
    if (_opening &&
        _openedEpoch == widget.store.profileEpoch &&
        !widget.store.locked &&
        _preview!.drama != null &&
        widget.store.allowsSource(_preview!.drama!.source)) {
      return;
    }
    final previous = _items.isEmpty ? null : _items[_index];
    final items = List<TheaterPick>.of(_feed!.items);
    _items = items;
    final batch = items.map((p) => theaterIdentity(p.drama)).join('|');
    final retained = previous == null ? -1 : items.indexOf(previous);
    if (batch != _batch || (retained >= 0 && retained != _index)) {
      final nextIndex = retained >= 0 ? retained : 0;
      final reposition = nextIndex != _index;
      _index = nextIndex;
      _batch = batch;
      // 纯追加不跳页，避免取消正在进行的手势；只有裁剪/重置才校正位置。
      if (reposition) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pages.hasClients) _pages.jumpToPage(_index);
        });
      }
    }
    _selectPick(items.isEmpty ? null : items[_index]);
    _feed!.position(_index);
    _visibility();
    setState(() {});
    if (items.isNotEmpty && !_feed!.loading && !_feed!.loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _nearEnd();
      });
    }
  }

  void _nearEnd() {
    if (!_opening &&
        _index >= _items.length - 4 &&
        _feed!.error == null &&
        _feed!.notice == null) {
      unawaited(_feed!.loadMore());
    }
  }

  void _move(int delta) {
    final next = _index + delta;
    if (next < 0) {
      widget.onExitUp?.call();
      return;
    }
    if (next >= _items.length) {
      unawaited(_feed!.loadMore(retry: true));
      return;
    }
    if (!_pages.hasClients) return;
    _pages.animateToPage(
      next,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Future<void> _openFull({bool completed = false}) async {
    final preview = _preview!;
    final detail = preview.detail;
    if (_opening ||
        detail == null ||
        detail.episodes.isEmpty ||
        !widget.store.allowsSource(detail.drama.source) ||
        widget.store.locked) {
      return;
    }
    final epoch = widget.store.profileEpoch;
    _opening = true;
    _openedEpoch = epoch;
    try {
      await preview.suspend(requireStopped: true);
      if (!mounted ||
          epoch != widget.store.profileEpoch ||
          widget.store.locked ||
          !widget.store.allowsSource(detail.drama.source)) {
        return;
      }
      final nextEpisode = completed && detail.episodes.length > 1;
      final index = nextEpisode ? 1 : 0;
      final position = completed ? Duration.zero : preview.position;
      if (widget.onOpenFull != null) {
        await widget.onOpenFull!(context, detail, position);
      } else {
        // 手动入口和首集结束自动入口共用同一完整播放页面。
        final handle = PlaybackHandle(
          repository: AppScope.of(context).repository,
          store: widget.store,
          detail: detail,
          index: index,
          position: position.inMilliseconds / 1000,
        );
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => PlaybackPage(store: widget.store, handle: handle),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法打开全集，请重试')));
      }
    } finally {
      _opening = false;
      if (mounted) _visibility();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibility);
    _feed?.removeListener(_feedChanged);
    _feed?.dispose();
    _preview?.removeListener(_changed);
    _preview?.dispose();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feed = _feed!;
    final preview = _preview!;
    return Theme(
      data: Theme.of(context).copyWith(
        brightness: Brightness.dark,
        textTheme: Theme.of(
          context,
        ).textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          bottom: false,
          child: Focus(
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                _move(1);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                _move(-1);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: GestureDetector(
              key: const ValueKey('theater-navigation-toggle'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (event) {
                final height = MediaQuery.sizeOf(context).height;
                if (event.localPosition.dy > height * .2 &&
                    event.localPosition.dy < height * .75) {
                  const TheaterNavigationToggleNotification().dispatch(context);
                }
              },
              child: Stack(
                children: [
                  if (_items.isNotEmpty)
                    NotificationListener<ScrollNotification>(
                      // Paging recommendations must not hide the shell's tab bar.
                      onNotification: (_) => true,
                      child: PageView.builder(
                        key: const ValueKey('theater-preview-flow'),
                        controller: _pages,
                        scrollDirection: Axis.vertical,
                        itemCount: _items.length,
                        onPageChanged: (index) {
                          if (index >= _items.length) return;
                          _index = index;
                          _selectPick(_items[index]);
                          feed.position(index);
                          _nearEnd();
                          setState(() {});
                        },
                        itemBuilder: (context, index) {
                          final pick = _items[index];
                          final active = index == _index;
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              // Neighbours have metadata only, never a Player or video layer.
                              if (active && preview.backend != null)
                                preview.backend!.buildVideo(),
                              const IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.black54,
                                        Colors.transparent,
                                        Colors.transparent,
                                        Colors.black87,
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              if (active && preview.loading)
                                const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              if (active && preview.error != null)
                                Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        preview.error!,
                                        textAlign: TextAlign.center,
                                      ),
                                      FilledButton(
                                        onPressed: preview.retry,
                                        child: const Text('重试预览'),
                                      ),
                                    ],
                                  ),
                                ),
                              Positioned(
                                left: 12,
                                right: 12,
                                bottom: MediaQuery.viewPaddingOf(
                                  context,
                                ).bottom,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (active && index == _items.length - 1)
                                      if (feed.loadingMore)
                                        const LinearProgressIndicator()
                                      else
                                        TextButton.icon(
                                          key: const ValueKey(
                                            'theater-load-more',
                                          ),
                                          onPressed: () =>
                                              feed.loadMore(retry: true),
                                          icon: const Icon(Icons.refresh),
                                          label: Text(
                                            feed.error ??
                                                feed.notice ??
                                                '继续加载推荐',
                                          ),
                                        ),
                                    Text(
                                      pick.drama.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.copyWith(color: Colors.white),
                                    ),
                                    Text(
                                      pick.reason,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 8),
                                    GlassSurface(
                                      radius: 12,
                                      showShadow: false,
                                      child: TextButton(
                                        key: const ValueKey(
                                          'theater-open-full',
                                        ),
                                        style: TextButton.styleFrom(
                                          foregroundColor: Colors.white,
                                          minimumSize: const Size(0, 40),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 6,
                                          ),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed:
                                            active &&
                                                preview.detail != null &&
                                                !_opening
                                            ? () => _openFull()
                                            : null,
                                        child: Text(
                                          '看全集 · 共${active && preview.detail != null ? preview.detail!.episodes.length : pick.drama.episodes}集',
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    )
                  else
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: feed.loading
                            ? const CircularProgressIndicator()
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    feed.error ?? '暂无新推荐，请稍后换一批',
                                    textAlign: TextAlign.center,
                                  ),
                                  OutlinedButton(
                                    onPressed: feed.reload,
                                    child: const Text('重试'),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  Positioned(
                    top: 0,
                    left: 12,
                    right: 12,
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '剧场 · 首集预览',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          focusNode: widget.entryFocus,
                          tooltip: '刷新推荐',
                          onPressed: feed.loading ? null : feed.reload,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
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

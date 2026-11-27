import 'dart:io';

import 'package:flutter/material.dart';

import '../../core_bridge.dart';
import '../../cover_loader.dart';
import '../../models.dart';
import '../app_motion.dart';
import '../app_scope.dart';

const vipGold = Color(0xFFF6C86B);
const onVipGold = Color(0xFF40300D);

class VipBadge extends StatelessWidget {
  const VipBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: vipGold,
      borderRadius: BorderRadius.circular(6),
    ),
    child: const Text(
      'VIP',
      style: TextStyle(
        color: onVipGold,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        height: 1.2,
      ),
    ),
  );
}

class DramaCover extends StatelessWidget {
  const DramaCover({
    super.key,
    required this.drama,
    this.radius = 12,
    this.details = true,
    this.rank,
    this.followed = false,
  });
  final Drama drama;
  final double radius;
  final bool details;
  final int? rank;
  final bool followed;
  static const imagesDisabled = bool.fromEnvironment('DISABLE_REMOTE_IMAGES');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.movie_creation_outlined,
          size: 36,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          placeholder,
          if (!imagesDisabled && drama.id.isNotEmpty)
            CoverImage(
              key: ValueKey('${drama.id}\u0000${drama.cover}'),
              drama: drama,
              repository: AppScope.of(context).repository,
              placeholder: placeholder,
            ),
          if (details)
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xC7000000)],
                  ),
                ),
              ),
            ),
          if (details && drama.episodes > 0)
            Positioned(
              left: 9,
              bottom: 9,
              child: Text(
                '共 ${drama.episodes} 集',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          if (details && drama.vip)
            Positioned(
              left: rank == null ? 8 : null,
              right: rank == null ? null : 8,
              top: followed ? (rank == null ? 42 : 74) : 8,
              child: const VipBadge(),
            ),
          if (rank case final rank?)
            Positioned(
              left: 0,
              top: followed ? 42 : 0,
              child: RankBadge(rank: rank),
            ),
          if (followed) const Positioned(left: 6, top: 6, child: FollowHeart()),
        ],
      ),
    );
  }
}

/// 追剧标记的粉色：心形与「已追剧」的站源胶囊共用同一个值，避免两处漂移。
const followHeartColor = Color(0xFFFF718D);

/// 只表达追剧状态，不拦截海报点击，也不占用菜单行宽。
class FollowHeart extends StatelessWidget {
  const FollowHeart({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Semantics(
      label: '已追剧',
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .55),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.favorite_rounded,
          size: 18,
          color: followHeartColor,
        ),
      ),
    ),
  );
}

class RankBadge extends StatelessWidget {
  const RankBadge({super.key, required this.rank});
  final int rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = rank <= 3;
    return Container(
      constraints: const BoxConstraints(minWidth: 28),
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: !top
            ? const Color(0x8C000000)
            : theme.brightness == Brightness.dark
            ? theme.colorScheme.inversePrimary
            : theme.colorScheme.primary,
        borderRadius: const BorderRadius.only(bottomRight: Radius.circular(10)),
      ),
      child: Text(
        '$rank',
        style: TextStyle(
          color: Colors.white,
          fontSize: top ? 15 : 13,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}

const coverDecodeTiers = <int>[128, 192, 256, 384, 512, 768, 1024];

int coverDecodeWidth(
  double logicalWidth,
  double devicePixelRatio, {
  bool lowResolution = false,
}) {
  // 模糊背景不需要海报细节；离散档位避免窗口微调产生大量解码缓存。
  if (lowResolution) return coverDecodeTiers.first;
  final pixels = logicalWidth * devicePixelRatio;
  if (!pixels.isFinite || pixels <= 0) return 512;
  return coverDecodeTiers.firstWhere(
    (width) => width >= pixels,
    orElse: () => coverDecodeTiers.last,
  );
}

class CoverImage extends StatefulWidget {
  const CoverImage({
    super.key,
    required this.drama,
    required this.repository,
    required this.placeholder,
    this.retryable = true,
    this.lowResolution = false,
  });
  final Drama drama;
  final AppRepository repository;
  final Widget placeholder;
  final bool retryable;
  final bool lowResolution;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  final _decodedWidths = <String, Set<int>>{};
  CoverRequest? _request;
  Future<String>? _file;
  String? _knownPath;
  int _generation = 0;
  Listenable? _coverChanges;
  Object? _coverContext;
  int _revision = 0;
  bool _failed = false;
  bool _retryOnFailure = false;
  bool _retryQueued = false;

  /// 是否已经排了一帧末的失败登记。
  ///
  /// 失败是在 `build` 里发现的，但实例字段不能在 `build` 期间改：那会让
  /// 「重建是否幂等」变得无法推理，也容易在将来演变成 build 中 `setState`。
  /// 这里只排一次帧末回调，把记账挪到安全时机，绘制结果完全一致。
  bool _failureQueued = false;
  String? _failedPath;

  /// 同一路径与解码宽度下复用同一个 [Image] 实例。
  ///
  /// 列表因加载状态或滚动重建时，element 发现 widget 未变会直接跳过，
  /// 不必重复解析图片流、重建解码配置。
  String? _imagePath;
  int? _imageWidth;
  Widget? _image;
  bool _animateCover = false;

  @override
  void initState() {
    super.initState();
    _revision = widget.repository.catalogUpdates.coverRevision(widget.drama.id);
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    widget.repository.cacheChanges.addListener(_cacheCleared);
    _listenForCoverChanges();
    _load();
  }

  @override
  void didUpdateWidget(covariant CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.catalogUpdates.removeListener(_metadataChanged);
      widget.repository.catalogUpdates.addListener(_metadataChanged);
      oldWidget.repository.cacheChanges.removeListener(_cacheCleared);
      widget.repository.cacheChanges.addListener(_cacheCleared);
      _listenForCoverChanges();
    }
    if (oldWidget.repository != widget.repository ||
        oldWidget.drama.source != widget.drama.source ||
        oldWidget.drama.id != widget.drama.id ||
        oldWidget.drama.cover != widget.drama.cover) {
      _failed = _retryOnFailure = false;
      _failedPath = null;
      _revision = widget.repository.catalogUpdates.coverRevision(
        widget.drama.id,
      );
      _load();
    }
  }

  @override
  void dispose() {
    _request?.cancel();
    _coverChanges?.removeListener(_coverChanged);
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    widget.repository.cacheChanges.removeListener(_cacheCleared);
    super.dispose();
  }

  void _listenForCoverChanges() {
    _coverChanges?.removeListener(_coverChanged);
    _coverChanges = widget.repository.coverChanges;
    _coverChanges?.addListener(_coverChanged);
  }

  void _coverChanged() {
    if (!mounted ||
        _coverContext == widget.repository.coverContext(widget.drama)) {
      return;
    }
    // 身份/授权变化必须换掉已完成的 Future；仅重建会继续展示旧 snapshot。
    _listenForCoverChanges();
    _cacheCleared();
  }

  void _cacheCleared() {
    if (!mounted) return;
    _decodedWidths.clear();
    _retryOnFailure = false;
    setState(() => _load(useKnown: false));
  }

  void _load({bool useKnown = true}) {
    _generation++;
    _coverContext = widget.repository.coverContext(widget.drama);
    _knownPath = useKnown ? widget.repository.knownCover(widget.drama) : null;
    _retryQueued = false;
    _request?.cancel();
    _request = null;
    _image = null;
    _imagePath = null;
    _imageWidth = null;
    _failureQueued = false;
    _failed = false;
    _failedPath = null;
    _file = CoverLoader.cached(widget.repository, widget.drama);
    _animateCover = _file == null && _knownPath == null;
    if (_file != null) return;
    final request = _request = CoverLoader.request(
      widget.repository,
      widget.drama,
    );
    _file = request.file;
  }

  /// 把「这一帧发现加载失败」记账到帧末。
  ///
  /// 同一帧内可能因为布局/父级重建被调用多次，用 [_failureQueued] 只排一次；
  /// 帧末还要确认这期间没有换过图源（重试 / 切剧），否则这次记账已经过期。
  /// 同一路径已经记过就直接返回，免得每帧都再排一次回调。
  void _recordFailure(String? path) {
    if (_failed && _failedPath == path) return;
    if (_failureQueued) return;
    _failureQueued = true;
    final source = _file;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(source, _file)) return;
      _failureQueued = false;
      _failed = true;
      _failedPath = path;
      if (_retryOnFailure) _queueRetry();
    });
  }

  void _metadataChanged() {
    final revision = widget.repository.catalogUpdates.coverRevision(
      widget.drama.id,
    );
    if (revision == _revision) return;
    _revision = revision;
    _retryOnFailure = true;
    if (_failed) _queueRetry();
  }

  void _queueRetry() {
    if (_retryQueued || !_retryOnFailure) return;
    _retryQueued = true;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      _retryQueued = false;
      if (!_retryOnFailure) return;
      _retryOnFailure = false;
      _retry(_failedPath);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _retry(String? path) async {
    if (!mounted) return;
    final repository = widget.repository;
    final drama = repository.catalogUpdates.current(widget.drama);
    final widths = _decodedWidths.remove(path) ?? const <int>{};
    final generation = ++_generation;
    _request?.cancel();
    // 先同步撤下旧路径，再异步驱逐解码缓存；期间切剧/清理不能重试新用户的图。
    setState(() {
      _request = null;
      _knownPath = null;
      _failed = _retryOnFailure = _retryQueued = _failureQueued = false;
      _failedPath = null;
      _image = null;
      _imagePath = null;
      _imageWidth = null;
      _animateCover = true;
      _file = () async {
        if (path != null) {
          // 同一路径可能经历多个布局档位，逐一清除实际使用过的 ResizeImage 键。
          for (final width in widths) {
            await ResizeImage.resizeIfNeeded(
              width,
              null,
              FileImage(File(path)),
            ).evict();
          }
        }
        // 过期分支可能尚未被 FutureBuilder 订阅；静默结束，避免孤立的错误 Future。
        if (!mounted || generation != _generation) return '';
        return repository.cover(drama, force: true);
      }();
    });
  }

  /// 失败态界面。
  ///
  /// build 期间（`FutureBuilder` / `Image.errorBuilder`）只出界面：失败记账
  /// 一律走 [_recordFailure] 推到帧末，这里既不能改状态，更不能请求重绘。
  Widget _failure(String? path) {
    _recordFailure(path);
    if (!widget.retryable) return widget.placeholder;
    return Center(
      child: IconButton(
        tooltip: '重试海报',
        onPressed: () => _retry(path),
        icon: Icon(
          Icons.refresh_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = coverDecodeWidth(
        constraints.maxWidth,
        MediaQuery.devicePixelRatioOf(context),
        lowResolution: widget.lowResolution,
      );
      return FutureBuilder<String>(
        key: ValueKey(_generation),
        future: _file,
        builder: (context, snapshot) {
          if (_coverContext != widget.repository.coverContext(widget.drama)) {
            return widget.placeholder;
          }
          String? path;
          if (snapshot.connectionState == ConnectionState.done) {
            if (snapshot.hasError || !snapshot.hasData) return _failure(null);
            path = snapshot.data;
          } else {
            // 仅采用本次加载捕获、且当前仍获授权的提示，绝不复用旧 snapshot.data。
            path = _knownPath;
            if (path == null ||
                widget.repository.knownCover(widget.drama) != path) {
              return widget.placeholder;
            }
          }
          if (path == null || path.isEmpty) return _failure(null);
          // 记账「该文件用过哪些解码档」，重试时据此逐个清掉 ResizeImage 缓存。
          // 只写实例字段、不触发重建；同档位重复登记要挡住，免得每次 build
          // 都新建一个 Set。
          if (!(_decodedWidths[path]?.contains(width) ?? false)) {
            (_decodedWidths[path] ??= <int>{}).add(width);
          }
          if (path == _imagePath && width == _imageWidth && _image != null) {
            return _image!;
          }
          _imagePath = path;
          _imageWidth = width;
          return _image = Image.file(
            File(path),
            key: ValueKey((_generation, path)),
            fit: BoxFit.cover,
            cacheWidth: width,
            excludeFromSemantics: true,
            frameBuilder: (context, child, frame, synchronous) => _CoverFrame(
              key: ValueKey((_generation, path)),
              ready: frame != null,
              synchronous: synchronous,
              animate: _animateCover && !widget.lowResolution,
              placeholder: widget.placeholder,
              child: child,
            ),
            errorBuilder: (_, _, _) => _failure(path),
          );
        },
      );
    },
  );
}

/// 文件就绪并不代表解码完成；占位保留到首帧，淡入只在首次异步显示时运行。
class _CoverFrame extends StatefulWidget {
  const _CoverFrame({
    super.key,
    required this.ready,
    required this.synchronous,
    required this.animate,
    required this.placeholder,
    required this.child,
  });

  final bool ready;
  final bool synchronous;
  final bool animate;
  final Widget placeholder;
  final Widget child;

  @override
  State<_CoverFrame> createState() => _CoverFrameState();
}

class _CoverFrameState extends State<_CoverFrame>
    with SingleTickerProviderStateMixin {
  AnimationController? _fade;
  bool _seen = false;

  bool get _skip =>
      !widget.animate ||
      widget.synchronous ||
      AppMotion.reduced(context) ||
      !TickerMode.valuesOf(context).enabled ||
      Scrollable.recommendDeferredLoadingForContext(context);

  void _reveal() {
    if (!widget.ready || _seen) return;
    _seen = true;
    if (_skip) return;
    _fade = AnimationController(
      vsync: this,
      duration: AppMotion.of(context, AppMotion.state),
    )..addStatusListener(_settled);
    _fade!.forward();
  }

  void _settled(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_skip) _fade?.value = 1;
    _reveal();
  }

  @override
  void didUpdateWidget(_CoverFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_skip) _fade?.value = 1;
    _reveal();
  }

  @override
  void dispose() {
    _fade?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.ready) return widget.placeholder;
    final fade = _fade;
    if (fade == null || fade.isCompleted) return widget.child;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(child: widget.placeholder),
          ),
        ),
        FadeTransition(opacity: fade, child: widget.child),
      ],
    );
  }
}

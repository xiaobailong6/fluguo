import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'theater_preview_backend.dart';
import 'theater_recommendations.dart';
import 'theater_cache.dart';

/// One network worker (latest intent wins) and one ordered media-operation lane.
/// Unlike PlaybackSession this never writes history or advances episodes.
class TheaterPreview extends ChangeNotifier {
  TheaterPreview(
    this.repository,
    this.store, {
    PreviewBackend Function()? backend,
  }) : _factory = backend ?? MediaKitPreviewBackend.new {
    _access = _accessKey();
    store.addListener(_storeChanged);
  }
  final AppRepository repository;
  final LocalStore store;
  final PreviewBackend Function() _factory;
  late final _details = TheaterDetailCache(repository, store);

  Future<void> warmNext(Drama drama) async {
    if (!_visible || !_ready || loading || ended || _disposed) return;
    await _details.warm(drama);
  }

  PreviewBackend? backend;
  Drama? drama;
  DramaDetail? detail;
  bool loading = false;
  bool ended = false;
  String? error;
  Duration position = Duration.zero;
  bool _visible = false;
  bool _disposed = false;
  bool _working = false;
  bool _pending = false;
  bool _ready = false;
  bool _adopted = false;
  int _generation = 0;
  late String _access;
  PlaybackPlan? _plan;
  Future<void> _media = Future.value();
  StreamSubscription<bool>? _completion;
  StreamSubscription<String>? _errors;

  String _accessKey() =>
      '${store.profile.id}:${store.profileEpoch}:${store.locked}:${store.sources.map((s) => s.id).join(',')}';
  void _storeChanged() {
    final key = _accessKey();
    if (key == _access) return;
    _access = key;
    _details.invalidate();
    drama = null;
    detail = null;
    position = Duration.zero;
    unawaited(suspend());
  }

  bool _valid(int generation) =>
      !_disposed &&
      _visible &&
      generation == _generation &&
      drama != null &&
      !store.locked &&
      store.allowsSource(drama!.source);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _serial(Future<void> Function() action) {
    final task = _media.then((_) => action());
    // A backend error must not poison subsequent stop/dispose operations.
    _media = task.catchError((Object _) {});
    return task;
  }

  Future<void> _release(PlaybackPlan? plan) async {
    if (plan == null || plan.session.isEmpty) return;
    try {
      await repository.release(plan.session);
    } catch (_) {
      /* No credentials in logs. */
    }
  }

  Future<void> _stop() => _serial(() async {
    try {
      await backend?.stop();
    } finally {
      final old = _plan;
      _plan = null;
      await _release(old);
    }
  });

  void select(Drama? next) {
    if (drama != null &&
        next != null &&
        theaterIdentity(drama!) == theaterIdentity(next)) {
      return;
    }
    _generation++;
    _pending = false;
    _adopted = false;
    loading = false;
    drama = next;
    detail = null;
    position = Duration.zero;
    ended = false;
    error = null;
    _ready = false;
    unawaited(_stop().catchError((Object _) {}));
    _request();
  }

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    if (!value) {
      unawaited(suspend());
      return;
    }
    _visible = true;
    _generation++;
    _request();
  }

  /// 接收回传的播放现场：同一播放器继续在剧场里渲染，不再重新加载。
  void adopt(
    PreviewBackend backend,
    PlaybackPlan plan,
    Drama drama,
    DramaDetail? detail,
    Duration position,
  ) {
    if (_disposed) {
      unawaited(backend.dispose());
      return;
    }
    final previous = this.backend;
    if (previous != null && !identical(previous, backend)) {
      unawaited(
        _serial(() async {
          await previous.stop();
          await previous.dispose();
        }).catchError((Object _) {}),
      );
    }
    _generation++;
    _adopted = true;
    _pending = false;
    loading = false;
    ended = false;
    error = null;
    this.drama = drama;
    this.detail = detail;
    this.position = position;
    _ready = true;
    this.backend = backend;
    _plan = plan;
    _attach(backend);
    _notify();
  }

  /// 把正在播的播放器整体交给正式播放页接管。
  ///
  /// 返回的 backend（含底层 Player 与渲染控制器）和当前 PlaybackPlan 从此
  /// 归调用方所有，剧场不再触碰也不再释放；剧场自身回到"未加载"状态，
  /// 下次需要预览时按常规流程新建 backend。无正在播放的内容时返回 null。
  ({PreviewBackend backend, PlaybackPlan plan})? steal() {
    final backend = this.backend;
    final plan = _plan;
    if (_disposed || !_ready || backend == null || plan == null) return null;
    position = backend.position;
    this.backend = null;
    _plan = null;
    _ready = false;
    _pending = false;
    loading = false;
    detail = null;
    ended = false;
    _generation++;
    unawaited(_completion?.cancel());
    unawaited(_errors?.cancel());
    _completion = null;
    _errors = null;
    _notify();
    return (backend: backend, plan: plan);
  }

  Future<void> suspend({bool requireStopped = false}) {
    if (_ready) position = backend?.position ?? position;
    _details.invalidate();
    detail = null;
    _visible = false;
    _ready = false;
    _adopted = false;
    _generation++;
    _pending = false;
    loading = false;
    _notify();
    return _stop().catchError((Object failure) {
      // Fail closed before handing audio ownership to full playback.
      if (requireStopped) throw failure;
    });
  }

  void retry() {
    ended = false;
    error = null;
    detail = null;
    if (drama != null) _details.forget(drama!);
    _generation++;
    _ready = false;
    _adopted = false;
    _request();
  }

  void _attach(PreviewBackend target) {
    unawaited(_completion?.cancel());
    unawaited(_errors?.cancel());
    _completion = target.completed.listen((done) {
      if (done && _ready && _valid(_generation)) {
        position = target.position;
        ended = true;
        _notify();
      }
    });
    _errors = target.errors.listen((_) {
      if (_ready && _valid(_generation)) {
        error = '预览播放失败，请重试';
        _notify();
      }
    });
  }

  void _request() {
    if (_adopted) {
      // 播放现场由 adopt 接回，保持现状即可，不重新加载。
      loading = false;
      _notify();
      return;
    }
    if (!_valid(_generation) || ended) {
      _notify();
      return;
    }
    loading = true;
    _pending = true;
    _notify();
    if (!_working) unawaited(_run());
  }

  Future<void> _run() async {
    _working = true;
    try {
      while (_pending && !_disposed) {
        _pending = false;
        final generation = _generation;
        final selected = drama!;
        PlaybackPlan? incoming;
        bool releasedIncoming = false;
        try {
          // Stale requests retain their slot until they actually settle.
          final loaded = detail ?? await _details.load(selected);
          if (!_valid(generation)) continue;
          detail = loaded;
          if (loaded.episodes.isEmpty) throw StateError('empty');
          incoming = await repository.resolve(
            loaded.drama,
            loaded.episodes.first,
          );
          if (!_valid(generation)) {
            await _release(incoming);
            continue;
          }
          if (incoming.url.isEmpty) throw StateError('empty media');
          final plan = incoming;
          await _serial(() async {
            if (!_valid(generation)) {
              await _release(plan);
              return;
            }
            await backend?.stop();
            final previous = _plan;
            _plan = null;
            await _release(previous);
            if (!_valid(generation)) {
              await _release(plan);
              return;
            }
            _plan = plan;
            // 先固定本轮回合的 backend：steal/suspend 可能把字段置空，
            // 闭包内再读字段会空引用。
            final target = backend ??= _factory();
            try {
              if (identical(_completion, null)) {
                _attach(target);
                // open 可能等待原生视频表面，必须先通知页面挂载 Video。
                _notify();
              }
              await target.open(plan, position);
              if (!_valid(generation)) {
                await target.stop();
                return;
              }
              _ready = true;
              await target.play();
            } catch (_) {
              // 留在同一媒体通道内清理，不能等待重新排入自身的_stop。
              _ready = false;
              try {
                await target.stop();
              } finally {
                if (identical(_plan, plan)) _plan = null;
                await _release(plan);
                releasedIncoming = true;
              }
              rethrow;
            }
          });
          if (_valid(generation)) {
            loading = false;
            _notify();
          }
        } catch (_) {
          // Never surface raw URLs, headers or decoder logs.
          if (!releasedIncoming && !identical(incoming, _plan)) {
            await _release(incoming);
          }
          if (_valid(generation)) {
            loading = false;
            error = '预览加载失败，请重试';
            _notify();
          }
        }
      }
    } finally {
      _working = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _pending = false;
    _details.dispose();
    store.removeListener(_storeChanged);
    unawaited(_completion?.cancel());
    unawaited(_errors?.cancel());
    unawaited(
      _serial(() async {
        try {
          await backend?.stop();
        } finally {
          await _release(_plan);
          _plan = null;
          await backend?.dispose();
        }
      }).catchError((Object _) {}),
    );
    super.dispose();
  }
}

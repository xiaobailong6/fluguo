import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'models.dart';

class _PreloadWork {
  _PreloadWork(
    this.identity,
    this.drama,
    this.episode,
    this.quality,
    this.online,
  );
  final String identity;
  final Drama drama;
  final Episode episode;
  final int quality;
  final bool online;
  final result = Completer<PlaybackPlan?>();
  bool started = false, cancelled = false, claimed = false;
}

/// 已准备数据与在途请求共用同一份所有权，切集可接管而不重复解析。
class PlaybackPreloader extends ChangeNotifier {
  PlaybackPreloader(
    this.repository, {
    DateTime Function()? now,
    this.delay = const Duration(milliseconds: 200),
    this.claimWait = const Duration(milliseconds: 1500),
  }) : _now = now ?? DateTime.now;

  final AppRepository repository;
  final DateTime Function() _now;
  final Duration delay;
  final Duration claimWait;
  PlaybackPlan? _ready;
  String? _identity;
  _PreloadWork? _work;
  Timer? _delay;
  DateTime _expires = DateTime(2000), _retryAt = DateTime(2000);
  bool _closed = false;
  String error = '';

  bool get loading => _work?.started == true;
  bool get claimed => _work?.claimed == true;
  bool get ready => _ready != null && _now().isBefore(_expires);
  DateTime get expires => _expires;

  void _release(PlaybackPlan plan) =>
      unawaited(repository.release(plan.session).catchError((Object _) {}));
  void _notify() {
    if (!_closed) notifyListeners();
  }

  String get status {
    if (ready) {
      final bytes = _ready!.prefetchedBytes;
      return _ready!.local
          ? '下一集已下载'
          : bytes > 0
          ? '下一集已准备 · 预取 ${(bytes / 1024).ceil()} KB'
          : '下一集播放地址已准备';
    }
    if (_work != null) return '正在准备下一集';
    return error.isNotEmpty ? '下一集预加载暂不可用，切集时会重新获取' : '缓冲充足时提前准备下一集';
  }

  String _key(Drama drama, Episode episode, int quality, bool online) =>
      '${drama.id}\u0000${episode.number}\u0000$quality\u0000$online';

  void prepare(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    if (_closed || claimed) return;
    final identity = _key(drama, episode, quality, online);
    if (_identity != identity) {
      clear();
      _identity = identity;
    }
    if (_ready != null && !ready) {
      _release(_ready!);
      _ready = null;
    }
    if (_ready != null || _work != null || _now().isBefore(_retryAt)) return;
    final work = _work = _PreloadWork(
      identity,
      drama,
      episode,
      quality,
      online,
    );
    _delay = Timer(delay, () {
      _delay = null;
      unawaited(_start(work));
    });
    _notify();
  }

  Future<void> _start(_PreloadWork work) async {
    if (work.started || work.cancelled || _closed) return;
    work.started = true;
    _notify();
    if (work.cancelled || _closed || !identical(_work, work)) return;
    try {
      final plan = await repository.preload(
        work.drama,
        work.episode,
        quality: work.quality,
        online: work.online,
      );
      if (work.cancelled || _closed || !identical(_work, work)) {
        if (plan != null) _release(plan);
        return;
      }
      if (plan == null || plan.url.isEmpty) {
        if (plan != null) _release(plan);
        throw AppFailure('未取得预加载结果');
      }
      var expiry = _now().add(const Duration(minutes: 2));
      if (plan.expiresAt > 0) {
        final authorizationExpiry = DateTime.fromMillisecondsSinceEpoch(
          plan.expiresAt,
        ).subtract(const Duration(seconds: 5));
        if (authorizationExpiry.isBefore(expiry)) expiry = authorizationExpiry;
      }
      if (!expiry.isAfter(_now())) {
        _release(plan);
        throw AppFailure('下一集播放凭证即将过期');
      }
      _expires = expiry;
      error = '';
      _work = null;
      if (!work.claimed) _ready = plan;
      work.result.complete(plan);
    } catch (failure) {
      if (work.cancelled || _closed || !identical(_work, work)) return;
      error = failure.toString();
      _retryAt = _now().add(const Duration(seconds: 30));
      _work = null;
      work.result.complete(null);
    } finally {
      _notify();
    }
  }

  PlaybackPlan? take(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    final result = _identity == _key(drama, episode, quality, online) && ready
        ? _ready
        : null;
    if (result != null) _ready = null;
    clear();
    return result;
  }

  /// 前台切集只接管同身份任务；等待有上限，失败/超时返回 null 交回普通加载。
  Future<PlaybackPlan?>? takeOrWait(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    if (_closed) return null;
    if (_identity != _key(drama, episode, quality, online) || claimed) {
      clear();
      return null;
    }
    if (ready) {
      return Future.value(
        take(drama, episode, quality: quality, online: online),
      );
    }
    final work = _work;
    if (work == null) {
      clear();
      return null;
    }
    work.claimed = true;
    _delay?.cancel();
    _delay = null;
    unawaited(_start(work));
    return work.result.future.timeout(
      claimWait,
      onTimeout: () {
        if (identical(_work, work)) _cancelWork();
        return null;
      },
    );
  }

  void _cancelWork() {
    _delay?.cancel();
    _delay = null;
    final work = _work;
    _work = null;
    if (work == null) return;
    work.cancelled = true;
    if (work.started) {
      unawaited(repository.cancelPreload().catchError((Object _) {}));
    }
    if (!work.result.isCompleted) work.result.complete(null);
  }

  /// 让路时只取消未完成的预取，已缓存的有效结果保留供切集使用。
  void pause() {
    _cancelWork();
    _notify();
  }

  void clear() {
    _cancelWork();
    final old = _ready;
    _ready = null;
    _identity = null;
    _retryAt = DateTime(2000);
    error = '';
    if (old != null) _release(old);
    _notify();
  }

  @override
  void dispose() {
    _closed = true;
    clear();
    super.dispose();
  }
}

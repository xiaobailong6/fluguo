import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app_foreground.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';

class DownloadOverview extends ChangeNotifier with WidgetsBindingObserver {
  DownloadOverview(
    this.repository,
    this.store, {
    this.interval = const Duration(seconds: 2),
    this.idleInterval = const Duration(seconds: 10),
  }) {
    _foreground = appForeground;
    // 纯逻辑测试可以没有绑定；正式应用由生命周期通知立即暂停/恢复轮询。
    try {
      _binding = WidgetsBinding.instance;
      _binding!.addObserver(this);
    } catch (_) {}
    store.addListener(_sync);
    repository.downloadChanges.addListener(_downloadsChanged);
    _sync();
  }

  final AppRepository repository;
  final LocalStore store;
  final Duration interval;
  final Duration idleInterval;
  WidgetsBinding? _binding;
  Timer? _timer;
  int? _epoch;
  int _request = 0;
  int _failures = 0;
  bool _disposed = false;
  bool _foreground = true;
  bool _refreshAgain = false;
  Future<void>? _refreshing;
  List<DownloadJob> _jobs = const [];

  bool get available => store.canDownload && repository.supportsDownloads;
  List<DownloadJob> get jobs => _jobs;
  int get active => _jobs.where((job) => job.active || job.converting).length;
  int get completed => _jobs.where((job) => job.completed).length;
  int get completedBytes => _jobs
      .where((job) => job.completed)
      .fold(0, (total, job) => total + job.bytes);
  DownloadJob? get current =>
      _jobs.where((job) => job.state == 'downloading').firstOrNull ??
      _jobs.where((job) => job.active).firstOrNull;

  void _sync() {
    if (_disposed) return;
    if (!available) {
      _stop();
      return;
    }
    if (_epoch != store.profileEpoch) {
      _epoch = store.profileEpoch;
      _request++;
      _failures = 0;
      _replace(const []);
      unawaited(refresh());
    }
  }

  void _downloadsChanged() {
    if (_disposed) return;
    if (!available || _epoch != store.profileEpoch) {
      _sync();
    } else {
      unawaited(refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (_disposed || visible == _foreground) return;
    _foreground = visible;
    if (visible) {
      unawaited(refresh());
    } else {
      // 只停定时轮询：转换收尾还要靠显式 refresh 拿到最新列表，
      // 因此在途请求的结果继续生效，也不作废后续主动刷新。
      _cancelTimer();
    }
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _stop() {
    _cancelTimer();
    _epoch = null;
    _request++;
    _failures = 0;
    _refreshAgain = false;
    _replace(const []);
  }

  static String _signature(List<DownloadJob> jobs) => [
    for (final job in jobs)
      '${job.id}|${job.state}|${job.progress}|${job.bytes}|${job.total}|'
          '${job.actualQuality}|${job.error}|${job.drama.title}|'
          '${job.revision}|${job.archived}',
  ].join('\n');

  void _replace(List<DownloadJob> jobs) {
    if (identical(jobs, _jobs) || _signature(jobs) == _signature(_jobs)) {
      return;
    }
    _jobs = jobs;
    if (!_disposed) notifyListeners();
  }

  /// 显式刷新：操作完成、转换收尾、回到前台时调用，后台也真正读取。
  Future<void> refresh() =>
      _requestRefresh(resetFailures: true, explicit: true);

  Future<void> _requestRefresh({
    required bool resetFailures,
    bool explicit = false,
  }) {
    if (_disposed) return Future.value();
    if (resetFailures) _failures = 0;
    if (explicit) _cancelTimer();
    if (!available) return Future.value();
    // 只有定时轮询受可见性约束；显式刷新在后台同样执行。
    if (!explicit && !_foreground) return Future.value();
    _refreshAgain = true;
    if (_refreshing case final pending?) return pending;
    final done = Completer<void>();
    _refreshing = done.future;
    unawaited(_refreshLoop(done));
    return done.future;
  }

  Future<void> _refreshLoop(Completer<void> done) async {
    try {
      while (_refreshAgain && !_disposed && available) {
        _refreshAgain = false;
        final request = _request;
        try {
          final jobs = await repository.downloads();
          if (!_disposed && request == _request) {
            _failures = 0;
            _replace(jobs);
          }
        } catch (_) {
          if (!_disposed && request == _request) {
            _failures = (_failures + 1).clamp(1, 4);
          }
        }
      }
    } finally {
      _refreshing = null;
      _schedule();
      done.complete();
    }
  }

  void _schedule() {
    _cancelTimer();
    if (_disposed || !available || !_foreground) return;
    final Duration delay;
    if (_failures > 0) {
      delay = Duration(seconds: const [2, 4, 8, 10][_failures - 1]);
    } else {
      // 转换依赖此总览派发，不能按下载页是否可见或下载网络是否空闲停掉。
      final working = _jobs.any(
        (job) => job.active || job.converting || job.state == 'removing',
      );
      delay = working ? interval : idleInterval;
    }
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_requestRefresh(resetFailures: false));
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _refreshAgain = false;
    _cancelTimer();
    _binding?.removeObserver(this);
    repository.downloadChanges.removeListener(_downloadsChanged);
    store.removeListener(_sync);
    super.dispose();
  }
}

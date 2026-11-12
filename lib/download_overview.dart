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
  // 汇总值跟随列表一起更新：job 不可变、列表在 _replace 整体替换，
  // 因此只在替换时算一遍，getter 不再每次遍历整个列表。
  int _active = 0;
  int _completed = 0;
  int _completedBytes = 0;
  DownloadJob? _current;

  bool get available => store.canDownload && repository.supportsDownloads;
  List<DownloadJob> get jobs => _jobs;
  int get active => _active;
  int get completed => _completed;
  int get completedBytes => _completedBytes;
  DownloadJob? get current => _current;

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

  /// 两批任务是否表示同一状态。
  ///
  /// 原先把所有字段拼成字符串再比较：每 2 秒一次刷新要拼两份，字段越多越贵，
  /// 而且字段里若含分隔符（`|`／换行）会被误判成相同。这里逐项比较同样十个
  /// 字段，判断结果与原逻辑一致，只是不再分配临时字符串。
  static bool _sameJobs(List<DownloadJob> a, List<DownloadJob> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      final left = a[index];
      final right = b[index];
      if (identical(left, right)) continue;
      if (left.id != right.id ||
          left.state != right.state ||
          left.progress != right.progress ||
          left.bytes != right.bytes ||
          left.total != right.total ||
          left.actualQuality != right.actualQuality ||
          left.error != right.error ||
          left.drama.title != right.drama.title ||
          left.revision != right.revision ||
          left.archived != right.archived) {
        return false;
      }
    }
    return true;
  }

  void _replace(List<DownloadJob> jobs) {
    if (identical(jobs, _jobs) || _sameJobs(jobs, _jobs)) {
      return;
    }
    // 外部若交出可变列表，之后原地修改会让汇总与列表脱节；这里保存不可变快照。
    // 快照身份在两次变化之间保持稳定，下游按 identical 判断缓存的逻辑不受影响。
    final snapshot = List<DownloadJob>.unmodifiable(jobs);
    _jobs = snapshot;
    _recount(snapshot);
    if (!_disposed) notifyListeners();
  }

  /// 汇总只在这里算一次；保持原有语义：converting 计入 active 但不算 current，
  /// current 优先 downloading，其次任意 active。
  void _recount(List<DownloadJob> jobs) {
    var active = 0;
    var completed = 0;
    var bytes = 0;
    DownloadJob? downloading;
    DownloadJob? running;
    for (final job in jobs) {
      if (job.active || job.converting) active++;
      if (job.completed) {
        completed++;
        bytes += job.bytes;
      }
      if (downloading == null && job.state == 'downloading') downloading = job;
      if (running == null && job.active) running = job;
    }
    _active = active;
    _completed = completed;
    _completedBytes = bytes;
    _current = downloading ?? running;
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

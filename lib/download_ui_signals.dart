import 'package:flutter/foundation.dart';

/// 只在 debug/test 运行，用实际 build 次数验证更新边界。
@visibleForTesting
void Function(String key)? debugDownloadBuild;

void trackDownloadBuild(String key) {
  assert(() {
    debugDownloadBuild?.call(key);
    return true;
  }());
}

/// 页面只订阅结构；懒列表中已挂载的行按键订阅显示变化。
/// 不替代业务对象原有的 ChangeNotifier，外部队列监听仍收到全部事件。
class DownloadUiSignals {
  final structure = _RowSignal();
  final _rows = <Object, _RowSignal>{};
  bool _disposed = false;

  Listenable row(Object key) => _RowListenable(this, key);

  void changed(Object key) {
    if (!_disposed) _rows[key]?.emit();
  }

  void structureChanged() {
    if (!_disposed) structure.emit();
  }

  void dispose() {
    _disposed = true;
    structure.dispose();
    for (final row in _rows.values) {
      row.dispose();
    }
    _rows.clear();
  }
}

class _RowListenable implements Listenable {
  _RowListenable(this.owner, this.key);
  final DownloadUiSignals owner;
  final Object key;

  @override
  void addListener(VoidCallback listener) {
    if (owner._disposed) return;
    (owner._rows[key] ??= _RowSignal()).addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    final signal = owner._rows[key];
    if (signal == null) return;
    signal.removeListener(listener);
    // 不保存离屏条目的 notifier，也不在通知过程中 dispose 正在派发的对象。
    if (!signal.observed()) owner._rows.remove(key);
  }
}

class _RowSignal extends ChangeNotifier {
  bool observed() => hasListeners;
  void emit() => notifyListeners();
}

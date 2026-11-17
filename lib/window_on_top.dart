import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// 应用级窗口偏好，不进入用户快照；PiP 强制置顶只改变有效值。
class WindowOnTop extends ValueNotifier<bool> {
  WindowOnTop({
    Future<bool> Function()? load,
    Future<void> Function(bool)? save,
    Future<void> Function(bool)? apply,
  }) : _load = load ?? _loadPreference,
       _save = save ?? _savePreference,
       _apply = apply ?? windowManager.setAlwaysOnTop,
       super(false);

  static final instance = WindowOnTop();
  static const preferenceKey = 'desktop_window_always_on_top';

  // 仅启用已经初始化 window_manager 的桌面平台。
  static bool supported() =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  final Future<bool> Function() _load;
  final Future<void> Function(bool) _save;
  final Future<void> Function(bool) _apply;
  Future<void> _tail = Future<void>.value();
  Future<void>? _initialization;
  bool _committed = false;
  bool _pictureInPicture = false;
  int _revision = 0;

  static Future<bool> _loadPreference() async =>
      (await SharedPreferences.getInstance()).getBool(preferenceKey) ?? false;

  static Future<void> _savePreference(bool value) async {
    if (!await (await SharedPreferences.getInstance()).setBool(
      preferenceKey,
      value,
    )) {
      throw StateError('无法保存窗口置顶设置');
    }
  }

  /// 窗口命令和持久化共用队列，避免 PiP 转换与快速切换交错。
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final task = _tail.then((_) => operation());
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  /// 仅在窗口 ready 后调用；读取或插件失败不阻断启动。
  Future<void> initialize() {
    final revision = _revision;
    return _initialization ??= _enqueue(() async {
      try {
        final saved = await _load();
        await _apply(saved || _pictureInPicture);
        _committed = saved;
        if (revision == _revision) value = saved;
      } catch (_) {
        // 保留默认关闭，后续切换仍可重试。
      }
    });
  }

  Future<void> setPreferred(bool next) {
    final revision = ++_revision;
    value = next;
    return _enqueue(() async {
      var saving = false;
      try {
        await _apply(next || _pictureInPicture);
        saving = true;
        await _save(next);
        _committed = next;
      } catch (_) {
        // SharedPreferences 失败时也可能已改内存缓存，需恢复上次成功值。
        if (saving) {
          try {
            await _save(_committed);
          } catch (_) {}
        }
        await _restoreBestEffort();
        if (revision == _revision) value = _committed;
        rethrow;
      }
    });
  }

  Future<void> _restoreBestEffort() async {
    try {
      await _apply(_committed || _pictureInPicture);
    } catch (_) {
      // 插件不可用时无法保证窗口状态，但不能让队列永久失效。
    }
  }

  /// 原生全屏退出可能重设窗口层级，恢复当前偏好而非固定取消置顶。
  Future<void> restore() =>
      _enqueue(() => _apply(_committed || _pictureInPicture));

  /// 把原生 PiP 转换也放进队列，避免恢复旧窗口层级覆盖用户新选择。
  Future<T> transitionPictureInPicture<T>({
    required bool enabled,
    required Future<T> Function() transition,
  }) => _enqueue(() async {
    final previous = _pictureInPicture;
    if (enabled) _pictureInPicture = true;
    late T result;
    try {
      if (enabled) await _apply(true);
      result = await transition();
    } catch (_) {
      _pictureInPicture = previous;
      await _restoreBestEffort();
      rethrow;
    }
    _pictureInPicture = enabled;
    // 转换已成功，置顶插件失败不能让调用者误认为 PiP 没有进入/退出。
    await _restoreBestEffort();
    return result;
  });
}

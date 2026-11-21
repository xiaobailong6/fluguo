import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_device.dart';
import 'media_controls.dart';

/// 默认关闭，仅 Windows runner 实现。设置页和启动恢复共用一个串行队列。
class MiniEdgeSnap extends ChangeNotifier {
  MiniEdgeSnap({
    Future<({bool enabled, bool pause})> Function()? load,
    Future<void> Function(String, bool)? save,
    Future<void> Function(bool)? apply,
  }) : _load = load ?? _loadPreferences,
       _save = save ?? _savePreference,
       _apply = apply ?? _applyNative;

  static final instance = MiniEdgeSnap();
  static const preferenceKey = 'miniEdgeSnap';
  static const pausePreferenceKey = 'miniEdgePause';
  static bool supported() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  final Future<({bool enabled, bool pause})> Function() _load;
  final Future<void> Function(String, bool) _save;
  final Future<void> Function(bool) _apply;
  final _media = MediaControls.instance;
  Future<void> _tail = Future<void>.value();
  bool enabled = false;
  bool autoPause = false;
  String? error;
  bool _hidden = false;
  bool _foreground = true;
  bool _changing = false;
  MiniEdgePauseLease? _lease;

  static Future<({bool enabled, bool pause})> _loadPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    return (
      enabled: preferences.getBool(preferenceKey) ?? false,
      pause: preferences.getBool(pausePreferenceKey) ?? false,
    );
  }

  static Future<void> _savePreference(String key, bool value) async {
    if (!await (await SharedPreferences.getInstance()).setBool(key, value)) {
      throw StateError('无法保存小窗贴边设置');
    }
  }

  static Future<void> _applyNative(bool enabled) => AppDevice.channel
      .invokeMethod<void>('setMiniEdgeSnap', {'enabled': enabled});

  Future<void> _enqueue(Future<void> Function() action) {
    final task = _tail.then((_) => action());
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> restore() => _enqueue(() async {
    if (!supported()) return;
    try {
      final saved = await _load();
      await _apply(saved.enabled);
      enabled = saved.enabled;
      autoPause = saved.pause;
      error = null;
    } catch (failure) {
      error = '恢复小窗贴边设置失败：$failure';
      rethrow;
    } finally {
      notifyListeners();
    }
  });

  Future<void> setEnabled(bool value) => _change(value, pauseOnly: false);
  Future<void> setAutoPause(bool value) => _change(value, pauseOnly: true);

  Future<void> _change(bool value, {required bool pauseOnly}) =>
      _enqueue(() async {
        if (!supported()) throw UnsupportedError('小窗贴边仅支持 Windows');
        final previous = pauseOnly ? autoPause : enabled;
        final key = pauseOnly ? pausePreferenceKey : preferenceKey;
        var saving = false;
        // 禁用/退出不是鼠标展开，不自动起播；失败后也不复活已撤销的凭证。
        cancelResume();
        _changing = true;
        try {
          if (!pauseOnly) await _apply(value);
          saving = true;
          await _save(key, value);
          if (pauseOnly) {
            autoPause = value;
          } else {
            enabled = value;
            _hidden = false;
          }
          error = null;
        } catch (failure) {
          final rollbackErrors = <Object>[];
          if (saving) {
            try {
              await _save(key, previous);
            } catch (rollback) {
              rollbackErrors.add(rollback);
            }
          }
          if (!pauseOnly) {
            try {
              await _apply(previous);
            } catch (rollback) {
              rollbackErrors.add(rollback);
            }
          }
          error = '更新小窗贴边设置失败：$failure';
          if (rollbackErrors.isNotEmpty) {
            error = '$error；回滚失败：${rollbackErrors.join('；')}';
          }
          throw StateError(error!);
        } finally {
          _changing = false;
          notifyListeners();
        }
      });

  /// 只消费状态边沿，重复消息不能暂停新 owner 或重复恢复旧会话。
  void hiddenChanged(bool hidden) {
    if (!supported() || !enabled || hidden == _hidden) return;
    _hidden = hidden;
    if (hidden) {
      _lease = autoPause && _foreground && !_changing
          ? _media.pauseForMiniEdge()
          : null;
    } else {
      final lease = _lease;
      _lease = null;
      if (autoPause && _foreground && !_changing && lease != null) {
        _media.resumeMiniEdge(lease);
      }
    }
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (!foreground) cancelResume();
  }

  void cancelResume() {
    _lease = null;
    _media.invalidateMiniEdgeResume();
  }

  /// 原生禁用、退出、改尺寸、销毁与真实 hover 展开使用不同回调。
  void reset() {
    cancelResume();
    _hidden = false;
  }

  void handleCall(MethodCall call) {
    if (!supported()) return;
    switch (call.method) {
      case 'miniEdgeHidden':
        if (call.arguments case final bool hidden) hiddenChanged(hidden);
      case 'miniEdgeReset':
        reset();
      case 'miniEdgeError':
        cancelResume();
        error = '小窗贴边操作失败：${call.arguments}';
        notifyListeners();
    }
  }

  @override
  void dispose() {
    reset();
    super.dispose();
  }
}

Future<void> restoreMiniEdgeSnap() async {
  if (!MiniEdgeSnap.supported()) return;
  for (final method in ['miniEdgeHidden', 'miniEdgeReset', 'miniEdgeError']) {
    AppDevice.registerCallback(method, (call) async {
      MiniEdgeSnap.instance.handleCall(call);
    });
  }
  await MiniEdgeSnap.instance.restore();
}

Future<void> setMiniEdgeSnap(bool enabled) =>
    MiniEdgeSnap.instance.setEnabled(enabled);
Future<void> setMiniEdgePause(bool enabled) =>
    MiniEdgeSnap.instance.setAutoPause(enabled);

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'core_bridge.dart';

class AppDevice {
  const AppDevice({this.television = false, this.version = ''});
  final bool television;
  final String version;
  static const channel = _DeviceMethodChannel();
  static final _callbacks = <String, Future<dynamic> Function(MethodCall)>{};
  static Future<dynamic> Function(MethodCall)? _deviceHandler;

  /// 附加原生回调，不替换 PiP 已注册的主 handler（注册顺序无关）。
  static void registerCallback(
    String method,
    Future<dynamic> Function(MethodCall) callback,
  ) {
    _callbacks[method] = callback;
    channel.listen();
  }

  static Future<dynamic> _dispatch(MethodCall call) async {
    final callback = _callbacks[call.method];
    if (callback != null) return callback(call);
    return _deviceHandler?.call(call);
  }

  static var _televisionMode = false;
  static var _phoneMode = false;
  static Future<void> _orientationQueue = Future<void>.value();
  static int _holdGeneration = 0;
  static bool _holdRequested = false;
  static bool _orientationHeld = false;
  static PlayerOrientation _orientation = PlayerOrientation.auto;

  // 所有方向请求共用队列，避免解锁、全屏退出与迟到的锁向互相覆盖。
  static Future<void> _queueOrientation(Future<void> Function() action) {
    final next = _orientationQueue.then((_) async {
      try {
        await action();
      } catch (_) {}
    });
    _orientationQueue = next;
    return next;
  }

  /// 临时固定当前画面；Android 在原生侧捕获实际方向（含反向横屏）。
  /// iOS 读取当前界面方向；旧原生包没有该通道时回退至画面横竖方向。
  static Future<void> holdOrientation({required bool landscape}) {
    if (_holdRequested) return _orientationQueue;
    _holdRequested = true;
    final generation = ++_holdGeneration;
    return _queueOrientation(() async {
      if (!_holdRequested || generation != _holdGeneration) return;
      if (defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS) {
        return;
      }
      _orientationHeld = true;
      if (defaultTargetPlatform == TargetPlatform.android) {
        await channel.invokeMethod<void>('holdPlayerOrientation');
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        String? actual;
        try {
          actual = await channel.invokeMethod<String>(
            'playerInterfaceOrientation',
          );
        } catch (_) {}
        if (!_holdRequested || generation != _holdGeneration) return;
        final orientation = switch (actual) {
          'landscapeLeft' => DeviceOrientation.landscapeLeft,
          'landscapeRight' => DeviceOrientation.landscapeRight,
          'portraitDown' => DeviceOrientation.portraitDown,
          'portraitUp' => DeviceOrientation.portraitUp,
          _ =>
            landscape
                ? DeviceOrientation.landscapeLeft
                : DeviceOrientation.portraitUp,
        };
        await SystemChrome.setPreferredOrientations([orientation]);
      }
    });
  }

  /// 仅撤销临时锁向，不修改手机模式或用户的播放方向偏好。
  static Future<void> releaseHeldOrientation() {
    _holdRequested = false;
    ++_holdGeneration;
    return _queueOrientation(() async {
      if (!_orientationHeld) return;
      if (defaultTargetPlatform == TargetPlatform.android) {
        await channel.invokeMethod<void>('releasePlayerOrientationHold');
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _applyPlayerOrientation(_orientation);
      }
      _orientationHeld = false;
    });
  }

  static Future<AppDevice> detect({
    AppDevice fallback = const AppDevice(),
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      try {
        final info = await PackageInfo.fromPlatform();
        return AppDevice(version: info.version);
      } catch (_) {
        return fallback;
      }
    }
    try {
      final data = await channel
          .invokeMapMethod<String, dynamic>('deviceInfo')
          .timeout(const Duration(seconds: 2));
      final television = data?['television'];
      if (television is! bool) return fallback;
      final version = data?['version'];
      return AppDevice(
        television: television,
        version: version is String && version.isNotEmpty
            ? version
            : fallback.version,
      );
    } on PlatformException {
      return fallback;
    } on MissingPluginException {
      return fallback;
    } on TimeoutException {
      return fallback;
    }
  }

  static Future<bool> compatibleRendering() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await channel.invokeMethod<bool>('compatibleRendering') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setCompatibleRendering(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      await channel.invokeMethod('setCompatibleRendering', {
        'enabled': enabled,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setTelevisionMode(bool enabled) {
    _holdRequested = false;
    ++_holdGeneration;
    return _queueOrientation(() async {
      _televisionMode = enabled;
      if (defaultTargetPlatform == TargetPlatform.android) {
        await channel.invokeMethod<void>('setTelevisionMode', {
          'enabled': enabled,
        });
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        _orientation = PlayerOrientation.auto;
        await _applyPlayerOrientation(_orientation);
      }
      _orientationHeld = false;
    });
  }

  static Future<void> setPhoneMode(bool enabled) {
    _phoneMode = enabled;
    return releaseOrientation();
  }

  static Future<void> releaseOrientation() => setPlayerOrientation(
    _phoneMode ? PlayerOrientation.lockedPortrait : PlayerOrientation.auto,
  );

  static Future<void> setPlayerOrientation(PlayerOrientation orientation) {
    _holdRequested = false;
    ++_holdGeneration;
    return _queueOrientation(() async {
      // 显式新策略优先；随后到达的 release 不应恢复旧策略。
      _orientation = orientation;
      await _applyPlayerOrientation(orientation);
      _orientationHeld = false;
    });
  }

  static Future<void> _applyPlayerOrientation(
    PlayerOrientation orientation,
  ) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await channel.invokeMethod<void>('setPlayerOrientation', {
        'mode': orientation.name,
      });
      return;
    }
    await SystemChrome.setPreferredOrientations(switch (_televisionMode
        ? PlayerOrientation.landscape
        : orientation) {
      PlayerOrientation.landscape ||
      PlayerOrientation.lockedLandscape => const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
      PlayerOrientation.portrait ||
      PlayerOrientation.lockedPortrait => const [DeviceOrientation.portraitUp],
      PlayerOrientation.auto => const [],
    });
  }

  static Future<double?> brightness() async {
    try {
      return await channel.invokeMethod<double>('getBrightness');
    } catch (_) {
      return null;
    }
  }

  static Future<void> setBrightness(double value) async {
    try {
      await channel.invokeMethod<void>('setBrightness', {'brightness': value});
    } catch (_) {}
  }

  static Future<void> resetBrightness() async {
    try {
      await channel.invokeMethod<void>('resetBrightness');
    } catch (_) {}
  }

  static Future<double?> volume() async {
    try {
      return await channel.invokeMethod<double>('volume');
    } catch (_) {
      return null;
    }
  }

  static Future<void> setVolume(double value) async {
    try {
      await channel.invokeMethod<void>('setVolume', {'volume': value});
    } catch (_) {}
  }

  static Future<String?> createDocument(String name, String mimeType) async {
    try {
      return await channel.invokeMethod<String>('createDocument', {
        'name': name,
        'mimeType': mimeType,
      });
    } on PlatformException catch (error) {
      throw AppFailure(error.message ?? '无法创建文件');
    }
  }

  static bool supportsVideoExport() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> requestVideoExport() async {
    try {
      return await channel.invokeMethod<bool>('requestVideoExport') ?? false;
    } on PlatformException catch (error) {
      throw AppFailure(error.message ?? '无法申请存储权限');
    }
  }

  static Future<void> exportVideo(
    String source,
    String folder,
    String name,
  ) async {
    try {
      await channel.invokeMethod<void>('exportVideo', {
        'source': source,
        'folder': folder,
        'name': name,
      });
    } on PlatformException catch (error) {
      throw AppFailure(error.message ?? '导出失败');
    }
  }

  static Future<void> deleteDocument(String uri) async {
    try {
      await channel.invokeMethod<bool>('deleteDocument', {'uri': uri});
    } catch (_) {}
  }

  static Future<({int level, bool charging})?> battery() async {
    try {
      final data = await channel.invokeMapMethod<String, dynamic>('battery');
      final level = data?['level'];
      if (level is! int) return null;
      return (level: level, charging: data?['charging'] == true);
    } catch (_) {
      return null;
    }
  }
}

enum PlayerOrientation {
  landscape,
  lockedLandscape,
  portrait,
  lockedPortrait,
  auto,
}

// 保持现有 channel API；未来 PiP 再注册 handler 也不会覆盖附加回调。
class _DeviceMethodChannel extends MethodChannel {
  const _DeviceMethodChannel() : super('duanju/device');

  void listen() => super.setMethodCallHandler(AppDevice._dispatch);

  @override
  void setMethodCallHandler(Future<dynamic> Function(MethodCall)? handler) {
    AppDevice._deviceHandler = handler;
    listen();
  }
}

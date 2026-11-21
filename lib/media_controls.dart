import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum MediaCommand { play, pause, toggle, next, previous, seek }

typedef MediaCommandHandler =
    void Function(
      MediaCommand command,
      Duration? position, {
      int? interruptionId,
    });

@immutable
class MediaState {
  const MediaState({
    required this.title,
    required this.subtitle,
    required this.artwork,
    required this.active,
    required this.playing,
    required this.position,
    required this.duration,
    required this.rate,
    required this.hasPrevious,
    required this.hasNext,
  });

  final String title;
  final String subtitle;
  final String artwork;
  final bool active;
  final bool playing;
  final Duration position;
  final Duration duration;
  final double rate;
  final bool hasPrevious;
  final bool hasNext;

  Map<String, Object> get _identity => {
    'title': title,
    'subtitle': subtitle,
    'artwork': artwork,
    'active': active,
    'playing': playing,
    'durationMs': duration.inMilliseconds ~/ 1000 * 1000,
    'rate': rate,
    'hasPrevious': hasPrevious,
    'hasNext': hasNext,
  };
}

/// 一次贴边暂停的凭证：owner 与意图代次均不可跨会话复用。
class MiniEdgePauseLease {
  const MiniEdgePauseLease._(this.owner, this.generation, this.interruptionId);
  final Object owner;
  final int generation;
  final int interruptionId;
}

class MediaControls {
  MediaControls._();

  static final instance = MediaControls._();
  static const _channel = MethodChannel('duanju/media');
  static const _drift = Duration(milliseconds: 1500);

  static bool get supported => switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };

  bool _listening = false;
  bool _systemPublished = false;
  Object? _owner;
  MediaCommandHandler? _handler;
  Map<String, Object>? _sentIdentity;
  MediaState? _sent;
  DateTime _sentAt = DateTime(2000);
  int _intentGeneration = 0;
  int _edgeInterruption = 0;
  MiniEdgePauseLease? _edgePause;

  /// 使用现有中断协议；本地暂停、换集、睡眠、权限撤销都会 cancelResume。
  /// 负编号与系统音频中断的正编号隔离，不能只凭全局 playing 恢复。
  MiniEdgePauseLease? pauseForMiniEdge() {
    final owner = _owner;
    final handler = _handler;
    if (owner == null ||
        handler == null ||
        _sent?.active != true ||
        _sent?.playing != true) {
      return null;
    }
    invalidateMiniEdgeResume();
    final lease = MiniEdgePauseLease._(
      owner,
      _intentGeneration,
      --_edgeInterruption,
    );
    _edgePause = lease;
    try {
      handler(MediaCommand.pause, null, interruptionId: lease.interruptionId);
      // PlaybackSession 同步发布播放意图；拒绝命令时不能记录虚假的暂停。
      if (!identical(_edgePause, lease) ||
          _sent?.active != false ||
          _sent?.playing != false) {
        invalidateMiniEdgeResume();
        return null;
      }
      return lease;
    } catch (_) {
      invalidateMiniEdgeResume();
      rethrow;
    }
  }

  void resumeMiniEdge(MiniEdgePauseLease lease) {
    if (!identical(_edgePause, lease) ||
        !owns(lease.owner) ||
        lease.generation != _intentGeneration) {
      return;
    }
    invalidateMiniEdgeResume(); // 先消费，重复/重入的展开不能再次播放。
    if (_sent?.active != false || _sent?.playing != false) return;
    _handler?.call(
      MediaCommand.play,
      null,
      interruptionId: lease.interruptionId,
    );
  }

  void invalidateMiniEdgeResume() {
    ++_intentGeneration;
    _edgePause = null;
  }

  bool owns(Object owner) => identical(owner, _owner);

  void update(
    Object owner,
    MediaState state,
    MediaCommandHandler handler, {
    bool system = true,
  }) {
    if (!supported) return;
    if (system && !_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_handle);
    }
    if (!owns(owner)) {
      invalidateMiniEdgeResume();
      _sentIdentity = null;
    } else if (_edgePause != null &&
        (_sent?.title != state.title ||
            _sent?.subtitle != state.subtitle ||
            _sent?.artwork != state.artwork ||
            state.active)) {
      // 同一 owner 换媒体或自行恢复播放，也终结旧暂停凭证。
      invalidateMiniEdgeResume();
    }
    _owner = owner;
    _handler = handler;
    if (_systemPublished != system) {
      if (_systemPublished) {
        unawaited(
          _channel.invokeMethod<void>('clear').catchError((Object _) {}),
        );
      }
      _sentIdentity = null;
      _systemPublished = system;
    }
    final identity = state._identity;
    if (mapEquals(identity, _sentIdentity) && !_drifted(state)) return;
    _sentIdentity = identity;
    _sent = state;
    _sentAt = DateTime.now();
    // Windows贴边可只使用本地控制，不擅自开启系统通知/后台播放。
    if (!system) return;
    unawaited(
      _channel
          .invokeMethod<void>('update', {
            ...identity,
            'durationMs': state.duration.inMilliseconds,
            'positionMs': state.position.inMilliseconds,
          })
          .catchError((Object _) {
            // 通道暂不可用时，下次同步应重新发送；旧请求不能覆盖新状态。
            if (identical(identity, _sentIdentity)) _sentIdentity = null;
          }),
    );
  }

  bool _drifted(MediaState state) {
    final sent = _sent;
    if (sent == null) return true;
    final elapsed = sent.playing
        ? DateTime.now().difference(_sentAt) * sent.rate
        : Duration.zero;
    return (state.position - (sent.position + elapsed)).abs() > _drift;
  }

  void release(Object owner) {
    if (!identical(owner, _owner)) return;
    invalidateMiniEdgeResume();
    _owner = null;
    _handler = null;
    _sentIdentity = null;
    _sent = null;
    if (_systemPublished) {
      unawaited(_channel.invokeMethod<void>('clear').catchError((Object _) {}));
    }
    _systemPublished = false;
  }

  void cancelResume(Object owner, int interruptionId) {
    if (!owns(owner)) return;
    if (_edgePause?.interruptionId == interruptionId) {
      invalidateMiniEdgeResume();
    }
    if (interruptionId < 0) return; // 贴边凭证只在 Dart 会话内使用。
    unawaited(
      _channel
          .invokeMethod<void>('cancelResume', {
            'interruptionId': interruptionId,
          })
          .catchError((Object _) {}),
    );
  }

  void pause() {
    invalidateMiniEdgeResume();
    _handler?.call(MediaCommand.pause, null);
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'command' || !_systemPublished) return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final command = MediaCommand.values.asNameMap()[arguments['command']];
    if (command == null) return;
    invalidateMiniEdgeResume(); // 系统媒体命令优先于边缘自动恢复。
    final position = arguments['positionMs'];
    _handler?.call(
      command,
      position is num && position.isFinite
          ? Duration(milliseconds: position.round())
          : null,
      interruptionId: arguments['interruptionId'] is int
          ? arguments['interruptionId'] as int
          : null,
    );
  }
}

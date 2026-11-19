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
  Object? _owner;
  MediaCommandHandler? _handler;
  Map<String, Object>? _sentIdentity;
  MediaState? _sent;
  DateTime _sentAt = DateTime(2000);

  bool owns(Object owner) => identical(owner, _owner);

  void update(Object owner, MediaState state, MediaCommandHandler handler) {
    if (!supported) return;
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_handle);
    }
    if (!owns(owner)) _sentIdentity = null;
    _owner = owner;
    _handler = handler;
    final identity = state._identity;
    if (mapEquals(identity, _sentIdentity) && !_drifted(state)) return;
    _sentIdentity = identity;
    _sent = state;
    _sentAt = DateTime.now();
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
    _owner = null;
    _handler = null;
    _sentIdentity = null;
    _sent = null;
    unawaited(_channel.invokeMethod<void>('clear').catchError((Object _) {}));
  }

  void cancelResume(Object owner, int interruptionId) {
    if (!owns(owner)) return;
    unawaited(
      _channel
          .invokeMethod<void>('cancelResume', {
            'interruptionId': interruptionId,
          })
          .catchError((Object _) {}),
    );
  }

  void pause() => _handler?.call(MediaCommand.pause, null);

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'command') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final command = MediaCommand.values.asNameMap()[arguments['command']];
    if (command == null) return;
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

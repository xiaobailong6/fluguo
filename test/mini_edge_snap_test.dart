import 'dart:async';

import 'package:duanju_app/app_device.dart';
import 'package:duanju_app/media_controls.dart';
import 'package:duanju_app/mini_edge_snap.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Repository extends FakeRepository {
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan(url: 'memory:${episode.number}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const mediaChannel = MethodChannel('duanju/media');
  late MiniEdgeSnap edge;
  final sessions = <PlaybackSession>[];

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(mediaChannel, (_) async => null);
    edge = MiniEdgeSnap(apply: (_) async {}, save: (_, _) async {});
    await edge.setEnabled(true);
    await edge.setAutoPause(true);
  });
  tearDown(() async {
    edge.dispose();
    for (final session in sessions) {
      session.dispose();
    }
    sessions.clear();
    await pumpEventQueue();
    messenger.setMockMethodCallHandler(mediaChannel, null);
    messenger.setMockMethodCallHandler(AppDevice.channel, null);
    AppDevice.channel.setMethodCallHandler(null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<PlaybackSession> open({bool background = true}) async {
    final store = await openStore();
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(backgroundPlayback: background),
    );
    final session = PlaybackSession(
      repository: _Repository(),
      store: store,
      detail: dramaDetail(drama('edge-${sessions.length}'), count: 2),
      player: FakePlayer(),
      index: 0,
    );
    sessions.add(session);
    await pumpEventQueue();
    return session;
  }

  Future<void> command(String name) async {
    await messenger.handlePlatformMessage(
      mediaChannel.name,
      mediaChannel.codec.encodeMethodCall(
        MethodCall('command', {'command': name}),
      ),
      (_) {},
    );
  }

  test('重复隐藏/展开只暂停恢复一次；原先暂停不恢复', () async {
    final session = await open();
    expect(session.player.state.playing, isTrue);
    edge.hiddenChanged(true);
    expect(session.paused, isTrue);
    edge.hiddenChanged(true);
    edge.hiddenChanged(false);
    await pumpEventQueue();
    expect(session.player.state.playing, isTrue);
    await command('pause');
    edge.hiddenChanged(false);
    edge.hiddenChanged(true);
    edge.hiddenChanged(false);
    expect(session.paused, isTrue);
  });

  for (final action in [
    'manual-pause',
    'toggle-twice',
    'load',
    'sleep',
    'profile',
    'background-disabled',
    'background',
    'disable',
    'pause-disable',
    'exit',
    'error',
    'owner',
    'release-reacquire',
  ]) {
    test('展开不覆盖新意图：$action', () async {
      final session = await open();
      edge.hiddenChanged(true);
      expect(session.paused, isTrue);
      switch (action) {
        case 'manual-pause':
          await command('pause');
        case 'toggle-twice':
          session.togglePlayback();
          session.togglePlayback();
        case 'load':
          await session.play(1, playWhenReady: false);
        case 'sleep':
          late void Function() expire;
          runZoned(
            () => session.setSleepTimer(minutes: 15),
            zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, delay, callback) {
                expire = callback;
                return parent.createTimer(zone, delay, callback);
              },
            ),
          );
          expire();
        case 'profile':
          await session.store.switchProfile(session.store.profile.id);
        case 'background-disabled':
          await session.store.setPlaybackPreferences(
            session.store.playbackPreferences.copyWith(
              backgroundPlayback: false,
            ),
          );
          session.setForeground(false);
        case 'background':
          edge.setForeground(false);
          edge.setForeground(true);
        case 'disable':
          await edge.setEnabled(false);
          await edge.setEnabled(true);
        case 'pause-disable':
          await edge.setAutoPause(false);
          await edge.setAutoPause(true);
        case 'exit':
          edge.handleCall(const MethodCall('miniEdgeReset'));
        case 'error':
          edge.handleCall(const MethodCall('miniEdgeError', 5));
          expect(edge.error, contains('5'));
        case 'owner':
          final other = await open();
          await command('pause');
          edge.hiddenChanged(true); // 重复隐藏不能暂停/登记新 owner。
          edge.hiddenChanged(false);
          expect(other.paused, isTrue);
        case 'release-reacquire':
          MediaControls.instance.release(session);
          session.togglePlayback();
          await pumpEventQueue();
          await command('pause');
      }
      edge.hiddenChanged(false);
      edge.hiddenChanged(false);
      await pumpEventQueue();
      expect(session.paused, isTrue);
      expect(session.player.state.playing, isFalse);
    });
  }

  test('没有媒体 owner 或后台时不制造恢复凭证', () async {
    final session = await open(background: false);
    edge.hiddenChanged(true);
    edge.hiddenChanged(false);
    expect(session.player.state.playing, isTrue);
    edge.setForeground(false);
    await session.store.setPlaybackPreferences(
      session.store.playbackPreferences.copyWith(backgroundPlayback: true),
    );
    edge.hiddenChanged(true);
    expect(session.player.state.playing, isTrue);
    edge.setForeground(true);
    edge.hiddenChanged(false);
  });

  test('拒绝暂停和仅 active 未实际播放都不能产生恢复凭证', () async {
    final controls = MediaControls.instance;
    final owner = Object();
    addTearDown(() => controls.release(owner));
    final commands = <MediaCommand>[];
    void publish(bool playing) => controls.update(
      owner,
      MediaState(
        title: 'test',
        subtitle: '',
        artwork: '',
        active: true,
        playing: playing,
        position: Duration.zero,
        duration: Duration.zero,
        rate: 1,
        hasPrevious: false,
        hasNext: false,
      ),
      (command, position, {int? interruptionId}) {
        commands.add(command);
      },
    );
    publish(false);
    edge.hiddenChanged(true);
    edge.hiddenChanged(false);
    expect(commands, isEmpty);
    publish(true);
    edge.hiddenChanged(true);
    edge.hiddenChanged(false);
    expect(commands, [MediaCommand.pause]);
  });

  test('快速开关串行，保存期间的边缘消息不创建恢复凭证', () async {
    final session = await open();
    final gate = Completer<void>();
    final applied = <bool>[];
    final value = MiniEdgeSnap(
      load: () async => (enabled: true, pause: true),
      apply: (enabled) async {
        applied.add(enabled);
      },
      save: (_, _) => gate.future,
    );
    addTearDown(value.dispose);
    await value.restore();
    final disabling = value.setEnabled(false);
    final enabling = value.setEnabled(true);
    await pumpEventQueue();
    value.hiddenChanged(true);
    expect(session.paused, isFalse);
    gate.complete();
    await Future.wait([disabling, enabling]);
    value.hiddenChanged(false);
    expect(value.enabled, isTrue);
    expect(applied, [true, false, true]);
  });

  test('默认关闭，持久化恢复；非 Windows 无通道操作', () async {
    final applied = <bool>[];
    final fresh = MiniEdgeSnap(
      apply: (value) async {
        applied.add(value);
      },
    );
    addTearDown(fresh.dispose);
    await fresh.restore();
    expect(fresh.enabled, isFalse);
    expect(fresh.autoPause, isFalse);
    await fresh.setEnabled(true);
    await fresh.setAutoPause(true);
    final restored = MiniEdgeSnap(apply: (_) async {});
    addTearDown(restored.dispose);
    await restored.restore();
    expect(restored.enabled, isTrue);
    expect(restored.autoPause, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await fresh.restore();
    await expectLater(fresh.setEnabled(false), throwsUnsupportedError);
    expect(applied, [false, true]);
  });

  for (final failNative in [true, false]) {
    test('操作失败保留配置并回滚；队列仍可重试 native=$failNative', () async {
      final applied = <bool>[];
      final saved = <bool>[];
      var failing = true;
      final value = MiniEdgeSnap(
        apply: (enabled) async {
          applied.add(enabled);
          if (failing && failNative && enabled) throw StateError('native');
        },
        save: (_, enabled) async {
          saved.add(enabled);
          if (failing && !failNative && enabled) throw StateError('save');
        },
      );
      addTearDown(value.dispose);
      await expectLater(value.setEnabled(true), throwsStateError);
      expect(value.enabled, isFalse);
      expect(value.error, isNotNull);
      expect(applied, [true, false]);
      expect(saved, failNative ? isEmpty : [true, false]);
      failing = false;
      await value.setEnabled(true);
      expect(value.enabled, isTrue);
      expect(value.error, isNull);
    });
  }

  test('设备通道保留现有 handler，后来注册也不覆盖边缘回调', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(AppDevice.channel, (_) async => null);
    AppDevice.channel.setMethodCallHandler((call) async {
      calls.add(call.method);
    });
    await restoreMiniEdgeSnap();
    AppDevice.channel.setMethodCallHandler((call) async {
      calls.add(call.method);
    });
    for (final method in ['pictureInPictureChanged', 'miniEdgeError']) {
      await messenger.handlePlatformMessage(
        AppDevice.channel.name,
        AppDevice.channel.codec.encodeMethodCall(MethodCall(method, 42)),
        (_) {},
      );
    }
    expect(calls, ['pictureInPictureChanged']);
    expect(MiniEdgeSnap.instance.error, contains('42'));
  });
}

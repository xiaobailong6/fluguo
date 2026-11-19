import 'dart:async';
import 'dart:math' as math;

import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/media_controls.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Repository extends FakeRepository {
  final second = Completer<PlaybackPlan>();

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => episode.number == 2
      ? second.future
      : const PlaybackPlan(url: 'memory:first');
}

class _CommentRepository extends FakeRepository {
  final starts = <int>[];
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => const PlaybackPlan(
    url: 'memory:comments',
    session: 'current',
    danmakuId: 'fixture',
  );

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    starts.add(startMs);
    return DanmakuPage(
      episodeId: plan.danmakuId,
      startMs: startMs,
      nextMs: math.min(startMs + danmakuWindowMs, durationMs),
      items: const [],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('duanju/media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('旧设置默认关闭；开关往返保存且不改变画中画', () {
    final old = PlaybackPreferences.fromJson({'autoPictureInPicture': true});
    expect(old.backgroundPlayback, isFalse);
    final saved = PlaybackPreferences.fromJson(
      old.copyWith(backgroundPlayback: true).toJson(),
    );
    expect(saved.backgroundPlayback, isTrue);
    expect(saved.autoPictureInPicture, isTrue);
  });

  test('切集后台保持 active；系统暂停立即撤回意图，加载结束不再起播', () async {
    final store = await openStore();
    final repository = _Repository();
    final player = FakePlayer();
    final session = PlaybackSession(
      repository: repository,
      store: store,
      detail: dramaDetail(drama('media'), count: 2),
      player: player,
      index: 0,
    );
    addTearDown(() async {
      session.dispose();
      await pumpEventQueue();
    });
    await pumpEventQueue();
    session.setForeground(false);
    expect(session.paused, isTrue);
    expect(calls, isEmpty);
    session.setForeground(true);
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(backgroundPlayback: true),
    );
    final loading = session.play(1);
    session.setForeground(false);
    await pumpEventQueue();
    expect(calls.last.method, 'update');
    expect(calls.last.arguments['active'], true);
    expect(calls.last.arguments['playing'], false);
    final command = channel.codec.encodeMethodCall(
      const MethodCall('command', {'command': 'pause'}),
    );
    await messenger.handlePlatformMessage(channel.name, command, (_) {});
    expect(session.paused, isTrue);
    repository.second.complete(const PlaybackPlan(url: 'memory:second'));
    await loading;
    expect(player.state.playing, isFalse);
    expect(calls.last.arguments['active'], false);
    session.togglePlayback();
    await pumpEventQueue();
    expect(player.state.playing, isTrue);
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(backgroundPlayback: false),
    );
    expect(session.paused, isTrue);
    expect(calls.last.method, 'clear');
    expect(MediaControls.instance.owns(session), isFalse);
  });

  test('后台听音不请求弹幕，画面恢复立即按当前位置加载且不补拉旧窗口', () async {
    final store = await openStore();
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(backgroundPlayback: true),
    );
    final player = FakePlayer();
    final repo = _CommentRepository();
    final session = PlaybackSession(
      repository: repo,
      store: store,
      detail: dramaDetail(drama('bg'), count: 1),
      player: player,
      index: 0,
    );
    addTearDown(() async {
      session.dispose();
      await pumpEventQueue();
    });
    await pumpEventQueue();
    player.progress(
      const Duration(seconds: 1),
      duration: const Duration(minutes: 2),
    );
    await pumpEventQueue();
    expect(repo.starts, [0]);
    session.setForeground(false);
    expect(session.danmaku.visible, isFalse);
    for (final second in [31, 61, 91]) {
      player.progress(Duration(seconds: second));
      await pumpEventQueue();
    }
    expect(player.state.playing, isTrue);
    expect(repo.starts, [0]);
    session.setForeground(true);
    await pumpEventQueue();
    expect(session.danmaku.visible, isTrue);
    expect(repo.starts, [0, 90000]);
  });
}

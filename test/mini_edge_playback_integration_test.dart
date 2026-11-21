import 'package:duanju_app/media_controls.dart';
import 'package:duanju_app/mini_edge_snap.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'support/fake_player.dart';

void main() {
  testWidgets('默认关闭后台播放也能贴边暂停，不发布系统媒体状态', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    const channel = MethodChannel('duanju/media');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return null;
    });
    final store = await openStore();
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(backgroundPlayback: false),
    );
    final player = FakePlayer();
    final session = PlaybackSession(
      repository: FakeRepository(),
      store: store,
      detail: dramaDetail(drama('edge-local'), count: 1),
      player: player,
      index: 0,
      adoptedPlan: const PlaybackPlan(url: 'https://fixture.invalid/current'),
    );
    final edge = MiniEdgeSnap(
      load: () async => (enabled: true, pause: true),
      save: (_, _) async {},
      apply: (_) async {},
    );
    try {
      await edge.restore();
      await player.play();
      await tester.pump();
      expect(MediaControls.instance.owns(session), isTrue);
      expect(calls, isNot(contains('update')));
      edge.hiddenChanged(true);
      await tester.pump();
      expect(session.paused, isTrue);
      expect(player.state.playing, isFalse);
      edge.hiddenChanged(false);
      await tester.pump();
      expect(session.paused, isFalse);
      expect(player.state.playing, isTrue);

      edge.hiddenChanged(true);
      await tester.pump();
      // 明确播放后再次手动暂停，旧贴边凭证不能恢复。
      session.togglePlayback();
      await tester.pump();
      session.togglePlayback();
      await tester.pump();
      edge.hiddenChanged(false);
      await tester.pump();
      expect(session.paused, isTrue);
      expect(player.state.playing, isFalse);
      expect(calls, isNot(contains('update')));
    } finally {
      edge.dispose();
      session.dispose();
      await tester.pump();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

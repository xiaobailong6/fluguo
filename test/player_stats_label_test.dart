import 'dart:async';

import 'package:duanju_app/ui/player/player_stats_label.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Platform implements PlatformPlayer {
  int calls = 0;
  Completer<String>? pending;
  Future<String> getProperty(String name) async {
    calls++;
    return pending?.future ?? '2048';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'speed reads wait for progress, do not overlap and stop while paused/background',
    (tester) async {
      final store = await openStore();
      await store.setPlaybackPreferences(
        store.playbackPreferences.copyWith(showCacheSpeed: true),
      );
      final platform = _Platform();
      final player = FakePlayer()..platform = platform;
      await player.play();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerStatsLabel(player: player, store: store),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(platform.calls, 0);
      player.progress(const Duration(seconds: 2));
      platform.pending = Completer<String>();
      await tester.pump(const Duration(seconds: 1));
      expect(platform.calls, 1);
      await tester.pump(const Duration(seconds: 4));
      expect(platform.calls, 1);
      await player.pause();
      platform.pending!.complete('999999');
      await tester.pump();
      expect(find.textContaining('976'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(platform.calls, 1);
      platform.pending = null;
      await player.play();
      await tester.pump(const Duration(seconds: 1));
      expect(platform.calls, 1);
      player.progress(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
      expect(platform.calls, 2);
      expect(find.text('2.0 KB/S'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      player.progress(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 2));
      expect(platform.calls, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));
      expect(platform.calls, 2);
      player.progress(const Duration(seconds: 8));
      player.buffer(true);
      await tester.pump(const Duration(seconds: 1));
      expect(platform.calls, 2);
      player.buffer(false);
      await tester.pump(const Duration(seconds: 1));
      expect(platform.calls, 3);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('hidden route and replaced player cannot publish stale speed', (
    tester,
  ) async {
    final store = await openStore();
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(showCacheSpeed: true),
    );
    final platform = _Platform()..pending = Completer<String>();
    final old = FakePlayer()..platform = platform;
    final nextPlatform = _Platform();
    final next = FakePlayer()..platform = nextPlatform;
    await old.play();
    await next.play();
    Widget frame(Player player, {bool enabled = true}) => MaterialApp(
      home: TickerMode(
        enabled: enabled,
        child: PlayerStatsLabel(player: player, store: store),
      ),
    );
    await tester.pumpWidget(frame(old));
    old.progress(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(platform.calls, 1);
    await tester.pumpWidget(frame(next));
    next.progress(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(nextPlatform.calls, 0);
    platform.pending!.complete('999999');
    await tester.pump();
    expect(find.textContaining('976'), findsNothing);
    await tester.pumpWidget(frame(next, enabled: false));
    await tester.pump(const Duration(seconds: 2));
    expect(nextPlatform.calls, 0);
    await tester.pumpWidget(frame(next));
    await tester.pump(const Duration(seconds: 1));
    expect(nextPlatform.calls, 1);
    await tester.pumpWidget(const SizedBox());
  });
}

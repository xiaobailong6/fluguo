import 'dart:async';

import 'package:duanju_app/diary_service.dart';
import 'package:duanju_app/playback_video_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  setUp(() async {
    DiaryService.traceEnabled = false;
    await DiaryService.clear();
  });
  tearDown(() => DiaryService.traceEnabled = false);

  test(
    'disabled tracing never reads native properties; enabled output deduplicates',
    () async {
      final stream = StreamController<VideoParams>.broadcast(sync: true);
      final diagnostics = PlaybackVideoDiagnostics();
      addTearDown(diagnostics.dispose);
      addTearDown(stream.close);
      final requested = <String>[];
      diagnostics.observe(
        stream.stream,
        read: (name) async {
          requested.add(name);
          return switch (name) {
            'hwdec-current' => 'd3d11va-copy',
            'current-vo' => 'gpu',
            'video-codec' => 'h264',
            _ => '24',
          };
        },
      );
      const params = VideoParams(w: 1920, h: 1080, pixelformat: 'yuv420p');
      stream.add(params);
      await pumpEventQueue();
      expect(requested, isEmpty);
      expect(DiaryService.entries, isEmpty);
      DiaryService.traceEnabled = true;
      stream.add(params);
      await pumpEventQueue();
      stream.add(params);
      await pumpEventQueue();
      expect(requested.toSet(), {
        'hwdec-current',
        'current-vo',
        'video-codec',
        'container-fps',
      });
      expect(DiaryService.entries, hasLength(1));
      expect(DiaryService.entries.single, contains('hwdec=d3d11va-copy'));
      expect(
        DiaryService.entries.single,
        contains('pixel=yuv420p size=1920x1080'),
      );
      stream.add(const VideoParams(w: 1280, h: 720));
      await pumpEventQueue();
      expect(DiaryService.entries, hasLength(2));
    },
  );

  test(
    'older sample and previous player cannot report after a newer sample',
    () async {
      DiaryService.traceEnabled = true;
      final stream = StreamController<VideoParams>.broadcast(sync: true);
      final other = StreamController<VideoParams>.broadcast(sync: true);
      final diagnostics = PlaybackVideoDiagnostics();
      addTearDown(diagnostics.dispose);
      addTearDown(stream.close);
      addTearDown(other.close);
      final pending = <Completer<String>>[];
      diagnostics.observe(
        stream.stream,
        read: (_) {
          final value = Completer<String>();
          pending.add(value);
          return value.future;
        },
      );
      stream.add(const VideoParams(w: 640, h: 360));
      stream.add(const VideoParams(w: 1280, h: 720));
      for (final value in pending.skip(4)) {
        value.complete('new');
      }
      await pumpEventQueue();
      for (final value in pending.take(4)) {
        value.complete('old');
      }
      await pumpEventQueue();
      expect(DiaryService.entries, hasLength(1));
      expect(DiaryService.entries.single, contains('1280x720'));
      pending.clear();
      stream.add(const VideoParams(w: 640, h: 360));
      diagnostics.observe(other.stream, read: (_) async => 'current');
      expect(stream.hasListener, isFalse);
      other.add(const VideoParams(w: 1920, h: 1080));
      await pumpEventQueue();
      for (final value in pending) {
        value.complete('previous-player');
      }
      await pumpEventQueue();
      expect(DiaryService.entries, hasLength(2));
      expect(DiaryService.entries.last, contains('1920x1080'));
      expect(DiaryService.fullText, isNot(contains('previous-player')));
    },
  );

  test(
    'dispose cancels subscriptions and discards pending properties',
    () async {
      DiaryService.traceEnabled = true;
      final stream = StreamController<VideoParams>.broadcast(sync: true);
      addTearDown(stream.close);
      final held = Completer<String>();
      final diagnostics = PlaybackVideoDiagnostics();
      diagnostics.observe(stream.stream, read: (_) => held.future);
      stream.add(const VideoParams(w: 640, h: 360));
      diagnostics.dispose();
      expect(stream.hasListener, isFalse);
      held.complete('late');
      await pumpEventQueue();
      expect(DiaryService.entries, isEmpty);
    },
  );

  test(
    'failed properties are silent; sensitive-looking output is redacted',
    () async {
      DiaryService.traceEnabled = true;
      final stream = StreamController<VideoParams>.broadcast(sync: true);
      final diagnostics = PlaybackVideoDiagnostics();
      addTearDown(diagnostics.dispose);
      addTearDown(stream.close);
      diagnostics.observe(
        stream.stream,
        read: (_) async => throw StateError('native disposed'),
      );
      stream.add(const VideoParams(w: 640, h: 360));
      await pumpEventQueue();
      expect(DiaryService.entries, isEmpty);
      diagnostics.observe(
        stream.stream,
        read: (_) async => 'https://secret.test/?cookie=key',
      );
      stream.add(const VideoParams(w: 640, h: 360));
      await pumpEventQueue();
      expect(DiaryService.entries, hasLength(1));
      expect(DiaryService.fullText, isNot(contains('secret')));
      expect(DiaryService.fullText, isNot(contains('cookie')));
    },
  );

  test(
    'disabling tracing during a property read suppresses its output',
    () async {
      DiaryService.traceEnabled = true;
      final stream = StreamController<VideoParams>.broadcast(sync: true);
      addTearDown(stream.close);
      final held = Completer<String>();
      final diagnostics = PlaybackVideoDiagnostics();
      addTearDown(diagnostics.dispose);
      diagnostics.observe(stream.stream, read: (_) => held.future);
      stream.add(const VideoParams(w: 640, h: 360));
      DiaryService.traceEnabled = false;
      held.complete('disabled');
      await pumpEventQueue();
      expect(DiaryService.entries, isEmpty);
    },
  );
  test(
    'media reset invalidates reads without replacing the player subscription',
    () async {
      DiaryService.traceEnabled = true;
      final stream = StreamController<VideoParams>.broadcast(sync: true);
      final diagnostics = PlaybackVideoDiagnostics();
      addTearDown(diagnostics.dispose);
      addTearDown(stream.close);
      final held = Completer<String>();
      diagnostics.observe(stream.stream, read: (_) => held.future);
      stream.add(const VideoParams(w: 640, h: 360));
      diagnostics.reset();
      held.complete('old-media');
      await pumpEventQueue();
      expect(DiaryService.entries, isEmpty);
      expect(stream.hasListener, isTrue);
    },
  );
}

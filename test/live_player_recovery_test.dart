import 'dart:async';

import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/live/live_player_gestures.dart';
import 'package:duanju_app/ui/live/live_player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

const room = LiveRoom(
  roomId: '1',
  title: '测试房间',
  anchor: '主播',
  cover: '',
  area: '',
  online: '',
);

class Source extends LivePlatform {
  @override
  String get id => 'fixture';
  @override
  String get name => '测试';
  int calls = 0;
  final selections = <({int quality, String line})>[];
  Completer<LiveStream>? pending;
  bool fail = false;
  Duration? renewAfter;
  LiveStream result(int n, String line) => LiveStream(
    url: 'https://example.invalid/live.m3u8?token=$n&line=$line',
    quality: '超清',
    qualityId: 250,
    headers: const {'Referer': 'https://example.invalid/'},
    lineId: line.isEmpty ? 'a' : line,
    lines: const [
      LiveLine(id: 'a', label: 'A'),
      LiveLine(id: 'b', label: 'B'),
    ],
    renewAfter: renewAfter,
  );
  @override
  Future<LiveStream> resolve(LiveRoom room, {int quality = 0}) =>
      resolveLine(room, quality: quality);
  @override
  Future<LiveStream> resolveLine(
    LiveRoom room, {
    int quality = 0,
    String line = '',
  }) async {
    final n = ++calls;
    selections.add((quality: quality, line: line));
    if (pending != null) return pending!.future;
    if (fail) throw StateError('fixture failure');
    return result(n, line);
  }

  @override
  Future<List<LiveCategory>> categories() async => [];
  @override
  Future<List<LiveRoom>> rooms(LiveCategory category, {int page = 1}) async =>
      [];
}

Future<void> mount(
  WidgetTester tester,
  Source source,
  FakePlayer player,
) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final store = await openStore();
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.phone,
        child: child!,
      ),
      home: LivePlayerPage(
        platform: source,
        room: room,
        store: store,
        player: player,
        videoSurface: const ColoredBox(color: Colors.black),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('duanju/device'),
      (_) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
  });
  testWidgets('短续期且零进度仍只能恢复三次', (tester) async {
    final source = Source()..renewAfter = const Duration(seconds: 2);
    final player = FakePlayer();
    await mount(tester, source, player);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    }
    expect(source.calls, 4);
    expect(find.text('直播恢复失败，请检查网络或手动重试'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('线路弹窗确认与自动续期交错时保留最新选择', (tester) async {
    final source = Source()..renewAfter = const Duration(seconds: 10);
    final player = FakePlayer();
    await mount(tester, source, player);
    player.progress(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('live-line-control')));
    await tester.pump(const Duration(milliseconds: 400));
    final pending = Completer<LiveStream>();
    source.pending = pending;
    await tester.pump(const Duration(seconds: 10));
    expect(source.calls, 2);
    await tester.tap(find.text('B'));
    await tester.pump(const Duration(milliseconds: 400));
    source.pending = null;
    pending.complete(source.result(2, 'a'));
    await tester.pump();
    await tester.pump();
    expect(source.calls, 3);
    expect(source.selections.last.line, 'b');
    expect(player.opened.last.uri, contains('line=b'));
    await unmount(tester);
  });

  testWidgets('EOF 重新解析签名并继续播放，保留当前档位、线路、请求头', (tester) async {
    final source = Source();
    final player = FakePlayer();
    await mount(tester, source, player);
    expect(player.opened.length, 1);
    player.finish();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(source.calls, 2);
    expect(source.selections.last, (quality: 250, line: 'a'));
    expect(player.opened.last.uri, contains('token=2'));
    expect(player.opened.last.httpHeaders, {
      'Referer': 'https://example.invalid/',
    });
    expect(player.state.playing, isTrue);
    await unmount(tester);
    expect(player.disposed, isTrue);
  });

  testWidgets('暂停取消错误恢复与续期，主动恢复重新取地址', (tester) async {
    final source = Source()..renewAfter = const Duration(seconds: 4);
    final player = FakePlayer();
    await mount(tester, source, player);
    player.fail('failed');
    tester
        .widget<LivePlayerGestures>(find.byType(LivePlayerGestures))
        .onTogglePlayback();
    await tester.pump();
    expect(player.state.playing, isFalse);
    await tester.pump(const Duration(minutes: 1));
    expect(source.calls, 1);
    tester
        .widget<LivePlayerGestures>(find.byType(LivePlayerGestures))
        .onTogglePlayback();
    await tester.pump();
    await tester.pump();
    expect(source.calls, 2);
    expect(player.state.playing, isTrue);
    await unmount(tester);
  });

  testWidgets('后台不请求，返回前台重新取流；后台已暂停不自动播放', (tester) async {
    final source = Source();
    final player = FakePlayer();
    await mount(tester, source, player);
    await lifecycle(tester, false);
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(source.calls, 1);
    expect(player.state.playing, isFalse);
    await lifecycle(tester, true);
    await tester.pump();
    await tester.pump();
    expect(source.calls, 2);
    expect(player.state.playing, isTrue);
    tester
        .widget<LivePlayerGestures>(find.byType(LivePlayerGestures))
        .onTogglePlayback();
    await tester.pump();
    await lifecycle(tester, false);
    await lifecycle(tester, true);
    await tester.pump();
    expect(source.calls, 2);
    expect(player.state.playing, isFalse);
    await unmount(tester);
  });

  testWidgets('取流期间进入后台/退出，迟到结果不打开播放器', (tester) async {
    final pending = Completer<LiveStream>();
    final source = Source()..pending = pending;
    final player = FakePlayer();
    await mount(tester, source, player);
    await unmount(tester);
    pending.complete(source.result(1, 'a'));
    await tester.pump();
    expect(player.opened, isEmpty);
    expect(player.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取流中暂停，迟到结果不播放，恢复重新解析', (tester) async {
    final pending = Completer<LiveStream>();
    final source = Source()..pending = pending;
    final player = FakePlayer();
    await mount(tester, source, player);
    tester
        .widget<LivePlayerGestures>(find.byType(LivePlayerGestures))
        .onTogglePlayback();
    pending.complete(source.result(1, 'a'));
    source.pending = null;
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(player.opened, isEmpty);
    expect(source.calls, 1);
    tester
        .widget<LivePlayerGestures>(find.byType(LivePlayerGestures))
        .onTogglePlayback();
    await tester.pump();
    await tester.pump();
    expect(source.calls, 2);
    expect(player.state.playing, isTrue);
    await unmount(tester);
  });

  testWidgets('原生 open 等待中隐藏，完成后不会启动声音', (tester) async {
    final source = Source();
    final player = PendingPlayer();
    await mount(tester, source, player);
    await lifecycle(tester, false);
    player.ready.complete();
    await tester.pump();
    await tester.pump();
    expect(player.state.playing, isFalse);
    expect(source.calls, 1);
    await lifecycle(tester, true);
    await tester.pump();
    expect(player.state.playing, isTrue);
    expect(source.calls, 2);
    await unmount(tester);
  });

  testWidgets('恢复失败有上限，第二次恢复才换备用 CDN', (tester) async {
    final source = Source();
    final player = FakePlayer();
    await mount(tester, source, player);
    source.fail = true;
    player.finish();
    for (final seconds in [1, 2, 4, 30]) {
      await tester.pump(Duration(seconds: seconds));
      await tester.pump();
    }
    expect(source.calls, 4);
    expect(source.selections[1].line, 'a');
    expect(source.selections[2].line, 'b');
    expect(find.text('直播恢复失败，请检查网络或手动重试'), findsOneWidget);
    await tester.pump(const Duration(minutes: 3));
    expect(source.calls, 4);
    await unmount(tester);
  });
}

Future<void> lifecycle(WidgetTester tester, bool visible) async {
  final states = visible
      ? [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]
      : [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ];
  for (final state in states) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}

class PendingPlayer extends FakePlayer {
  final ready = Completer<void>();
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    await ready.future;
    await super.open(playable, play: play);
  }
}

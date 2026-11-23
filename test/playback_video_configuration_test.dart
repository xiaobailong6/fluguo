import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_decoder.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/playback_video_configuration.dart';
import 'package:duanju_app/theater_preview.dart';
import 'package:duanju_app/theater_preview_backend.dart';
import 'package:duanju_app/ui/player/playback_handle.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Repository extends FakeRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async => dramaDetail(drama, count: 4);
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async =>
      PlaybackPlan(url: 'https://fixture.invalid/${episode.number}.mp4');
}

class _Native extends Fake implements NativePlayer {
  final properties = <String, String>{};
  @override
  bool isVideoControllerAttached = false;
  @override
  final videoControllerCompleter = Completer<void>();
  @override
  Future<void> setProperty(
    String name,
    String value, {
    bool waitForInitialization = true,
  }) async => properties[name] = value;
}

class _Video extends Fake implements VideoController {
  _Video(this.player, this.configuration);
  @override
  final Player player;
  final VideoControllerConfiguration configuration;
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
  @override
  final id = ValueNotifier<int?>(null);
  @override
  final rect = ValueNotifier<Rect?>(null);
}

class _MediaFactory {
  final players = <FakePlayer>[];
  final videos = <_Video>[];
  final limited = <bool>[];
  FakePlayer player({bool limited = false}) {
    this.limited.add(limited);
    final player = FakePlayer()..platform = _Native();
    players.add(player);
    return player;
  }

  VideoController video(Player player, VideoControllerConfiguration config) {
    final video = _Video(player, config);
    videos.add(video);
    return video;
  }

  void disposeSignals() {
    for (final video in videos) {
      video.notifier.dispose();
      video.id.dispose();
      video.rect.dispose();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('直通解码和输出必须成对，其他模式及跨平台保持原输出', () {
    for (final platform in TargetPlatform.values) {
      for (final decoder in TelevisionDecoder.values) {
        final setup = PlaybackVideoConfiguration(decoder, platform);
        final video = setup.videoConfiguration();
        final direct =
            platform == TargetPlatform.android &&
            decoder == TelevisionDecoder.hardwareDirect;
        expect(video.vo, direct ? 'mediacodec_embed' : null);
        expect(video.hwdec, direct ? 'mediacodec' : null);
        if (direct) {
          expect(playbackDecoderProperties(decoder, platform), {
            'hwdec': 'mediacodec',
            'vf': '',
            'glsl-shaders': '',
          });
        } else if (decoder == TelevisionDecoder.hardwareDirect) {
          expect(
            playbackDecoderProperties(decoder, platform),
            playbackDecoderProperties(TelevisionDecoder.hardware, platform),
          );
        }
      }
    }
  });

  test('控制器初始化完成后应用解码，不等待首帧且清除旧滤镜', () async {
    final native = _Native()..isVideoControllerAttached = true;
    const setup = PlaybackVideoConfiguration(
      TelevisionDecoder.hardwareDirect,
      TargetPlatform.android,
    );
    var completed = false;
    final work = setup.apply(native).then((_) => completed = true);
    await pumpEventQueue();
    expect(native.properties, isEmpty);
    expect(completed, isFalse);
    native.properties.addAll({
      'hwdec': 'auto-safe',
      'vf': 'old',
      'glsl-shaders': 'old',
    });
    native.videoControllerCompleter.complete();
    await work;
    expect(native.properties, {
      'hwdec': 'mediacodec',
      'vf': '',
      'glsl-shaders': '',
    });
  });

  test('播放器配置不能在交接时改成另一种输出', () {
    final player = FakePlayer();
    const direct = PlaybackVideoConfiguration(
      TelevisionDecoder.hardwareDirect,
      TargetPlatform.android,
    );
    direct.bind(player);
    expect(PlaybackVideoConfiguration.of(player), same(direct));
    expect(
      () => const PlaybackVideoConfiguration(
        TelevisionDecoder.hardware,
        TargetPlatform.android,
      ).bind(player),
      throwsStateError,
    );
    expect(PlaybackVideoConfiguration.of(player), same(direct));
  });

  test('主播放器与备用、设置改变后创建的第三播放器沿用同一输出', () async {
    final store = await openStore();
    await store.setPlaybackPreferences(
      const PlaybackPreferences(
        televisionDecoder: TelevisionDecoder.hardwareDirect,
      ),
    );
    final factory = _MediaFactory();
    final handle = PlaybackHandle(
      repository: _Repository(),
      store: store,
      detail: dramaDetail(drama('direct-slots'), count: 4),
      index: 0,
      autoplay: false,
      playerFactory: factory.player,
      videoFactory: factory.video,
    );
    await pumpEventQueue();
    expect(factory.players, hasLength(2));
    await store.setPlaybackPreferences(
      const PlaybackPreferences(televisionDecoder: TelevisionDecoder.software),
    );
    final spare = handle.session.createSparePlayer!();
    expect(factory.players, hasLength(3));
    expect(factory.limited, [false, true, true]);
    for (final video in factory.videos) {
      expect(video.configuration.vo, 'mediacodec_embed');
      expect(video.configuration.hwdec, 'mediacodec');
      expect(
        PlaybackVideoConfiguration.of(video.player)!.decoder,
        TelevisionDecoder.hardwareDirect,
      );
    }
    expect(
      (handle.session.player.platform as _Native).properties['hwdec'],
      'mediacodec',
    );
    await handle.session.disposeVideo!(spare);
    await spare.dispose();
    handle.dispose();
    await pumpEventQueue();
    factory.disposeSignals();
  });

  for (final decoder in [
    TelevisionDecoder.hardwareDirect,
    TelevisionDecoder.hardware,
  ]) {
    test('剧场接管与交还保留 $decoder，不重开首集、不新建主播放器', () async {
      final store = await openStore();
      final factory = _MediaFactory();
      final preview = MediaKitPreviewBackend(
        decoder: decoder,
        playerFactory: factory.player,
        videoFactory: factory.video,
      );
      const plan = PlaybackPlan(url: 'https://fixture.invalid/video.mp4');
      await preview.open(plan, const Duration(seconds: 8));
      await preview.play();
      // 交接时设置恰好变化，已有输出必须保留，而不是追随新设置。
      await store.setPlaybackPreferences(
        PlaybackPreferences(
          televisionDecoder: decoder == TelevisionDecoder.hardwareDirect
              ? TelevisionDecoder.hardware
              : TelevisionDecoder.hardwareDirect,
        ),
      );
      final handle = PlaybackHandle(
        repository: _Repository(),
        store: store,
        detail: dramaDetail(drama('handoff'), count: 2),
        index: 0,
        adoptedPlayer: preview.handoffPlayer,
        adoptedVideo: preview.handoffVideo,
        adoptedPlan: plan,
        returnable: true,
        preopen: false,
        playerFactory: factory.player,
        videoFactory: factory.video,
      );
      await pumpEventQueue();
      expect(factory.players, hasLength(1));
      expect(factory.players.single.opened, hasLength(1));
      expect(
        (factory.players.single.platform as _Native).properties['hwdec'],
        decoder == TelevisionDecoder.hardwareDirect
            ? 'mediacodec'
            : 'mediacodec-copy',
      );
      final returned = handle.consumeHandback()!;
      handle.dispose();
      final back = MediaKitPreviewBackend.adopted(
        returned.player,
        returned.video,
      );
      expect(back.configuration.decoder, decoder);
      expect(back.handoffVideo, same(preview.handoffVideo));
      expect(factory.players.single.opened, hasLength(1));
      await back.dispose();
      await pumpEventQueue();
      factory.disposeSignals();
    });
  }

  test('剧场保活后修改解码，在下一次加载替换后端而不热改旧输出', () async {
    final store = await openStore();
    await store.setPlaybackPreferences(
      const PlaybackPreferences(
        televisionDecoder: TelevisionDecoder.hardwareDirect,
      ),
    );
    final factory = _MediaFactory();
    final preview = TheaterPreview(
      _Repository(),
      store,
      backend: () => MediaKitPreviewBackend(
        decoder: store.playbackPreferences.televisionDecoder,
        playerFactory: factory.player,
        videoFactory: factory.video,
      ),
    );
    preview.select(drama('one'));
    preview.setVisible(true);
    await pumpEventQueue();
    final first = factory.players.single;
    expect(first.opened, hasLength(1));
    await store.setPlaybackPreferences(
      const PlaybackPreferences(televisionDecoder: TelevisionDecoder.software),
    );
    await pumpEventQueue();
    expect(first.disposed, isFalse);
    expect(factory.players, hasLength(1));
    preview.select(drama('two'));
    await pumpEventQueue();
    expect(first.disposed, isTrue);
    expect(factory.players, hasLength(2));
    expect(factory.videos.last.configuration.vo, isNull);
    expect(
      (factory.players.last.platform as _Native).properties['hwdec'],
      'no',
    );
    expect(factory.players.last.opened, hasLength(1));
    preview.dispose();
    await pumpEventQueue();
    factory.disposeSignals();
  });
  test('播放页保活修改设置不热换解码，重新创建才应用新模式', () async {
    final store = await openStore();
    await store.setPlaybackPreferences(
      const PlaybackPreferences(
        televisionDecoder: TelevisionDecoder.hardwareDirect,
      ),
    );
    final factory = _MediaFactory();
    PlaybackHandle create() => PlaybackHandle(
      repository: _Repository(),
      store: store,
      detail: dramaDetail(drama('reopen'), count: 2),
      index: 0,
      preopen: false,
      autoplay: false,
      playerFactory: factory.player,
      videoFactory: factory.video,
    );
    final first = create();
    await pumpEventQueue();
    await store.setPlaybackPreferences(
      const PlaybackPreferences(televisionDecoder: TelevisionDecoder.software),
    );
    await first.session.play(1, playWhenReady: false);
    expect(
      (first.session.player.platform as _Native).properties['hwdec'],
      'mediacodec',
    );
    first.dispose();
    await pumpEventQueue();
    final second = create();
    await pumpEventQueue();
    expect(factory.videos.last.configuration.vo, isNull);
    expect(
      (second.session.player.platform as _Native).properties['hwdec'],
      'no',
    );
    second.dispose();
    await pumpEventQueue();
    factory.disposeSignals();
  });
}

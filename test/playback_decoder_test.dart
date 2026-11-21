import 'package:duanju_app/playback_decoder.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new decoder roundtrips without changing old defaults or names', () {
    expect(
      const PlaybackPreferences().televisionDecoder,
      TelevisionDecoder.optimized,
    );
    for (final decoder in TelevisionDecoder.values) {
      final settings = PlaybackPreferences(televisionDecoder: decoder);
      expect(
        PlaybackPreferences.fromJson(settings.toJson()).televisionDecoder,
        decoder,
      );
    }
    expect(
      PlaybackPreferences.fromJson({
        'televisionDecoder': 'unknown',
      }).televisionDecoder,
      TelevisionDecoder.optimized,
    );
  });
  test('Android UV correction is explicit and cleared on every other mode', () {
    expect(
      playbackDecoderProperties(
        TelevisionDecoder.hardwareSwapUv,
        TargetPlatform.android,
        chromaShader: '/data/user/0/app/support/swap.glsl',
      ),
      {
        'hwdec': 'mediacodec-copy',
        'vf': '',
        'glsl-shaders': '/data/user/0/app/support/swap.glsl',
      },
    );
    for (final decoder in [
      TelevisionDecoder.optimized,
      TelevisionDecoder.hardware,
      TelevisionDecoder.software,
    ]) {
      expect(
        playbackDecoderProperties(decoder, TargetPlatform.android)['vf'],
        '',
      );
      expect(
        playbackDecoderProperties(
          decoder,
          TargetPlatform.android,
          chromaShader: '/old.glsl',
        )['glsl-shaders'],
        '',
      );
    }
    expect(
      playbackDecoderProperties(
        TelevisionDecoder.software,
        TargetPlatform.android,
      )['hwdec'],
      'no',
    );
  });
  test(
    'cross-platform restored preference does not apply Android color filter',
    () {
      for (final platform in TargetPlatform.values.where(
        (p) => p != TargetPlatform.android,
      )) {
        expect(
          playbackDecoderProperties(TelevisionDecoder.hardwareSwapUv, platform),
          playbackDecoderProperties(TelevisionDecoder.hardware, platform),
        );
        expect(
          playbackDecoderProperties(TelevisionDecoder.hardwareSwapUv, platform),
          isNot(contains('vf')),
        );
        expect(
          playbackDecoderProperties(
            TelevisionDecoder.hardwareSwapUv,
            platform,
            chromaShader: '/android-only.glsl',
          ),
          isNot(contains('glsl-shaders')),
        );
      }
      expect(
        playbackDecoderProperties(
          TelevisionDecoder.optimized,
          TargetPlatform.windows,
        ),
        {'hwdec': 'd3d11va-copy'},
      );
    },
  );
}

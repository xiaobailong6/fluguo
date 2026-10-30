import 'package:duanju_app/playback_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test('旧播放配置默认直播为自动，并与短剧画质独立', () {
    final preferences = PlaybackPreferences.fromJson({'quality': 720});
    expect(preferences.liveQuality, 0);
    expect(preferences.quality, 720);
    expect(liveQualityOptions[0], '自动（优先高清）');
  });

  test('直播画质序列化、修改其他偏好时保持直播选择', () {
    final original = const PlaybackPreferences(quality: 1080, liveQuality: 250);
    final changed = original.copyWith(speed: 1.5);
    final restored = PlaybackPreferences.fromJson(changed.toJson());
    expect(restored.liveQuality, 250);
    expect(restored.quality, 1080);
    expect(restored.speed, 1.5);
    expect(
      () => PlaybackPreferences.fromJson({'liveQuality': -1}),
      throwsFormatException,
    );
  });

  test('保存直播默认清晰度后可从用户设置重新读取', () async {
    final store = await openStore();
    addTearDown(store.dispose);
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(liveQuality: 150),
    );
    expect(store.playbackPreferences.liveQuality, 150);
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(quality: 720),
    );
    expect(store.playbackPreferences.liveQuality, 150);
  });
}

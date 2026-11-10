import 'dart:io';

import 'package:duanju_app/merged_library.dart';
import 'package:duanju_app/merged_playback.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

void main() {
  late Directory root;
  late MergedLibrary library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('merged-playback-');
    library = MergedLibrary(directory: root);
  });
  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  test('成品解析仅返回本地文件，删除成品后拒绝旧记录', () async {
    final video = await library.create(drama('file'), [2, 3], (file) async {
      await File(file).writeAsString('local-merged');
    });
    final store = await openStore();
    final original = FakeRepository();
    final repository = MergedPlaybackRepository(library, video, store, original);
    final detail = repository.playbackDetail();
    final plan = await repository.resolve(detail.drama, detail.episodes.single);
    expect(plan.local, isTrue);
    expect(plan.url, Uri.file(await library.fileFor(video)).toString());
    expect(detail.episodes, hasLength(1));
    expect(original.detailRequests, 0);
    expect(original.catalogRequests, isEmpty);
    expect(await library.remove({video.id}), isEmpty);
    await expectLater(
      repository.resolve(detail.drama, detail.episodes.single),
      throwsA(anything),
    );
  });

  test('合并播放保存独立mediaHistory，不覆盖原分集历史', () async {
    final show = drama('independent');
    final video = await library.create(show, [1, 2], (file) async {
      await File(file).writeAsString('local-merged');
    });
    final store = await openStore();
    final repository = MergedPlaybackRepository(library, video, store, FakeRepository());
    final player = FakePlayer();
    final id = 'merged:${video.id}';
    final session = PlaybackSession(
      repository: repository,
      store: store,
      detail: repository.playbackDetail(),
      player: player,
      index: 0,
      mediaHistoryId: id,
    );
    await pumpEventQueue();
    expect(player.opened, hasLength(1));
    expect(session.local, isTrue);
    expect(session.danmakuSupported, isFalse);
    player.progress(const Duration(seconds: 42), duration: const Duration(seconds: 180));
    await session.saveProgress();
    expect(store.mediaWatched(id)?.position, 42);
    expect(store.history, isEmpty);
    await store.setSourceEnabled(show.source, false);
    await pumpEventQueue();
    expect(player.state.playing, isFalse);
    session.togglePlayback();
    await pumpEventQueue();
    expect(player.state.playing, isFalse);
    session.dispose();
    await pumpEventQueue();
  });

  test('用户代次变更后不能继续解析旧成品会话', () async {
    final video = await library.create(drama('epoch'), [1, 2], (file) async {
      await File(file).writeAsString('local-merged');
    });
    final store = await openStore();
    final repository = MergedPlaybackRepository(library, video, store, FakeRepository());
    await store.switchProfile('default');
    final detail = repository.playbackDetail();
    await expectLater(
      repository.resolve(detail.drama, detail.episodes.single),
      throwsA(anything),
    );
  });
}

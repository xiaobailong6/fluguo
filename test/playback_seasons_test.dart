import 'dart:async';

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:duanju_app/ui/player/playback_handle.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

final _first = drama('season-a', title: '同名');
final _second = drama('season-b', title: '同名');
final _seasons = [
  DramaSeason(number: 1, drama: _first),
  DramaSeason(number: 2, drama: _second),
];

class _Repository extends FakeRepository {
  List<DramaSeason> official = _seasons;
  Completer<List<DramaSeason>>? heldSeasons;
  Completer<DramaDetail>? heldDetail;
  Completer<PlaybackPlan>? heldResolve;
  int seasonRequests = 0;
  final requested = <String>[];
  final resolved = <String>[];
  final released = <String>[];
  DramaDetail nextDetail = dramaDetail(_second, count: 2);
  @override
  Future<List<DramaSeason>> seasons(Drama drama) async {
    seasonRequests++;
    return heldSeasons == null ? official : await heldSeasons!.future;
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    requested.add(drama.id);
    return heldDetail == null ? nextDetail : await heldDetail!.future;
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    resolved.add(drama.id);
    if (heldResolve != null) return heldResolve!.future;
    return PlaybackPlan(
      url: 'https://media.test/${resolved.length}.mp4',
      session: 'p${resolved.length}',
    );
  }

  @override
  Future<void> release(String session) async => released.add(session);
}

class _AccessStore extends LocalStore {
  _AccessStore(super.preferences);
  bool permitted = true;
  @override
  bool allowsSource(String source) => permitted && super.allowsSource(source);
  void revoke() {
    permitted = false;
    notifyListeners();
  }
}

class _Video implements VideoController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _until(bool Function() done) async {
  for (var attempt = 0; attempt < 200 && !done(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: '异步会话应在一秒内达到目标状态');
}

Future<(PlaybackSession, FakePlayer)> _open(
  _Repository repository, {
  LocalStore? store,
  List<DramaSeason> seasons = const [],
  String? mediaHistoryId,
}) async {
  final player = FakePlayer();
  final session = PlaybackSession(
    repository: repository,
    store: store ?? await openStore(),
    detail: DramaDetail(
      _first,
      dramaDetail(_first, count: 3).episodes,
      seasons: seasons,
    ),
    player: player,
    index: 2,
    mediaHistoryId: mediaHistoryId,
  );
  addTearDown(() async {
    if (!player.disposed) session.dispose();
    await pumpEventQueue();
  });
  await _until(() => session.ready);
  return (session, player);
}

void _finish(FakePlayer player) {
  player.progress(
    const Duration(seconds: 99),
    duration: const Duration(seconds: 100),
  );
  player.finish();
}

void main() {
  test(
    'lazy official seasons advance once and save the old season independently',
    () async {
      final repository = _Repository();
      final (session, player) = await _open(repository);
      expect(await session.next(), isFalse); // 手动下一集保持原语义。
      _finish(player);
      player.finish();
      await _until(() => !session.loading);
      expect(session.detail.drama.id, _second.id);
      expect(session.index, 0);
      expect(session.ready, isTrue);
      expect(player.state.playing, isTrue);
      expect(player.opened, hasLength(2));
      expect(repository.seasonRequests, 1);
      expect(repository.requested, [_second.id]);
      expect(repository.released, contains('p1'));
      expect(session.store.watched(_first.id)!.episode, 3);
      expect(session.store.watched(_first.id)!.position, 100);
      expect(session.store.watched(_second.id), isNull);
      player.progress(const Duration(seconds: 10));
      await session.saveProgress();
      expect(session.store.watched(_second.id)!.episode, 1);
      expect(session.store.watched(_first.id)!.episode, 3);
    },
  );

  for (final mode in [
    'pause',
    'sleep',
    'timer',
    'background',
    'permission',
    'profile',
    'dispose',
    'manual',
  ]) {
    test(
      '$mode during next-season detail await prevents late playback',
      () async {
        final base = await openStore(viewerPreferences);
        final store = _AccessStore(base.preferences);
        addTearDown(store.dispose);
        final held = Completer<DramaDetail>();
        final repository = _Repository()..heldDetail = held;
        final (session, player) = await _open(repository, store: store);
        _finish(player);
        await _until(() => repository.requested.isNotEmpty);
        expect(repository.requested, [_second.id]);
        switch (mode) {
          case 'pause':
            session.togglePlayback();
          case 'sleep':
            session.setSleepTimer(episodeEnd: true);
          case 'timer':
            Timer? captured;
            runZoned(
              () => session.setSleepTimer(minutes: 15),
              zoneSpecification: ZoneSpecification(
                createTimer: (self, parent, zone, delay, callback) {
                  captured = parent.createTimer(zone, Duration.zero, callback);
                  return captured!;
                },
              ),
            );
            await pumpEventQueue();
          case 'background':
            session.setForeground(false);
          case 'permission':
            store.revoke();
          case 'profile':
            await store.switchProfile('viewer');
          case 'dispose':
            session.dispose();
            await pumpEventQueue();
          case 'manual':
            await session.play(0, playWhenReady: false);
        }
        held.complete(dramaDetail(_second, count: 2));
        await pumpEventQueue();
        expect(session.detail.drama.id, _first.id);
        expect(
          repository.resolved,
          mode == 'manual' ? [_first.id, _first.id] : [_first.id],
        );
        if (mode != 'dispose') expect(player.state.playing, isFalse);
        if (mode != 'manual' && mode != 'dispose') {
          player.finish();
          await pumpEventQueue();
          expect(repository.requested, hasLength(1));
        }
      },
    );
  }

  test('pause while lazy seasons await never requests next detail', () async {
    final held = Completer<List<DramaSeason>>();
    final repository = _Repository()..heldSeasons = held;
    final (session, player) = await _open(repository);
    _finish(player);
    await _until(() => repository.seasonRequests == 1);
    session.togglePlayback();
    held.complete(_seasons);
    await pumpEventQueue();
    expect(repository.requested, isEmpty);
    expect(session.detail.drama.id, _first.id);
    expect(session.paused, isTrue);
  });

  test('pause during new-season resolve does not restore sound', () async {
    final repository = _Repository();
    final (session, player) = await _open(repository, seasons: _seasons);
    final held = Completer<PlaybackPlan>();
    repository.heldResolve = held;
    _finish(player);
    await _until(() => repository.resolved.length == 2);
    expect(session.detail.drama.id, _second.id);
    session.togglePlayback();
    held.complete(const PlaybackPlan(url: 'https://media.test/next.mp4'));
    await pumpEventQueue();
    expect(session.paused, isTrue);
    expect(player.state.playing, isFalse);
  });

  for (final mode in [
    'empty',
    'missing-current',
    'last',
    'disabled',
    'sleep',
    'merged',
  ]) {
    test('$mode cannot auto-advance to another title', () async {
      final repository = _Repository();
      if (mode == 'empty') repository.official = [];
      if (mode == 'missing-current') repository.official = [_seasons.last];
      if (mode == 'last') repository.official = [_seasons.last, _seasons.first];
      final (session, player) = await _open(
        repository,
        mediaHistoryId: mode == 'merged' ? 'merged-product' : null,
      );
      if (mode == 'disabled') {
        await session.store.setPlaybackPreferences(
          session.store.playbackPreferences.copyWith(autoAdvance: false),
        );
      }
      if (mode == 'sleep') session.setSleepTimer(episodeEnd: true);
      _finish(player);
      await pumpEventQueue();
      player.finish();
      await pumpEventQueue();
      expect(session.detail.drama.id, _first.id);
      expect(repository.requested, isEmpty);
      expect(player.opened, hasLength(1));
      expect(session.paused, isTrue);
    });
  }

  for (final mode in ['empty', 'mismatch', 'failure']) {
    test(
      'next-season $mode stops visibly with old detail and index intact',
      () async {
        final repository = _Repository();
        if (mode == 'empty') {
          repository.nextDetail = dramaDetail(_second, count: 0);
        }
        if (mode == 'mismatch') {
          repository.nextDetail = dramaDetail(drama('same-name', title: '同名'));
        }
        if (mode == 'failure') repository.heldDetail = Completer<DramaDetail>();
        final (session, player) = await _open(repository);
        _finish(player);
        await pumpEventQueue();
        repository.heldDetail?.completeError(StateError('offline'));
        await pumpEventQueue();
        expect(session.detail.drama.id, _first.id);
        expect(session.index, 2);
        expect(session.error, contains('下一季'));
        expect(session.paused, isTrue);
        player.finish();
        await pumpEventQueue();
        expect(repository.requested, hasLength(1));
      },
    );
  }

  test(
    'handback retains Player/VideoController only for original drama first episode',
    () async {
      final repository = _Repository();
      final store = await openStore();
      final player = FakePlayer();
      final video = _Video();
      final handle = PlaybackHandle(
        repository: repository,
        store: store,
        detail: DramaDetail(
          _first,
          dramaDetail(_first, count: 1).episodes,
          seasons: _seasons,
        ),
        index: 0,
        preopen: false,
        adoptedPlayer: player,
        adoptedVideo: video,
        returnable: true,
      );
      await _until(() => handle.session.ready);
      expect(handle.canHandback, isTrue);
      expect(handle.video(player), same(video));
      _finish(player);
      await _until(() => !handle.session.loading);
      expect(handle.session.detail.drama.id, _second.id);
      expect(handle.session.index, 0);
      expect(handle.canHandback, isFalse);
      expect(handle.consumeHandback(), isNull);
      handle.dispose();
      await pumpEventQueue();
      expect(player.disposed, isTrue);

      final original = FakePlayer();
      final originalVideo = _Video();
      final other = PlaybackHandle(
        repository: repository,
        store: store,
        detail: dramaDetail(_first, count: 2),
        index: 0,
        preopen: false,
        adoptedPlayer: original,
        adoptedVideo: originalVideo,
        returnable: true,
      );
      await _until(() => other.session.ready);
      final returned = other.consumeHandback()!;
      expect(returned.player, same(original));
      expect(returned.video, same(originalVideo));
      other.dispose();
      await pumpEventQueue();
      expect(original.disposed, isFalse);
      await original.dispose();
    },
  );
}

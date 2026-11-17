import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

final first = drama('manual-first');
final second = drama('manual-second');
final seasons = [
  DramaSeason(number: 1, drama: first),
  DramaSeason(number: 2, drama: second),
];

class Repository extends FakeRepository {
  Completer<DramaDetail>? held;
  Completer<PlaybackPlan>? resolveGate;
  int requests = 0;
  DramaDetail? overrideDetail;
  @override
  Future<List<DramaSeason>> seasons(Drama drama) async => [
    DramaSeason(number: 1, drama: first),
    DramaSeason(number: 2, drama: second),
  ];
  @override
  Future<DramaDetail> detail(Drama drama) async {
    requests++;
    return held?.future ?? overrideDetail ?? dramaDetail(drama, count: 5);
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async =>
      resolveGate?.future ??
      PlaybackPlan(
        url: 'https://fixture.invalid/${drama.id}/${episode.number}',
      );
}

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<(PlaybackSession, FakePlayer)> open(
    Repository repo, {
    bool preloadSeasons = true,
  }) async {
    final player = FakePlayer();
    final session = PlaybackSession(
      repository: repo,
      store: await openStore(),
      detail: DramaDetail(
        first,
        dramaDetail(first, count: 3).episodes,
        seasons: preloadSeasons ? seasons : const [],
      ),
      player: player,
      index: 0,
    );
    await until(() => session.ready);
    addTearDown(() async {
      if (!player.disposed) session.dispose();
      await pumpEventQueue();
    });
    return (session, player);
  }

  for (final finished in [false, true]) {
    test(
      'manual selection restores season progress (finished=$finished)',
      () async {
        final repo = Repository();
        final (session, player) = await open(repo);
        await session.store.saveWatch(
          watching(second, episode: 2, position: finished ? 100 : 25),
        );
        player.progress(
          const Duration(seconds: 18),
          duration: const Duration(seconds: 100),
        );
        expect(await session.playSeason(seasons[1]), isTrue);
        expect(session.detail.drama.id, second.id);
        expect(session.index, finished ? 2 : 1);
        expect(
          player.opened.last.start,
          finished ? isNull : const Duration(seconds: 25),
        );
        expect(session.store.watched(first.id)!.position, 18);
        expect(session.store.watched(second.id)!.episode, 2);
        expect(player.state.playing, isTrue);
      },
    );
  }
  test(
    'paused selection remains paused, repeated current season does not reopen',
    () async {
      final (session, player) = await open(Repository());
      session.togglePlayback();
      await pumpEventQueue();
      expect(await session.playSeason(seasons[1]), isTrue);
      expect(player.state.playing, isFalse);
      final opens = player.opened.length;
      expect(await session.playSeason(seasons[1]), isTrue);
      expect(player.opened.length, opens);
    },
  );
  test(
    'unrelated title, locked screen and duplicate clicks never request detail',
    () async {
      final repo = Repository()..held = Completer<DramaDetail>();
      final (session, _) = await open(repo);
      expect(
        await session.playSeason(
          DramaSeason(number: 2, drama: drama('same-name')),
        ),
        isFalse,
      );
      session.setLocked(true);
      expect(await session.playSeason(seasons[1]), isFalse);
      session.setLocked(false);
      final switching = session.playSeason(seasons[1]);
      await until(() => repo.requests == 1);
      expect(await session.playSeason(seasons[1]), isFalse);
      repo.held!.complete(dramaDetail(second, count: 5));
      expect(await switching, isTrue);
      expect(repo.requests, 1);
    },
  );
  for (final mode in ['pause', 'background', 'profile', 'dispose', 'manual']) {
    test('$mode invalidates late season details', () async {
      final repo = Repository()..held = Completer<DramaDetail>();
      final (session, player) = await open(repo);
      final switching = session.playSeason(seasons[1]);
      await until(() => repo.requests == 1);
      switch (mode) {
        case 'pause':
          session.togglePlayback();
        case 'background':
          session.setForeground(false);
        case 'profile':
          await session.store.switchProfile(session.store.profile.id);
        case 'dispose':
          session.dispose();
          await pumpEventQueue();
        case 'manual':
          await session.play(1);
      }
      repo.held!.complete(dramaDetail(second, count: 5));
      expect(await switching, isFalse);
      expect(session.detail.drama.id, first.id);
      if (mode != 'manual' && mode != 'dispose') {
        expect(player.state.playing, isFalse);
      }
    });
  }
  for (final mismatch in [false, true]) {
    test(
      'bad season response preserves original detail (mismatch=$mismatch)',
      () async {
        final repo = Repository()
          ..overrideDetail = dramaDetail(
            mismatch ? drama('wrong') : second,
            count: mismatch ? 2 : 0,
          );
        final (session, player) = await open(repo);
        await expectLater(
          session.playSeason(seasons[1]),
          throwsA(isA<AppFailure>()),
        );
        expect(session.detail.drama.id, first.id);
        expect(session.index, 0);
        expect(session.loading, isFalse);
        expect(player.state.playing, isFalse);
      },
    );
  }
  test(
    'lazy official season load enables selection without changing current playback',
    () async {
      final (session, player) = await open(Repository(), preloadSeasons: false);
      await session.loadSeasons();
      expect(session.seasons, hasLength(2));
      expect(player.opened, hasLength(1));
      expect(await session.playSeason(seasons[1]), isTrue);
    },
  );
  test(
    'screen lock ends boost without pausing and clears on profile change',
    () async {
      final (session, player) = await open(Repository());
      session.setBoostLocked(true);
      session.setLocked(true);
      expect(session.boostLocked, isFalse);
      expect(session.boosting, isFalse);
      expect(player.state.playing, isTrue);
      session.holdBoost();
      expect(session.boosting, isFalse);
      await session.store.switchProfile(session.store.profile.id);
      expect(session.locked, isFalse);
    },
  );
  test(
    'sleep expiration during details cancels switching and preserves old season',
    () async {
      final repo = Repository()..held = Completer<DramaDetail>();
      final (session, player) = await open(repo);
      late void Function() stop;
      runZoned(
        () => session.setSleepTimer(minutes: 15),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, delay, callback) {
            stop = callback;
            return parent.createTimer(zone, delay, callback);
          },
        ),
      );
      final switching = session.playSeason(seasons[1]);
      await until(() => repo.requests == 1);
      stop();
      repo.held!.complete(dramaDetail(second, count: 5));
      expect(await switching, isFalse);
      expect(session.detail.drama.id, first.id);
      expect(player.state.playing, isFalse);
    },
  );
  test('pause while target media resolves never restores sound', () async {
    final repo = Repository();
    final (session, player) = await open(repo);
    repo.resolveGate = Completer<PlaybackPlan>();
    final switching = session.playSeason(seasons[1]);
    await until(() => session.detail.drama.id == second.id);
    session.togglePlayback();
    repo.resolveGate!.complete(
      PlaybackPlan(url: 'https://fixture.invalid/new-season'),
    );
    await switching;
    expect(player.state.playing, isFalse);
    expect(session.paused, isTrue);
  });
}

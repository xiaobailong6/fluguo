import 'dart:async';

import 'package:duanju_app/drama_details.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

final _first = drama('season-a', title: '同名');
final _second = drama('season-b', title: '同名');
final _third = drama('season-c', title: '同名');
final _seasons = [
  DramaSeason(number: 7, drama: _first),
  DramaSeason(number: 2, drama: _second),
  DramaSeason(number: 9, drama: _third),
];

class _Repository extends FakeRepository {
  final pendingSeasons = <Completer<List<DramaSeason>>>[];
  final pendingDetails = <Completer<DramaDetail>>[];
  @override
  Future<List<DramaSeason>> seasons(Drama drama) {
    final request = Completer<List<DramaSeason>>();
    pendingSeasons.add(request);
    return request.future;
  }

  @override
  Future<DramaDetail> detail(Drama drama) {
    final request = Completer<DramaDetail>();
    pendingDetails.add(request);
    return request.future;
  }
}

void main() {
  test(
    'official order, not season number or title, determines next season',
    () {
      final parsed = DramaSeason.fromJson({
        'number': '7',
        'drama': _first.toJson(),
      });
      expect(parsed.number, 7);
      expect(parsed.label, '第 7 季');
      expect(parsed.drama.id, _first.id);
      expect(
        DramaDetail(_first, [], seasons: _seasons).nextSeason?.drama.id,
        _second.id,
      );
      expect(DramaDetail(_third, [], seasons: _seasons).nextSeason, isNull);
      expect(
        DramaDetail(
          drama('unrelated', title: '同名'),
          [],
          seasons: _seasons,
        ).nextSeason,
        isNull,
      );
      expect(DramaDetail(_first, []).nextSeason, isNull);
      expect(
        DramaDetail(
          _first,
          [],
          seasons: [
            _seasons.first,
            DramaSeason(number: 8, drama: drama('season-b', source: 'sorani')),
          ],
        ).nextSeason,
        isNull,
      );
    },
  );

  test(
    'detail and seasons load in parallel; manual selection clears stale state',
    () async {
      final repository = _Repository();
      final details = DramaDetails(repository, await openStore(), _first);
      addTearDown(details.dispose);
      expect(repository.pendingDetails, hasLength(1));
      expect(repository.pendingSeasons, hasLength(1));
      repository.pendingSeasons[0].complete(_seasons);
      repository.pendingDetails[0].complete(dramaDetail(_first, count: 80));
      await pumpEventQueue();
      details.selectGroup(2);
      final changed = details.selectSeason(_seasons[1]);
      expect(details.drama.id, _second.id);
      expect(details.episodes, isEmpty);
      expect(details.error, isNull);
      expect(details.group, 0);
      expect(details.loading, isTrue);
      expect(details.seasons, hasLength(3));
      repository.pendingDetails[1].completeError(StateError('offline'));
      repository.pendingSeasons[1].complete([_seasons[1], _seasons[2]]);
      await changed;
      await pumpEventQueue();
      expect(details.error, contains('offline'));
      expect(details.seasons.map((s) => s.drama.id), [_second.id, _third.id]);
      // 同名但未列入官方列表的条目不可选择。
      await details.selectSeason(
        DramaSeason(number: 3, drama: drama('other', title: '同名')),
      );
      expect(repository.pendingDetails, hasLength(2));
    },
  );

  test(
    'older generations cannot replace the selected seasons or episodes',
    () async {
      final repository = _Repository();
      final details = DramaDetails(repository, await openStore(), _first);
      addTearDown(details.dispose);
      repository.pendingSeasons[0].complete(_seasons);
      await pumpEventQueue();
      final refresh = details.load();
      final changed = details.selectSeason(_seasons[1]);
      repository.pendingDetails[2].complete(dramaDetail(_second, count: 2));
      repository.pendingSeasons[2].complete([_seasons[1], _seasons[2]]);
      await changed;
      repository.pendingDetails[0].complete(dramaDetail(_first, count: 80));
      repository.pendingDetails[1].complete(dramaDetail(_first, count: 80));
      repository.pendingSeasons[1].complete(_seasons);
      await refresh;
      await pumpEventQueue();
      expect(details.drama.id, _second.id);
      expect(details.episodes, hasLength(2));
      expect(details.seasons, hasLength(2));
    },
  );

  test('profile change rejects both late responses', () async {
    final store = await openStore(viewerPreferences);
    final repository = _Repository();
    final details = DramaDetails(repository, store, _first);
    addTearDown(details.dispose);
    await store.switchProfile('viewer');
    repository.pendingSeasons.single.complete(_seasons);
    repository.pendingDetails.single.complete(dramaDetail(_first));
    await pumpEventQueue();
    expect(details.allowed, isFalse);
    expect(details.seasons, isEmpty);
    expect(details.episodes, isEmpty);
  });

  test(
    'unassociated response replaces cache with empty rather than guessing',
    () async {
      final repository = _Repository();
      final details = DramaDetails(repository, await openStore(), _first);
      addTearDown(details.dispose);
      repository.pendingSeasons.single.complete([_seasons[1], _seasons[2]]);
      repository.pendingDetails.single.complete(dramaDetail(_first));
      await pumpEventQueue();
      expect(details.seasons, isEmpty);
      expect(details.episodes, isNotEmpty);
    },
  );
  test(
    'source revocation rejects late official and detail responses',
    () async {
      final store = await openStore();
      final repository = _Repository();
      final details = DramaDetails(repository, store, _first);
      addTearDown(details.dispose);
      await store.setSourceEnabled(_first.source, false);
      repository.pendingSeasons.single.complete(_seasons);
      repository.pendingDetails.single.complete(dramaDetail(_first));
      await pumpEventQueue();
      expect(details.allowed, isFalse);
      expect(details.seasons, isEmpty);
      expect(details.episodes, isEmpty);
    },
  );

  test('disposed details never apply a pending response', () async {
    final repository = _Repository();
    final details = DramaDetails(repository, await openStore(), _first);
    details.dispose();
    repository.pendingSeasons.single.complete(_seasons);
    repository.pendingDetails.single.complete(dramaDetail(_first));
    await pumpEventQueue();
    expect(details.seasons, isEmpty);
    expect(details.episodes, isEmpty);
  });
}

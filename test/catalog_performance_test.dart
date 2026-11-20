import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/native_request_pool.dart';
import 'package:duanju_app/source_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Worker implements NativeRequestWorker {
  _Worker(this.run);
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) run;
  final _dead = Completer<void>();
  @override
  Future<void> get dead => _dead.future;
  @override
  Future<Map<String, dynamic>> execute(String body) =>
      run(jsonDecode(body) as Map<String, dynamic>);
}

Map<String, dynamic> _protocol(bool search) => {
  'ok': true,
  'data': {
    'allSources': allSourcesEnabled,
    'protocolVersion': 1,
    'minCompatibleVersion': 1,
    'capabilities': [
      'structuredErrors',
      'catalogWarningDetails',
      if (search) 'cachedSearch',
    ],
  },
};

final _items = [
  const Drama(
    id: 'hongguo:1',
    source: 'hongguo',
    title: 'ALPHA 城市',
    description: 'Brave',
    tags: ['ROMANCE'],
  ),
  drama('1', title: 'duplicate'),
  drama('2', title: 'alpha only'),
  drama('3', source: 'fanguo', title: 'alpha brave romance'),
  drama('4', title: 'wrong'),
  drama('4', title: 'alpha brave romance'),
];
Map<String, dynamic> _page() => {
  'ok': true,
  'data': {
    'items': [for (final item in _items) item.toJson()],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'old fake inherits cachedSearch AND matching and first-ID dedup',
    () async {
      final repository = FakeRepository()
        ..cachedPages['hongguo|'] = CatalogPage(_items);
      final catalog = SourceCatalog(repository, SourceSite.hongguo);
      for (final query in ['  ALpha\tBrAVE\nRomance ', '城市 romance']) {
        expect((await catalog.cachedSearch(query)).items.map((e) => e.id), [
          'hongguo:1',
        ]);
      }
      expect((await catalog.cachedSearch('missing')).items, isEmpty);
      expect((await catalog.cachedSearch('')).items.map((e) => e.id), [
        'hongguo:1',
        'hongguo:2',
        'hongguo:4',
      ]);
      expect(repository.catalogRequests, isEmpty);
    },
  );

  for (final capable in [false, true]) {
    test(
      'cachedSearch optional capability $capable filters old binaries',
      () async {
        final calls = <Map<String, dynamic>>[];
        final repository = NativeRepository(
          dispatcher: NativeRequestDispatcher(
            () async => _Worker((input) async {
              calls.add(input);
              if (input['action'] == 'protocol') return _protocol(capable);
              return _page();
            }),
          ),
        );
        await repository.checkProtocol();
        final page = await repository.cachedSearch(
          'hongguo',
          'alpha brave romance',
        );
        expect(page.items.map((e) => e.id), ['hongguo:1']);
        expect(calls.last['action'], 'cached');
        expect(calls.last['query'], capable ? 'alpha brave romance' : null);
      },
    );
  }

  test('cachedSearch checks source authorization before dispatch', () async {
    final store = await openStore(viewerPreferences);
    var calls = 0;
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _Worker((input) async {
          if (input['action'] == 'protocol') return _protocol(true);
          calls++;
          return _page();
        }),
      ),
    )..access = store;
    await repository.checkProtocol();
    await expectLater(
      repository.cachedSearch('fanguo', 'alpha'),
      throwsA(isA<AppFailure>()),
    );
    expect(calls, 0);
  });

  test('cachedSearch rejects old permission epoch response', () async {
    final store = await openStore();
    final response = Completer<Map<String, dynamic>>();
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _Worker((input) async {
          if (input['action'] == 'protocol') return _protocol(true);
          return response.future;
        }),
      ),
    )..access = store;
    await repository.checkProtocol();
    final result = expectLater(
      repository.cachedSearch('hongguo', 'alpha'),
      throwsA(isA<AppFailure>()),
    );
    await pumpEventQueue();
    await store.switchProfile(store.profile.id);
    response.complete(_page());
    await result;
  });

  test('cachedSearch fences old cache response and waits for clear', () async {
    final old = Completer<Map<String, dynamic>>();
    final clear = Completer<Map<String, dynamic>>();
    var searches = 0;
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _Worker((input) async {
          if (input['action'] == 'protocol') return _protocol(true);
          if (input['action'] == 'clearCache') return clear.future;
          searches++;
          return searches == 1 ? old.future : _page();
        }),
        concurrency: 2,
      ),
    );
    await repository.checkProtocol();
    final stale = expectLater(
      repository.cachedSearch('hongguo', 'alpha'),
      throwsA(isA<AppFailure>()),
    );
    await pumpEventQueue();
    final clearing = repository.clearCache();
    await pumpEventQueue();
    final fresh = repository.cachedSearch('hongguo', 'alpha');
    expect(searches, 1);
    clear.complete({'ok': true, 'data': <String, dynamic>{}});
    await clearing;
    old.complete(_page());
    await stale;
    expect((await fresh).items.map((e) => e.id), ['hongguo:1', 'hongguo:2']);
    expect(searches, 2);
  });

  test(
    'category cache reuses identity and removes last old category',
    () async {
      final repository = FakeRepository()..categoryList = const [];
      final catalog = SourceCatalog(repository, SourceSite.hongguo);
      catalog.remember([drama('1', category: '城市')]);
      final first = catalog.categories;
      expect(identical(first, catalog.categories), isTrue);
      catalog.remember([
        drama('1', category: '城市', title: 'new title'),
        drama('2', category: '城市'),
      ]);
      expect(identical(first, catalog.categories), isTrue);
      catalog.remember([drama('1', category: '成长')]);
      expect(catalog.categories.map((e) => e.name), ['全部', '城市', '成长']);
      catalog.remember([drama('2', category: '成长')]);
      expect(catalog.categories.map((e) => e.name), ['全部', '成长']);
      final local = catalog.categories;
      await catalog.loadCategories();
      expect(identical(local, catalog.categories), isTrue);
      expect(
        () => catalog.categories.add(CatalogCategory.all),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'category cache preserves remote order and tag override on revision',
    () async {
      final repository = FakeRepository()
        ..categoryList = const [
          CatalogCategory('b', 'AI成人漫剧'),
          CatalogCategory('a', '城市'),
        ];
      final catalog = SourceCatalog(repository, SourceSite.hongguo)
        ..remember([drama('1', category: '成长')]);
      await catalog.loadCategories();
      final first = catalog.categories;
      expect(first.map((e) => e.id), ['', 'b', 'a', 'local:成长']);
      repository.categoryList = const [
        CatalogCategory('b', 'AI 漫剧'),
        CatalogCategory('a', '城市'),
      ];
      await catalog.loadCategories();
      expect(identical(first, catalog.categories), isTrue);
      repository.categoryList = const [
        CatalogCategory('tag:1', '城市'),
        CatalogCategory('b', 'AI漫剧'),
      ];
      await catalog.loadCategories();
      expect(catalog.categories.map((e) => e.id), ['', 'tag:1', 'b']);
      repository.categoryList = const [];
      await catalog.loadCategories();
      expect(catalog.categories.map((e) => e.id), ['', 'local:成长']);
    },
  );
}

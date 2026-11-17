import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/source_capabilities.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test('source policies cover the existing list and only two new ids', () {
    expect(
      SourceSite.allValues.map((site) => site.id).toSet(),
      sourceCapabilities.keys.toSet(),
    );
    expect(sourceCapabilities, hasLength(20));
    expect(
      sourceCapabilities.entries
          .where((entry) => entry.value.standard)
          .map((entry) => entry.key),
      ['hongguo', 'fanguo', 'shuangguo'],
    );
    expect(
      SourceSite.restrictedValues.map((site) => site.id).toSet(),
      sourceCapabilities.entries
          .where((e) => e.value.adult)
          .map((e) => e.key)
          .toSet(),
    );
  });

  test('existing special capabilities and search behavior are preserved', () {
    expect(SourceSite.hongguo.recommends, isTrue);
    expect(SourceSite.hongguo.danmaku, isTrue);
    expect(SourceSite.hongguo.devices, isTrue);
    expect(SourceSite.hongguo.searchSuggestions, isTrue);
    expect(SourceSite.sorani.account, isTrue);
    expect(SourceSite.shuangguo.onlineSearch, isTrue);
    expect(SourceSite.shuangguo.pagedSearch, isFalse);
    expect(SourceSite.byId('huangdou').onlineSearch, isFalse);
    expect(SourceSite.byId('huangguo-video').onlineSearch, isFalse);
    expect(sourceHasCapability('unknown', 'danmaku'), isFalse);
    for (final site in SourceSite.allValues) {
      expect(site.recommends, site.id == 'hongguo');
      expect(site.danmaku, site.id == 'hongguo');
      expect(site.account, site.id == 'sorani');
    }
  });

  for (final id in ['missav', 'hanime1']) {
    test('$id is known, restricted, and only available in all-sources', () {
      final site = SourceSite.byId(id);
      expect(site.id, id);
      expect(site.onlineSearch, isTrue);
      expect(site.pagedSearch, isTrue);
      expect(site.recommends, isFalse);
      expect(site.danmaku, isFalse);
      expect(SourceSite.isRestricted(id), isTrue);
      expect(SourceSite.isAvailable(id), allSourcesEnabled);
    });

    test('$id stays disabled until an administrator enables it', () async {
      final store = await openStore();
      expect(store.sourceEnabled(id), isFalse);
      expect(store.allowsSource(id), isFalse);
      if (allSourcesEnabled) {
        await store.setSourceEnabled(id, true);
        expect(store.allowsSource(id), isTrue);
        final restarted = restartStore(store);
        expect(restarted.allowsSource(id), isTrue);
        await restarted.setSourceEnabled(id, false);
        expect(restarted.allowsSource(id), isFalse);
      } else {
        await expectLater(store.setSourceEnabled(id, true), throwsStateError);
        expect(store.allowsSource(id), isFalse);
      }
    });
  }
}

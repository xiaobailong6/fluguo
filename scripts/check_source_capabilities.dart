import 'dart:io';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/source_capabilities.g.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  final ids = SourceSite.allValues.map((site) => site.id).toSet();
  check(ids.length == 20, 'Expected 18 existing and 2 new sources');
  check(
    ids.length == sourceCapabilities.length &&
        ids.every(sourceCapabilities.containsKey),
    'Capability registry drift',
  );
  final standard = sourceCapabilities.entries
      .where((entry) => entry.value.standard)
      .map((entry) => entry.key)
      .join(',');
  check(standard == 'hongguo,fanguo,shuangguo', 'Standard edition changed');
  check(
    SourceSite.values.length == (allSourcesEnabled ? 20 : 3),
    'Edition source count is wrong',
  );
  const paged = {
    'hongguo',
    'huangju',
    'yeguo',
    'jinguoduanju',
    'jinguo',
    'heitao',
    'beabox',
    'dsd',
    'sorani',
    'guipian',
    'fanguo',
    'hanxiaoquan',
    'huangguoai',
    'missav',
    'hanime1',
  };
  for (final site in SourceSite.allValues) {
    check(
      site.pagedSearch == paged.contains(site.id),
      '${site.id}: paged search',
    );
    check(
      site.onlineSearch == (paged.contains(site.id) || site.id == 'shuangguo'),
      '${site.id}: search',
    );
    check(
      site.recommends == (site.id == 'hongguo'),
      '${site.id}: recommendations',
    );
    check(site.danmaku == (site.id == 'hongguo'), '${site.id}: danmaku');
    check(site.devices == (site.id == 'hongguo'), '${site.id}: devices');
    check(site.account == (site.id == 'sorani'), '${site.id}: account');
  }
  for (final id in ['missav', 'hanime1']) {
    check(
      SourceSite.isKnown(id) && SourceSite.isRestricted(id),
      '$id: visibility policy',
    );
    check(SourceSite.isAvailable(id) == allSourcesEnabled, '$id: edition leak');
    check(SourceSite.byId(id).id == id, '$id: saved identity lost');
  }
  check(
    !SourceSite.isKnown('unknown') &&
        !SourceSite.isAvailable('unknown') &&
        !sourceHasCapability('unknown', 'recommendations'),
    'Unknown source enabled',
  );
  stdout.writeln(
    'Source capabilities: 20 entries checked; edition=$appSlug; OK',
  );
}

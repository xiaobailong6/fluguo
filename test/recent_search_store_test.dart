import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test('连续删除最近搜索按队列中的最新记录计算，重启后不复活', () async {
    final store = await openStore();
    for (final query in ['甲', '乙', '丙']) {
      await store.rememberSearch(query);
    }
    await Future.wait([store.forgetSearch('甲'), store.forgetSearch('乙')]);
    expect(store.recentSearches, ['丙']);
    expect(restartStore(store).recentSearches, ['丙']);
  });

  test('排队删除不能跨越用户代次', () async {
    final store = await openStore(viewerPreferences);
    await store.rememberSearch('保留');
    final switching = store.switchProfile(store.profile.id);
    final deletion = expectLater(store.forgetSearch('保留'), throwsStateError);
    await switching;
    await deletion;
    expect(store.recentSearches, ['保留']);
  });
}

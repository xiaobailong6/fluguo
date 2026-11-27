import 'package:duanju_app/ui/widgets/favorite_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('单剧订阅只通知目标状态，权限变更与重新订阅读取最新值', () async {
    final store = await openStore();
    final target = drama('favorite');
    final signal = store.favoriteStatus(target.id);
    var changes = 0;
    void changed() => changes++;
    signal.addListener(changed);
    await store.setHideVip(false);
    await store.toggleFavorite(drama('other'));
    expect(changes, 0);
    await store.toggleFavorite(target);
    expect(signal.value, isTrue);
    expect(changes, 1);
    await store.setSourceEnabled('hongguo', false);
    expect(signal.value, isFalse);
    expect(changes, 2);
    signal.removeListener(changed);
    await store.setSourceEnabled('hongguo', true);
    final another = store.favoriteStatus(target.id);
    var otherChanges = 0;
    void otherChanged() => otherChanges++;
    another.addListener(otherChanged);
    signal.addListener(changed);
    expect(signal.value, isTrue);
    await store.toggleFavorite(target);
    expect(signal.value, isFalse);
    expect(otherChanges, 1);
    signal.removeListener(changed);
    another.removeListener(otherChanged);
  });

  testWidgets('无关通知不构建海报，隐藏期间停止更新，恢复补齐状态', (tester) async {
    final store = await openStore();
    final target = drama('poster');
    var builds = 0;
    final poster = FavoriteBuilder(
      store: store,
      id: target.id,
      builder: (_, followed) {
        builds++;
        return Text('$followed');
      },
    );
    Widget app(bool visible) => Directionality(
      textDirection: TextDirection.ltr,
      child: TickerMode(enabled: visible, child: poster),
    );
    await tester.pumpWidget(app(true));
    final initial = builds;
    await store.setHideVip(false);
    await store.toggleFavorite(drama('unrelated'));
    await tester.pump();
    expect(builds, initial);
    await store.toggleFavorite(target);
    await tester.pump();
    expect(builds, initial + 1);
    expect(find.text('true'), findsOneWidget);
    await tester.pumpWidget(app(false));
    final hidden = builds;
    await store.toggleFavorite(target);
    await tester.pump();
    expect(builds, hidden);
    await tester.pumpWidget(app(true));
    expect(find.text('false'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await store.toggleFavorite(target);
    expect(tester.takeException(), isNull);
  });

  testWidgets('复用组件更换剧目后改订阅目标', (tester) async {
    final store = await openStore();
    final a = drama('a'), b = drama('b');
    Widget app(String id) => Directionality(
      textDirection: TextDirection.ltr,
      child: FavoriteBuilder(
        store: store,
        id: id,
        builder: (_, followed) => Text('$id:$followed'),
      ),
    );
    await store.toggleFavorite(a);
    await tester.pumpWidget(app(a.id));
    expect(find.text('${a.id}:true'), findsOneWidget);
    await tester.pumpWidget(app(b.id));
    expect(find.text('${b.id}:false'), findsOneWidget);
    await store.toggleFavorite(b);
    await tester.pump();
    expect(find.text('${b.id}:true'), findsOneWidget);
  });
}

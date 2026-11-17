import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/settings/danmaku_settings.dart';
import 'package:duanju_app/ui/settings/settings_rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<void> mountOptions(WidgetTester tester, LocalStore store) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.phone,
        child: child!,
      ),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: store,
          builder: (context, _) => ListView(
            children: danmakuSettingsRows(context, store, (_, _) {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('新弹幕选项默认关闭且复用原有设置行', (tester) async {
    final store = await openStore();
    await mountOptions(tester, store);
    final merge = tester.widget<ValueTile<DanmakuMerge>>(
      find.byType(ValueTile<DanmakuMerge>),
    );
    expect(merge.value, DanmakuMerge.off);
    expect(merge.options.keys, DanmakuMerge.values);
    final emoji = tester
        .widgetList<SwitchTile>(find.byType(SwitchTile))
        .singleWhere((row) => row.title == '图片表情');
    expect(emoji.value, isFalse);
    expect(find.byType(SettingsCard), findsWidgets);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(store.playbackPreferences.danmakuScale, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择合并和表情后修改字号仍保留选项并可关闭', (tester) async {
    final store = await openStore();
    await mountOptions(tester, store);
    await tester.tap(find.text('重复弹幕合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20 秒'));
    await tester.pumpAndSettle();
    expect(store.playbackPreferences.danmakuMerge, DanmakuMerge.twenty);
    await tester.tap(find.text('图片表情'));
    await tester.pumpAndSettle();
    expect(store.playbackPreferences.danmakuEmoji, isTrue);
    await tester.tap(find.text('弹幕字号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('大'));
    await tester.pumpAndSettle();
    final saved = store.playbackPreferences;
    expect(saved.danmakuScale, 1.25);
    expect(saved.danmakuMerge, DanmakuMerge.twenty);
    expect(saved.danmakuEmoji, isTrue);
    final restored = PlaybackPreferences.fromJson(saved.toJson());
    expect(restored.danmakuMerge, saved.danmakuMerge);
    expect(restored.danmakuEmoji, saved.danmakuEmoji);
    await tester.tap(find.text('重复弹幕合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('图片表情'));
    await tester.pumpAndSettle();
    expect(store.playbackPreferences.danmakuMerge, DanmakuMerge.off);
    expect(store.playbackPreferences.danmakuEmoji, isFalse);
    expect(store.playbackPreferences.danmakuScale, 1.25);
    expect(tester.takeException(), isNull);
  });
}

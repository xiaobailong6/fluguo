import 'dart:io';

import 'package:duanju_app/resource_settings_editor.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/settings/settings_rows.dart';
import 'package:duanju_app/ui/settings/settings_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('播放设置短文案保留开关行为和风险提示，320宽字号 $scale', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await openStore();
      final repo = FakeRepository();
      final editor = ResourceSettingsEditor(repo, store);
      addTearDown(editor.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => AppScope(
            repository: repo,
            formFactor: FormFactor.phone,
            child: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 800),
                textScaler: TextScaler.linear(scale),
              ),
              child: child!,
            ),
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SettingsSection(
                group: SettingsGroup.playback,
                store: store,
                editor: editor,
                open: (_, _) {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('点击剧集先看详情'), findsOneWidget);
      expect(find.text('关闭后直接播放'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsWidgets);
      expect(find.byType(SettingsCard), findsWidgets);
      expect(
        find.text(
          Platform.isAndroid
              ? '偏蓝修正仅用于硬解色彩异常的设备，下次打开视频时生效'
              : '有声音没画面或卡顿时可换兼容方式，下次打开视频时生效',
        ),
        findsOneWidget,
      );
      expect(find.text('适应保留完整画面；裁切会切掉边缘；拉伸会改变长宽比'), findsOneWidget);
      final options = [
        (title: '显示当前时间', subtitle: '在播放控件中显示，默认关闭'),
        (title: '显示缓存速度', subtitle: '无缓存或无法读取时显示 0 KB/S'),
        (title: '提前加载下一集', subtitle: '减少切集等待'),
      ];
      for (final option in options) {
        final row = find.byWidgetPredicate(
          (widget) => widget is SwitchTile && widget.title == option.title,
        );
        expect(row, findsOneWidget);
        final before = tester.widget<SwitchTile>(row).value;
        expect(tester.widget<SwitchTile>(row).subtitle, option.subtitle);
        await tester.ensureVisible(find.text(option.title));
        await tester.pumpAndSettle();
        await tester.tap(find.text(option.title));
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchTile>(row).value, !before);
        final saved = restartStore(store).playbackPreferences;
        final value = switch (option.title) {
          '显示当前时间' => saved.showClock,
          '显示缓存速度' => saved.showCacheSpeed,
          _ => saved.preopens(television: false),
        };
        expect(value, !before);
        expect(tester.takeException(), isNull);
      }
      expect(find.text('播控显示缓存读速'), findsNothing);
      expect(find.text('预开下一集'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

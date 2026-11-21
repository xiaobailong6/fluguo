import 'dart:io';

import 'package:duanju_app/resource_settings_editor.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/settings/settings_rows.dart';
import 'package:duanju_app/ui/settings/settings_sections.dart';
import 'package:duanju_app/ui/settings/source_proxy_settings.dart';
import 'package:duanju_app/ui/widgets/group_card.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final admin in [true, false]) {
    testWidgets('站源组代理入口遵守管理员权限 admin=$admin', (tester) async {
      final store = admin
          ? await openStore()
          : await openStore(viewerPreferences);
      final repo = FakeRepository();
      final editor = ResourceSettingsEditor(repo, store);
      await editor.load();
      WidgetBuilder? opened;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => AppScope(
            repository: repo,
            formFactor: FormFactor.phone,
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SettingsSection(
                group: SettingsGroup.proxy,
                store: store,
                editor: editor,
                open: (_, body) => opened = body,
              ),
            ),
          ),
        ),
      );
      final entry = find.byWidgetPredicate(
        (widget) => widget is SettingsTile && widget.title == '按站源组设置',
      );
      expect(entry, findsOneWidget);
      expect(tester.widget<SettingsTile>(entry).enabled, admin);
      final global = find.byWidgetPredicate(
        (widget) => widget is ValueTile<String> && widget.title == '连接方式',
      );
      expect(tester.widget<ValueTile<String>>(global).onChanged != null, admin);
      if (admin) {
        await tester.tap(find.text('按站源组设置'));
        await tester.pump();
        expect(opened, isNotNull);
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => AppScope(
              repository: repo,
              formFactor: FormFactor.phone,
              child: child!,
            ),
            home: Scaffold(body: Builder(builder: opened!)),
          ),
        );
        expect(find.byType(SourceProxySettings), findsOneWidget);
      } else {
        expect(opened, isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      editor.dispose();
    });
  }

  testWidgets('小窗贴边设置仅在Windows播放设置出现', (tester) async {
    if (Platform.isWindows) {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    }
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final store = await openStore();
    final repo = FakeRepository();
    final editor = ResourceSettingsEditor(repo, store);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => AppScope(
          repository: repo,
          formFactor: FormFactor.window,
          child: child!,
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
    expect(
      find.text('小窗贴边隐藏'),
      Platform.isWindows ? findsOneWidget : findsNothing,
    );
    expect(
      find.text('贴边自动暂停'),
      Platform.isWindows ? findsOneWidget : findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    editor.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
}

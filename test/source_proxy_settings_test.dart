import 'dart:async';

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/resource_settings.dart';
import 'package:duanju_app/resource_settings_editor.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/settings/settings_rows.dart';
import 'package:duanju_app/ui/settings/source_proxy_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Repository extends FakeRepository {
  int loads = 0;
  bool failLoad = false, failSave = false;
  Completer<ResourceSettings>? pendingSave;

  @override
  Future<ResourceSettings> resourceSettings() async {
    loads++;
    if (failLoad) throw StateError('离线读取失败');
    return resource;
  }

  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async {
    if (failSave) throw StateError('离线保存失败');
    if (pendingSave != null) return pendingSave!.future;
    return super.saveResourceSettings(settings);
  }
}

Future<void> _mount(
  WidgetTester tester,
  LocalStore store,
  ResourceSettingsEditor editor,
) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.phone,
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SourceProxySettings(store: store, editor: editor),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ValueTile<String> _hongguo(WidgetTester tester) => tester
    .widgetList<ValueTile<String>>(find.byType(ValueTile<String>))
    .singleWhere((row) => row.title == '红果');

void main() {
  test('旧设置迁移及序列化保留本地字段，继承不等于自动', () {
    final old = ResourceSettings.fromJson({'proxyMode': 'direct'});
    expect(old.sourceProxies, isEmpty);
    expect(old.catalogIntervalMs, 250);
    final configured = old
        .copyWith(
          catalogIntervalMs: 0,
          traceEnabled: true,
          downloadBySource: true,
        )
        .withSourceProxy(
          'hongguo',
          const SourceProxy('manual', 'socks5://user:secret@127.0.0.1:1080'),
        );
    final roundTrip = ResourceSettings.fromJson(configured.toJson());
    expect(
      roundTrip.sourceProxies['hongguo']?.url,
      'socks5://user:secret@127.0.0.1:1080',
    );
    expect(roundTrip.catalogIntervalMs, 0);
    expect(roundTrip.traceEnabled, isTrue);
    expect(roundTrip.downloadBySource, isTrue);
    final automatic = roundTrip.withSourceProxy(
      'hongguo',
      const SourceProxy('auto'),
    );
    expect(automatic.sourceProxies['hongguo']?.mode, 'auto');
    expect(automatic.withSourceProxy('hongguo', null).sourceProxies, isEmpty);
    expect(
      roundTrip.copyWith(proxyMode: 'auto').sourceProxies['hongguo']?.mode,
      'manual',
    );
  });

  testWidgets('加载当前设置，修改自动与继承，仅保存目标组', (tester) async {
    final store = await openStore();
    final repository = _Repository()
      ..resource = const ResourceSettings(
        proxyMode: 'direct',
        catalogIntervalMs: 731,
        traceEnabled: true,
        sourceProxies: {
          'hongguo': SourceProxy('manual', 'http://user:secret@localhost:7890'),
          'fanguo': SourceProxy('direct'),
        },
      );
    final editor = ResourceSettingsEditor(repository, store);
    addTearDown(editor.dispose);
    await _mount(tester, store, editor);
    expect(repository.loads, 1);
    expect(_hongguo(tester).value, 'manual');
    expect(find.textContaining('user:secret'), findsNothing);
    _hongguo(tester).onChanged!('auto');
    await tester.pumpAndSettle();
    expect(editor.settings?.sourceProxies['hongguo']?.mode, 'auto');
    expect(editor.settings?.sourceProxies['fanguo']?.mode, 'direct');
    expect(editor.settings?.catalogIntervalMs, 731);
    expect(editor.settings?.traceEnabled, isTrue);
    _hongguo(tester).onChanged!('follow');
    await tester.pumpAndSettle();
    expect(editor.settings?.sourceProxies.containsKey('hongguo'), isFalse);
    expect(repository.savedResources.length, 2);
  });

  testWidgets('访客不能读取代理凭证或修改配置', (tester) async {
    final store = await openStore(viewerPreferences);
    final repository = _Repository();
    final editor = ResourceSettingsEditor(repository, store);
    addTearDown(editor.dispose);
    await _mount(tester, store, editor);
    expect(repository.loads, 0);
    expect(find.text('需要管理员'), findsOneWidget);
    expect(find.byType(ValueTile<String>), findsNothing);
  });

  testWidgets('加载错误可重试，保存错误保留旧值且显示状态', (tester) async {
    final store = await openStore();
    final repository = _Repository()..failLoad = true;
    final editor = ResourceSettingsEditor(repository, store);
    addTearDown(editor.dispose);
    await _mount(tester, store, editor);
    expect(find.text('读取设置失败'), findsOneWidget);
    repository.failLoad = false;
    await tester.tap(find.text('重新读取'));
    await tester.pumpAndSettle();
    expect(_hongguo(tester).value, 'follow');
    repository.failSave = true;
    _hongguo(tester).onChanged!('direct');
    await tester.pumpAndSettle();
    expect(_hongguo(tester).value, 'follow');
    expect(editor.error, contains('离线保存失败'));
    expect(find.text('保存设置失败，原设置保持不变'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手动地址校验与保存中的禁用状态', (tester) async {
    final store = await openStore();
    final repository = _Repository();
    final editor = ResourceSettingsEditor(repository, store);
    addTearDown(editor.dispose);
    await _mount(tester, store, editor);
    _hongguo(tester).onChanged!('manual');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), 'ftp://localhost:21');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入有效的'), findsOneWidget);
    repository.pendingSave = Completer<ResourceSettings>();
    await tester.enterText(find.byType(TextField), 'socks5://127.0.0.1:1080');
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(editor.saving, isTrue);
    expect(_hongguo(tester).onChanged, isNull);
    repository.pendingSave!.complete(
      const ResourceSettings(
        sourceProxies: {
          'hongguo': SourceProxy('manual', 'socks5://127.0.0.1:1080'),
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(editor.saving, isFalse);
    expect(_hongguo(tester).value, 'manual');
  });
}

import 'dart:convert';

import 'package:duanju_app/local_backup_codec.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:duanju_app/navigation_order.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _admin = LocalProfile(
  id: 'default',
  name: '管理员',
  admin: true,
  salt: '00000000000000000000000000000000',
  pinHash: '1111111111111111111111111111111111111111111111111111111111111111',
);
const _viewer = LocalProfile(id: 'viewer', name: '访客', sources: ['hongguo']);

Map<String, dynamic> _library() => {
  'history': [],
  'favorites': [],
  'source': 'hongguo',
  'hideVip': true,
};
Map<String, dynamic> _backup() => {
  'schema': 1,
  'app': 'zhenguojian',
  'profiles': [_admin.toJson(), _viewer.toJson()],
  'libraries': {'default': _library(), 'viewer': _library()},
};
String _key(String category, String id) =>
    id == 'default' ? category : 'profile.$id.$category';

void main() {
  test('旧备份缺可选字段时保留原默认值与用户键名', () {
    final data = _backup();
    final before = jsonEncode(data);
    final values = LocalBackupCodec.snapshotValues(
      data,
      profiles: [_admin, _viewer],
      fallbackThemeMode: 'dark',
      fileBacked: false,
      keyFor: _key,
    );
    expect(jsonEncode(data), before, reason: '组装不修改原备份');
    expect(values['activeProfile'], 'default');
    expect(values['displayMode'], 'auto');
    expect(values['themeMode'], 'dark');
    expect(values['forceLogin'], isTrue);
    expect(values['autoExport'], isFalse);
    expect(
      jsonDecode(values['navigationOrder'] as String),
      normalizeNavigationOrder([]),
    );
    expect(
      jsonDecode(values['navigationVisible'] as String),
      normalizeNavigationVisible([]),
    );
    expect(values['profile.viewer.source'], 'hongguo');
    expect(values['profile.viewer.hideVip'], isTrue);
    expect(values['profile.viewer.liveHistory'], isEmpty);
    expect(values['profile.viewer.mediaHistory'], isEmpty);
    expect(values['profile.viewer.playback'], '{}');
    expect(values['profile.viewer.recentSearches'], '[]');
    expect(values.keys.every(LocalSnapshot.owns), isTrue);
    expect(values.keys.any((key) => key.contains('seriesCandidates')), isFalse);
  });

  test('分文件存储的系列候选与偏好编码保持原类型', () {
    final data = _backup();
    final item = drama('series');
    final library = (data['libraries'] as Map)['viewer'] as Map;
    library.addAll(<String, dynamic>{
      'favorites': [item.toJson()],
      'seriesCandidates': [item.toJson()],
      'playback': {'speed': 1.5},
      'downloadPreferences': {'quality': 720},
      'recentSearches': ['剧名'],
    });
    data.addAll({
      'displayMode': 'pad',
      'themeMode': 'light',
      'forceLogin': false,
      'autoExport': true,
      'exportPosters': true,
    });
    final values = LocalBackupCodec.snapshotValues(
      data,
      profiles: [_admin, _viewer],
      fallbackThemeMode: 'dark',
      fileBacked: true,
      keyFor: _key,
    );
    expect(
      values['profile.viewer.seriesCandidates'],
      library['seriesCandidates'],
    );
    expect(values['profile.viewer.favorites'], same(library['favorites']));
    expect(jsonDecode(values['profile.viewer.playback'] as String), {
      'speed': 1.5,
    });
    expect(jsonDecode(values['profile.viewer.downloadPreferences'] as String), {
      'quality': 720,
    });
    expect(jsonDecode(values['profile.viewer.recentSearches'] as String), [
      '剧名',
    ]);
    expect(values['themeMode'], 'light');
    expect(values['displayMode'], 'pad');
    expect(values['forceLogin'], isFalse);
    expect(values['autoExport'], isTrue);
    expect(values['exportPosters'], isTrue);
  });

  test('LocalStore原校验入口无写入，保持可选字段及未知展示字段兼容', () async {
    final store = await openStore();
    await store.exportBackup(); // 等待原初始化队列结束。
    final before = {
      for (final key in store.preferences.getKeys())
        key: store.preferences.get(key),
    };
    final data = _backup()..['futureDisplayField'] = 'ignored';
    expect(store.validateBackup(jsonEncode(data)), data);
    expect({
      for (final key in store.preferences.getKeys())
        key: store.preferences.get(key),
    }, before);
  });

  final invalid = <String, void Function(Map<String, dynamic>)>{
    '备份格式': (data) => data['schema'] = 2,
    '主题': (data) => data['themeMode'] = 'invalid',
    '颜色': (data) => data['themeColor'] = 'invalid',
    '玻璃': (data) => data['glassEffects'] = 'yes',
    '登录': (data) => data['forceLogin'] = 1,
    '重复用户': (data) => (data['profiles'] as List).add(_viewer.toJson()),
    '无密码管理员与访客': (data) => (data['profiles'] as List)[0] = const LocalProfile(
      id: 'default',
      name: '管理员',
      admin: true,
    ).toJson(),
    '过多历史': (data) =>
        ((data['libraries'] as Map)['default'] as Map)['history'] = List.filled(
          301,
          {},
        ),
    '追剧孤立状态': (data) =>
        ((data['libraries'] as Map)['default'] as Map)['followStates'] = {
          'absent': {},
        },
    '搜索长度': (data) =>
        ((data['libraries'] as Map)['default'] as Map)['recentSearches'] = [
          '字' * 81,
        ],
    '搜索数量': (data) =>
        ((data['libraries'] as Map)['default'] as Map)['recentSearches'] =
            List.filled(21, '字'),
  };
  for (final entry in invalid.entries) {
    test('${entry.key}仍由原入口拒绝', () async {
      final store = await openStore();
      final data = _backup();
      entry.value(data);
      expect(
        () => store.validateBackup(jsonEncode(data)),
        throwsFormatException,
      );
    });
  }

  test('8MiB上限仍按UTF-8字节数而不是字符数判断', () async {
    final store = await openStore();
    final content = '字' * (3 * 1024 * 1024);
    expect(
      () => store.validateBackup(content),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          '备份文件过大',
        ),
      ),
    );
  });
}

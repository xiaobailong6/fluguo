import 'dart:convert';
import 'dart:io';
import 'live_history.dart';

/// 分类别文件存储。写前日志用于恢复跨文件提交，不把身份文件损坏当作新安装。
class LocalFileStore {
  LocalFileStore(this.directory, {this.validateProfiles});
  final Directory directory;
  final void Function(Object?)? validateProfiles;
  Map<String, Object> _values = {};
  bool initialized = false;
  Object? loadError;
  Map<String, Object> get values {
    if (loadError != null) throw const FormatException('分文件存储需要恢复');
    return Map.of(_values);
  }

  static String fileFor(String key) {
    if ({'profiles', 'activeProfile', 'forceLogin'}.contains(key))
      return 'users.json';
    final match = RegExp(
      r'^profile\.([a-zA-Z0-9_-]{1,64})\.([a-zA-Z]+)$',
    ).firstMatch(key);
    final category = match == null ? key : match[2]!;
    if (!RegExp(r'^[a-zA-Z]+$').hasMatch(category))
      throw const FormatException('无效存储类别');
    const library = {
      'history',
      'favorites',
      'liveFavorites',
      'liveHistory',
      'followChecks',
      'followStates',
      'seriesCandidates',
      'mediaHistory',
      'source',
      'hideVip',
      'playback',
      'downloadPreferences',
      'catalogView',
      'recentSearches',
    };
    const global = {
      'displayMode',
      'themeMode',
      'autoExport',
      'exportPosters',
      'sourceSwitches',
    };
    if (!library.contains(category) && !global.contains(category))
      throw const FormatException('未知存储字段');
    return library.contains(category)
        ? 'profiles/${match == null ? 'default' : match[1]}/$category.json'
        : 'settings/$category.json';
  }

  File _file(String name) {
    if (!RegExp(
      r'^(users\.json|settings/[a-zA-Z]+\.json|profiles/[a-zA-Z0-9_-]{1,64}/[a-zA-Z]+\.json|transaction\.json|initialized)$',
    ).hasMatch(name)) {
      throw const FormatException('无效存储路径');
    }
    return File(
      '${directory.path}/${name.replaceAll('/', Platform.pathSeparator)}',
    );
  }

  Map<String, Object> _decode(String text, String name) {
    if (utf8.encode(text).length > 16 * 1024 * 1024)
      throw const FormatException('类别文件超过保存上限');
    final json = jsonDecode(text);
    if (json is! Map || json['version'] != 1 || json['values'] is! Map)
      throw const FormatException('存储格式无效');
    final values = Map<String, Object>.from(json['values'] as Map);
    for (final entry in values.entries) {
      final category = entry.key.split('.').last;
      final boolean = {
        'hideVip',
        'autoExport',
        'exportPosters',
        'forceLogin',
      }.contains(category);
      if (fileFor(entry.key) != name ||
          (boolean ? entry.value is! bool : entry.value is! String)) {
        throw const FormatException('存储字段无效');
      }
      if (!boolean &&
          !{
            'source',
            'activeProfile',
            'displayMode',
            'themeMode',
          }.contains(category)) {
        final decoded = jsonDecode(entry.value as String);
        final list = {
          'profiles',
          'history',
          'favorites',
          'liveFavorites',
          'liveHistory',
          'seriesCandidates',
          'recentSearches',
        }.contains(category);
        if (list ? decoded is! List : decoded is! Map)
          throw const FormatException('类别数据无效');
        if (category == 'profiles') validateProfiles?.call(decoded);
        if (category == 'liveHistory') LiveHistoryEntry.validateList(decoded);
      }
    }
    if (name == 'users.json' && !values.containsKey('profiles'))
      throw const FormatException('用户配置缺失');
    return values;
  }

  Future<Map<String, Object>?> _read(String name) async {
    final file = _file(name);
    for (final candidate in [file, File('${file.path}.bak')]) {
      if (!await candidate.exists()) continue;
      try {
        if (await candidate.length() > 16 * 1024 * 1024)
          throw const FormatException('存储文件过大');
        final text = await candidate.readAsString();
        final values = _decode(text, name);
        if (candidate.path != file.path)
          await _atomic(name, text, backup: false);
        return values;
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
      // 权限/磁盘错误必须上抛并保留原记录，不能当作损坏清空。
    }
    if (name == 'users.json') throw const FormatException('用户配置损坏，需恢复备份');
    return null;
  }

  Future<void> load() async {
    await directory.create(recursive: true);
    final journal = _file('transaction.json');
    if (await journal.exists()) {
      // 先验证全部日志内容，再做任何写入；禁止损坏日志改变用户身份。
      final decoded = jsonDecode(await journal.readAsString());
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['files'] is! Map)
        throw const FormatException('存储事务损坏');
      final files = Map<String, String>.from(decoded['files'] as Map);
      for (final entry in files.entries) {
        _decode(entry.value, entry.key);
      }
      for (final entry in files.entries) {
        await _atomic(entry.key, entry.value);
      }
      await _atomic('initialized', '1', backup: false);
      await journal.delete();
    }
    final marked = await _file('initialized').exists();
    initialized =
        marked ||
        await _file('users.json').exists() ||
        await File('${_file('users.json').path}.bak').exists();
    _values = {};
    if (!initialized) {
      final userFiles = await directory
          .list(recursive: true, followLinks: false)
          .any(
            (entity) =>
                entity is File &&
                (entity.path.contains(
                      '${Platform.pathSeparator}profiles${Platform.pathSeparator}',
                    ) ||
                    entity.path.contains(
                      '${Platform.pathSeparator}settings${Platform.pathSeparator}',
                    )) &&
                (entity.path.endsWith('.json') ||
                    entity.path.endsWith('.json.bak')),
          );
      if (userFiles) throw const FormatException('已有记录但用户文件缺失');
      return;
    }
    final users = await _read('users.json');
    _values.addAll(users!);
    final names = <String>{};
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      var name = entity.path
          .substring(directory.path.length + 1)
          .replaceAll('\\', '/');
      if (name.endsWith('.bak')) name = name.substring(0, name.length - 4);
      if (name == 'users.json' ||
          !name.endsWith('.json') ||
          name == 'transaction.json')
        continue;
      if (RegExp(
        r'^(profiles/[a-zA-Z0-9_-]{1,64}/[a-zA-Z]+|settings/[a-zA-Z]+)\.json$',
      ).hasMatch(name))
        names.add(name);
    }
    for (final name in names) {
      final values = await _read(name);
      if (values != null) _values.addAll(values);
    }
    if (!marked) await _atomic('initialized', '1', backup: false);
  }

  static Map<String, Map<String, Object>> _groups(Map<String, Object> values) {
    final result = <String, Map<String, Object>>{};
    for (final entry in values.entries) {
      (result[fileFor(entry.key)] ??= {})[entry.key] = entry.value;
    }
    return result;
  }

  /// 旧快照中某类记录格式错误时，只跳过该类别；身份结构错误不能跳过。
  Map<String, Object> prepareMigration(Map<String, Object> values) {
    final result = <String, Object>{};
    for (final group in _groups(values).entries) {
      try {
        _decode(jsonEncode({'version': 1, 'values': group.value}), group.key);
        result.addAll(group.value);
      } catch (_) {
        if (group.key == 'users.json') rethrow;
      }
    }
    return result;
  }

  Future<void> commit(Map<String, Object> values) async {
    final before = _groups(_values);
    final after = _groups(values);
    if (!after.containsKey('users.json'))
      throw const FormatException('不能删除用户配置');
    final changed = <String, String>{};
    final names = {...before.keys, ...after.keys};
    if (loadError != null) {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        var name = entity.path
            .substring(directory.path.length + 1)
            .replaceAll('\\', '/');
        if (name.endsWith('.bak')) name = name.substring(0, name.length - 4);
        if (RegExp(
          r'^(profiles/[a-zA-Z0-9_-]{1,64}/[a-zA-Z]+|settings/[a-zA-Z]+)\.json$',
        ).hasMatch(name))
          names.add(name);
      }
    }
    for (final name in names) {
      final next = after[name] ?? <String, Object>{};
      final old = before[name];
      if (initialized &&
          old != null &&
          old.length == next.length &&
          next.entries.every((entry) => old[entry.key] == entry.value))
        continue;
      changed[name] = jsonEncode({'version': 1, 'values': next});
      _decode(changed[name]!, name);
    }
    if (changed.isEmpty) return;
    var prepared = false;
    try {
      await _atomic(
        'transaction.json',
        jsonEncode({'version': 1, 'files': changed}),
        backup: false,
      );
      prepared = true;
      for (final entry in changed.entries) {
        await _atomic(entry.key, entry.value);
      }
      if (!initialized) await _atomic('initialized', '1', backup: false);
      await _file('transaction.json').delete();
      _values = Map.of(values);
      initialized = true;
      loadError = null;
    } catch (_) {
      // 日志已持久化后不能声称回滚成功；调用者须锁定并重新读取。
      if (prepared) {
        loadError = const FileStoreRecoveryRequired();
        throw const FileStoreRecoveryRequired();
      }
      rethrow;
    }
  }

  Future<Map<String, Object>?> readIdentity() => _read('users.json');

  /// 恢复导出只在配置损坏页面调用，保留原文供用户取回，不自动覆盖损坏记录。
  Map<String, String> recoveryFiles() {
    final result = <String, String>{};
    var total = 0;
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File ||
          !(entity.path.endsWith('.json') || entity.path.endsWith('.json.bak')))
        continue;
      final size = entity.lengthSync();
      if (size > 16 * 1024 * 1024 || total + size > 64 * 1024 * 1024) continue;
      final name = entity.path
          .substring(directory.path.length + 1)
          .replaceAll('\\', '/');
      result[name] = utf8.decode(
        entity.readAsBytesSync(),
        allowMalformed: true,
      );
      total += size;
    }
    return result;
  }

  Future<void> _atomic(String name, String text, {bool backup = true}) async {
    final file = _file(name);
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(text, flush: true);
    if (backup && await file.exists()) {
      // copy 而非先移走主文件，避免备份复制失败时主文件也丢失。
      await file.copy('${file.path}.bak');
    }
    // Windows 不允许 rename 覆盖；间隙发生崩溃时由事务日志/备份恢复。
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }
}

class FileStoreRecoveryRequired implements Exception {
  const FileStoreRecoveryRequired();
}

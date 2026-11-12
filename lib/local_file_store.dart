import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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

  /// 每次提交都会对每个字段调用，正则与集合提到静态，避免反复编译和分配。
  static const _identityKeys = {'profiles', 'activeProfile', 'forceLogin'};
  static final _profileKey = RegExp(
    r'^profile\.([a-zA-Z0-9_-]{1,64})\.([a-zA-Z]+)$',
  );
  static final _categoryKey = RegExp(r'^[a-zA-Z]+$');

  /// 布尔类字段与直接存字符串的字段：读盘校验与写盘校验共用同一份定义。
  static const _booleanKeys = {
    'hideVip',
    'autoExport',
    'exportPosters',
    'forceLogin',
  };
  static const _plainTextCategories = {
    'source',
    'activeProfile',
    'displayMode',
    'themeMode',
  };

  /// 编码后应当是 JSON 数组的字段；其余有嵌套结构的字段应当是 JSON 对象。
  static const _listCategories = {
    'profiles',
    'history',
    'favorites',
    'liveFavorites',
    'liveHistory',
    'seriesCandidates',
    'recentSearches',
    'navigationOrder',
    'navigationVisible',
  };

  static String fileFor(String key) {
    if (_identityKeys.contains(key)) return 'users.json';
    final match = _profileKey.firstMatch(key);
    final category = match == null ? key : match[2]!;
    if (!_categoryKey.hasMatch(category)) {
      throw const FormatException('无效存储类别');
    }
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
      'navigationOrder',
      'navigationVisible',
      'autoExport',
      'exportPosters',
      'sourceSwitches',
    };
    if (!library.contains(category) && !global.contains(category)) {
      throw const FormatException('未知存储字段');
    }
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
    if (_tooLarge(text)) throw const FormatException('类别文件超过保存上限');
    final json = jsonDecode(text);
    if (json is! Map || json['version'] != 1 || json['values'] is! Map) {
      throw const FormatException('存储格式无效');
    }
    final values = Map<String, Object>.from(json['values'] as Map);
    for (final entry in values.entries) {
      final category = entry.key.split('.').last;
      final boolean = _booleanKeys.contains(category);
      if (fileFor(entry.key) != name ||
          (boolean ? entry.value is! bool : entry.value is! String)) {
        throw const FormatException('存储字段无效');
      }
      if (!boolean && !_plainTextCategories.contains(category)) {
        final decoded = jsonDecode(entry.value as String);
        if (_listCategories.contains(category)
            ? decoded is! List
            : decoded is! Map) {
          throw const FormatException('类别数据无效');
        }
        if (category == 'profiles') validateProfiles?.call(decoded);
        if (category == 'liveHistory') LiveHistoryEntry.validateList(decoded);
      }
    }
    if (name == 'users.json' && !values.containsKey('profiles')) {
      throw const FormatException('用户配置缺失');
    }
    return values;
  }

  /// 储存上限判定：每个 UTF-16 代码单元最多编码成 3 字节，因此长度不到上限
  /// 三分之一的内容必然合格；只有跨过这条线时才真的编码一遍来量字节数。
  /// 写盘与读盘共用同一份判定，保证写得出去的内容一定还能被自己读回来。
  static bool _tooLarge(String text) {
    const limit = 16 * 1024 * 1024;
    return text.length > limit ||
        (text.length * 3 > limit && utf8.encode(text).length > limit);
  }

  /// 写盘前的自生成校验。
  ///
  /// 内容由本进程刚用 [jsonEncode] 生成，JSON 语法必然正确，再整份解码一遍
  /// 只是白费一次解析；这里改为核对储存上限、字段归属、类型与容器形状，
  /// 判定结果与 [_decode] 相同。需要逐条校验的 profiles 与 liveHistory 仍
  /// 解析后交给原校验器。从磁盘读入的内容一律继续走 [_decode] 的完整校验。
  void _verifyGenerated(
    Map<String, Object> values,
    String name,
    String encoded,
  ) {
    // 与读盘同样的上限：超过上限的文件下次启动读不回来，必须先在这里拦住。
    if (_tooLarge(encoded)) throw const FormatException('类别文件超过保存上限');
    for (final entry in values.entries) {
      if (fileFor(entry.key) != name) {
        throw const FormatException('存储字段无效');
      }
      final category = entry.key.split('.').last;
      final value = entry.value;
      if (_booleanKeys.contains(category)) {
        if (value is! bool) throw const FormatException('存储字段无效');
        continue;
      }
      if (value is! String) throw const FormatException('存储字段无效');
      if (_plainTextCategories.contains(category)) continue;
      if (_containerStart(value) !=
          (_listCategories.contains(category) ? '[' : '{')) {
        throw const FormatException('类别数据无效');
      }
      if (category == 'profiles') validateProfiles?.call(jsonDecode(value));
      if (category == 'liveHistory') {
        LiveHistoryEntry.validateList(jsonDecode(value));
      }
    }
    if (name == 'users.json' && !values.containsKey('profiles')) {
      throw const FormatException('用户配置缺失');
    }
  }

  /// [jsonEncode] 的结果里，第一个非空白字符就是容器类型。
  static String _containerStart(String value) {
    for (var index = 0; index < value.length; index++) {
      final character = value[index];
      if (character != ' ' &&
          character != '\n' &&
          character != '\r' &&
          character != '\t') {
        return character;
      }
    }
    return '';
  }

  Future<Map<String, Object>?> _read(String name) async {
    final file = _file(name);
    for (final candidate in [file, File('${file.path}.bak')]) {
      if (!await candidate.exists()) continue;
      try {
        if (await candidate.length() > 16 * 1024 * 1024) {
          throw const FormatException('存储文件过大');
        }
        final text = await candidate.readAsString();
        final values = _decode(text, name);
        if (candidate.path != file.path) {
          await _atomic(name, text, backup: false);
        }
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
          decoded['files'] is! Map) {
        throw const FormatException('存储事务损坏');
      }
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
          name == 'transaction.json') {
        continue;
      }
      if (RegExp(
        r'^(profiles/[a-zA-Z0-9_-]{1,64}/[a-zA-Z]+|settings/[a-zA-Z]+)\.json$',
      ).hasMatch(name)) {
        names.add(name);
      }
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
    if (!after.containsKey('users.json')) {
      throw const FormatException('不能删除用户配置');
    }
    final pending = <String, Map<String, Object>>{};
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
        ).hasMatch(name)) {
          names.add(name);
        }
      }
    }
    for (final name in names) {
      final next = after[name] ?? <String, Object>{};
      final old = before[name];
      if (initialized &&
          old != null &&
          old.length == next.length &&
          next.entries.every((entry) => old[entry.key] == entry.value)) {
        continue;
      }
      pending[name] = next;
    }
    if (pending.isEmpty) return;
    final encoded = await _encode(pending);
    for (final entry in encoded.files.entries) {
      // 写前只做自生成校验：内容刚由本进程编码，重复整份解码纯属浪费。
      _verifyGenerated(pending[entry.key]!, entry.key, entry.value);
    }
    var prepared = false;
    try {
      await _atomic(
        'transaction.json',
        encoded.index,
        backup: false,
      );
      prepared = true;
      for (final entry in encoded.files.entries) {
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

  /// 小于这个估算体积就直接在主线程编码，省掉 isolate 的启停与数据拷贝。
  static const _inlineEncodeLimit = 64 * 1024;

  /// 编码是纯 CPU 工作：内容较大时整批丢到后台 isolate。
  ///
  /// 写入顺序、事务日志内容和最终字节都不变，只是不再占着主线程做
  /// `jsonEncode`；小改动仍走同步路径，避免每 5 秒一次的进度保存
  /// 付一次 isolate 启动开销。
  Future<({Map<String, String> files, String index})> _encode(
    Map<String, Map<String, Object>> pending,
  ) async {
    if (_encodeWeight(pending) <= _inlineEncodeLimit) {
      return _encodeNow(pending);
    }
    return Isolate.run(() => _encodeNow(pending));
  }

  /// 体积估算：只看键名与字符串值，足够决定走不走 isolate。
  static int _encodeWeight(Map<String, Map<String, Object>> pending) {
    var weight = 0;
    for (final entry in pending.entries) {
      weight += entry.key.length;
      for (final item in entry.value.entries) {
        weight += item.key.length;
        final value = item.value;
        if (value is String) weight += value.length;
      }
    }
    return weight;
  }

  static ({Map<String, String> files, String index}) _encodeNow(
    Map<String, Map<String, Object>> pending,
  ) {
    final files = <String, String>{
      for (final entry in pending.entries)
        entry.key: jsonEncode({'version': 1, 'values': entry.value}),
    };
    return (files: files, index: jsonEncode({'version': 1, 'files': files}));
  }
}

class FileStoreRecoveryRequired implements Exception {
  const FileStoreRecoveryRequired();
}

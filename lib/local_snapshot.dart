import 'dart:convert';
import 'dart:isolate';

import 'local_file_store.dart';
import 'history_retention.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalSnapshot {
  LocalSnapshot(this.preferences, {this.files}) {
    reloadValues();
  }
  LocalSnapshot.empty(this.preferences, {this.files});

  static const storageKey = 'localSnapshot.v1';

  /// 校验与清理都要逐字段判断，集合提到静态，避免每条记录分配一次。
  static const _booleanKeys = {
    'hideVip',
    'autoExport',
    'exportPosters',
    'forceLogin',
  };
  static const libraryKeys = {
    'history',
    'favorites',
    'liveFavorites',
    'liveHistory',
    'followStates',
    'followChecks',
    'seriesCandidates',
    'mediaHistory',
    'source',
    'hideVip',
    'playback',
    'downloadPreferences',
    'catalogView',
    'recentSearches',
  };
  static const globalKeys = {
    'profiles',
    'activeProfile',
    'displayMode',
    'themeMode',
    'autoExport',
    'navigationOrder',
    'navigationVisible',
    'exportPosters',
    'sourceSwitches',
    'forceLogin',
  };
  static const _retiredKeys = {
    'sourceGateEnabled',
    'sourceGateOff',
    'sourceGateSalt',
    'sourceGateHash',
  };
  static final _retiredLibraryKey = RegExp(
    r'^(profile\.[a-zA-Z0-9_-]{1,64}\.)?(lanRecords|lanSettings|lanReceipts)$',
  );
  final SharedPreferences preferences;
  final LocalFileStore? files;
  Map<String, Object> _values = {};

  static bool owns(String key) =>
      globalKeys.contains(key) ||
      libraryKeys.contains(key) ||
      RegExp(
        r'^profile\.[a-zA-Z0-9_-]{1,64}\.(history|favorites|liveFavorites|liveHistory|followStates|followChecks|seriesCandidates|mediaHistory|source|hideVip|playback|downloadPreferences|catalogView|recentSearches)$',
      ).hasMatch(key);

  Map<String, Object> get values => Map.of(_values);
  String? getString(String key) => _values[key] as String?;
  bool? getBool(String key) => _values[key] as bool?;

  void reloadValues() {
    if (files != null) {
      _values = files!.values;
      _validate(_values);
      return;
    }
    final raw = preferences.getString(storageKey);
    if (raw == null) {
      _values = {
        for (final key in preferences.getKeys().where(owns))
          key: preferences.get(key)!,
      };
      _validate(_values);
      return;
    }
    final decoded = jsonDecode(raw) as Map;
    if (decoded['version'] != 1 || decoded['values'] is! Map) {
      throw const FormatException('本地配置快照无效');
    }
    final values = Map<String, Object>.from(decoded['values'] as Map)
      ..removeWhere(
        (key, _) =>
            _retiredKeys.contains(key) || _retiredLibraryKey.hasMatch(key),
      );
    if (!values.containsKey('profiles')) {
      throw const FormatException('本地配置快照无效');
    }
    _validate(values);
    _values = values;
  }

  void _validate(Map<String, Object> values) {
    for (final entry in values.entries) {
      final boolean = _booleanKeys.contains(entry.key.split('.').last);
      if (!owns(entry.key) ||
          (boolean ? entry.value is! bool : entry.value is! String)) {
        throw const FormatException('本地配置字段无效');
      }
    }
  }

  Future<bool> _restore(Object? value) => switch (value) {
    null => preferences.remove(storageKey),
    String value => preferences.setString(storageKey, value),
    bool value => preferences.setBool(storageKey, value),
    int value => preferences.setInt(storageKey, value),
    double value => preferences.setDouble(storageKey, value),
    List<String> value => preferences.setStringList(storageKey, value),
    _ => Future.value(false),
  };

  /// 退休字段只在成功保存时移除，不影响读取旧备份。
  static Map<String, Object> cleanValues(Map<String, Object> values) {
    final result = Map<String, Object>.of(values);
    result.removeWhere((key, _) => key.split('.').last == 'catalogView');
    for (final entry in values.entries) {
      if (entry.key.split('.').last != 'playback' || entry.value is! String) {
        continue;
      }
      try {
        final playback = Map<String, dynamic>.from(
          jsonDecode(entry.value as String) as Map,
        )..remove('enhancement');
        result[entry.key] = jsonEncode(playback);
      } catch (_) {}
    }
    return result;
  }

  /// 原始容器延迟到提交时编码，避免调用处已经在主线程生成大 JSON。
  /// 估算遇到模型时取保守权重；无需先编码一遍来决定是否后台执行。
  static Future<Map<String, Object>> encodeChanges(
    Map<String, Object> changes,
    DateTime now,
  ) {
    final captured = Map<String, Object>.of(changes);
    return _encodingWeight(captured) > 64 * 1024
        ? Isolate.run(() => _encodeChanges(captured, now))
        : Future.value(_encodeChanges(captured, now));
  }

  Future<void> commit(Map<String, Object> values) async {
    if (values.keys.any((key) => !owns(key))) throw StateError('无效的本地配置字段');
    values = cleanValues(values);
    if (files != null) {
      _validate(values);
      try {
        await files!.commit(values);
      } on FileStoreRecoveryRequired {
        throw const SnapshotRecoveryRequired();
      }
      _values = Map.of(values);
      return;
    }
    final payload = <String, Object>{'version': 1, 'values': values};
    final content = _encodingWeight(values) > 64 * 1024
        ? await Isolate.run(() => _encodeSnapshot(payload))
        : _encodeSnapshot(payload);
    final previous = preferences.get(storageKey);
    try {
      if (!await preferences.setString(storageKey, content)) {
        throw StateError('本地配置未能保存');
      }
    } catch (_) {
      try {
        await preferences.reload();
        if (preferences.get(storageKey) != previous) {
          final restored = await _restore(previous);
          if (!restored) throw StateError('无法恢复原配置');
          await preferences.reload();
          if (preferences.get(storageKey) != previous) {
            throw StateError('无法恢复原配置');
          }
        }
      } catch (_) {
        throw const SnapshotRecoveryRequired();
      }
      throw StateError('未能保存，原有记录已保留；请检查存储空间和权限后重试');
    }
    _values = Map.of(values);
  }
}

class SnapshotRecoveryRequired implements Exception {
  const SnapshotRecoveryRequired();
  @override
  String toString() => '无法确认本地配置保存结果，已锁定访问；请重新读取配置或恢复备份';
}

int _encodingWeight(Object? value) {
  if (value is String) return value.length;
  if (value is bool || value is num || value == null) return 8;
  var weight = 0;
  if (value is Map) {
    for (final entry in value.entries) {
      weight += _encodingWeight(entry.key) + _encodingWeight(entry.value);
      if (weight > 64 * 1024) break;
    }
    return weight;
  }
  if (value is Iterable) {
    for (final item in value) {
      weight += _encodingWeight(item);
      if (weight > 64 * 1024) break;
    }
    return weight;
  }
  return 2048;
}

Map<String, Object> _encodeChanges(Map<String, Object> changes, DateTime now) {
  final encoded = <String, Object>{
    for (final entry in changes.entries)
      entry.key: entry.value is String || entry.value is bool
          ? entry.value
          : jsonEncode(entry.value),
  };
  pruneWatchHistoryValues(encoded, now);
  return encoded;
}

String _encodeSnapshot(Map<String, Object> payload) {
  final content = jsonEncode(payload);
  const limit = 16 * 1024 * 1024;
  if (content.length > limit ||
      (content.length * 3 > limit && utf8.encode(content).length > limit)) {
    throw StateError('本地记录超过保存上限，请先导出备份并清理记录');
  }
  return content;
}

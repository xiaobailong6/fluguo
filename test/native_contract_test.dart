import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `lib/` 里发出去的动作名，形如 `{'action': 'detail', ...}`。
final _dartAction = RegExp(r"'action':\s*'([A-Za-z0-9_]+)'");

/// 原生分发器里的 `case "a", "b":`。
final _goCase = RegExp(
  r'case\s+((?:"[A-Za-z0-9_]+"\s*,\s*)*"[A-Za-z0-9_]+")\s*:',
);

/// 原生分发器里放在 switch 之前的 `input.Action == "a"` 形式。
final _goCompare = RegExp(r'input\.Action\s*==\s*"([A-Za-z0-9_]+)"');

final _goLiteral = RegExp(r'"([A-Za-z0-9_]+)"');

void main() {
  test('每个 dart 动作在原生分发器里都有分支', () {
    final dartActions = _dartActions();
    final nativeActions = _nativeActions();
    expect(dartActions.length, greaterThan(20));
    expect(nativeActions.length, greaterThan(20));
    final missing = dartActions.difference(nativeActions).toList()..sort();
    expect(
      missing,
      isEmpty,
      reason:
          'native/core/app_runtime.go 的 nativeDispatch 里缺少这些动作的分支：'
          '${missing.join(', ')}',
    );
  });

  // 这批是最早期就有的接口：任一侧改名或被删都说明契约被动过。
  test('长期存在的动作两侧都还在', () {
    const stable = {
      'initialize',
      'detail',
      'resolve',
      'preload',
      'danmaku',
      'catalog',
      'downloads',
      'storage',
    };
    expect(_dartActions(), containsAll(stable));
    expect(_nativeActions(), containsAll(stable));
  });
}

/// 读 `lib/` 下全部 dart 源文件里的动作字面量。
Set<String> _dartActions() {
  final actions = <String>{};
  for (final file in _sources('lib')) {
    final source = file.readAsStringSync();
    for (final match in _dartAction.allMatches(source)) {
      actions.add(match.group(1)!);
    }
  }
  return actions;
}

/// 只取原生分发器里的分支标签。
///
/// 同文件里还有编解码、状态字符串等别的 switch，把它们算进契约会得到一堆
/// 噪音，所以先按函数边界裁出 `nativeDispatch` 再解析。
Set<String> _nativeActions() {
  final file = File('native/core/app_runtime.go');
  expect(file.existsSync(), isTrue, reason: '找不到原生分发器源文件');
  final source = file.readAsStringSync();
  final start = source.indexOf('func nativeDispatch(');
  expect(start, greaterThanOrEqualTo(0), reason: 'nativeDispatch 已改名或移动');
  final end = source.indexOf('\nfunc ', start + 1);
  final body = end < 0 ? source.substring(start) : source.substring(start, end);
  final actions = <String>{};
  for (final match in _goCase.allMatches(body)) {
    for (final name in _goLiteral.allMatches(match.group(1)!)) {
      actions.add(name.group(1)!);
    }
  }
  for (final match in _goCompare.allMatches(body)) {
    actions.add(match.group(1)!);
  }
  return actions;
}

Iterable<File> _sources(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'));

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:duanju_app/recovery_export.dart';
import 'package:flutter_test/flutter_test.dart';

/// 保留真实路径检查，只替换枚举和文件句柄，使限额、短读和读盘故障可重复。
class _ListedDirectory implements Directory {
  _ListedDirectory(this.directory, this.entries);
  final Directory directory;
  final List<FileSystemEntity> entries;

  @override
  String get path => directory.path;
  @override
  Directory get absolute => directory.absolute;
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) {
    expect(recursive, isTrue);
    expect(followLinks, isFalse);
    return entries;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _ReadFile implements File {
  _ReadFile(this.file, this.input, {this.openFailure});
  final File file;
  final _ReadInput input;
  final FileSystemException? openFailure;

  @override
  String get path => file.path;
  @override
  Directory get parent => file.parent;
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    expect(mode, FileMode.read);
    if (openFailure case final failure?) throw failure;
    return input;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _ReadInput implements RandomAccessFile {
  _ReadInput(
    this.size, {
    this.afterSize,
    this.chunk,
    this.failure,
    this.eof = false,
  });
  final int size;
  final int? afterSize;
  final int? chunk;
  final FileSystemException? failure;
  final bool eof;
  int lengthCalls = 0;
  int bytesRead = 0;
  int readCalls = 0;
  bool closed = false;

  @override
  int lengthSync() => lengthCalls++ == 0 ? size : afterSize ?? size;
  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) {
    readCalls++;
    if (failure case final error?) throw error;
    if (eof) return 0;
    final available = (end ?? buffer.length) - start;
    final count = chunk != null && chunk! < available ? chunk! : available;
    buffer.fillRange(start, start + count, 0x61);
    bytesRead += count;
    return count;
  }

  @override
  void closeSync() => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('recovery-export-');
    directory = Directory(await temp.resolveSymbolicLinks());
  });
  tearDown(() => directory.delete(recursive: true));

  File file(String name) => File('${directory.path}/$name');
  Map<String, dynamic> decode(Uint8List bytes) =>
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  _ReadFile controlled(String name, _ReadInput input) {
    final target = file(name)..createSync();
    return _ReadFile(target, input);
  }

  test('目录创建和文件读取不在调用者 isolate 执行', () async {
    await file('users.json').writeAsString('raw');
    final path = directory.path;
    // IOOverrides 不跨 isolate；若退回主 isolate 扫描/打开文件，此测试会失败。
    final bytes = await IOOverrides.runZoned(
      () => exportRecoveryBytes(values: {}, directoryPath: path),
      createDirectory: (_) => throw StateError('主 isolate 不能访问目录'),
      createFile: (_) => throw StateError('主 isolate 不能访问文件'),
    );
    expect(decode(bytes)['files'], {'users.json': 'raw'});
  });

  test('worker 输出兼容 JSON；嵌套路径、原始空白及 bak 分别保留且不修复', () async {
    final rawFiles = {
      'users.json': ' \r\n{ "version": 1, "values": {} }\n',
      'users.json.bak': '{损坏的备份\n',
      'profiles/default/history.json': ' [ { "原始": "记录😀" } ]\r\n',
      'settings/themeMode.json.bak': '仅存在备份，不创建主文件',
      'transaction.json': '{unfinished',
      'empty.json': '',
    };
    for (final entry in rawFiles.entries) {
      await file(entry.key).parent.create(recursive: true);
      await file(entry.key).writeAsString(entry.value);
    }
    for (final name in [
      'initialized',
      'ignored.txt',
      'users.json.tmp',
      'plain.bak',
    ]) {
      await file(name).writeAsString('ignored');
    }
    const values = <String, Object?>{'profiles': ' {原始偏好} ', 'hideVip': true};
    final bytes = await exportRecoveryBytes(
      values: values,
      directoryPath: '${directory.path}${Platform.pathSeparator}',
    );
    expect(bytes, isA<Uint8List>());
    expect(decode(bytes), {
      'app': 'zhenguojian',
      'recovery': true,
      'values': values,
      'files': rawFiles,
    });
    for (final entry in rawFiles.entries) {
      expect(await file(entry.key).readAsString(), entry.value);
    }
    expect(await file('settings/themeMode.json').exists(), isFalse);
    expect(directory.listSync(recursive: true).whereType<File>(), hasLength(10));
  });

  test('损坏 UTF-8 容错解码，磁盘字节保持原样', () async {
    final raw = <int>[0x7b, 0xff, 0xc3, 0x28, 0xe4, 0xb8, 0xad, 0x7d];
    await file('users.json').writeAsBytes(raw);
    final result = decode(
      await exportRecoveryBytes(values: {}, directoryPath: directory.path),
    );
    expect(result['files'], {'users.json': '{\uFFFD\uFFFD(中}'});
    expect(await file('users.json').readAsBytes(), raw);
  });

  test('旧 preferences-only 格式不新增 files 字段；空目录则包含空 files', () async {
    const values = <String, Object?>{
      'localSnapshot.v1': ' {broken\r\n',
      'history': <String>['一', '二'],
      'autoExport': false,
      'hideVip': 7,
      'navigationOrder': 1.5,
      'profiles': null,
    };
    final legacy = decode(await exportRecoveryBytes(values: values));
    expect(legacy, {'app': 'zhenguojian', 'recovery': true, 'values': values});
    expect(
      decode(
        await exportRecoveryBytes(
          values: values,
          directoryPath: directory.path,
        ),
      ),
      {...legacy, 'files': <String, String>{}},
    );
  });

  test('真实超大文件跳过，继续导出后续合格文件', () async {
    final oversized = file('large.json').openSync(mode: FileMode.write);
    oversized.truncateSync(recoveryFileByteLimit + 1);
    oversized.closeSync();
    await file('small.json.bak').writeAsString('原文');
    final result = decode(
      await exportRecoveryBytes(values: {}, directoryPath: directory.path),
    );
    expect(result['files'], {'small.json.bak': '原文'});
    expect(await file('large.json').length(), recoveryFileByteLimit + 1);
  });

  test('单文件 16MiB 边界包含，超过边界不读取也不消费总额', () {
    expect(recoveryFileByteLimit, 16 * 1024 * 1024);
    final exact = _ReadInput(recoveryFileByteLimit);
    final over = _ReadInput(recoveryFileByteLimit + 1);
    final small = _ReadInput(1);
    final result = readRecoveryFiles(
      _ListedDirectory(directory, [
        controlled('large.json', over),
        controlled('exact.json.bak', exact),
        controlled('small.json', small),
      ]),
    );
    expect(result.keys, ['exact.json.bak', 'small.json']);
    expect(result['exact.json.bak']!.length, recoveryFileByteLimit);
    expect(exact.bytesRead, recoveryFileByteLimit);
    expect(over.readCalls, 0);
    expect(small.bytesRead, 1);
    expect([exact, over, small].every((input) => input.closed), isTrue);
  });

  test('累计最多读取 64MiB，跳过超剩余额度文件后仍导出能容纳的文件', () {
    expect(recoveryTotalByteLimit, 64 * 1024 * 1024);
    final full = List.generate(3, (_) => _ReadInput(recoveryFileByteLimit));
    final almost = _ReadInput(recoveryFileByteLimit - 1);
    final over = _ReadInput(2);
    final last = _ReadInput(1);
    final empty = _ReadInput(0);
    final inputs = [...full, almost, over, last, empty];
    final result = readRecoveryFiles(
      _ListedDirectory(directory, [
        for (var index = 0; index < inputs.length; index++)
          controlled('$index.json', inputs[index]),
      ]),
    );
    expect(result.keys, [
      '0.json', '1.json', '2.json', '3.json', '5.json', '6.json',
    ]);
    expect(
      inputs.fold<int>(0, (total, input) => total + input.bytesRead),
      recoveryTotalByteLimit,
    );
    expect(over.readCalls, 0);
    expect(last.bytesRead, 1);
    expect(result['6.json'], '');
    expect(inputs.every((input) => input.closed), isTrue);
  });

  test('短读继续补齐，不重复读取或遗漏原文字节', () {
    final input = _ReadInput(11, chunk: 3);
    final result = readRecoveryFiles(
      _ListedDirectory(directory, [controlled('short.json', input)]),
    );
    expect(result, {'short.json': 'a' * 11});
    expect(input.readCalls, 4);
    expect(input.bytesRead, 11);
    expect(input.closed, isTrue);
  });

  test('打开失败及读取失败如实上抛，已打开的句柄关闭', () {
    final failure = FileSystemException('注入读盘失败', file('bad.json').path);
    final input = _ReadInput(8, failure: failure);
    final entry = controlled('bad.json', input);
    expect(
      () => readRecoveryFiles(_ListedDirectory(directory, [entry])),
      throwsA(same(failure)),
    );
    expect(input.closed, isTrue);
    expect(
      () => readRecoveryFiles(
        _ListedDirectory(directory, [
          _ReadFile(entry.file, _ReadInput(8), openFailure: failure),
        ]),
      ),
      throwsA(same(failure)),
    );
    expect(entry.file.readAsBytesSync(), isEmpty);
  });

  for (final (name, input) in [
    ('截断', _ReadInput(8, eof: true)),
    ('增长', _ReadInput(8, afterSize: recoveryFileByteLimit + 1)),
  ]) {
    test('文件并发$name 报错而非导出部分原文，实际读取不突破核准大小', () {
      expect(
        () => readRecoveryFiles(
          _ListedDirectory(directory, [controlled('changed.json', input)]),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(input.bytesRead, lessThanOrEqualTo(8));
      expect(input.closed, isTrue);
    });
  }

  test('worker 的目录扫描错误通过 Future 上抛', () async {
    final missing = '${directory.path}/missing';
    await expectLater(
      exportRecoveryBytes(values: {}, directoryPath: missing),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.path,
          'path',
          contains('missing'),
        ),
      ),
    );
  });

  test(
    '不跟随文件、目录、悬空链接或作为导出根目录的链接',
    () async {
      await file('real.json').writeAsString('safe');
      await Directory('${directory.path}/real').create();
      await file('real/nested.json').writeAsString('nested');
      await Link('${directory.path}/linked.json').create(file('real.json').path);
      await Link(
        '${directory.path}/linked-directory',
      ).create('${directory.path}/real');
      await Link('${directory.path}/missing.json').create(file('gone.json').path);
      final result = decode(
        await exportRecoveryBytes(values: {}, directoryPath: directory.path),
      );
      expect(result['files'], {'real.json': 'safe', 'real/nested.json': 'nested'});
      await expectLater(
        exportRecoveryBytes(
          values: {},
          directoryPath: '${directory.path}/linked-directory',
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
    skip: Platform.isWindows
        ? 'Windows 创建 symlink 需要开发者模式或额外权限'
        : false,
  );
}

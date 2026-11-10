import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

const recoveryFileByteLimit = 16 * 1024 * 1024;
const recoveryTotalByteLimit = 64 * 1024 * 1024;

/// 调用者只提供偏好快照和路径；此处的闭包不捕获 store、插件或界面对象。
/// Isolate.run 退出时转移最终字节，主 isolate 不再编码或复制整份恢复数据。
Future<Uint8List> exportRecoveryBytes({
  required Map<String, Object?> values,
  String? directoryPath,
}) => Isolate.run(
  () => _encodeRecovery(values, directoryPath),
  debugName: 'recovery-export',
);

Uint8List _encodeRecovery(Map<String, Object?> values, String? directoryPath) {
  return utf8.encode(
    jsonEncode({
      'app': 'zhenguojian',
      'recovery': true,
      'values': values,
      if (directoryPath != null)
        'files': readRecoveryFiles(Directory(directoryPath)),
    }),
  );
}

/// 仅在导出 worker 内使用；独立的纯 Dart 入口也便于注入读盘故障测试。
/// 不解析或修复类别 JSON，主文件和 .json.bak 分别保留原文，不覆盖磁盘。
Map<String, String> readRecoveryFiles(Directory directory) {
  _rejectLinkedDirectory(directory);
  final result = <String, String>{};
  final prefix = directory.path.endsWith('/') || directory.path.endsWith('\\')
      ? directory.path
      : '${directory.path}${Platform.pathSeparator}';
  var total = 0;
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File ||
        !(entity.path.endsWith('.json') || entity.path.endsWith('.json.bak'))) {
      continue;
    }
    // 除了禁止遍历链接，还在打开前复查，避免读到扫描后被换成链接的文件。
    if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
        FileSystemEntityType.link) {
      continue;
    }
    _rejectLinkedDirectory(entity.parent);
    final input = entity.openSync(mode: FileMode.read);
    try {
      final size = input.lengthSync();
      if (size > recoveryFileByteLimit || total + size > recoveryTotalByteLimit) {
        continue;
      }
      // 只分配、读取已核准的字节数；文件并发增长也不能突破读取上限。
      // 允许短读，但截断或长度变化必须报错，不能伪装成完整的原始记录。
      final bytes = Uint8List(size);
      var offset = 0;
      while (offset < size) {
        final count = input.readIntoSync(bytes, offset, size);
        if (count == 0) {
          throw FileSystemException('恢复文件在读取时被截断', entity.path);
        }
        offset += count;
      }
      if (input.lengthSync() != size) {
        throw FileSystemException('恢复文件在读取时发生变化，请重试', entity.path);
      }
      final name = entity.path.substring(prefix.length).replaceAll('\\', '/');
      result[name] = utf8.decode(bytes, allowMalformed: true);
      total += size;
    } finally {
      input.closeSync();
    }
  }
  return result;
}

/// listSync 的 followLinks 不检查根目录自身；也复查打开文件的直接父目录。
/// 不向存储根之外追溯，避免拒绝系统提供的合法应用目录别名。
void _rejectLinkedDirectory(Directory directory) {
  if (FileSystemEntity.typeSync(directory.path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw FileSystemException('恢复导出不能读取符号链接目录', directory.path);
  }
}

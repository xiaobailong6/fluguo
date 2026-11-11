import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_device.dart';
import 'core_bridge.dart';
import 'download_merge.dart' show safeFileName;
import 'merged_library.dart';

/// 成品导出与合并互不影响：只把 App 内副本复制到 Movies，内部成品始终保留。
///
/// 播放本身读的是私有副本，与这里的外部导出无关，所以导出失败不会让成品失效。
/// 测试主机不是 Android，可在用例里临时打开，覆盖菜单与点击链路。
@visibleForTesting
bool debugMergedExportSupported = false;

/// 成品导出走 Android 的 MediaStore 通道，其它平台暂不提供。
bool get mergedExportSupported =>
    Platform.isAndroid || debugMergedExportSupported;

/// 把合并成品导出到 `Movies/<剧名>/`，返回给用户看的结果文案。
Future<String> exportMergedVideo(MergedLibrary library, MergedVideo video) async {
  if (!mergedExportSupported) throw AppFailure('当前平台暂不支持导出到 Movies');
  if (!await AppDevice.requestVideoExport()) {
    throw AppFailure('未获得存储权限，无法导出');
  }
  // 文件可能在授权弹窗期间被删除，取路径放在授权之后。
  final managed = await library.fileFor(video);
  final folder = safeFileName(video.drama.title);
  await AppDevice.exportVideo(managed, folder, video.fileName);
  return '已导出到 Movies/$folder';
}

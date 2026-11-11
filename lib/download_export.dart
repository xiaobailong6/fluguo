import 'dart:math';

import 'package:path/path.dart' as path;

import 'app_device.dart';
import 'core_bridge.dart';
import 'download_merge.dart';
import 'models.dart';

String exportFileName(int number, int episodes) {
  final width = max(2, '${max(number, episodes)}'.length);
  return '第${'$number'.padLeft(width, '0')}集.mp4';
}

/// 外部副本已成功，失败的只是内部清理，调用方必须分别计数。
class DownloadCleanupFailure extends AppFailure {
  DownloadCleanupFailure(super.message);
}

Future<void> exportDownload(
  AppRepository repository,
  DownloadJob job, {
  required bool delete,
  void Function()? checkAccess,
  void Function()? beforeDelete,
}) async {
  checkAccess?.call();
  final plan = await repository.localPlayback(job.drama, job.episode);
  if (plan == null ||
      !plan.local ||
      plan.decryptionKey.isNotEmpty ||
      path.extension(plan.url).toLowerCase() != '.mp4') {
    throw AppFailure('第 ${job.episode.number} 集还没有处理成 mp4，暂时不能导出');
  }
  checkAccess?.call();
  await AppDevice.exportVideo(
    plan.url,
    safeFileName(job.drama.title),
    exportFileName(job.episode.number, job.drama.episodes),
  );
  if (!delete) return;
  // 系统导出可能耗时，删除前由调用方重新核对用户权限与合并占用，
  // 不能仅凭导出开始时的快照删除随后被合并任务打开的原分集。
  try {
    beforeDelete?.call();
  } catch (error) {
    throw DownloadCleanupFailure('已导出，但 App 内副本未删除：$error');
  }
  try {
    await repository.removeExportedDownload(job);
  } catch (error) {
    throw DownloadCleanupFailure('已导出，但 App 内副本未能删除：$error');
  }
}

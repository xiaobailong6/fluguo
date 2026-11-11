import 'package:flutter/material.dart';

import '../../merge_queue.dart';
import '../../models.dart';
import '../widgets/app_notice.dart';

/// 成品先进入 App 管理库；合并与导出已拆开，只有显式给位置时才顺带复制。
Future<bool> enqueueMerges(
  BuildContext context,
  MergeQueue merges,
  List<List<DownloadJob>> groups,
) async {
  final notice = AppNotice.of(context);
  var added = 0;
  final errors = <String>[];
  for (final jobs in groups) {
    final completed = jobs.where((job) => job.completed).toList();
    if (completed.length < 2) {
      errors.add('至少要有 2 集已下载分集才能合并');
      continue;
    }
    try {
      merges.add(completed);
      added++;
    } catch (error) {
      errors.add('$error');
    }
  }
  if (added == 0) {
    notice.show(errors.firstOrNull ?? '没有可合并的分集');
    return false;
  }
  notice.show('已加入 $added 个合并任务，可在下载 › 已合并查看进度，导出请用成品海报菜单'
      '${errors.isEmpty ? '' : '；${errors.first}'}');
  return true;
}

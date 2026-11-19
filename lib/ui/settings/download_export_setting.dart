import 'package:flutter/material.dart';

import '../../app_device.dart';
import '../../core_bridge.dart';
import '../../local_store.dart';
import 'settings_rows.dart';

/// 下载设置的一级开关；与导出队列共用现有偏好，不追溯历史下载。
class DownloadExportSetting extends StatefulWidget {
  const DownloadExportSetting({super.key, required this.store});

  final LocalStore store;

  @override
  State<DownloadExportSetting> createState() => _DownloadExportSettingState();
}

class _DownloadExportSettingState extends State<DownloadExportSetting> {
  bool _saving = false;

  Future<void> _change(bool enabled) async {
    final store = widget.store;
    if (_saving || !store.canDownload || !AppDevice.supportsVideoExport()) {
      return;
    }
    final epoch = store.profileEpoch;
    setState(() => _saving = true);
    try {
      await saveSetting(context, () async {
        final allowed = !enabled || await AppDevice.requestVideoExport();
        // 权限弹窗可能跨越退出设置或用户切换，迟到的结果不写给新用户。
        if (!mounted ||
            !identical(store, widget.store) ||
            epoch != store.profileEpoch ||
            !store.canDownload) {
          return;
        }
        if (!allowed) throw AppFailure('未获得存储权限，自动导出未开启');
        await store.setAutoExport(enabled);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = AppDevice.supportsVideoExport();
    final allowed = widget.store.canDownload;
    return SwitchTile(
      title: '下载完成后自动导出',
      subtitle: !supported
          ? '仅 Android 支持导出到系统视频目录'
          : !allowed
          ? '当前用户没有下载权限'
          : '将新下载的分集保存到 Movies/剧名/，不导出已有剧集',
      value: supported && allowed && widget.store.autoExport,
      onChanged: supported && allowed && !_saving ? _change : null,
    );
  }
}

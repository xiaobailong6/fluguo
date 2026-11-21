import 'package:flutter/material.dart';

import '../../mini_edge_snap.dart';
import 'settings_rows.dart';

/// 可直接放入播放设置页；非 Windows 不占布局空间。
class MiniEdgeSettings extends StatefulWidget {
  const MiniEdgeSettings({super.key});

  @override
  State<MiniEdgeSettings> createState() => _MiniEdgeSettingsState();
}

class _MiniEdgeSettingsState extends State<MiniEdgeSettings> {
  bool _saving = false;

  Future<void> _change(Future<void> Function() change) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await saveSetting(context, change);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!MiniEdgeSnap.supported()) return const SizedBox.shrink();
    final edge = MiniEdgeSnap.instance;
    return ListenableBuilder(
      listenable: edge,
      builder: (context, _) => SettingsCard(
        children: [
          SwitchTile(
            title: '小窗贴边隐藏',
            subtitle: edge.error ?? '小窗拖到屏幕外沿自动收起，鼠标移到边缘展开',
            value: edge.enabled,
            onChanged: _saving
                ? null
                : (value) => _change(() => edge.setEnabled(value)),
          ),
          SwitchTile(
            title: '贴边自动暂停',
            subtitle: '收起时暂停，展开只恢复本次暂停；不覆盖手动暂停或换集',
            value: edge.autoPause,
            onChanged: _saving || !edge.enabled
                ? null
                : (value) => _change(() => edge.setAutoPause(value)),
          ),
        ],
      ),
    );
  }
}

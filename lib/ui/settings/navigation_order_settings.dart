import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../navigation_order.dart';
import '../shell/app_shell.dart';
import '../widgets/group_card.dart';
import 'settings_rows.dart';

/// 上下移动按钮兼容触屏、鼠标及遥控器，不依赖拖动手势。
class NavigationOrderSettings extends StatefulWidget {
  const NavigationOrderSettings({super.key, required this.store});
  final LocalStore store;

  @override
  State<NavigationOrderSettings> createState() =>
      _NavigationOrderSettingsState();
}

class _NavigationOrderSettingsState extends State<NavigationOrderSettings> {
  bool _saving = false;

  Future<void> _save(List<String> order) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await saveSetting(context, () => widget.store.setNavigationOrder(order));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _move(int index, int delta) {
    final order = widget.store.navigationOrder.toList();
    final value = order.removeAt(index);
    order.insert(index + delta, value);
    _save(order);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final order = widget.store.navigationOrder;
      return GroupCard(
        children: [
          const ListTile(
            title: Text('底栏顺序'),
            subtitle: Text('同时应用于手机底栏、桌面侧栏和电视菜单，不改变当前页面'),
          ),
          for (var index = 0; index < order.length; index++)
            ListTile(
              key: ValueKey('order-${order[index]}'),
              leading: Icon(AppTab.values.byName(order[index]).icon),
              title: Text(AppTab.values.byName(order[index]).label),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '上移${AppTab.values.byName(order[index]).label}',
                    onPressed: _saving || index == 0
                        ? null
                        : () => _move(index, -1),
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                  IconButton(
                    tooltip: '下移${AppTab.values.byName(order[index]).label}',
                    onPressed: _saving || index == order.length - 1
                        ? null
                        : () => _move(index, 1),
                    icon: const Icon(Icons.arrow_downward_rounded),
                  ),
                ],
              ),
            ),
          ListTile(
            title: const Text('恢复默认顺序'),
            subtitle: const Text('剧场、短剧、直播、追剧、我的'),
            trailing: TextButton(
              onPressed: _saving ? null : () => _save(defaultNavigationOrder),
              child: const Text('恢复默认'),
            ),
          ),
        ],
      );
    },
  );
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../../resource_settings.dart';
import '../../resource_settings_editor.dart';
import '../widgets/focus_ring.dart';
import '../widgets/group_card.dart';
import 'settings_rows.dart';

/// 嵌入代理设置页的站源组设置；复用页面已有 editor，不拥有或销毁它。
class SourceProxySettings extends StatefulWidget {
  const SourceProxySettings({
    super.key,
    required this.store,
    required this.editor,
  });
  final LocalStore store;
  final ResourceSettingsEditor editor;

  @override
  State<SourceProxySettings> createState() => _SourceProxySettingsState();
}

class _SourceProxySettingsState extends State<SourceProxySettings> {
  static const _modes = {
    'follow': '跟随全局',
    'auto': '自动',
    'direct': '直连',
    'manual': '手动代理',
  };

  @override
  void initState() {
    super.initState();
    _loadAfterBuild();
  }

  @override
  void didUpdateWidget(covariant SourceProxySettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editor != widget.editor) _loadAfterBuild();
  }

  void _loadAfterBuild() {
    // 共享 editor 可能已由父页面加载；避免构建中通知监听器或覆盖已编辑配置。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          widget.editor.settings == null &&
          widget.editor.error == null) {
        unawaited(widget.editor.load());
      }
    });
  }

  Future<void> _save(String group, SourceProxy? proxy) =>
      saveSetting(context, () async {
        final editor = widget.editor;
        final current = editor.settings;
        if (!editor.allowed ||
            editor.saving ||
            editor.loading ||
            current == null) {
          return;
        }
        await editor.save(current.withSourceProxy(group, proxy));
      });

  Future<void> _edit(String group) async {
    final editor = widget.editor;
    final epoch = widget.store.profileEpoch;
    if (!editor.allowed || editor.saving) return;
    final address = await showDialog<String>(
      context: context,
      builder: (_) => _SourceProxyDialog(
        initial: editor.settings?.sourceProxies[group]?.url ?? '',
      ),
    );
    // 弹窗期间切换用户、锁定或更换 editor 时，不能把旧管理员的输入保存到新会话。
    if (address == null ||
        !mounted ||
        editor != widget.editor ||
        epoch != widget.store.profileEpoch ||
        !editor.allowed) {
      return;
    }
    await _save(group, SourceProxy('manual', address));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.store, widget.editor]),
    builder: (context, _) {
      final editor = widget.editor;
      if (!editor.allowed ||
          widget.store.locked ||
          !widget.store.profile.admin) {
        return const SettingsCard(
          children: [
            SettingsTile(title: '站源组代理', subtitle: '需要管理员', enabled: false),
          ],
        );
      }
      final settings = editor.settings;
      if (settings == null && editor.error == null && !editor.loading) {
        _loadAfterBuild();
      }
      final editable = settings != null && !editor.saving && !editor.loading;
      final epoch = widget.store.profileEpoch;
      final groups = SourceGroup.fromSources(SourceSite.values);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('未单独设置的站源跟随全局；自动使用系统代理。覆盖设置用于目录、播放、海报及下载，仅保存在本机。'),
          ),
          SettingsCard(
            children: [
              if (editor.loading || settings == null && editor.error == null)
                const SettingsTile(title: '正在读取站源代理设置', enabled: false),
              if (editor.error != null)
                SettingsTile(
                  title: settings == null ? '读取设置失败' : '保存设置失败，原设置保持不变',
                  subtitle: editor.error,
                  value: '重新读取',
                  enabled: !editor.loading && !editor.saving,
                  onTap: () => unawaited(editor.load()),
                ),
              if (settings != null && settings.warning.isNotEmpty)
                SettingsTile(
                  title: '设置提示',
                  subtitle: settings.warning,
                  enabled: false,
                ),
              if (settings != null)
                for (final group in groups) ...[
                  ValueTile<String>(
                    title: group.name,
                    options: _modes,
                    value: settings.sourceProxies[group.id]?.mode ?? 'follow',
                    subtitle: settings.sourceProxies[group.id]?.mode == 'auto'
                        ? settings.systemProxyStatus
                        : null,
                    onChanged: editable
                        ? (mode) {
                            if (!mounted ||
                                editor != widget.editor ||
                                epoch != widget.store.profileEpoch ||
                                !editor.allowed) {
                              return;
                            }
                            if (mode == 'manual') {
                              unawaited(_edit(group.id));
                            } else {
                              unawaited(
                                _save(
                                  group.id,
                                  mode == 'follow' ? null : SourceProxy(mode),
                                ),
                              );
                            }
                          }
                        : null,
                  ),
                  if (settings.sourceProxies[group.id]?.mode == 'manual')
                    SettingsTile(
                      title: '${group.name} · 代理地址',
                      value: '已设置',
                      enabled: editable,
                      onTap: () => unawaited(_edit(group.id)),
                    ),
                ],
            ],
          ),
          if (editor.saving) const LinearProgressIndicator(),
        ],
      );
    },
  );
}

class _SourceProxyDialog extends StatefulWidget {
  const _SourceProxyDialog({required this.initial});
  final String initial;

  @override
  State<_SourceProxyDialog> createState() => _SourceProxyDialogState();
}

class _SourceProxyDialogState extends State<_SourceProxyDialog> {
  late final _address = TextEditingController(text: widget.initial);
  bool _visible = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _submit() {
    final address = _address.text.trim();
    final uri = Uri.tryParse(address);
    if (address.length > 2048 ||
        uri == null ||
        !const ['http', 'https', 'socks5', 'socks5h'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      setState(() => _error = '请输入有效的 HTTP、HTTPS 或 SOCKS5 代理地址');
      return;
    }
    Navigator.pop(context, address);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('站源代理地址'),
    content: SizedBox(
      width: 420,
      child: TextField(
        controller: _address,
        autofocus: true,
        obscureText: !_visible,
        enableSuggestions: false,
        autocorrect: false,
        keyboardType: TextInputType.url,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          hintText: 'http://127.0.0.1:7890',
          errorText: _error,
          helperText: '支持 HTTP、HTTPS、SOCKS5',
          suffixIcon: IconButton(
            tooltip: _visible ? '隐藏代理地址' : '显示代理地址',
            onPressed: () => setState(() => _visible = !_visible),
            icon: Icon(
              _visible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
          ),
        ),
      ),
    ),
    actions: [
      FocusRing(
        radius: 20,
        child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
      FocusRing(
        radius: 20,
        child: FilledButton(onPressed: _submit, child: const Text('保存')),
      ),
    ],
  );
}

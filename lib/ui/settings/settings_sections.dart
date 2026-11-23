import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/app_notice.dart';

import '../../app_build.dart';
import '../../app_device.dart';
import '../../download_preferences.dart';
import '../../local_store.dart';
import '../../media_controls.dart';
import '../../playback_decoder.dart';
import '../../playback_preferences.dart';
import '../../resource_settings.dart';
import '../../resource_settings_editor.dart';
import '../../window_on_top.dart';
import '../app_scope.dart';
import '../users/users_view.dart';
import '../widgets/focus_ring.dart';
import '../widgets/group_card.dart';
import '../widgets/glass/glass_dialog.dart';
import 'appearance_settings.dart';
import 'backup_actions.dart';
import 'danmaku_settings.dart';
import 'diary_view.dart';
import 'download_export_setting.dart';
import 'settings_rows.dart';
import 'sources_view.dart';
import 'storage_view.dart';
import 'about_view.dart';
import 'navigation_order_settings.dart';
import 'mini_edge_settings.dart';
import 'source_proxy_settings.dart';

enum SettingsGroup {
  appearance('外观', Icons.palette_outlined),
  playback('播放', Icons.play_arrow_rounded),
  danmaku('弹幕', Icons.subtitles_rounded),
  download('下载', Icons.download_rounded),
  sources('站源', Icons.dns_outlined),
  proxy('代理', Icons.language_rounded),
  users('用户', Icons.manage_accounts_outlined),
  about('关于', Icons.info_outline_rounded),
  diagnostics('诊断', Icons.receipt_long_outlined);

  const SettingsGroup(this.label, this.icon);
  final String label;
  final IconData icon;
}

typedef OpenSubpage = void Function(String title, WidgetBuilder body);

const adminOnly = '需要管理员';
const _noDownload = '当前用户没有下载权限';
const _proxyModes = {'auto': '自动', 'direct': '直连', 'manual': '手动代理'};
const _counts = {1: '1', 2: '2', 3: '3', 4: '4', 5: '5', 6: '6'};
const _intervals = [0, 100, 250, 500, 1000, 2000, 3000, 5000];
const _decoders = {
  TelevisionDecoder.optimized: '默认',
  TelevisionDecoder.hardware: '硬解（兼容）',
  TelevisionDecoder.software: '软解（兼容）',
};

/// 短剧片头片尾都很短，档位只做到 10 秒。
const _skipOptions = {
  0: '不跳过',
  1: '1 秒',
  2: '2 秒',
  3: '3 秒',
  5: '5 秒',
  8: '8 秒',
  10: '10 秒',
};

/// 旧版本可能存过更大的档位（如 30 秒）：补一条同名选项，
/// 免得选中态在上面的档位表里找不到、显示成空。
Map<int, String> _skipOptionsIncluding(int value) {
  if (_skipOptions.containsKey(value)) return _skipOptions;
  return {..._skipOptions, value: '$value 秒'};
}

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.group,
    required this.store,
    required this.editor,
    required this.open,
  });
  final SettingsGroup group;
  final LocalStore store;
  final ResourceSettingsEditor editor;
  final OpenSubpage open;

  Future<void> _saveResource(BuildContext context, ResourceSettings settings) =>
      saveSetting(context, () => editor.save(settings));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, editor]),
    builder: (context, _) => group == SettingsGroup.appearance
        ? Column(
            spacing: 12,
            children: [
              AppearanceSettings(store: store),
              SettingsCard(
                children: [
                  SettingsTile(
                    title: '底栏顺序',
                    subtitle: '调整手机底栏、桌面侧栏和电视菜单的显示顺序',
                    onTap: () => open(
                      '底栏顺序',
                      (_) => ListView(
                        padding: const EdgeInsets.all(16),
                        children: [NavigationOrderSettings(store: store)],
                      ),
                    ),
                  ),
                  if (WindowOnTop.supported())
                    ListenableBuilder(
                      listenable: WindowOnTop.instance,
                      builder: (context, _) => SwitchTile(
                        title: '窗口置顶',
                        subtitle: '让应用保持在其他窗口上方；小窗播放始终置顶',
                        value: WindowOnTop.instance.value,
                        onChanged: (value) => saveSetting(
                          context,
                          () => WindowOnTop.instance.setPreferred(value),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: switch (group) {
              SettingsGroup.playback => _playback(context),
              SettingsGroup.danmaku => _danmaku(context),
              SettingsGroup.download => _download(context),
              SettingsGroup.sources => _sources(context),
              SettingsGroup.proxy => _proxy(context),
              SettingsGroup.users => [UsersView(store: store, open: open)],
              SettingsGroup.about => [const AboutView()],
              SettingsGroup.diagnostics => _diagnostics(context),
              _ => const [],
            },
          ),
  );

  Widget? _editorError() => switch (editor.error) {
    final error? => SettingsTile(
      title: '无法读取网络与下载设置',
      subtitle: error,
      trailing: const Icon(Icons.refresh_rounded),
      onTap: editor.load,
    ),
    null => null,
  };

  List<Widget> _playback(BuildContext context) {
    final preferences = store.playbackPreferences;
    final television = AppScope.of(context).television;
    void savePreferences(PlaybackPreferences next) =>
        saveSetting(context, () => store.setPlaybackPreferences(next));
    return [
      SettingsCard(
        children: [
          SwitchListTile(
            title: const Text('点击剧集先看详情'),
            subtitle: const Text('关闭后直接播放'),
            value: store.showDramaDetails,
            onChanged: (value) =>
                saveSetting(context, () => store.setShowDramaDetails(value)),
          ),
          ValueTile<double>(
            title: '默认倍速',
            subtitle: '与播放器内设置同步',
            options: {for (final speed in playbackSpeeds) speed: '${speed}x'},
            value: preferences.speed,
            onChanged: (speed) =>
                savePreferences(preferences.copyWith(speed: speed)),
          ),
          ValueTile<int>(
            title: '默认清晰度',
            subtitle: '指定清晰度不可用时，使用源站可用画质',
            options: {
              for (final quality in {
                ...DownloadPreferences.qualities,
                preferences.quality,
              }.toList()..sort((a, b) => b - a))
                quality: quality == 0 ? '自动（优先高清）' : '${quality}P',
            },
            value: preferences.quality,
            onChanged: (quality) =>
                savePreferences(preferences.copyWith(quality: quality)),
          ),
          ValueTile<int>(
            title: '直播默认清晰度',
            subtitle: '打开直播时生效，实际画质受平台和当前线路限制',
            options: liveQualityOptions,
            value: preferences.liveQuality,
            onChanged: (quality) =>
                savePreferences(preferences.copyWith(liveQuality: quality)),
          ),
        ],
      ),
      SettingsCard(
        children: [
          ValueTile<TelevisionDecoder>(
            title: '解码方式',
            subtitle: defaultTargetPlatform == TargetPlatform.android
                ? '直通可减少视频拷贝，黑屏时请换兼容硬解；偏蓝修正用于色彩异常。重新打开播放页后生效，剧场下次加载时生效'
                : '有声音没画面或卡顿时可换兼容方式，重新打开播放页后生效',
            options: {
              ..._decoders,
              if (defaultTargetPlatform == TargetPlatform.android) ...{
                TelevisionDecoder.hardwareSwapUv: '硬解（修正偏蓝）',
                TelevisionDecoder.hardwareDirect: '硬解（直通）',
              },
            },
            value: effectivePlaybackDecoder(
              preferences.televisionDecoder,
              defaultTargetPlatform,
            ),
            onChanged: (decoder) => savePreferences(
              preferences.copyWith(televisionDecoder: decoder),
            ),
          ),
          ValueTile<VideoFitMode>(
            title: '画面比例',
            subtitle: '适应保留完整画面；裁切会切掉边缘；拉伸会改变长宽比',
            options: const {
              VideoFitMode.contain: '适应（默认）',
              VideoFitMode.cover: '裁切铺满',
              VideoFitMode.stretch: '拉伸铺满',
            },
            value: preferences.videoFit,
            onChanged: (value) =>
                savePreferences(preferences.copyWith(videoFit: value)),
          ),
          if (Platform.isAndroid) const _RenderingTile(),
          SwitchTile(
            title: '显示当前时间',
            subtitle: '在播放控件中显示，默认关闭',
            value: preferences.showClock,
            onChanged: (value) =>
                savePreferences(preferences.copyWith(showClock: value)),
          ),
          SwitchTile(
            title: '显示缓存速度',
            subtitle: '无缓存或无法读取时显示 0 KB/S',
            value: preferences.showCacheSpeed,
            onChanged: (value) =>
                savePreferences(preferences.copyWith(showCacheSpeed: value)),
          ),
          SwitchTile(
            title: '提前加载下一集',
            subtitle: '减少切集等待',
            value: preferences.preopens(television: television),
            onChanged: (value) =>
                savePreferences(preferences.copyWith(preopen: value)),
          ),
        ],
      ),
      if ((Platform.isAndroid || Platform.isIOS) && !television)
        SettingsCard(
          children: [
            SwitchTile(
              title: '双击快退/快进',
              subtitle: '左侧双击快退，右侧双击快进，关闭时均为暂停',
              value: preferences.doubleTapSeek,
              onChanged: (value) =>
                  savePreferences(preferences.copyWith(doubleTapSeek: value)),
            ),
            SwitchTile(
              title: '横屏亮度/音量手势',
              subtitle: '开启时左侧调亮度、右侧调音量；关闭后全画面上下滑动切换剧集',
              value: preferences.swipeLevels,
              onChanged: (value) =>
                  savePreferences(preferences.copyWith(swipeLevels: value)),
            ),
          ],
        ),
      if (MediaControls.supported)
        SettingsCard(
          children: [
            SwitchTile(
              title: '后台播放',
              subtitle: '离开应用、锁屏或最小化时继续播放，可用系统媒体控件控制',
              value: preferences.backgroundPlayback,
              onChanged: (value) => savePreferences(
                preferences.copyWith(backgroundPlayback: value),
              ),
            ),
          ],
        ),
      if (Platform.isAndroid && !television)
        SettingsCard(
          children: [
            SwitchTile(
              title: '离开应用时自动小窗',
              subtitle: '播放中回到桌面时自动进入画中画',
              value: preferences.autoPictureInPicture,
              onChanged: (value) => savePreferences(
                preferences.copyWith(autoPictureInPicture: value),
              ),
            ),
          ],
        ),
      if (Platform.isWindows) const MiniEdgeSettings(),
      SettingsCard(
        children: [
          ValueTile<int>(
            title: '跳过片头',
            subtitle: '从本集开头播放时自动跳到该位置，手动拖回后本集不再跳过',
            options: _skipOptionsIncluding(preferences.skipIntroSeconds),
            value: preferences.skipIntroSeconds,
            onChanged: (value) =>
                savePreferences(preferences.copyWith(skipIntroSeconds: value)),
          ),
          ValueTile<int>(
            title: '跳过片尾',
            subtitle: '播到此位置时直接结束，交给自动连播进入下一集',
            options: _skipOptionsIncluding(preferences.skipOutroSeconds),
            value: preferences.skipOutroSeconds,
            onChanged: (value) =>
                savePreferences(preferences.copyWith(skipOutroSeconds: value)),
          ),
        ],
      ),
    ];
  }

  List<Widget> _danmaku(BuildContext context) =>
      danmakuSettingsRows(context, store, open);

  List<Widget> _download(BuildContext context) {
    final canDownload = store.canDownload;
    final admin = store.profile.admin;
    final preferences = store.downloadPreferences;
    final settings = editor.settings;
    final editable = settings != null && !editor.saving;
    void savePreferences(DownloadPreferences next) =>
        saveSetting(context, () => store.setDownloadPreferences(next));
    return [
      SettingsCard(
        children: [
          ValueTile<int>(
            title: '默认画质',
            subtitle: canDownload ? '指定画质不可用时，使用源站可用画质' : _noDownload,
            options: {
              for (final quality in DownloadPreferences.qualities)
                quality: quality == 0 ? '自动（优先高清）' : '${quality}P',
            },
            value: preferences.quality,
            onChanged: canDownload
                ? (quality) =>
                      savePreferences(preferences.copyWith(quality: quality))
                : null,
          ),
          SwitchTile(
            title: '默认包含 VIP 集',
            subtitle: canDownload ? 'VIP 集可能仅提供试看内容，下载前仍可调整选择' : _noDownload,
            value: preferences.includeVip,
            onChanged: canDownload
                ? (value) =>
                      savePreferences(preferences.copyWith(includeVip: value))
                : null,
          ),
          DownloadExportSetting(store: store),
          if (AppDevice.supportsVideoExport() &&
              canDownload &&
              store.autoExport)
            SwitchTile(
              title: '自动导出后删除 App 内副本',
              subtitle: '删除后不能在 App 内离线观看这一集',
              value: store.deleteAfterAutoExport,
              onChanged: (value) => saveSetting(
                context,
                () => store.setDeleteAfterAutoExport(value),
              ),
            ),
          SettingsTile(
            title: '目录与空间',
            subtitle: canDownload ? '查看存储用量、迁移已下载文件' : _noDownload,
            enabled: canDownload,
            onTap: () => open('目录与空间', (_) => StorageView(store: store)),
          ),
        ],
      ),
      SettingsCard(
        children: [
          ?_editorError(),
          ValueTile<int>(
            title: '同时下载数量',
            subtitle: admin ? null : adminOnly,
            options: _counts,
            value: settings?.downloadConcurrency,
            onChanged: editable
                ? (value) => _saveResource(
                    context,
                    settings.copyWith(downloadConcurrency: value),
                  )
                : null,
          ),
          SwitchTile(
            title: '按站源分类保存',
            subtitle: admin ? '新任务放入各站源的子目录，已有下载继续使用原位置' : adminOnly,
            value: settings?.downloadBySource ?? false,
            onChanged: editable
                ? (value) => _saveResource(
                    context,
                    settings.copyWith(downloadBySource: value),
                  )
                : null,
          ),
        ],
      ),
      if (Platform.isIOS) const _Note('iOS 下载和媒体处理需要保持应用在前台；切到后台会暂停，回到前台后可继续。'),
    ];
  }

  List<Widget> _sources(BuildContext context) {
    final settings = editor.settings;
    final editable = settings != null && !editor.saving;
    return [
      if (allSourcesEnabled)
        SettingsCard(
          children: [
            SettingsTile(
              title: '站源管理',
              subtitle: '开启或关闭站源',
              onTap: () => open('站源管理', (_) => SourcesView(store: store)),
            ),
          ],
        ),
      SettingsCard(
        children: [
          ?_editorError(),
          ValueTile<int>(
            title: '目录请求间隔',
            subtitle: store.profile.admin ? '同一站源两次请求之间的最短间隔' : adminOnly,
            options: {
              for (final interval in {
                ..._intervals,
                ?settings?.catalogIntervalMs,
              }.toList()..sort())
                interval: '$interval 毫秒',
            },
            value: settings?.catalogIntervalMs,
            onChanged: editable
                ? (value) => _saveResource(
                    context,
                    settings.copyWith(catalogIntervalMs: value),
                  )
                : null,
          ),
        ],
      ),
    ];
  }

  List<Widget> _proxy(BuildContext context) {
    final admin = store.profile.admin;
    final settings = editor.settings;
    final editable =
        admin && settings != null && !editor.saving && !editor.loading;
    final mode = settings?.proxyMode;
    return [
      if (settings != null && settings.warning.isNotEmpty)
        _Note(settings.warning),
      SettingsCard(
        children: [
          ?_editorError(),
          ValueTile<String>(
            title: '连接方式',
            subtitle: !admin
                ? adminOnly
                : switch (mode) {
                    'auto' when settings!.systemProxyStatus.isNotEmpty =>
                      settings.systemProxyStatus,
                    'auto' => '使用系统静态代理；未配置时使用环境变量或直连',
                    _ => null,
                  },
            options: _proxyModes,
            value: mode,
            onChanged: editable
                ? (value) => value == 'manual'
                      ? _editProxy(context, settings)
                      : _saveResource(
                          context,
                          settings.copyWith(proxyMode: value),
                        )
                : null,
          ),
          if (mode == 'manual')
            SettingsTile(
              title: '代理地址',
              subtitle: '支持 HTTP、HTTPS、SOCKS5；仅保存在本机，不进入配置备份',
              value: settings!.proxyUrl.isEmpty ? '未设置' : '已设置',
              enabled: editable,
              onTap: () => _editProxy(context, settings),
            ),
        ],
      ),
      SettingsCard(
        children: [
          SettingsTile(
            title: '按站源组设置',
            subtitle: admin ? '单独选择直连或代理，未设置时跟随全局' : adminOnly,
            enabled: admin && !store.locked,
            onTap: () => open(
              '站源组代理',
              (_) => ListView(
                padding: const EdgeInsets.all(16),
                children: [SourceProxySettings(store: store, editor: editor)],
              ),
            ),
          ),
        ],
      ),
    ];
  }

  Future<void> _editProxy(
    BuildContext context,
    ResourceSettings settings,
  ) async {
    final address = await showDialog<String>(
      context: context,
      builder: (_) => _ProxyDialog(initial: settings.proxyUrl),
    );
    if (address == null || !context.mounted) return;
    await _saveResource(
      context,
      settings.copyWith(proxyMode: 'manual', proxyUrl: address),
    );
  }

  List<Widget> _diagnostics(BuildContext context) {
    final settings = editor.settings;
    final editable = settings != null && !editor.saving;
    return [
      SettingsCard(
        children: [
          SettingsTile(
            title: '播放调试日记',
            subtitle: '查看并复制应用运行与播放器的详细事件日志',
            onTap: () => open('播放调试日记', (_) => const DiaryView()),
          ),
          SwitchTile(
            title: '调试日志',
            subtitle: '开启后记录详细取流、分集转换与合并过程，便于排查问题；关闭后停止记录这些过程日志',
            value: settings?.traceEnabled ?? false,
            onChanged: editable
                ? (value) => _saveResource(
                    context,
                    settings.copyWith(traceEnabled: value),
                  )
                : null,
          ),
        ],
      ),
      _BackupCard(store: store),
    ];
  }
}

class _BackupCard extends StatefulWidget {
  const _BackupCard({required this.store});
  final LocalStore store;

  @override
  State<_BackupCard> createState() => _BackupCardState();
}

class _BackupCardState extends State<_BackupCard> {
  var _busy = false;

  Future<void> _run(Future<String?> Function() task) async {
    setState(() => _busy = true);
    String? message;
    try {
      message = await task();
    } catch (failure) {
      message = '$failure';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (message != null && mounted) {
      showAppNotice(context, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final admin = widget.store.profile.admin;
    return SettingsCard(
      children: [
        SettingsTile(
          title: '导出备份',
          subtitle: admin ? '包含本地用户、追剧、历史和设置，不含视频文件' : adminOnly,
          enabled: admin && !_busy,
          onTap: () => _run(() => exportBackupFile(widget.store)),
        ),
        SettingsTile(
          title: '恢复备份',
          subtitle: admin ? '替换本机的用户、追剧、观看记录和偏好设置，已下载视频保留' : adminOnly,
          enabled: admin && !_busy,
          onTap: () => _run(() => restoreBackupFile(context, widget.store)),
        ),
      ],
    );
  }
}

class _RenderingTile extends StatefulWidget {
  const _RenderingTile();

  @override
  State<_RenderingTile> createState() => _RenderingTileState();
}

class _RenderingTileState extends State<_RenderingTile> {
  bool? _compatible;

  @override
  void initState() {
    super.initState();
    AppDevice.compatibleRendering().then((value) {
      if (mounted) setState(() => _compatible = value);
    });
  }

  Future<void> _switch(bool enabled) async {
    final accepted = await showGlassDialog<bool>(
      context,
      builder: (dialogContext) => GlassDialogBody(
        title: enabled ? '开启兼容渲染模式？' : '关闭兼容渲染模式？',
        message: '需要重启应用才能生效，正在进行的下载会中断。',
        actions: [
          FocusRing(
            radius: 20,
            child: TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
          ),
          FocusRing(
            radius: 20,
            child: FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('立即重启'),
            ),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    if (!await AppDevice.setCompatibleRendering(enabled) && mounted) {
      showAppNotice(context, '兼容渲染模式未能保存，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => SwitchTile(
    title: '兼容渲染模式',
    subtitle: '换了解码方式仍没画面时可尝试，需重启应用',
    value: _compatible ?? false,
    onChanged: _compatible == null ? null : _switch,
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _ProxyDialog extends StatefulWidget {
  const _ProxyDialog({required this.initial});
  final String initial;

  @override
  State<_ProxyDialog> createState() => _ProxyDialogState();
}

class _ProxyDialogState extends State<_ProxyDialog> {
  late final _address = TextEditingController(text: widget.initial);
  var _visible = false;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _submit() {
    final address = _address.text.trim();
    if (address.isNotEmpty) Navigator.pop(context, address);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('代理地址'),
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

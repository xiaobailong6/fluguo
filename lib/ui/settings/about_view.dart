import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_build.dart';
import '../app_scope.dart';
import '../widgets/app_notice.dart';
import '../widgets/group_card.dart';
import 'settings_rows.dart';

const _links = [
  ('GitHub · 重建版', 'https://github.com/Xanerix/guoapp'),
  ('GitHub · 原作者', 'https://github.com/fish2018'),
  ('Telegram · 交流群组', 'https://t.me/+c9YKHp7FjSk0MjI1'),
  ('Telegram · 更新频道', 'https://t.me/+F9NnQSsMfOU3OTdl'),
];

/// 隐藏信息仅在当前关于页展示；正常文档流展开，避免覆盖功能介绍。
class AboutView extends StatefulWidget {
  const AboutView({super.key});
  @override
  State<AboutView> createState() => _AboutViewState();
}

class _AboutViewState extends State<AboutView> {
  int _taps = 0;
  bool _revealed = false;
  Timer? _tapReset;

  void _versionTap() {
    if (_revealed) return;
    _tapReset?.cancel();
    if (++_taps >= 5) {
      setState(() => _revealed = true);
    } else {
      _tapReset = Timer(const Duration(seconds: 3), () => _taps = 0);
    }
  }

  @override
  void dispose() {
    _tapReset?.cancel();
    super.dispose();
  }

  Future<void> _openLink(String url) async {
    final notice = AppNotice.of(context);
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    if (opened) return;
    await Clipboard.setData(ClipboardData(text: url));
    notice.show('无法打开浏览器，链接已复制');
  }

  @override
  Widget build(BuildContext context) {
    final version = AppScope.of(context).version;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        SettingsCard(
          children: [
            ListTile(
              key: const ValueKey('about-version'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 8,
              ),
              title: Text(
                appName,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(version.isEmpty ? '版本未知' : '版本 $version'),
                  const SizedBox(height: 4),
                  Text(
                    allSourcesEnabled ? '全站源版' : '标准版',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              onTap: _versionTap,
            ),
          ],
        ),
        SettingsCard(
          children: [
            Padding(
              key: const ValueKey('about-introduction'),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text('轻松找剧，随时开看', style: theme.textTheme.titleSmall),
                  Text(
                    '短剧与直播，一站观看。剧场按最近观看的题材推荐新剧，支持追剧收藏、观看记录和离线下载。',
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                  Text(
                    '适配手机、平板、电脑与电视，支持全屏和画中画。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      height: 1.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_revealed)
          SettingsCard(
            key: const ValueKey('about-hidden-links'),
            children: [
              for (final (title, url) in _links)
                SettingsTile(
                  title: title,
                  subtitle: url.replaceFirst('https://', ''),
                  onTap: () => _openLink(url),
                ),
            ],
          ),
      ],
    );
  }
}

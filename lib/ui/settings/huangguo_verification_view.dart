import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../local_store.dart';
import '../widgets/app_notice.dart';

/// 使用系统提供的应用内浏览器展示站方验证页面，不接管验证流程。
class HuangguoVerificationTile extends StatefulWidget {
  const HuangguoVerificationTile({super.key, required this.store});
  final LocalStore store;

  @override
  State<HuangguoVerificationTile> createState() =>
      _HuangguoVerificationTileState();
}

class _HuangguoVerificationTileState extends State<HuangguoVerificationTile> {
  bool _opening = false;

  bool get _allowed =>
      !widget.store.locked &&
      widget.store.profile.admin &&
      widget.store.sourceEnabled('huangguo-video');

  Future<void> _open() async {
    if (_opening || !_allowed) return;
    final notice = AppNotice.of(context);
    final epoch = widget.store.profileEpoch;
    setState(() => _opening = true);
    try {
      // 先检查能力，防止插件将不支持的内开模式静默降级为外部浏览器。
      final supported = await supportsLaunchMode(LaunchMode.inAppBrowserView);
      if (!mounted || !_allowed || widget.store.profileEpoch != epoch) return;
      if (!supported) {
        notice.show('当前平台不支持应用内浏览器，请使用浏览器访问 huangguo.video/videos');
        return;
      }
      final opened = await launchUrl(
        Uri.parse('https://huangguo.video/videos'),
        mode: LaunchMode.inAppBrowserView,
      );
      if (!mounted || !_allowed || widget.store.profileEpoch != epoch) return;
      if (!opened) notice.show('无法打开校验页面，请稍后重试');
    } catch (_) {
      if (mounted && _allowed && widget.store.profileEpoch == epoch) {
        notice.show('无法打开校验页面，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    minTileHeight: 68,
    contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
    title: const Text('黄果视频'),
    subtitle: const Text('手动完成 Cloudflare 校验；浏览器会话与应用请求独立'),
    trailing: TextButton(
      onPressed: _opening || !_allowed ? null : _open,
      child: Text(_opening ? '打开中' : '校验'),
    ),
  );
}

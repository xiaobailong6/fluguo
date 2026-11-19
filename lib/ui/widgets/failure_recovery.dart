import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_failure.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../settings/settings_page.dart';
import '../settings/settings_sections.dart';
import '../settings/sorani_account_view.dart';
import '../shell/app_shell.dart';
import 'app_notice.dart';
import 'focus_ring.dart';

/// 首屏与分页共用恢复动作；操作前重新核对权限，迟到登录不能刷新另一个用户。
class FailureRecovery extends StatefulWidget {
  const FailureRecovery({
    super.key,
    required this.failure,
    required this.onRetry,
    this.onRecovered,
    this.store,
    this.source,
    this.title,
    this.clock,
  });

  final AppFailure failure;
  final Future<void> Function() onRetry;
  final LocalStore? store;
  final Future<void> Function()? onRecovered;
  final SourceSite? source;
  final String? title;
  final DateTime Function()? clock;

  @override
  State<FailureRecovery> createState() => _FailureRecoveryState();
}

class _FailureRecoveryState extends State<FailureRecovery> {
  Timer? _retryTimer;
  bool _busy = false;

  DateTime _now() => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(FailureRecovery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.failure != widget.failure) _schedule();
  }

  void _schedule() {
    _retryTimer?.cancel();
    final until = widget.failure.retryAt;
    final now = _now();
    if (until == null || !until.isAfter(now)) return;
    _retryTimer = Timer(until.difference(now), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  bool _allowed() {
    final store = widget.store;
    return store == null ||
        !store.locked &&
            (widget.source == null || store.allowsSource(widget.source!.id));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_allowed()) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) showAppNotice(context, '操作未完成，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login() async {
    final store = widget.store!;
    if (!store.profile.admin) return;
    final epoch = store.profileEpoch;
    final account = await showSoraniLogin(context);
    if (!mounted || store.profileEpoch != epoch || !_allowed()) return;
    if (account?.loggedIn == true) {
      await (widget.onRecovered ?? widget.onRetry)();
    }
  }

  Widget _button(String label, Future<void> Function() action) => FocusRing(
    radius: 999,
    child: TextButton(
      onPressed: _busy ? null : () => _run(action),
      child: Text(label),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final failure = widget.failure;
    final store = widget.store;
    final admin = store != null && !store.locked && store.profile.admin;
    final waiting = failure.retryable && !failure.canRetryAt(_now());
    final message = switch (failure.code) {
      'source_login' when !admin => '此站源需要登录，请联系管理员',
      'permission' => '当前用户没有权限，请联系管理员',
      'source_unavailable' => '当前版本不支持此站源，请选择其他站源',
      _ => failure.message,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.title case final title?) ...[
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
          ],
          Text(message, textAlign: TextAlign.center),
          if (waiting) ...[
            const SizedBox(height: 6),
            const Text('请稍后重试，按钮会自动恢复'),
          ],
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              if (failure.retryable)
                FocusRing(
                  radius: 999,
                  child: TextButton(
                    onPressed: waiting || _busy
                        ? null
                        : () => _run(widget.onRetry),
                    child: const Text('重试'),
                  ),
                ),
              if (failure.code == 'source_login' &&
                  admin &&
                  widget.source?.id == 'sorani')
                _button('登录站源', _login),
              if (admin && const {'network', 'timeout'}.contains(failure.code))
                _button('网络设置', () => openProxySettings(context, store)),
              if (admin && failure.code == 'source_blocked')
                _button('站源设置', () async {
                  await openPage<void>(
                    context,
                    (_) => SettingsPage(
                      store: store,
                      initialGroup: SettingsGroup.sources,
                    ),
                  );
                }),
            ],
          ),
        ],
      ),
    );
  }
}

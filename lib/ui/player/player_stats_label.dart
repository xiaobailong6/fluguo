import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../local_store.dart';

/// 播控上可选的「时钟 / 缓存读速」小字。
///
/// 两个开关都关闭时不建 Timer、不读原生属性、不占任何空间；打开后每秒刷新
/// 一次，读速取自 mpv 的 `cache-speed`，读不到就永久隐藏，避免反复报错。
class PlayerStatsLabel extends StatefulWidget {
  const PlayerStatsLabel({
    super.key,
    required this.player,
    required this.store,
  });

  final Player player;
  final LocalStore store;

  @override
  State<PlayerStatsLabel> createState() => _PlayerStatsLabelState();
}

class _PlayerStatsLabelState extends State<PlayerStatsLabel> {
  Timer? _timer;
  String _speed = '';
  bool _speedAvailable = true;

  bool get _wanted =>
      widget.store.playbackPreferences.showClock ||
      widget.store.playbackPreferences.showCacheSpeed;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_changed);
    _sync();
  }

  @override
  void didUpdateWidget(PlayerStatsLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_changed);
      widget.store.addListener(_changed);
    }
    _sync();
  }

  @override
  void dispose() {
    widget.store.removeListener(_changed);
    _timer?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _sync();
  }

  /// 按开关状态开/停每秒一次的小计时器。
  void _sync() {
    if (_wanted) {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _tick() {
    if (!mounted) return;
    setState(() {});
    if (widget.store.playbackPreferences.showCacheSpeed) {
      unawaited(_readSpeed());
    }
  }

  Future<void> _readSpeed() async {
    if (!_speedAvailable) return;
    try {
      // `getProperty` 只在原生后端存在：用 dynamic 调用，缺实现时走 catch，
      // 这样不必把 media_kit 的平台实现绑进静态依赖。
      final platform = widget.player.platform;
      final value = await (platform as dynamic).getProperty('cache-speed');
      if (!mounted) return;
      setState(() => _speed = _format(value));
    } catch (_) {
      _speedAvailable = false;
    }
  }

  String _format(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return '';
    final bytes = double.tryParse(text);
    if (bytes == null || bytes <= 0) return '';
    const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
    var size = bytes;
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[unit]}';
  }

  String _clock() {
    final now = TimeOfDay.now();
    final hour = now.hour.toString().padLeft(2, '0');
    return '$hour:${now.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final preferences = widget.store.playbackPreferences;
    final parts = <String>[
      if (preferences.showClock) _clock(),
      if (preferences.showCacheSpeed && _speed.isNotEmpty) _speed,
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        parts.join('  '),
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: 11,
          height: 1,
          color: Colors.white.withValues(alpha: .82),
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

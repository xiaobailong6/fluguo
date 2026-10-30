import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../live_bilibili.dart';
import '../../live_feed.dart';

/// 直播播放页。
///
/// 一组接口只能拿到一条线路，所以这里不做清晰度切换；失败可以重试，
/// 点画面暂停 / 继续。退出页面即释放播放器。
class LivePlayerPage extends StatefulWidget {
  const LivePlayerPage({super.key, required this.platform, required this.room});

  final LivePlatform platform;
  final LiveRoom room;

  @override
  State<LivePlayerPage> createState() => _LivePlayerPageState();
}

class _LivePlayerPageState extends State<LivePlayerPage> {
  final _player = Player();
  late final _video = VideoController(_player);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  String _quality = '';
  String _error = '';
  bool _loading = true;
  bool _buffering = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _subscriptions.add(
      _player.stream.buffering.listen((value) {
        if (mounted) setState(() => _buffering = value);
      }),
    );
    _subscriptions.add(
      _player.stream.playing.listen((_) {
        if (mounted) setState(() {});
      }),
    );
    _subscriptions.add(
      _player.stream.error.listen((message) {
        if (mounted && message.isNotEmpty) setState(() => _error = message);
      }),
    );
    unawaited(_open());
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _open() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = '';
      _quality = '';
    });
    try {
      final stream = await widget.platform.resolve(widget.room);
      if (!mounted || generation != _generation) return;
      await _player.open(Media(stream.url, httpHeaders: stream.headers));
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _quality = stream.quality;
      });
    } catch (failure) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = liveErrorText(failure);
      });
    }
  }

  void _toggle() {
    if (_loading || _error.isNotEmpty) return;
    unawaited(_player.playOrPause());
  }

  @override
  Widget build(BuildContext context) {
    final playing = _player.state.playing;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggle,
              child: Video(
                controller: _video,
                controls: NoVideoControls,
                fill: Colors.black,
              ),
            ),
            Positioned(left: 4, right: 12, top: 0, child: _header(context)),
            if (_loading || _buffering)
              const IgnorePointer(child: Center(child: CircularProgressIndicator())),
            if (!_loading && !playing && _error.isEmpty)
              const IgnorePointer(
                child: Center(
                  child: Icon(
                    Icons.play_arrow_rounded,
                    size: 72,
                    color: Colors.white70,
                  ),
                ),
              ),
            if (_error.isNotEmpty) _failure(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    const shadow = [Shadow(color: Color(0x66000000), blurRadius: 2)];
    final room = widget.room;
    return SizedBox(
      height: 56,
      child: Row(
        spacing: 2,
        children: [
          IconButton(
            onPressed: () => unawaited(Navigator.maybePop(context)),
            icon: const Icon(Icons.arrow_back_rounded),
            color: Colors.white,
            tooltip: '返回',
            style: IconButton.styleFrom(fixedSize: const Size.square(48)),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  room.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    shadows: shadow,
                  ),
                ),
                Text(
                  [
                    if (room.anchor.isNotEmpty) room.anchor,
                    if (_quality.isNotEmpty) _quality,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .78),
                    fontSize: 12,
                    shadows: shadow,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _failure(BuildContext context) => Center(
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .78),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, color: Colors.white70, size: 36),
          const SizedBox(height: 12),
          Text(
            _error,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => unawaited(_open()),
                child: const Text('重试'),
              ),
              TextButton(
                onPressed: () => unawaited(Navigator.maybePop(context)),
                child: const Text('返回'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
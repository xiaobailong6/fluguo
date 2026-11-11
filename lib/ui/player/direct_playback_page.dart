import 'package:flutter/material.dart';

import '../../follow_state.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../widgets/glass/glass_dialog.dart';
import 'playback_handle.dart';
import 'playback_page.dart';

/// 仅省略剧集信息页；详情加载、权限检查、VIP 提醒和正式播放仍保留。
class DirectPlaybackPage extends StatefulWidget {
  const DirectPlaybackPage({
    super.key,
    required this.store,
    required this.drama,
    this.playbackBuilder,
  });
  final LocalStore store;
  final Drama drama;
  final Widget Function(DramaDetail detail, int index, double position)?
  playbackBuilder;

  @override
  State<DirectPlaybackPage> createState() => _DirectPlaybackPageState();
}

class _DirectPlaybackPageState extends State<DirectPlaybackPage> {
  DramaDetail? _detail;
  PlaybackHandle? _handle;
  String? _error;
  int _index = 0;
  double _position = 0;
  int _generation = 0;
  late final int _epoch = widget.store.profileEpoch;

  bool get _allowed =>
      mounted &&
      widget.store.profileEpoch == _epoch &&
      widget.store.allowsSource(widget.drama.source);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_generation == 0) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (!_allowed) return;
    setState(() => _error = null);
    try {
      final detail = await AppScope.of(context).repository.detail(widget.drama);
      if (!mounted || !_allowed || generation != _generation) return;
      if (detail.episodes.isEmpty) throw StateError('empty');
      if (detail.drama.source != widget.drama.source) {
        throw StateError('invalid source');
      }
      final watch = widget.store.watched(detail.drama.id);
      final index = resumeEpisodeIndex(detail.episodes, watch);
      if (detail.episodes[index].vip &&
          detail.drama.source != SourceSite.dsd.id) {
        final confirmed = await showGlassDialog<bool>(
          context,
          builder: (context) => GlassDialogBody(
            title: '这是一集 VIP 内容',
            message: '站源可能只提供试看或限制播放。',
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('尝试播放'),
              ),
            ],
          ),
        );
        if (!mounted || !_allowed || generation != _generation) return;
        if (confirmed != true) {
          Navigator.pop(context);
          return;
        }
      }
      if (!widget.store.allowsSource(detail.drama.source)) return;
      setState(() {
        _detail = detail;
        _index = index;
        _position =
            watch != null &&
                !watch.finished &&
                watch.episode == detail.episodes[index].number
            ? watch.position
            : 0;
      });
    } catch (_) {
      if (_allowed && generation == _generation) {
        setState(() => _error = '无法加载剧集，请重试');
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    // 已挂载的 PlaybackPage 负责释放 handle；加载阶段没有创建播放器。
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      if (!_allowed) {
        _handle = null;
        return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Text('当前用户无权播放此内容', style: TextStyle(color: Colors.white)),
          ),
        );
      }
      final detail = _detail;
      if (detail != null) {
        if (widget.playbackBuilder != null) {
          return widget.playbackBuilder!(detail, _index, _position);
        }
        _handle ??= PlaybackHandle(
          repository: AppScope.of(context).repository,
          store: widget.store,
          detail: detail,
          index: _index,
          position: _position,
          preopen: widget.store.playbackPreferences.preopens(
            television: AppScope.of(context).television,
          ),
        );
        return PlaybackPage(store: widget.store, handle: _handle!);
      }
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(widget.drama.title),
        ),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, style: const TextStyle(color: Colors.white)),
                    TextButton(onPressed: _load, child: const Text('重试')),
                  ],
                ),
        ),
      );
    },
  );
}

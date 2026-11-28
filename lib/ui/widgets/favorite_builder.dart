import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../local_store.dart';

class FavoriteBuilder extends _LibraryFlagBuilder {
  const FavoriteBuilder({
    super.key,
    required super.store,
    required super.id,
    required super.builder,
  });
}

class WatchedBuilder extends _LibraryFlagBuilder {
  const WatchedBuilder({
    super.key,
    required super.store,
    required super.id,
    required super.builder,
  }) : super(watched: true);
}

/// 隐藏标签页解除订阅；恢复显示时读取最新值，保留海报自身的布局和焦点状态。
class _LibraryFlagBuilder extends StatefulWidget {
  const _LibraryFlagBuilder({
    super.key,
    required this.store,
    required this.id,
    required this.builder,
    this.watched = false,
  });

  final LocalStore? store;
  final String id;
  final Widget Function(BuildContext, bool) builder;
  final bool watched;

  @override
  State<_LibraryFlagBuilder> createState() => _LibraryFlagBuilderState();
}

class _LibraryFlagBuilderState extends State<_LibraryFlagBuilder> {
  ValueListenable<TickerModeData>? _visibility;
  ValueListenable<bool>? _status;
  bool _value = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchVisibility();
  }

  @override
  void activate() {
    super.activate();
    _watchVisibility();
  }

  void _watchVisibility() {
    _visibility?.removeListener(_visibilityChanged);
    _visibility = TickerMode.getValuesNotifier(context);
    _visibility!.addListener(_visibilityChanged);
    _subscribe();
  }

  @override
  void didUpdateWidget(_LibraryFlagBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store ||
        oldWidget.id != widget.id ||
        oldWidget.watched != widget.watched) {
      _subscribe();
    }
  }

  void _subscribe() {
    _status?.removeListener(_changed);
    _status = null;
    if (_visibility?.value.enabled == true) {
      _status = widget.watched
          ? widget.store?.watchedStatus(widget.id)
          : widget.store?.favoriteStatus(widget.id);
      _status?.addListener(_changed);
      _value = _status?.value ?? false;
    }
  }

  void _visibilityChanged() {
    final previous = _value;
    _subscribe();
    if (_value != previous) setState(() {});
  }

  void _changed() {
    final next = _status?.value ?? false;
    if (next != _value) setState(() => _value = next);
  }

  @override
  void dispose() {
    _visibility?.removeListener(_visibilityChanged);
    _status?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

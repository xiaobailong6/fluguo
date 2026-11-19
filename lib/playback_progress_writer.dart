import 'models.dart';

/// 只负责保存去重与结果提示；会话继续决定何时保存、用户权限和媒体生命周期。
class PlaybackProgressWriter {
  PlaybackProgressWriter({
    required this.saveWatch,
    required this.saveMediaWatch,
    required this.currentDrama,
    required this.onWarningChanged,
    this.mediaHistoryId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Future<void> Function(WatchEntry entry, {bool quiet}) saveWatch;
  final Future<void> Function(String id, WatchEntry entry) saveMediaWatch;
  final Drama Function(Drama drama) currentDrama;
  final void Function() onWarningChanged;
  final String? mediaHistoryId;
  final DateTime Function() _clock;

  String? warning;
  String? _savedKey;
  bool _savedQuietly = false;

  Future<void> save({
    required DramaDetail detail,
    required int openedIndex,
    required double position,
    required double duration,
    bool quiet = false,
  }) async {
    if (position < .1) return;
    final key = '${detail.drama.id}:$openedIndex:$position:$duration';
    // 静默保存后仍需一次显式保存，让返回页面时的通知与原会话一致。
    if (_savedKey == key && warning == null && (quiet || !_savedQuietly)) {
      return;
    }
    final entry = WatchEntry(
      drama: currentDrama(detail.drama),
      episode: detail.episodes[openedIndex].number,
      position: position,
      duration: duration,
      updatedAt: _clock(),
    );
    try {
      if (mediaHistoryId case final id?) {
        await saveMediaWatch(id, entry);
      } else {
        await saveWatch(entry, quiet: quiet);
      }
      // 只有写入完成才消费去重键；失败后同一位置仍允许重试。
      _savedKey = key;
      _savedQuietly = quiet;
      if (warning != null) {
        warning = null;
        onWarningChanged();
      }
    } catch (_) {
      if (warning == null) {
        warning = '观看进度尚未保存，请检查存储空间后重试。';
        onWarningChanged();
      }
    }
  }
}

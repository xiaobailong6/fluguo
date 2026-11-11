import '../../playback_session.dart';

/// -1 表示本集结束，0 表示关闭；各播放器入口共用同一组选择。
const sleepTimerOptions = [-1, 15, 30, 60, 90, 0];

int selectedSleepTimer(PlaybackSession session) =>
    session.sleepAtEpisodeEnd ? -1 : session.sleepMinutes;

String sleepTimerOptionLabel(int value) => switch (value) {
  -1 => '播完本集',
  0 => '关闭定时',
  _ => '$value 分钟',
};

void applySleepTimer(PlaybackSession session, int value) =>
    session.setSleepTimer(minutes: value < 0 ? 0 : value, episodeEnd: value == -1);

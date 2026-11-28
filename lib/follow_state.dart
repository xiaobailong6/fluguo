import 'dart:math';

import 'models.dart';

class FollowState {
  const FollowState({
    this.knownEpisodes = 0,
    this.readEpisodes,
    this.seriesSeasons = const {},
    this.seasonsSeeded = false,
  });

  final int knownEpisodes;
  final int? readEpisodes;
  final Map<String, SeriesSeasonNotice> seriesSeasons;
  final bool seasonsSeeded;

  int get newEpisodes =>
      readEpisodes == null ? 0 : max(0, knownEpisodes - readEpisodes!);
  // 旧版按标题推断的候选继续保留，但不作为官方新季提醒。
  List<SeriesSeasonNotice> get unreadSeasons => seasonsSeeded
      ? seriesSeasons.values.where((notice) => !notice.read).toList()
      : const [];
  bool get hasUpdates => newEpisodes > 0 || unreadSeasons.isNotEmpty;
  String? get updateBadge {
    final seasons = unreadSeasons;
    final parts = [
      if (newEpisodes > 0) '$newEpisodes 集更新',
      if (seasons.length == 1) '第${seasons.first.season}季已上线',
      if (seasons.length > 1) '更新${seasons.length}季',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  FollowState copyWith({
    int? knownEpisodes,
    int? readEpisodes,
    Map<String, SeriesSeasonNotice>? seriesSeasons,
    bool? seasonsSeeded,
  }) => FollowState(
    knownEpisodes: knownEpisodes ?? this.knownEpisodes,
    readEpisodes: readEpisodes ?? this.readEpisodes,
    seriesSeasons: seriesSeasons ?? this.seriesSeasons,
    seasonsSeeded: seasonsSeeded ?? this.seasonsSeeded,
  );

  factory FollowState.initial(Drama drama) {
    final count = max(0, drama.episodes);
    return FollowState(
      knownEpisodes: count,
      readEpisodes: count > 0 ? count : null,
    );
  }

  FollowState observe(Drama drama) {
    final count = max(knownEpisodes, drama.episodes);
    return FollowState(
      knownEpisodes: count,
      readEpisodes: readEpisodes ?? (count > 0 ? count : null),
      seriesSeasons: seriesSeasons,
      seasonsSeeded: seasonsSeeded,
    );
  }

  FollowState observeSeasons({
    required Drama anchor,
    required List<DramaSeason> seasons,
    required Set<String> favoriteIds,
    required Set<String> watchedIds,
    bool baselineOnly = false,
    DateTime? now,
  }) {
    if (baselineOnly && seasonsSeeded) return this;
    if (seasons.length > 200) throw const FormatException('官方分季数量无效');
    final linked = DramaSeason.associated(anchor, seasons);
    if (seasons.isNotEmpty && linked.isEmpty) {
      throw const FormatException('官方分季未包含当前剧集');
    }
    // 空列表表示当前还没有官方关联，也要建立基线，之后新增一季才会提醒。
    final index = linked.indexWhere((season) => season.drama.id == anchor.id);
    // A temporarily incomplete response must not erase read history.
    final updated = seasonsSeeded
        ? Map<String, SeriesSeasonNotice>.of(seriesSeasons)
        : <String, SeriesSeasonNotice>{};
    for (final id in updated.keys.toList()) {
      if (favoriteIds.contains(id) || watchedIds.contains(id)) {
        updated[id] = updated[id]!.markRead();
      }
    }
    final current = now ?? DateTime.now();
    final today = DateTime(current.year, current.month, current.day);
    for (final season in linked.skip(index + 1)) {
      final drama = season.drama;
      final online = DateTime.tryParse(drama.onlineDate);
      if ((online == null ? drama.episodes <= 0 : online.isAfter(today)) ||
          const {'upcoming', 'unreleased'}.contains(drama.releaseStatus)) {
        continue;
      }
      final previous = seasonsSeeded ? seriesSeasons[drama.id] : null;
      final notice = SeriesSeasonNotice(
        id: drama.id,
        title: drama.title.trim().isEmpty ? season.label : drama.title,
        season: season.number,
        unit: '季',
        read:
            !seasonsSeeded ||
            favoriteIds.contains(drama.id) ||
            watchedIds.contains(drama.id) ||
            previous?.read == true,
      );
      // 与落盘/备份读取使用同一校验，避免存入下次启动无法读取的数据。
      SeriesSeasonNotice.fromJson(notice.toJson());
      updated[drama.id] = notice;
    }
    if (updated.length > 200) throw const FormatException('官方分季数量无效');
    return copyWith(seriesSeasons: updated, seasonsSeeded: true);
  }

  FollowState markRead() => FollowState(
    knownEpisodes: knownEpisodes,
    readEpisodes: knownEpisodes > 0 ? knownEpisodes : null,
    seriesSeasons: {
      for (final entry in seriesSeasons.entries)
        entry.key: seasonsSeeded ? entry.value.markRead() : entry.value,
    },
    seasonsSeeded: seasonsSeeded,
  );

  FollowState markSeriesSeasonRead(String id) =>
      seriesSeasons[id]?.read != false
      ? this
      : copyWith(
          seriesSeasons: Map.of(seriesSeasons)
            ..[id] = seriesSeasons[id]!.markRead(),
        );

  Map<String, dynamic> toJson() {
    final value = <String, dynamic>{
      'knownEpisodes': knownEpisodes,
      'readEpisodes': readEpisodes,
    };
    if (seasonsSeeded) value['seasonsSeeded'] = true;
    if (seriesSeasons.isNotEmpty) {
      value['seriesSeasons'] = {
        for (final entry in seriesSeasons.entries)
          entry.key: entry.value.toJson(),
      };
    }
    return value;
  }

  factory FollowState.fromJson(Map<String, dynamic> json) {
    final known = json['knownEpisodes'];
    final read = json['readEpisodes'];
    if (json['seasonsSeeded'] != null && json['seasonsSeeded'] is! bool) {
      throw const FormatException('新季检查状态无效');
    }
    final rawSeasons = json['seriesSeasons'];
    final seasons = <String, SeriesSeasonNotice>{};
    if (rawSeasons != null) {
      if (rawSeasons is! Map || rawSeasons.length > 200) {
        throw const FormatException('系列剧提醒无效');
      }
      for (final entry in rawSeasons.entries) {
        if (entry.key is! String) throw const FormatException('系列剧提醒无效');
        if (entry.value is! Map) throw const FormatException('系列剧提醒无效');
        final notice = SeriesSeasonNotice.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (entry.key != notice.id || seasons.containsKey(notice.id)) {
          throw const FormatException('系列剧提醒无效');
        }
        seasons[notice.id] = notice;
      }
    }
    if (known is! int ||
        known < 0 ||
        known > 1000000 ||
        read != null && (read is! int || read < 0 || read > known)) {
      throw const FormatException('追剧状态无效');
    }
    return FollowState(
      knownEpisodes: known,
      readEpisodes: read as int?,
      seriesSeasons: seasons,
      seasonsSeeded: json['seasonsSeeded'] == true,
    );
  }
}

class SeriesSeasonNotice {
  const SeriesSeasonNotice({
    required this.id,
    required this.title,
    required this.season,
    required this.unit,
    this.read = false,
  });

  final String id;
  final String title;
  final int season;
  final String unit;
  final bool read;

  SeriesSeasonNotice markRead() => read
      ? this
      : SeriesSeasonNotice(
          id: id,
          title: title,
          season: season,
          unit: unit,
          read: true,
        );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'season': season,
    'unit': unit,
    'read': read,
  };

  factory SeriesSeasonNotice.fromJson(Map<String, dynamic> json) {
    final id = json['id'], title = json['title'], season = json['season'];
    final unit = json['unit'], read = json['read'];
    if (id is! String ||
        !id.startsWith('${SourceSite.hongguo.id}:') ||
        id.length > 512 ||
        title is! String ||
        title.trim().isEmpty ||
        title.length > 300 ||
        season is! int ||
        season < 1 ||
        season > 200 ||
        unit is! String ||
        !{'季', '部'}.contains(unit) ||
        read is! bool) {
      throw const FormatException('系列剧提醒无效');
    }
    return SeriesSeasonNotice(
      id: id,
      title: title,
      season: season,
      unit: unit,
      read: read,
    );
  }
}

class FollowCheck {
  const FollowCheck(
    this.checkedAt, {
    this.failures = 0,
    this.seasonsCheckedAt,
    this.seasonFailures = 0,
  });

  final DateTime checkedAt;
  final int failures;
  final DateTime? seasonsCheckedAt;
  final int seasonFailures;

  FollowCheck withDetail(DateTime at, {int failures = 0}) => FollowCheck(
    at,
    failures: failures,
    seasonsCheckedAt: seasonsCheckedAt,
    seasonFailures: seasonFailures,
  );

  FollowCheck withSeasons(DateTime at, {int failures = 0}) => FollowCheck(
    checkedAt,
    failures: this.failures,
    seasonsCheckedAt: at,
    seasonFailures: failures,
  );

  List<int> toJson() => [
    checkedAt.millisecondsSinceEpoch,
    failures,
    if (seasonsCheckedAt != null || seasonFailures > 0) ...[
      seasonsCheckedAt?.millisecondsSinceEpoch ?? 0,
      seasonFailures,
    ],
  ];

  factory FollowCheck.fromJson(Object? json) {
    if (json is! List ||
        (json.length != 2 && json.length != 4) ||
        json[0] is! int ||
        json[1] is! int ||
        (json[1] as int) < 0) {
      throw const FormatException('追剧检查记录无效');
    }
    DateTime? seasonsCheckedAt;
    var seasonFailures = 0;
    if (json.length == 4) {
      if (json[2] is! int || json[3] is! int || (json[3] as int) < 0) {
        throw const FormatException('追剧检查记录无效');
      }
      final timestamp = json[2] as int;
      if (timestamp > 0) {
        seasonsCheckedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
      }
      seasonFailures = json[3] as int;
    }
    return FollowCheck(
      DateTime.fromMillisecondsSinceEpoch(json[0] as int),
      failures: json[1] as int,
      seasonsCheckedAt: seasonsCheckedAt,
      seasonFailures: seasonFailures,
    );
  }
}

int resumeEpisodeIndex(List<Episode> episodes, WatchEntry? watch) {
  if (episodes.isEmpty || watch == null) return 0;
  final current = episodes.indexWhere((item) => item.number == watch.episode);
  if (current >= 0 && !watch.finished) return current;
  final next = episodes.indexWhere((item) => item.number > watch.episode);
  if (next >= 0) return next;
  return current >= 0 ? current : episodes.length - 1;
}

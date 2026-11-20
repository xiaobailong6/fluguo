import 'catalog_sort.dart';
import 'follow_state.dart';
import 'models.dart';

const _hongguoSeriesLimit = 200;

final _seasonSuffix = RegExp(
  r'第\s*([0-9零〇一二两兩三四五六七八九十百]+)\s*([季部])[\s\u3000，。！？、：；·「」『』（）【】《》“”‘’.,!?:;\-_/()\[\]{}]*$',
);

class HongguoSeriesInfo {
  const HongguoSeriesInfo({
    required this.baseTitle,
    required this.key,
    required this.season,
    required this.unit,
    required this.explicit,
  });

  final String baseTitle;
  final String key;
  final int season;
  final String unit;
  final bool explicit;
}

class HongguoSeriesEntry {
  const HongguoSeriesEntry({
    required this.drama,
    required this.season,
    required this.unit,
  });

  final Drama drama;
  final int season;
  final String unit;

  String get label => '第 $season $unit';
}

int? _seasonNumber(String label) {
  final numeric = int.tryParse(label);
  if (numeric != null) {
    return numeric >= 1 && numeric <= _hongguoSeriesLimit ? numeric : null;
  }
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  var number = 0;
  if (!label.contains(RegExp('[十百]'))) {
    for (final rune in label.runes) {
      final digit = digits[String.fromCharCode(rune)];
      if (digit == null) return null;
      number = number * 10 + digit;
      if (number > _hongguoSeriesLimit) return null;
    }
    return number >= 1 ? number : null;
  }
  var digit = 0;
  var previous = 1000;
  for (final rune in label.runes) {
    final character = String.fromCharCode(rune);
    final value = digits[character];
    if (value != null) {
      digit = digit * 10 + value;
      continue;
    }
    final multiplier = character == '百' ? 100 : 10;
    if (multiplier >= previous || digit > 9) return null;
    number += (digit == 0 ? 1 : digit) * multiplier;
    digit = 0;
    previous = multiplier;
  }
  number += digit;
  return number >= 1 && number <= _hongguoSeriesLimit ? number : null;
}

HongguoSeriesInfo? hongguoSeriesInfo(Drama drama, {String? unit}) {
  if (drama.source != SourceSite.hongguo.id) return null;
  final title = drama.title.trim();
  final match = _seasonSuffix.firstMatch(title);
  if (match == null) {
    if (unit == null || title.isEmpty) return null;
    return HongguoSeriesInfo(
      baseTitle: title,
      key: normalizedSearchText(title),
      season: 1,
      unit: unit,
      explicit: false,
    );
  }
  final base = title.substring(0, match.start).trim();
  final season = _seasonNumber(match[1]!);
  if (base.isEmpty || season == null) return null;
  return HongguoSeriesInfo(
    baseTitle: base,
    key: normalizedSearchText(base),
    season: season,
    unit: match[2]!,
    explicit: true,
  );
}

List<HongguoSeriesEntry> hongguoSeriesEntries(
  Drama anchor,
  Iterable<Drama> candidates,
) {
  if (anchor.source != SourceSite.hongguo.id) return const [];
  var anchorInfo = hongguoSeriesInfo(anchor);
  String key, unit;
  int anchorSeason;
  if (anchorInfo == null) {
    final baseKey = normalizedSearchText(anchor.title);
    final groups = <String, List<HongguoSeriesInfo>>{};
    for (final drama in candidates) {
      final info = hongguoSeriesInfo(drama);
      if (info != null && info.key == baseKey) {
        (groups[info.unit] ??= []).add(info);
      }
    }
    if (groups.isEmpty) return const [];
    final best = groups.entries.toList()
      ..sort((a, b) {
        final count = b.value.length.compareTo(a.value.length);
        if (count != 0) return count;
        final maxA = a.value.fold<int>(
          0,
          (value, info) => value > info.season ? value : info.season,
        );
        final maxB = b.value.fold<int>(
          0,
          (value, info) => value > info.season ? value : info.season,
        );
        return maxB.compareTo(maxA);
      });
    key = baseKey;
    unit = best.first.key;
    anchorSeason = 1;
    anchorInfo = hongguoSeriesInfo(anchor, unit: unit);
  } else {
    key = anchorInfo.key;
    unit = anchorInfo.unit;
    anchorSeason = anchorInfo.season;
  }
  if (anchorInfo == null) return const [];
  final byId = <String, HongguoSeriesEntry>{};
  for (final drama in [anchor, ...candidates]) {
    if (drama.source != SourceSite.hongguo.id) continue;
    final info = hongguoSeriesInfo(drama, unit: unit);
    if (info == null || info.key != key || info.unit != unit) continue;
    byId[drama.id] = HongguoSeriesEntry(
      drama: drama,
      season: drama.id == anchor.id ? anchorSeason : info.season,
      unit: unit,
    );
  }
  final entries = byId.values.toList()
    ..sort((a, b) {
      final season = a.season.compareTo(b.season);
      return season != 0
          ? season
          : naturalTitleCompare(a.drama.title, b.drama.title);
    });
  return entries.length > 1 ? entries : const [];
}

/// 单批索引：候选仅解析一次，同系列的排序结果在多个收藏之间复用。
/// 不改变公开的单次匹配函数，便于与既有规则做差分回归。
class HongguoSeriesIndex {
  HongguoSeriesIndex(Iterable<Drama> candidates) {
    for (final drama in candidates) {
      final info = hongguoSeriesInfo(drama, unit: '季');
      if (info == null) continue;
      final row = (drama: drama, info: info);
      _parsed[drama.id] = row;
      (_byTitle[info.key] ??= []).add(row);
      if (info.explicit) {
        final units = _units[info.key] ??= {};
        final previous = units[info.unit] ?? (count: 0, max: 0);
        units[info.unit] = (
          count: previous.count + 1,
          max: previous.max > info.season ? previous.max : info.season,
        );
      }
    }
  }

  final _parsed = <String, ({Drama drama, HongguoSeriesInfo info})>{};
  final _byTitle = <String, List<({Drama drama, HongguoSeriesInfo info})>>{};
  final _units = <String, Map<String, ({int count, int max})>>{};
  final _sorted = <(String, String), List<HongguoSeriesEntry>>{};
  final _titleKeys = <String, String>{};

  int _compare(HongguoSeriesEntry a, HongguoSeriesEntry b) {
    final season = a.season.compareTo(b.season);
    return season != 0
        ? season
        : naturalTitleKeyCompare(
            _titleKeys.putIfAbsent(
              a.drama.title,
              () => naturalTitleKey(a.drama.title),
            ),
            _titleKeys.putIfAbsent(
              b.drama.title,
              () => naturalTitleKey(b.drama.title),
            ),
          );
  }

  List<HongguoSeriesEntry> entries(Drama anchor) {
    if (anchor.source != SourceSite.hongguo.id) return const [];
    final cached = _parsed[anchor.id];
    final info = identical(cached?.drama, anchor)
        ? cached?.info
        : hongguoSeriesInfo(anchor, unit: '季');
    if (info == null) return const [];
    var unit = info.unit;
    if (!info.explicit) {
      final groups = _units[info.key];
      if (groups == null) return const [];
      var count = -1, max = -1;
      for (final entry in groups.entries) {
        if (entry.value.count > count ||
            entry.value.count == count && entry.value.max > max) {
          unit = entry.key;
          count = entry.value.count;
          max = entry.value.max;
        }
      }
    }
    final selectedUnit = unit;
    final rows = _sorted.putIfAbsent((info.key, unit), () {
      final byId = <String, HongguoSeriesEntry>{};
      for (final row in _byTitle[info.key] ?? const []) {
        if (row.info.explicit && row.info.unit != selectedUnit) continue;
        byId[row.drama.id] = HongguoSeriesEntry(
          drama: row.drama,
          season: row.info.season,
          unit: selectedUnit,
        );
      }
      return byId.values.toList()..sort(_compare);
    });
    final existing = rows.where((row) => row.drama.id == anchor.id).firstOrNull;
    if (existing != null && existing.season == info.season) {
      return rows.length > 1 ? rows : const [];
    }
    // anchor 不在候选中时只插入一项；不为每个收藏重排整个分组。
    final result = rows.where((row) => row.drama.id != anchor.id).toList();
    final entry = HongguoSeriesEntry(
      drama: existing?.drama ?? anchor,
      season: info.season,
      unit: unit,
    );
    final position = result.indexWhere((row) => _compare(entry, row) <= 0);
    result.insert(position < 0 ? result.length : position, entry);
    return result.length > 1 ? result : const [];
  }
}

FollowState observeHongguoSeriesSeasons({
  required Drama anchor,
  required FollowState state,
  required Iterable<Drama> candidates,
  required Set<String> favoriteIds,
  HongguoSeriesIndex? index,
}) {
  final entries =
      index?.entries(anchor) ?? hongguoSeriesEntries(anchor, candidates);
  if (entries.isEmpty) return state;
  final anchorSeason = entries
      .where((entry) => entry.drama.id == anchor.id)
      .firstOrNull
      ?.season;
  if (anchorSeason == null) return state;
  var seasons = state.seriesSeasons;
  for (final id in seasons.keys.toList()) {
    if (id == anchor.id || favoriteIds.contains(id)) {
      if (identical(seasons, state.seriesSeasons)) seasons = Map.of(seasons);
      seasons.remove(id);
    }
  }
  for (final entry in entries) {
    if (entry.drama.id == anchor.id ||
        favoriteIds.contains(entry.drama.id) ||
        entry.season <= anchorSeason) {
      continue;
    }
    final previous = seasons[entry.drama.id];
    final notice = SeriesSeasonNotice(
      id: entry.drama.id,
      title: entry.drama.title,
      season: entry.season,
      unit: entry.unit,
      read: previous?.read ?? false,
    );
    if (previous?.title == notice.title &&
        previous?.season == notice.season &&
        previous?.unit == notice.unit &&
        previous?.read == notice.read) {
      continue;
    }
    if (identical(seasons, state.seriesSeasons)) seasons = Map.of(seasons);
    seasons[notice.id] = notice;
  }
  return identical(seasons, state.seriesSeasons)
      ? state
      : state.copyWith(seriesSeasons: seasons);
}

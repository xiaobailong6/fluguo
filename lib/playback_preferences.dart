import 'catalog_sort.dart';

const playbackSpeeds = [.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0];
const danmakuColors = [
  0xFFFFFFFF,
  0xFFFFE066,
  0xFF66E0FF,
  0xFFFF8FB8,
  0xFF8CF08C,
];

/// 直播平台的画质代码与短剧分辨率分开存储，0 表示优先最高可用画质。
const liveQualityOptions = <int, String>{
  0: '自动（优先高清）',
  10000: '原画',
  400: '蓝光',
  250: '超清',
  150: '高清',
  80: '流畅',
};

enum TelevisionDecoder { optimized, hardware, software }

enum DanmakuCoverage {
  quarter(.25, '顶部四分之一'),
  half(.5, '顶部一半'),
  full(1, '全部');

  const DanmakuCoverage(this.fraction, this.label);

  final double fraction;
  final String label;
}

const danmakuScaleMin = .6;
const danmakuScaleMax = 2.0;

const danmakuStrokeMin = 0.0;
const danmakuStrokeMax = 6.0;

const danmakuShadowMin = 0.0;
const danmakuShadowMax = 12.0;

const danmakuWordLength = 40;
const danmakuWordLimit = 60;

/// 跳过片头/片尾可设置的上限（秒）。
const skipSecondsMax = 600;

/// 读取跳过秒数：非整数、负数或超上限一律收敛到合法区间。
int skipSecondsOr(Object? value) {
  if (value is! int || value <= 0) return 0;
  return value > skipSecondsMax ? skipSecondsMax : value;
}

/// 播放画面的填充方式。
///
/// [contain] 保留完整画面并在必要时留黑边（默认），[cover] 裁切边缘铺满，
/// [stretch] 不裁切但会改变长宽比。
enum VideoFitMode { contain, cover, stretch }

class PlaybackPreferences {
  const PlaybackPreferences({
    this.speed = 1,
    this.quality = 0,
    this.liveQuality = 0,
    this.autoAdvance = true,
    this.danmaku = true,
    this.danmakuScale = 1,
    this.danmakuColor = 0xFFFFFFFF,
    this.danmakuOpacity = 1,
    this.danmakuBold = true,
    this.danmakuStroke = 0,
    this.danmakuShadow = 3,
    this.danmakuCoverage = DanmakuCoverage.half,
    this.danmakuWords = const [],
    this.preload = true,
    this.televisionDecoder = TelevisionDecoder.optimized,
    this.preopen,
    this.doubleTapSeek = true,
    this.swipeLevels = true,
    this.autoPictureInPicture = false,
    this.skipIntroSeconds = 0,
    this.skipOutroSeconds = 0,
    this.videoFit = VideoFitMode.contain,
    this.showClock = false,
    this.showCacheSpeed = false,
  });

  final double speed;
  final int quality;
  final int liveQuality;
  final bool autoAdvance;
  final bool danmaku;
  final bool preload;
  final TelevisionDecoder televisionDecoder;
  final bool? preopen;
  final bool doubleTapSeek;
  final bool swipeLevels;
  final double danmakuScale;
  final int danmakuColor;
  final double danmakuOpacity;
  final bool danmakuBold;
  final double danmakuStroke;
  final double danmakuShadow;
  final DanmakuCoverage danmakuCoverage;
  final List<String> danmakuWords;
  final bool autoPictureInPicture;
  /// 从本集开头播放时自动跳过的秒数；0 表示关闭。
  final int skipIntroSeconds;

  /// 接近结尾时直接跳到结束的秒数；0 表示关闭。
  final int skipOutroSeconds;

  /// 播放画面的填充方式；默认适应，行为与旧版本完全一致。
  final VideoFitMode videoFit;

  /// 播控上显示当前时间；默认关闭。
  final bool showClock;

  /// 播控上显示缓存读速；默认关闭，取不到时自动隐藏。
  final bool showCacheSpeed;

  bool preopens({required bool television}) => preopen ?? !television;

  PlaybackPreferences copyWith({
    double? speed,
    int? quality,
    int? liveQuality,
    bool? autoAdvance,
    bool? danmaku,
    bool? preload,
    TelevisionDecoder? televisionDecoder,
    bool? preopen,
    bool? doubleTapSeek,
    bool? swipeLevels,
    bool? autoPictureInPicture,
    double? danmakuScale,
    int? danmakuColor,
    double? danmakuOpacity,
    bool? danmakuBold,
    double? danmakuStroke,
    double? danmakuShadow,
    DanmakuCoverage? danmakuCoverage,
    List<String>? danmakuWords,
    int? skipIntroSeconds,
    int? skipOutroSeconds,
    VideoFitMode? videoFit,
    bool? showClock,
    bool? showCacheSpeed,
  }) => PlaybackPreferences(
    speed: speed ?? this.speed,
    quality: quality ?? this.quality,
    liveQuality: liveQuality ?? this.liveQuality,
    autoAdvance: autoAdvance ?? this.autoAdvance,
    danmaku: danmaku ?? this.danmaku,
    preload: preload ?? this.preload,
    televisionDecoder: televisionDecoder ?? this.televisionDecoder,
    preopen: preopen ?? this.preopen,
    doubleTapSeek: doubleTapSeek ?? this.doubleTapSeek,
    swipeLevels: swipeLevels ?? this.swipeLevels,
    autoPictureInPicture: autoPictureInPicture ?? this.autoPictureInPicture,
    danmakuScale: danmakuScale ?? this.danmakuScale,
    danmakuColor: danmakuColor ?? this.danmakuColor,
    danmakuOpacity: danmakuOpacity ?? this.danmakuOpacity,
    danmakuBold: danmakuBold ?? this.danmakuBold,
    danmakuStroke: danmakuStroke ?? this.danmakuStroke,
    danmakuShadow: danmakuShadow ?? this.danmakuShadow,
    danmakuCoverage: danmakuCoverage ?? this.danmakuCoverage,
    danmakuWords: danmakuWords ?? this.danmakuWords,
    skipIntroSeconds: skipIntroSeconds ?? this.skipIntroSeconds,
    skipOutroSeconds: skipOutroSeconds ?? this.skipOutroSeconds,
    videoFit: videoFit ?? this.videoFit,
    showClock: showClock ?? this.showClock,
    showCacheSpeed: showCacheSpeed ?? this.showCacheSpeed,
  );

  Map<String, dynamic> toJson() => {
    'speed': speed,
    'quality': quality,
    'liveQuality': liveQuality,
    'autoAdvance': autoAdvance,
    'danmaku': danmaku,
    'danmakuScale': danmakuScale,
    'danmakuColor': danmakuColor,
    'danmakuOpacity': danmakuOpacity,
    'danmakuBold': danmakuBold,
    'danmakuStroke': danmakuStroke,
    'danmakuShadow': danmakuShadow,
    'danmakuCoverage': danmakuCoverage.name,
    'danmakuWords': danmakuWords,
    'preload': preload,
    'televisionDecoder': televisionDecoder.name,
    if (preopen != null) 'preopen': preopen,
    'doubleTapSeek': doubleTapSeek,
    'swipeLevels': swipeLevels,
    'autoPictureInPicture': autoPictureInPicture,
    'skipIntroSeconds': skipIntroSeconds,
    'skipOutroSeconds': skipOutroSeconds,
    'videoFit': videoFit.name,
    'showClock': showClock,
    'showCacheSpeed': showCacheSpeed,
  };

  factory PlaybackPreferences.fromJson(Map<String, dynamic> value) {
    final speed = (value['speed'] as num? ?? 1).toDouble();
    final quality = value['quality'] as int? ?? 0;
    final liveQuality = value['liveQuality'] as int? ?? 0;
    final autoAdvance = value['autoAdvance'] as bool? ?? true;
    final danmaku = value['danmaku'] as bool? ?? true;
    final danmakuScale = (value['danmakuScale'] as num? ?? 1).toDouble();
    final danmakuColor = value['danmakuColor'] as int? ?? 0xFFFFFFFF;
    final preload = value['preload'] as bool? ?? true;
    if (!playbackSpeeds.contains(speed) || quality < 0 || quality > 4320) {
      throw const FormatException('播放偏好无效');
    }
    if (!liveQualityOptions.containsKey(liveQuality)) {
      throw const FormatException('直播默认清晰度无效');
    }
    return PlaybackPreferences(
      speed: speed,
      quality: quality,
      liveQuality: liveQuality,
      autoAdvance: autoAdvance,
      danmaku: danmaku,
      danmakuScale: danmakuScale.clamp(danmakuScaleMin, danmakuScaleMax),
      danmakuColor: danmakuColors.contains(danmakuColor)
          ? danmakuColor
          : 0xFFFFFFFF,
      danmakuOpacity: (value['danmakuOpacity'] as num? ?? 1).toDouble().clamp(
        0.1,
        1.0,
      ),
      danmakuBold: value['danmakuBold'] as bool? ?? true,
      danmakuStroke: (value['danmakuStroke'] as num? ?? 0).toDouble().clamp(
        danmakuStrokeMin,
        danmakuStrokeMax,
      ),
      danmakuShadow: (value['danmakuShadow'] as num? ?? 3).toDouble().clamp(
        danmakuShadowMin,
        danmakuShadowMax,
      ),
      danmakuCoverage:
          DanmakuCoverage.values.asNameMap()[value['danmakuCoverage']] ??
          DanmakuCoverage.half,
      danmakuWords: normalizeDanmakuWords(value['danmakuWords']),
      preload: preload,
      televisionDecoder:
          TelevisionDecoder.values.asNameMap()[value['televisionDecoder']] ??
          TelevisionDecoder.optimized,
      preopen: value['preopen'] as bool?,
      doubleTapSeek: value['doubleTapSeek'] as bool? ?? true,
      swipeLevels: value['swipeLevels'] as bool? ?? true,
      autoPictureInPicture: value['autoPictureInPicture'] as bool? ?? false,
      skipIntroSeconds: skipSecondsOr(value['skipIntroSeconds']),
      skipOutroSeconds: skipSecondsOr(value['skipOutroSeconds']),
      videoFit:
          VideoFitMode.values.asNameMap()[value['videoFit']] ??
          VideoFitMode.contain,
      showClock: value['showClock'] as bool? ?? false,
      showCacheSpeed: value['showCacheSpeed'] as bool? ?? false,
    );
  }
}

List<String> normalizeDanmakuWords(Object? value) {
  if (value is! List) return const [];
  final words = <String>[];
  final keys = <String>{};
  for (final entry in value) {
    if (entry is! String) continue;
    final word = entry.trim();
    if (word.length > danmakuWordLength) continue;
    final key = normalizedSearchText(word);
    if (key.isEmpty || !keys.add(key)) continue;
    words.add(word);
    if (words.length >= danmakuWordLimit) break;
  }
  return List.unmodifiable(words);
}

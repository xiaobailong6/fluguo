import 'core_bridge.dart';
import 'media_pipeline.dart';

String _value(Object? value, [String fallback = '']) =>
    value == null || value == '' || value == 'unknown' || value == 'N/A'
        ? fallback : '$value';

double mediaRotation(MediaProbe probe) {
  final sides = (probe.video['side_data_list'] as List? ?? []).whereType<Map>();
  final raw = sides.where((item) => item['rotation'] != null).firstOrNull?['rotation'] ??
      (probe.video['tags'] as Map?)?['rotate'] ?? 0;
  final value = double.tryParse('$raw') ?? 0;
  return value.isFinite ? (value % 360 + 360) % 360 : 0;
}

/// 比较实际要拼接的首个视频/音频轨，不因封面、字幕或附加数据重编码。
String _videoEncodingFormat(MediaProbe probe) => [
  for (final key in ['codec_name', 'profile', 'width', 'height', 'pix_fmt'])
    _value(probe.video[key]),
  _value(probe.video['sample_aspect_ratio'], '1:1'),
  mediaRotation(probe),
].join('|');
String mergeVideoFormat(MediaProbe probe) =>
    '${_videoEncodingFormat(probe)}|${_value(probe.video['time_base'])}';
String _audioEncodingFormat(MediaProbe probe) => probe.audio.isEmpty ? 'silent' : [
  for (final key in ['codec_name', 'profile', 'sample_rate', 'channels'])
    _value(probe.audio[key]),
  _value(probe.audio['channel_layout'], switch (probe.audio['channels']) {
    1 => 'mono', 2 => 'stereo', _ => '',
  }),
].join('|');
String mergeAudioFormat(MediaProbe probe) => probe.audio.isEmpty ? 'silent' :
    '${_audioEncodingFormat(probe)}|${_value(probe.audio['time_base'], '1/${probe.audio['sample_rate']}')}';
String mergeMediaFormat(MediaProbe probe) =>
    '${mergeVideoFormat(probe)}|${mergeAudioFormat(probe)}';

/// 优先使用有效平均帧率；不把异常的时间戳公倍数当成真实输出帧率。
String? normalizationFrameRate(MediaProbe reference) {
  for (final key in ['avg_frame_rate', 'r_frame_rate']) {
    final raw = _value(reference.video[key]);
    final parts = raw.split('/');
    final numerator = double.tryParse(parts.first);
    final denominator = parts.length == 2 ? double.tryParse(parts.last) : 1.0;
    if (parts.length > 2 || numerator == null || denominator == null || denominator <= 0) continue;
    final fps = numerator / denominator;
    if (fps.isFinite && fps >= 1 && fps <= 120) return raw;
  }
  return null;
}

String normalizationMode(MediaProbe input, MediaProbe reference) {
  final video = _videoEncodingFormat(input) != _videoEncodingFormat(reference);
  final audio = _audioEncodingFormat(input) != _audioEncodingFormat(reference);
  return video && audio ? '转换视频与音频' : video ? '转换视频，复制音频' :
      audio ? '复制视频，转换音频' : '仅调整封装，不重编码';
}

String normalizationSummary(MediaProbe probe) {
  final video = probe.video, audio = probe.audio;
  return '${_value(video['codec_name'], '未知视频')} ${video['width']}×${video['height']} '
      '${_value(video['profile'])}，帧率 ${normalizationFrameRate(probe) ?? '保留原时间戳'}，'
      '视频时间基 ${_value(video['time_base'], '未知')}；'
      '时长 ${probe.duration.toStringAsFixed(1)} 秒，${_value(video['pix_fmt'])}，'
      '${audio.isEmpty ? '无音轨' : '${audio['codec_name']} ${_value(audio['profile'])} ${audio['sample_rate']}Hz ${audio['channels']}声道'}';
}

String normalizationMismatch(MediaProbe actual, MediaProbe target) {
  final differences = <String>[];
  for (final key in ['codec_name', 'profile', 'width', 'height', 'pix_fmt', 'time_base']) {
    if (_value(actual.video[key]) != _value(target.video[key])) {
      differences.add('视频$key：${actual.video[key]} → ${target.video[key]}');
    }
  }
  if (_value(actual.video['sample_aspect_ratio'], '1:1') != _value(target.video['sample_aspect_ratio'], '1:1')) {
    differences.add('像素宽高比：${actual.video['sample_aspect_ratio']} → ${target.video['sample_aspect_ratio']}');
  }
  if (mediaRotation(actual) != mediaRotation(target)) differences.add('画面方向不一致');
  if (mergeAudioFormat(actual) != mergeAudioFormat(target)) {
    differences.add('音频格式：${mergeAudioFormat(actual)} → ${mergeAudioFormat(target)}');
  }
  return differences.join('；');
}

/// 只编码不相同的轨道，编码目标取多数分集而非另造统一规格。
List<String> normalizationArguments(
  String source, String output, MediaProbe reference, {required MediaProbe input}
) {
  // 时间基由 MP4 muxer 调整，不为容器元数据差异重编码视频或音频。
  final copyVideo = _videoEncodingFormat(input) == _videoEncodingFormat(reference);
  final copyAudio = _audioEncodingFormat(input) == _audioEncodingFormat(reference);
  final video = reference.video;
  final audio = reference.audio;
  final silence = audio.isNotEmpty && input.audio.isEmpty;
  final codec = _value(video['codec_name']);
  final encoder = switch (codec) {
    'h264' => 'libx264', 'hevc' => 'libx265', 'mpeg4' => 'mpeg4', _ => '',
  };
  if (!copyVideo && encoder.isEmpty) {
    throw AppFailure('目标视频编码 $codec 暂不支持单集转换，原文件已保留');
  }
  final audioCodec = _value(audio['codec_name']);
  final audioEncoder = switch (audioCodec) {
    'aac' => 'aac', 'mp3' => 'libmp3lame', 'ac3' => 'ac3',
    'eac3' => 'eac3', 'opus' => 'libopus', 'alac' => 'alac', 'flac' => 'flac', _ => '',
  };
  if (audio.isNotEmpty && !copyAudio && audioEncoder.isEmpty) {
    throw AppFailure('目标音频编码 $audioCodec 暂不支持单集转换，原文件已保留');
  }
  if (!copyAudio && audioCodec == 'aac' &&
      _value(audio['profile']) != 'LC') {
    throw AppFailure('目标音频为 ${audio['profile']}，当前 AAC 编码器不能可靠生成同规格音轨；'
        '已停止转换并保留原文件。输入：${normalizationSummary(input)}；目标：${normalizationSummary(reference)}');
  }
  final width = video['width'], height = video['height'];
  if (!copyVideo && (width is! int || height is! int || width <= 0 || height <= 0)) {
    throw AppFailure('目标分集画面尺寸无效，不能转换');
  }
  final rate = normalizationFrameRate(reference);
  final timeBase = _value(video['time_base']).split('/');
  final timescale = timeBase.length == 2 && timeBase[0] == '1'
      ? int.tryParse(timeBase[1]) : null;
  if (!copyVideo && (timescale == null || timescale <= 0)) {
    throw AppFailure('目标视频时间基 ${video['time_base']} 不可可靠复现，原文件已保留');
  }
  final profile = _value(video['profile']).toLowerCase();
  final videoProfile = switch (profile) {
    'constrained baseline' || 'baseline' => 'baseline', 'main' => 'main',
    'high' => 'high', 'high 10' => 'high10', 'main 10' => 'main10', _ => '',
  };
  if (!copyVideo && (codec == 'h264' || codec == 'hevc') && videoProfile.isEmpty) {
    throw AppFailure('目标视频 profile ${video['profile']} 暂不支持可靠匹配，原文件已保留');
  }
  final sampleRate = _value(audio['sample_rate'], '48000');
  final channels = _value(audio['channels'], '2');
  final layout = _value(audio['channel_layout'], channels == '1' ? 'mono' : 'stereo');
  final rotation = ((mediaRotation(reference) - mediaRotation(input)) % 360 + 360) % 360;
  final orient = switch (rotation.round()) {
    90 => 'transpose=clock,', 180 => 'hflip,vflip,',
    270 => 'transpose=cclock,', 0 => '',
    _ => throw AppFailure('非直角旋转暂不支持单集转换，原文件已保留'),
  };
  return [
    '-threads', '2', '-noautorotate', '-i', source,
    if (silence) ...['-f', 'lavfi', '-i', 'anullsrc=r=$sampleRate:cl=$layout'],
    '-map', '0:v:0',
    if (audio.isNotEmpty) ...['-map', silence ? '1:a:0' : '0:a:0'],
    '-c:v', copyVideo ? 'copy' : encoder,
    if (!copyVideo) ...[
      '-threads', '2', '-filter_threads', '1',
      '-vf', '${orient}scale=$width:$height:force_original_aspect_ratio=decrease:force_divisible_by=2,'
          'pad=$width:$height:(ow-iw)/2:(oh-ih)/2,'
          'setsar=${_value(video['sample_aspect_ratio'], '1:1').replaceAll(':', '/')}',
      if (rate != null) ...['-r', rate] else ...['-fps_mode', 'passthrough'],
      if (codec == 'h264' || codec == 'hevc') ...['-preset', 'veryfast', '-crf', '20'],
      if (codec == 'hevc') ...['-x265-params', 'pools=2:frame-threads=2'],
      if (videoProfile.isNotEmpty && (codec == 'h264' || codec == 'hevc'))
        ...['-profile:v', videoProfile],
      '-pix_fmt', _value(video['pix_fmt'], 'yuv420p'),
      for (final entry in const {
        'color_range': '-color_range', 'color_space': '-colorspace',
        'color_transfer': '-color_trc', 'color_primaries': '-color_primaries',
      }.entries)
        if (_value(video[entry.key]).isNotEmpty) ...[entry.value, '${video[entry.key]}'],
    ],
    if (timescale != null && timescale > 0) ...['-video_track_timescale', '$timescale'],
    if (audio.isNotEmpty) ...[
      '-c:a', copyAudio ? 'copy' : audioEncoder,
      if (!copyAudio) ...[
        '-ar', sampleRate, '-ac', channels,
        '-channel_layout', layout,
        if (audioCodec == 'aac') ...['-profile:a', 'aac_low'],
        if (input.duration.isFinite && input.duration > 0) ...['-af', 'apad'],
      ],
    ],
    if (input.duration.isFinite && input.duration > 0) ...['-t', '${input.duration}'],
    '-map_metadata', '-1', '-metadata:s:v:0', 'rotate=${mediaRotation(reference)}',
    '-f', 'mp4', output,
  ];
}

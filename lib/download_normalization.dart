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
String mergeVideoFormat(MediaProbe probe) => [
  for (final key in ['codec_name', 'profile', 'width', 'height', 'pix_fmt', 'time_base'])
    _value(probe.video[key]),
  _value(probe.video['sample_aspect_ratio'], '1:1'),
  mediaRotation(probe),
].join('|');
String mergeAudioFormat(MediaProbe probe) => probe.audio.isEmpty ? 'silent' : [
  for (final key in ['codec_name', 'profile', 'sample_rate', 'channels', 'time_base'])
    _value(probe.audio[key]),
  _value(probe.audio['channel_layout'], switch (probe.audio['channels']) {
    1 => 'mono', 2 => 'stereo', _ => '',
  }),
].join('|');
String mergeMediaFormat(MediaProbe probe) =>
    '${mergeVideoFormat(probe)}|${mergeAudioFormat(probe)}';

/// 只编码不相同的轨道，编码目标取多数分集而非另造统一规格。
List<String> normalizationArguments(
  String source, String output, MediaProbe reference, {required MediaProbe input}
) {
  final copyVideo = mergeVideoFormat(input) == mergeVideoFormat(reference);
  final copyAudio = mergeAudioFormat(input) == mergeAudioFormat(reference);
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
  final width = video['width'], height = video['height'];
  if (!copyVideo && (width is! int || height is! int || width <= 0 || height <= 0)) {
    throw AppFailure('目标分集画面尺寸无效，不能转换');
  }
  final rate = _value(video['r_frame_rate'], _value(video['avg_frame_rate'], '25/1'));
  final timeBase = _value(video['time_base']).split('/');
  final timescale = timeBase.length == 2 && timeBase[0] == '1'
      ? int.tryParse(timeBase[1]) : null;
  final profile = _value(video['profile']).toLowerCase();
  final videoProfile = switch (profile) {
    'constrained baseline' || 'baseline' => 'baseline', 'main' => 'main',
    'high' => 'high', 'high 10' => 'high10', 'main 10' => 'main10', _ => '',
  };
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
      '-r', rate,
      if (codec == 'h264' || codec == 'hevc') ...['-preset', 'veryfast', '-crf', '20'],
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
        if (audioCodec == 'aac') ...['-profile:a', switch (_value(audio['profile'])) {
          'HE-AAC' => 'aac_he', 'HE-AACv2' => 'aac_he_v2', _ => 'aac_low',
        }],
        if (input.duration.isFinite && input.duration > 0) ...['-af', 'apad'],
      ],
    ],
    if (input.duration.isFinite && input.duration > 0) ...['-t', '${input.duration}'],
    '-map_metadata', '-1', '-metadata:s:v:0', 'rotate=${mediaRotation(reference)}',
    '-f', 'mp4', output,
  ];
}

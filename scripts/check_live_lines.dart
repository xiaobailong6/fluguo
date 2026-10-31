import 'dart:convert';
import 'dart:io';

import '../lib/live_bilibili.dart';
import '../lib/live_douyu.dart';
import '../lib/live_huya.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void checkLiveLineParsers() {
  Map<String, dynamic> codec(int quality, String host) => {
    'protocol_name': 'http_stream',
    'format': [
      {
        'format_name': 'flv',
        'codec': [
          {
            'codec_name': 'avc',
            'current_qn': quality,
            'base_url': '/stream.flv?',
            'url_info': [
              {'host': host, 'extra': 'token=fresh'},
              {'host': host, 'extra': 'token=fresh'},
            ],
          },
        ],
      },
    ],
  };
  final bili = BilibiliLive.parsePlayStream({
    'code': 0,
    'data': {
      'playurl_info': {
        'playurl': {
          'stream': [
            codec(150, 'https://one.test'),
            codec(150, 'https://two.test'),
            codec(80, 'https://low.test'),
          ],
        },
      },
    },
  }, requestedQuality: 150);
  check(
    bili.lines.length == 2,
    'bilibili lost routes or failed to deduplicate',
  );
  check(
    bili.lines.every((line) => !line.url.contains('low.test')),
    'bilibili mixed quality into routes',
  );
  final stream = LiveStream(
    url: bili.url,
    quality: bili.quality,
    qualityId: bili.qualityId,
    headers: const {'Referer': 'https://live.test'},
    lines: bili.lines,
    lineId: bili.lines.first.id,
    renewAfter: const Duration(minutes: 1),
  );
  final switched = stream.selectLine(bili.lines.last.id);
  check(
    switched.url.contains('two.test') && switched.qualityId == 150,
    'line switching changed quality',
  );
  check(
    switched.headers['Referer'] == 'https://live.test' &&
        switched.renewAfter == stream.renewAfter,
    'switch lost headers/expiry',
  );
  check(
    identical(stream.selectLine('removed'), stream),
    'removed route must fall back to current platform result',
  );

  final douyu = DouyuLive.parseLines({
    'cdnsWithName': [
      {'cdn': 'a', 'name': '线路一'},
      {'cdn': 'a', 'name': '重复'},
      {'cdn': 'b', 'name': '线路二'},
      {},
      null,
    ],
  });
  check(
    douyu.length == 2 && douyu.last.id == 'b',
    'douyu CDN descriptors invalid',
  );
  check(
    douyu.every((line) => line.url.isEmpty),
    'douyu descriptor fabricated media URLs',
  );

  final now = DateTime.fromMillisecondsSinceEpoch(1000000);
  final anti = Uri(
    queryParameters: {
      'fm': base64Encode(utf8.encode(r'prefix_$0_$1_$2_$3')),
      'wsTime': 1300.toRadixString(16),
      'ctype': 'huya_webh5',
      't': '100',
    },
  ).query;
  Map<String, Object> line(String cdn, {String? signature}) => {
    'sCdnType': cdn,
    'sFlvUrl': 'https://$cdn.test/live',
    'sStreamName': 'room',
    'sFlvUrlSuffix': 'flv',
    'sFlvAntiCode': signature ?? anti,
  };
  final huya = HuyaLive.parseStream(
    {
      'data': [
        {
          'gameStreamInfoList': [
            line('a'),
            line('broken', signature: 'fm=not-base64'),
            line('b'),
            line('a'),
          ],
        },
      ],
      'vMultiStreamInfo': [
        {'iCodecType': 0, 'iBitRate': 0, 'sDisplayName': '原画'},
        {'iCodecType': 0, 'iBitRate': 2000, 'sDisplayName': '高清'},
      ],
    },
    quality: 150,
    at: now,
    viewer: 12345,
  );
  check(
    huya.lines.length == 2 && huya.qualityId == 150,
    'huya routes/quality parsing failed',
  );
  check(
    huya.lines.every(
      (line) => Uri.parse(line.url).queryParameters['ratio'] == '2000',
    ),
    'huya route quality mismatch',
  );
  check(
    huya.lines.every(
      (line) => !Uri.parse(line.url).queryParameters.containsKey('fm'),
    ),
    'huya raw signature template leaked',
  );
  check(huya.selectLine('b').lineId == 'b', 'huya route selection failed');
  check(
    const LiveStream(url: 'single', quality: '默认', headers: {}).lines.isEmpty,
    'single route platform changed',
  );
  print(
    'PASS live route parsers / deduplication / quality isolation / signatures / selection',
  );
}

Future<bool> mediaPrefix(LiveStream stream) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(Uri.parse(stream.url));
    stream.headers.forEach((key, value) => request.headers.set(key, value));
    final response = await request.close().timeout(const Duration(seconds: 15));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      bytes.addAll(chunk.take(16 - bytes.length));
      if (bytes.length >= 16) break;
    }
    final prefix = String.fromCharCodes(bytes);
    return response.statusCode == 200 &&
        (prefix.startsWith('FLV') || prefix.startsWith('#EXTM3U'));
  } finally {
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  checkLiveLineParsers();
  if (!args.contains('--network')) return;
  var failures = 0;
  for (final platform in livePlatforms.where(
    (entry) => ['bilibili', 'douyu', 'huya'].contains(entry.id),
  )) {
    try {
      final groups = await platform.categories();
      final area = groups
          .firstWhere((entry) => entry.children.isNotEmpty)
          .children
          .first;
      final rooms = await platform.rooms(area);
      final room = rooms.first;
      final stream = await platform.resolveLine(room);
      check(
        await mediaPrefix(stream),
        '${platform.name} default stream has no FLV/HLS signature',
      );
      print(
        'PASS ${platform.name} room=${room.roomId} quality=${stream.quality} lines=${stream.lines.length} default media',
      );
      if (stream.lines.length > 1) {
        final target = stream.lines[1];
        final changed = await platform.resolveLine(
          room,
          quality: stream.qualityId,
          line: target.id,
        );
        check(
          changed.lineId == target.id,
          '${platform.name} did not apply selected line',
        );
        check(
          await mediaPrefix(changed),
          '${platform.name} alternate stream invalid',
        );
        print(
          'PASS ${platform.name} alternate line, quality=${changed.quality}',
        );
      }
    } catch (error) {
      failures++;
      // 不输出含临时签名的 URL。
      print('UNVERIFIED ${platform.name}: ${error.runtimeType}');
    }
  }
  if (failures > 0) exitCode = 1;
}

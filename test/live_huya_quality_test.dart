import 'dart:convert';

import 'package:duanju_app/live_huya.dart';
import 'package:duanju_app/live_models.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.fromMillisecondsSinceEpoch(1000000);

Map<String, Object?> _rate(Object? bitRate, String label, {int codec = 0}) => {
  'iCodecType': codec,
  'iBitRate': bitRate,
  'sDisplayName': label,
};

// 固定签名时间并预置旧 ratio，所有档位都必须重新应用真实码率。
Map<String, dynamic> _stream(Object? rates) => {
  'data': [
    {
      'gameStreamInfoList': [
        for (final cdn in ['a', 'b'])
          {
            'sCdnType': cdn,
            'sFlvUrl': 'https://$cdn.test/live',
            'sStreamName': 'room',
            'sFlvUrlSuffix': 'flv',
            'sFlvAntiCode': Uri(
              queryParameters: {
                'fm': base64Encode(utf8.encode(r'prefix_$0_$1_$2_$3')),
                'wsTime': 1100.toRadixString(16),
                'ctype': 'huya_webh5',
                't': '100',
                'ratio': '9999',
              },
            ).query,
          },
      ],
    },
  ],
  'vMultiStreamInfo': rates,
};

LiveStream _parse(Object? rates, {int quality = 0, DateTime? at}) =>
    HuyaLive.parseStream(
      _stream(rates),
      quality: quality,
      viewer: 12345,
      at: at ?? _now,
    );

void _expectSelection(LiveStream stream, int bitRate, String label) {
  expect(stream.qualityId, -bitRate - 1);
  expect(stream.quality, label);
  expect(
    stream.qualities
        .where((entry) => entry.id == stream.qualityId)
        .single
        .label,
    label,
  );
  expect(stream.lines, hasLength(2));
  for (final line in stream.lines) {
    final fields = Uri.parse(line.url).queryParameters;
    if (bitRate == 0) {
      expect(fields, isNot(contains('ratio')));
    } else {
      expect(fields['ratio'], '$bitRate');
    }
  }
}

void main() {
  test('同语义甚至同名的真实码率全部保留，仅按码率去重', () {
    final rates = [
      _rate(6000, '蓝光'),
      _rate(3000, '蓝光'),
      _rate(6000, '重复码率'),
      _rate('3000', '重复字符串码率'),
      _rate(0, '原画'),
      _rate(0, '重复原画'),
      _rate(2000, '高清'),
      _rate(1000, '高清'),
    ];
    final stream = _parse(rates);
    expect(stream.qualities.map((entry) => entry.id), [
      -6001,
      -3001,
      -1,
      -2001,
      -1001,
    ]);
    expect(stream.qualities.map((entry) => entry.label), [
      '蓝光',
      '蓝光',
      '原画',
      '高清',
      '高清',
    ]);
    _expectSelection(_parse(rates, quality: 400), 6000, '蓝光');
    _expectSelection(_parse(rates, quality: -3001), 3000, '蓝光');
  });

  final preferences = <int, (int, String)>{
    0: (0, '原画'),
    10000: (0, '原画'),
    400: (6000, '蓝光'),
    250: (3000, '超清'),
    150: (2000, '高清'),
    80: (500, '流畅'),
  };
  for (final preference in preferences.entries) {
    test('默认偏好 ${preference.key} 保持旧语义，不当作原生 rate', () {
      // 故意放在最前，确保与全局代码同值的原生码率不会抢占偏好。
      final rates = [
        if (preference.key != 0) _rate(preference.key, '其它画质'),
        _rate(500, '流畅'),
        _rate(2000, '高清'),
        _rate(3000, '超清'),
        _rate(6000, '蓝光'),
        _rate(0, '原画'),
      ];
      final (bitRate, label) = preference.value;
      // 未知标签旧映射也属于超清，使用明确的不同语义避免改变此旧规则。
      if (preference.key == 250) rates[0] = _rate(250, '高清');
      _expectSelection(_parse(rates, quality: preference.key), bitRate, label);
      if (preference.key != 0) {
        _expectSelection(
          _parse(rates, quality: -preference.key - 1),
          preference.key,
          preference.key == 250 ? '高清' : '其它画质',
        );
      }
    });
  }

  test('整数字符串码率保留身份，标签空白不影响原画/标清旧语义', () {
    final rates = [_rate('1500', ' 标清 '), _rate('0', ' 原画 ')];
    _expectSelection(_parse(rates, quality: 80), 1500, '标清');
    _expectSelection(_parse(rates, quality: 10000), 0, '原画');
  });

  test('页面传回负 ID 可精确选择，刷新/切线后仍保持同一真实码率', () {
    final initial = _parse([
      _rate(6000, '蓝光'),
      _rate(3000, '蓝光'),
      _rate(0, '原画'),
    ]);
    final selectedId = initial.qualities[1].id;
    final selected = _parse([
      _rate(6000, '蓝光'),
      _rate(3000, '蓝光'),
      _rate(0, '原画'),
    ], quality: selectedId);
    _expectSelection(selected, 3000, '蓝光');
    final renewed = _parse(
      [_rate(3000, '蓝光 3M'), _rate(6000, '蓝光 6M'), _rate(0, '原画')],
      quality: selected.qualityId,
      at: _now.add(const Duration(seconds: 10)),
    );
    _expectSelection(renewed, 3000, '蓝光 3M');
    expect(renewed.url, isNot(selected.url));
    expect(renewed.renewAfter, const Duration(seconds: 60));
    final switched = renewed.selectLine('b');
    _expectSelection(switched, 3000, '蓝光 3M');
    expect(switched.lineId, 'b');
    expect(switched.headers, renewed.headers);
    expect(switched.renewAfter, renewed.renewAfter);
  });

  test('精确档位消失时回退实际原画，不用同语义档位冒充', () {
    final stream = _parse([_rate(6000, '蓝光'), _rate(0, '原画')], quality: -3001);
    _expectSelection(stream, 0, '原画');
    expect(stream.qualities.map((entry) => entry.id), isNot(contains(-3001)));
  });

  test('无原画时缺失 ID/偏好回退首个真实档位，不凭空生成原画', () {
    final rates = [_rate(2000, '高清'), _rate(6000, '蓝光')];
    for (final request in [0, 10000, 80, -1, -3001, -999999]) {
      final stream = _parse(rates, quality: request);
      _expectSelection(stream, 2000, '高清');
      expect(stream.qualities.map((entry) => entry.id), [-2001, -6001]);
    }
  });

  test('缺失语义偏好或未知正值不视作真实码率，回退原画', () {
    final rates = [_rate(2000, '高清'), _rate(0, '原画')];
    for (final request in [400, 250, 80, 2000, 999]) {
      _expectSelection(_parse(rates, quality: request), 0, '原画');
    }
  });

  test('匿名模式过滤 HDR/4K/不支持的编码，受限档位不占用重复 rate', () {
    final rates = [
      _rate(0, '4K'),
      _rate(9000, ' 4k会员 '),
      _rate(8000, 'HDR'),
      _rate(7000, 'hdr 超清'),
      _rate(6000, '蓝光', codec: 1),
      _rate(6000, '蓝光'),
      _rate(0, '原画'),
    ];
    final stream = _parse(rates);
    expect(stream.qualities.map((entry) => entry.id), [-6001, -1]);
    _expectSelection(_parse(rates, quality: 400), 6000, '蓝光');
    _expectSelection(_parse(rates, quality: -9001), 0, '原画');
  });

  test('只有明确受限的 4K 时禁止用原画回退重新提供它', () {
    for (final rates in [
      [_rate(0, '4K')],
      [_rate(10000, '4K会员')],
      [_rate(0, '4K HDR'), _rate(-1, '无效'), null],
      [_rate(0, '4K', codec: 1)],
    ]) {
      for (final quality in [0, 10000, 400, -1, -10001]) {
        expect(() => _parse(rates, quality: quality), throwsStateError);
      }
    }
  });

  test('4K 被过滤且没有原画时，回退已存在的普通档位', () {
    final stream = _parse([_rate(0, '4K'), _rate(2000, '高清')], quality: 10000);
    _expectSelection(stream, 2000, '高清');
    expect(stream.qualities.single.id, -2001);
  });

  test('负数/小数/缺失及异常 rate 被拒绝，不能变成原画或正语义 ID', () {
    final stream = _parse([
      for (final invalid in [
        -1,
        -400,
        '-150',
        null,
        '',
        'invalid',
        true,
        1.5,
        -0.5,
        '2.5',
        double.nan,
        double.infinity,
        <String, Object>{},
      ])
        _rate(invalid, '原画'),
      {'iCodecType': 0, 'sDisplayName': '缺少码率'},
      null,
      123,
      _rate(3000, '   '),
      _rate(2000, '高清'),
    ]);
    expect(stream.qualities.single.id, -2001);
    _expectSelection(stream, 2000, '高清');
  });

  test('无有效档位且没有明确受限 4K 时只回退原画', () {
    for (final rates in [
      null,
      <Object?>[],
      <String, Object>{},
      [_rate(-1, '无效'), _rate(null, '未知')],
      [_rate(5000, 'HDR'), _rate(4000, '蓝光', codec: 1)],
    ]) {
      final stream = _parse(rates, quality: -2001);
      expect(stream.qualities.single.id, -1);
      _expectSelection(stream, 0, '原画');
    }
  });

  test('原画去除旧 ratio，保留网页签名、headers 和 renewAfter 契约', () {
    final rates = [_rate(0, '原画'), _rate(2000, '高清')];
    final stream = _parse(rates, quality: -1);
    _expectSelection(stream, 0, '原画');
    expect(stream.headers, HuyaLive.headers);
    expect(stream.headers['Referer'], '${HuyaLive.origin}/');
    expect(stream.renewAfter, const Duration(seconds: 70));
    for (final line in stream.lines) {
      final fields = Uri.parse(line.url).queryParameters;
      expect(fields['codec'], '264');
      expect(fields['wsTime'], 1100.toRadixString(16));
      expect(fields['ctype'], 'huya_webh5');
      expect(fields['wsSecret'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(fields, isNot(contains('fm')));
    }
    _expectSelection(_parse(rates, quality: -2001), 2000, '高清');
  });
}

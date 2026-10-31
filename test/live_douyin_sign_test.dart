import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:duanju_app/live_douyin_sign.dart';
import 'package:flutter_test/flutter_test.dart';

const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const _fingerprint =
    '1440|900|1464|975|0|30|0|0|1920|1080|1920|1040|1440|900|24|24|Win32';
const _query =
    'aid=6383&browser_name=Edge&browser_version=125.0.0.0&'
    'keyword=%E6%B5%8B%E8%AF%95&dup=1&dup=2&token=a%2Bb%2F%3D&'
    'space=a+b&blank=';

String _hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

String _sign({String query = _query, String userAgent = _userAgent}) {
  var tick = 1700000000123;
  return signDouyinQuery(
    query,
    userAgent: userAgent,
    random: _FixtureRandom(),
    nowMilliseconds: () {
      final value = tick;
      tick += 7;
      return value;
    },
    browserFingerprint: _fingerprint,
  );
}

String _signature(String signed) => signed.split('a_bogus=').last;

void main() {
  group('standalone SM3', () {
    test('published abc and abcd x16 vectors', () {
      expect(
        _hex(douyinSm3(utf8.encode('abc'))),
        '66c7f0f462eeedd9d1f2d46bdc10e4e2'
        '4167c4875cf2f7a2297da02b8f4ba8e0',
      );
      expect(
        _hex(douyinSm3(utf8.encode('abcd' * 16))),
        'debe9ff92275b8a138604889c18e5a4d'
        '6fdb70e5387e5765293dcba39c0c5732',
      );
    });

    // Independently computed with Python hashlib/OpenSSL SM3, covering both
    // padding branches, block boundaries, arbitrary binary input and chaining.
    const vectors = <int, String>{
      0: '1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b',
      55: 'a79cf9dcee3404abf7f769698201647fd9d3ff61d629d0f58bb4b5579a427db8',
      56: '62f7363b15f4de76dd925c493b9d6d00d4ba0ef2a1f334c1d0f13b293aeb40d1',
      63: '6165e4cbb15cde01c6226e0015a47f710f8f8e1f2c296700033bb34d9212109c',
      64: '93566f236d157aae078d1ddb5cebdbba1520b5142e22a8915564345ba2ae1d63',
      65: 'c886e6814be748285a10b28ae62ddacd85db830cd2cf3a2bfa2f729c15f63618',
      128: 'a9e7985473ca09df1510d83b572f72375430756c4a661b00724afeb8b75dd0a5',
      1024: '1f00bad6a72e851e0f6e94fd317f97b74d5fbc4c090aefb91e7554e3f9c8c7fb',
    };
    for (final vector in vectors.entries) {
      test('binary input length ${vector.key}', () {
        final input = List<int>.generate(vector.key, (i) => i % 256);
        final before = List<int>.of(input);
        expect(_hex(douyinSm3(input)), vector.value);
        expect(input, before);
      });
    }
  });

  group('Douyin query signing', () {
    test('matches independent reference algorithm fixture', () {
      // Python port of the complete reference abogus.dart, using hashlib SM3,
      // its original two sort orders and permutation; fixed prefix draws are
      // 1234, 5678, 9012 and clock samples differ by 7 ms. Compare a digest so
      // test failures never print a complete signed query/URL.
      expect(
        sha256.convert(utf8.encode(_sign())).toString(),
        '4392ace280c87bbcebfa1bd4c2739b3040508522fc49d82c0bff39d2c666c0f5',
      );
      expect(_signature(_sign()).length, 168);
    });

    test('preserves original query bytes, duplicates and encoding', () {
      final signed = _sign();
      expect(signed.startsWith('$_query&a_bogus='), isTrue);
      expect(RegExp(r'(^|&)a_bogus=').allMatches(signed).length, 1);
      expect(
        RegExp(r'^[A-Za-z0-9/\-]+={0,2}$').hasMatch(_signature(signed)),
        isTrue,
      );
    });

    test('binds signature to the exact UA and exact encoded query', () {
      final original = _signature(_sign());
      expect(
        _signature(_sign(userAgent: '$_userAgent Edg/125.0.0.0')) == original,
        isFalse,
      );
      for (final query in [
        _query.replaceFirst('dup=1&dup=2', 'dup=2&dup=1'),
        _query.replaceFirst('a+b', 'a%20b'),
        _query.replaceFirst('%2B', '%2b'),
        '$_query&extra=1',
      ]) {
        expect(_signature(_sign(query: query)) == original, isFalse);
      }
    });

    test('requests do not share mutated cipher state', () {
      final firstDigest = sha256.convert(utf8.encode(_sign())).toString();
      _sign(query: 'aid=6383&other=1');
      expect(sha256.convert(utf8.encode(_sign())).toString(), firstDigest);
    });

    test('generated fingerprint and randomness can also be deterministic', () {
      String generate() => signDouyinQuery(
        _query,
        userAgent: _userAgent,
        random: Random(42),
        nowMilliseconds: () => 1700000000123,
      );
      expect(
        sha256.convert(utf8.encode(generate())).toString(),
        sha256.convert(utf8.encode(generate())).toString(),
      );
      final changedTime = signDouyinQuery(
        _query,
        userAgent: _userAgent,
        random: Random(42),
        nowMilliseconds: () => 1700000000124,
      );
      expect(_signature(changedTime) == _signature(generate()), isFalse);
      final changedRandom = signDouyinQuery(
        _query,
        userAgent: _userAgent,
        random: Random(43),
        nowMilliseconds: () => 1700000000123,
      );
      expect(_signature(changedRandom) == _signature(generate()), isFalse);
    });

    test(
      'default entropy and clock produce a signature without dependencies',
      () {
        final signed = signDouyinQuery('aid=6383', userAgent: _userAgent);
        expect(signed.startsWith('aid=6383&a_bogus='), isTrue);
        expect(_signature(signed).length, greaterThan(100));
      },
    );

    test(
      'empty query has no leading separator; trailing bytes are preserved',
      () {
        expect(_sign(query: '').startsWith('a_bogus='), isTrue);
        expect(_sign(query: 'x=1&').startsWith('x=1&&a_bogus='), isTrue);
      },
    );

    test('rejects missing UA and accidental re-signing', () {
      expect(() => _sign(userAgent: ''), throwsArgumentError);
      expect(() => _sign(query: 'x=1&a_bogus=old'), throwsArgumentError);
      expect(() => _sign(query: 'a_bogus=old'), throwsArgumentError);
    });
  });
}

class _FixtureRandom implements Random {
  var _index = 0;

  @override
  int nextInt(int max) {
    if (max != 10000) throw StateError('Unexpected random bound');
    return [1234, 5678, 9012][_index++];
  }

  @override
  bool nextBool() => throw UnsupportedError('Not used');

  @override
  double nextDouble() => throw UnsupportedError('Not used');
}

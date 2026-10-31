// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from Pure Live: live/lib/shared/platforms/douyin/abogus.dart.
// The reference has no per-file author notice; its repository LICENSE is the
// GNU Affero General Public License v3: https://www.gnu.org/licenses/agpl-3.0.html
// This standalone adaptation retains its alphabets, permutation, byte layout
// and timestamp semantics. SM3 below is implemented from the SM3 specification;
// no dart_sm, Flutter, GetX or Pure Live runtime dependency is required.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Signs the exact, already encoded, unsigned GET [query] for Douyin webcast.
///
/// Send [userAgent] unchanged in the HTTP User-Agent header. This function does
/// not infer it from browser_name/browser_version: the reference production UA
/// is Chrome 134 while those query fields identify Edge 125.
/// Append the returned string as a raw URL query; do not rebuild it with
/// Uri.queryParameters, decode it, or add/change parameters after signing.
/// [random], [nowMilliseconds] and [browserFingerprint] allow offline fixtures.
String signDouyinQuery(
  String query, {
  required String userAgent,
  Random? random,
  int Function()? nowMilliseconds,
  String? browserFingerprint,
}) {
  if (userAgent.isEmpty) {
    throw ArgumentError.value(userAgent, 'userAgent', 'Must not be empty');
  }
  if (RegExp(r'(^|&)a_bogus=').hasMatch(query)) {
    throw ArgumentError('query must not already contain a_bogus');
  }
  final entropy = random ?? Random.secure();
  final fingerprint = browserFingerprint ?? _fingerprint(entropy);
  final clock = nowMilliseconds ?? () => DateTime.now().millisecondsSinceEpoch;
  final start = clock();
  final paramsHash = douyinSm3(douyinSm3(utf8.encode('${query}cus')));
  final bodyHash = douyinSm3(douyinSm3(utf8.encode('cus')));
  final uaHash = douyinSm3(utf8.encode(_encode(_rc4(userAgent), _uaAlphabet)));
  final end = clock();

  // Only serialized fields are retained from the reference's configuration map.
  // Its jsShiftRight masks to 32 bits BEFORE shifting by 32/40, producing zero
  // in Dart. Preserve that behavior instead of silently changing the protocol.
  final fields = <int, int>{
    18: 44,
    20: (start >> 24) & 255,
    21: (start >> 16) & 255,
    22: (start >> 8) & 255,
    23: start & 255,
    24: 0,
    25: 0,
    26: 0,
    27: 0,
    28: 0,
    29: 0,
    30: 0,
    31: 1,
    32: 0,
    33: 0,
    34: 0,
    35: 0,
    36: 0,
    37: 14,
    38: paramsHash[21],
    39: paramsHash[22],
    40: bodyHash[21],
    41: bodyHash[22],
    42: uaHash[23],
    43: uaHash[24],
    44: (end >> 24) & 255,
    45: (end >> 16) & 255,
    46: (end >> 8) & 255,
    47: end & 255,
    48: 3,
    49: 0,
    50: 0,
    52: 0,
    53: 0,
    54: 0,
    55: 0,
    57: 6383 & 255,
    58: (6383 >> 8) & 255,
    59: 0,
    60: 0,
    65: fingerprint.length,
    66: 0,
    70: 0,
    71: 0,
  };
  // Both reference orderings cover the same fields; XOR is order independent.
  var checksum = 0;
  for (final value in fields.values) {
    checksum ^= value;
  }
  final payload = <int>[
    for (final index in _fieldOrder) fields[index]!,
    ...fingerprint.codeUnits,
    checksum,
  ];
  final prefix = <int>[];
  for (var i = 0; i < 3; i++) {
    final value = entropy.nextInt(10000);
    prefix.addAll([
      ((value & 255) & 170) | 1,
      ((value & 255) & 85) | 2,
      (((value & 0xffffffff) >>> 8) & 170) | 5,
      (((value & 0xffffffff) >>> 8) & 85) | 40,
    ]);
  }
  final signature = _encode([...prefix, ..._transform(payload)], _alphabet);
  return '${query.isEmpty ? '' : '$query&'}a_bogus=$signature';
}

const _alphabet =
    'Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe';
const _uaAlphabet =
    'ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe';
const _fieldOrder = <int>[
  18,
  20,
  52,
  26,
  30,
  34,
  58,
  38,
  40,
  53,
  42,
  21,
  27,
  54,
  55,
  31,
  35,
  57,
  39,
  41,
  43,
  22,
  28,
  32,
  60,
  36,
  23,
  29,
  33,
  37,
  44,
  45,
  59,
  46,
  47,
  48,
  49,
  50,
  24,
  25,
  65,
  66,
  70,
  71,
];
const _permutation = <int>[
  121,
  243,
  55,
  234,
  103,
  36,
  47,
  228,
  30,
  231,
  106,
  6,
  115,
  95,
  78,
  101,
  250,
  207,
  198,
  50,
  139,
  227,
  220,
  105,
  97,
  143,
  34,
  28,
  194,
  215,
  18,
  100,
  159,
  160,
  43,
  8,
  169,
  217,
  180,
  120,
  247,
  45,
  90,
  11,
  27,
  197,
  46,
  3,
  84,
  72,
  5,
  68,
  62,
  56,
  221,
  75,
  144,
  79,
  73,
  161,
  178,
  81,
  64,
  187,
  134,
  117,
  186,
  118,
  16,
  241,
  130,
  71,
  89,
  147,
  122,
  129,
  65,
  40,
  88,
  150,
  110,
  219,
  199,
  255,
  181,
  254,
  48,
  4,
  195,
  248,
  208,
  32,
  116,
  167,
  69,
  201,
  17,
  124,
  125,
  104,
  96,
  83,
  80,
  127,
  236,
  108,
  154,
  126,
  204,
  15,
  20,
  135,
  112,
  158,
  13,
  1,
  188,
  164,
  210,
  237,
  222,
  98,
  212,
  77,
  253,
  42,
  170,
  202,
  26,
  22,
  29,
  182,
  251,
  10,
  173,
  152,
  58,
  138,
  54,
  141,
  185,
  33,
  157,
  31,
  252,
  132,
  233,
  235,
  102,
  196,
  191,
  223,
  240,
  148,
  39,
  123,
  92,
  82,
  128,
  109,
  57,
  24,
  38,
  113,
  209,
  245,
  2,
  119,
  153,
  229,
  189,
  214,
  230,
  174,
  232,
  63,
  52,
  205,
  86,
  140,
  66,
  175,
  111,
  171,
  246,
  133,
  238,
  193,
  99,
  60,
  74,
  91,
  225,
  51,
  76,
  37,
  145,
  211,
  166,
  151,
  213,
  206,
  0,
  200,
  244,
  176,
  218,
  44,
  184,
  172,
  49,
  216,
  93,
  168,
  53,
  21,
  183,
  41,
  67,
  85,
  224,
  155,
  226,
  242,
  87,
  177,
  146,
  70,
  190,
  12,
  162,
  19,
  137,
  114,
  25,
  165,
  163,
  192,
  23,
  59,
  9,
  94,
  179,
  107,
  35,
  7,
  142,
  131,
  239,
  203,
  149,
  136,
  61,
  249,
  14,
  156,
];

String _fingerprint(Random random) {
  final width = 1024 + random.nextInt(897);
  final height = 768 + random.nextInt(313);
  final outerWidth = width + 24 + random.nextInt(9);
  final outerHeight = height + 75 + random.nextInt(16);
  final screenY = [0, 30][random.nextInt(2)];
  final sizeWidth = 1024 + random.nextInt(897);
  final sizeHeight = 768 + random.nextInt(313);
  final availWidth = 1280 + random.nextInt(641);
  final availHeight = 800 + random.nextInt(281);
  return '$width|$height|$outerWidth|$outerHeight|0|$screenY|0|0|'
      '$sizeWidth|$sizeHeight|$availWidth|$availHeight|'
      '$width|$height|24|24|Win32';
}

String _encode(List<int> bytes, String alphabet) {
  // Base64's grouping/padding is unchanged; only the 64-symbol alphabet differs.
  const standard =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  return base64.encode(bytes).split('').map((char) {
    return char == '=' ? char : alphabet[standard.indexOf(char)];
  }).join();
}

List<int> _rc4(String plaintext) {
  const key = [0, 1, 14];
  final state = List<int>.generate(256, (i) => i);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + state[i] + key[i % key.length]) & 255;
    final value = state[i];
    state[i] = state[j];
    state[j] = value;
  }
  var i = 0;
  j = 0;
  return [
    for (final unit in plaintext.codeUnits)
      (() {
        i = (i + 1) & 255;
        j = (j + state[i]) & 255;
        final value = state[i];
        state[i] = state[j];
        state[j] = value;
        return (unit ^ state[(state[i] + state[j]) & 255]) & 255;
      })(),
  ];
}

List<int> _transform(List<int> bytes) {
  // The reference mutates this permutation. Copy per call to prevent signatures
  // depending on earlier requests or concurrent adapter instances.
  final state = List<int>.of(_permutation);
  var indexB = state[1];
  var initial = 0;
  var valueE = 0;
  final output = <int>[];
  for (var index = 0; index < bytes.length; index++) {
    int sum;
    if (index == 0) {
      initial = state[indexB];
      sum = indexB + initial;
      state[1] = initial;
      state[indexB] = indexB;
    } else {
      sum = initial + valueE;
    }
    output.add(bytes[index] ^ state[sum % 256]);
    final next = (index + 2) % 256;
    valueE = state[next];
    sum = (indexB + valueE) % 256;
    initial = state[sum];
    state[sum] = state[next];
    state[next] = initial;
    indexB = sum;
  }
  return output;
}

/// Standard SM3 digest of bytes, exposed for independent published test vectors.
/// Input is copied; the returned 32-byte digest owns its storage.
Uint8List douyinSm3(List<int> input) {
  final paddedLength = ((input.length + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(paddedLength)..setRange(0, input.length, input);
  padded[input.length] = 0x80;
  final view = ByteData.sublistView(padded);
  final bitLength = input.length * 8;
  view.setUint32(paddedLength - 8, bitLength ~/ 0x100000000);
  view.setUint32(paddedLength - 4, bitLength & 0xffffffff);
  final state = <int>[
    0x7380166f,
    0x4914b2b9,
    0x172442d7,
    0xda8a0600,
    0xa96f30bc,
    0x163138aa,
    0xe38dee4d,
    0xb0fb0e4e,
  ];
  final words = Uint32List(68);
  for (var block = 0; block < paddedLength; block += 64) {
    for (var i = 0; i < 16; i++) {
      words[i] = view.getUint32(block + i * 4);
    }
    for (var i = 16; i < 68; i++) {
      final value = words[i - 16] ^ words[i - 9] ^ _rotate(words[i - 3], 15);
      words[i] =
          value ^
          _rotate(value, 15) ^
          _rotate(value, 23) ^
          _rotate(words[i - 13], 7) ^
          words[i - 6];
    }
    var a = state[0], b = state[1], c = state[2], d = state[3];
    var e = state[4], f = state[5], g = state[6], h = state[7];
    for (var round = 0; round < 64; round++) {
      final a12 = _rotate(a, 12);
      final ss1 = _rotate(
        (a12 + e + _rotate(round < 16 ? 0x79cc4519 : 0x7a879d8a, round)) &
            0xffffffff,
        7,
      );
      final ss2 = ss1 ^ a12;
      final ff = round < 16 ? a ^ b ^ c : (a & b) | (a & c) | (b & c);
      final gg = round < 16 ? e ^ f ^ g : (e & f) | ((~e) & g);
      final tt1 =
          (ff + d + ss2 + (words[round] ^ words[round + 4])) & 0xffffffff;
      final tt2 = (gg + h + ss1 + words[round]) & 0xffffffff;
      d = c;
      c = _rotate(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = _rotate(f, 19);
      f = e;
      e = tt2 ^ _rotate(tt2, 9) ^ _rotate(tt2, 17);
    }
    final compressed = [a, b, c, d, e, f, g, h];
    for (var i = 0; i < 8; i++) {
      state[i] ^= compressed[i];
    }
  }
  final digest = ByteData(32);
  for (var i = 0; i < 8; i++) {
    digest.setUint32(i * 4, state[i]);
  }
  return digest.buffer.asUint8List();
}

int _rotate(int value, int count) {
  final shift = count % 32;
  return ((value << shift) | (value >>> (32 - shift))) & 0xffffffff;
}

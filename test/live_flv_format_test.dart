import 'dart:async';
import 'dart:typed_data';

import 'package:duanju_app/live_flv_format.dart';
import 'package:flutter_test/flutter_test.dart';

const flvHeader = <int>[70, 76, 86, 1, 5, 0, 0, 0, 9, 0, 0, 0, 0];
const avc = <int>[
  0x17,
  0,
  0,
  0,
  0,
  1,
  66,
  0,
  30,
  255,
  225,
  0,
  4,
  0x67,
  66,
  0,
  30,
  1,
  0,
  2,
  0x68,
  0,
];
const aac = <int>[0xaf, 0, 0x12, 0x10];
List<int> flvTag(int type, int time, List<int> data) =>
    LiveFlvTag(type, time, Uint8List.fromList(data), time).encode(time);
List<int> frame(int time, int id, {bool key = true}) => flvTag(9, time, [
  key ? 0x17 : 0x27,
  1,
  0,
  0,
  0,
  0,
  0,
  0,
  2,
  key ? 0x65 : 0x41,
  id,
]);
List<int> flvStart({
  int time = 100,
  int id = 1,
  List<int> video = avc,
  List<int> audio = aac,
}) => [
  ...flvHeader,
  ...flvTag(9, 0, video),
  ...flvTag(8, 0, audio),
  ...frame(time, id),
];
LiveFlvReader readerOf(List<int> bytes, {bool fragmented = false}) =>
    LiveFlvReader(
      fragmented
          ? Stream.fromIterable(bytes.map((b) => [b]))
          : Stream.value(bytes),
      abort: () {},
    );
Matcher code(String value) =>
    isA<LiveFlvException>().having((e) => e.code, 'code', value);

void main() {
  test('转发接管自有缓冲区且再次编码不会篡改已发字节', () async {
    final reader = readerOf(flvStart());
    await reader.readHeader();
    expect(reader.hasCompleteTagBuffered, isTrue);
    await reader.next();
    await reader.next();
    final tag = await reader.next();
    final data = Uint8List.fromList(tag.data);
    final packet = tag.takePacket(200);
    packet[11] ^= 1;
    expect(tag.data[0], packet[11]);
    packet[11] ^= 1;
    expect(packet, frame(200, 1));
    final second = tag.takePacket(300);
    expect(second, frame(300, 1));
    expect(packet, frame(200, 1));
    expect(tag.data, data);
    expect(reader.hasCompleteTagBuffered, isFalse);
    await reader.cancel();
  });
  test(
    'one-byte fragments reconstruct FLV header, sequence headers and IDR',
    () async {
      final reader = readerOf(flvStart(), fragmented: true);
      addTearDown(reader.cancel);
      await reader.readHeader();
      expect(reader.header, flvHeader);
      expect((await reader.next()).videoConfig, isTrue);
      expect((await reader.next()).audioConfig, isTrue);
      final tag = await reader.next();
      expect(tag.keyframe, isTrue);
      expect(tag.timestamp, 100);
      expect(tag.encode(200), frame(200, 1));
    },
  );

  test(
    'extended header offsets and timestamp wrap are bounded and unwrapped',
    () async {
      final header = [...flvHeader.take(8), 11, 7, 8, 0, 0, 0, 0];
      final reader = readerOf([
        ...header,
        ...flvTag(9, 0, avc),
        ...frame(0xfffffff0, 1),
        ...frame(20, 2),
      ]);
      addTearDown(reader.cancel);
      await reader.readHeader();
      await reader.next();
      expect((await reader.next()).time, 0xfffffff0);
      expect((await reader.next()).time, 0x100000014);
    },
  );

  for (final entry in <String, List<int>>{
    'unsupported-header': [0, ...flvHeader.skip(1)],
    'header-limit': [70, 76, 86, 1, 5, 0, 1, 0, 0],
    'previous-tag-size': [...flvHeader.take(12), 1],
    'unexpected-eof': flvHeader.take(6).toList(),
  }.entries) {
    test('reject header ${entry.key}', () async {
      final reader = readerOf(entry.value);
      addTearDown(reader.cancel);
      await expectLater(reader.readHeader(), throwsA(code(entry.key)));
    });
  }

  for (final entry in <String, List<int>>{
    'tag-limit': [9, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0],
    'invalid-tag-header': [0x29, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0],
    'previous-tag-size': [...flvTag(9, 0, avc).take(36), 0],
    'unsupported-video': flvTag(9, 0, [0x1c, 0, 0, 0, 0, 1]),
    'unsupported-audio': flvTag(8, 0, [0x2f, 1, 1]),
    'missing-avc-config': frame(0, 1),
    'missing-aac-config': flvTag(8, 0, [0xaf, 1, 1]),
    'invalid-avc-config': flvTag(9, 0, [0x17, 0, 0, 0, 0, 1]),
    'invalid-aac-config': flvTag(8, 0, [0xaf, 0, 0]),
    'unexpected-eof': [9, 0, 0, 30],
  }.entries) {
    test('reject tag ${entry.key}', () async {
      final reader = readerOf([...flvHeader, ...entry.value], fragmented: true);
      addTearDown(reader.cancel);
      await reader.readHeader();
      await expectLater(reader.next(), throwsA(code(entry.key)));
    });
  }

  test(
    'NAL sizes and genuine IDR are checked rather than just FLV key flag',
    () async {
      for (final payload in <List<int>>[
        [0x17, 1, 0, 0, 0, 0, 0, 0, 99, 0x65],
        [0x17, 1, 0, 0, 0, 0, 0, 0, 1, 0x41],
      ]) {
        final reader = readerOf([
          ...flvHeader,
          ...flvTag(9, 0, avc),
          ...flvTag(9, 0, payload),
        ]);
        await reader.readHeader();
        await reader.next();
        await expectLater(reader.next(), throwsA(isA<LiveFlvException>()));
        await reader.cancel();
      }
    },
  );

  test('read deadline cancels a stalled subscription exactly once', () async {
    var aborted = 0;
    var cancelled = 0;
    final controller = StreamController<List<int>>(onCancel: () => cancelled++);
    final reader = LiveFlvReader(controller.stream, abort: () => aborted++);
    await expectLater(reader.readHeader(), throwsA(code('read-timeout')));
    await reader.cancel();
    await reader.cancel();
    expect(aborted, 1);
    expect(cancelled, 1);
    await controller.close();
  });

  test(
    'exact maximum tag is accepted; zero and oversized tags fail before body allocation',
    () async {
      final payload = Uint8List(LiveFlvLimits.maxTag);
      final reader = LiveFlvReader(
        Stream.fromIterable([flvHeader, flvTag(18, 0, payload)]),
        abort: () {},
      );
      addTearDown(reader.cancel);
      await reader.readHeader();
      expect((await reader.next()).data.length, LiveFlvLimits.maxTag);
      for (final size in [0, LiveFlvLimits.maxTag + 1]) {
        final invalid = readerOf([
          ...flvHeader,
          18,
          size >> 16,
          (size >> 8) & 255,
          size & 255,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
        ]);
        await invalid.readHeader();
        await expectLater(invalid.next(), throwsA(code('tag-limit')));
        await invalid.cancel();
      }
    },
  );

  test(
    'every truncation of a tag is rejected, not emitted as a partial frame',
    () async {
      final tag = flvTag(9, 0, avc);
      for (var length = 0; length < tag.length; length++) {
        final reader = readerOf([...flvHeader, ...tag.take(length)]);
        await reader.readHeader();
        await expectLater(reader.next(), throwsA(code('unexpected-eof')));
        await reader.cancel();
      }
    },
  );

  test(
    'cancel wakes a pending read and does not leave the subscription running',
    () async {
      final controller = StreamController<List<int>>();
      var aborted = 0;
      final reader = LiveFlvReader(controller.stream, abort: () => aborted++);
      final pending = expectLater(
        reader.readHeader(),
        throwsA(isA<LiveFlvException>()),
      );
      await reader.cancel();
      await pending;
      expect(aborted, 1);
      await controller.close();
    },
  );

  test(
    'in-band SPS/PPS cannot silently change decoder configuration',
    () async {
      for (final changed in [false, true]) {
        final data = <int>[
          0x17,
          1,
          0,
          0,
          0,
          0,
          0,
          0,
          4,
          0x67,
          66,
          0,
          changed ? 31 : 30,
          0,
          0,
          0,
          2,
          0x65,
          1,
        ];
        final reader = readerOf([
          ...flvHeader,
          ...flvTag(9, 0, avc),
          ...flvTag(9, 100, data),
        ]);
        await reader.readHeader();
        await reader.next();
        if (changed) {
          await expectLater(
            reader.next(),
            throwsA(code('configuration-changed')),
          );
        } else {
          expect((await reader.next()).keyframe, isTrue);
        }
        await reader.cancel();
      }
    },
  );
}

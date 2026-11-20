// Run with the project Dart SDK. Synthetic framing only: no network/decoder.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:duanju_app/live_flv_format.dart';

const header = [70, 76, 86, 1, 1, 0, 0, 0, 9, 0, 0, 0, 0];
const avc = [
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
Future<void> run(int count, int size, {required bool transfer}) async {
  final payload = Uint8List(size)
    ..[0] = 0x17
    ..[1] = 1;
  ByteData.sublistView(payload).setUint32(5, size - 9);
  payload[9] = 0x65;
  final frame = LiveFlvTag(9, 100, payload, 100).encode(100);
  final config = LiveFlvTag(9, 0, Uint8List.fromList(avc), 0).encode(0);
  final elapsed = <int>[];
  var checksum = 0;
  for (var run = 0; run < 6; run++) {
    final watch = Stopwatch()..start();
    final reader = LiveFlvReader(
      Stream.fromIterable([
        Uint8List.fromList(header),
        config,
        for (var i = 0; i < count; i++) frame,
      ]),
      abort: () {},
    );
    await reader.readHeader();
    for (var i = 0; i <= count; i++) {
      final tag = await reader.next();
      checksum += (transfer ? tag.takePacket(i) : tag.encode(i))[6];
    }
    await reader.cancel();
    watch.stop();
    if (run > 0) elapsed.add(watch.elapsedMicroseconds);
  }
  elapsed.sort();
  stdout.writeln(
    'mode=${transfer ? 'transfer' : 'copy'} tags=$count payload=$size median_us=${elapsed[2]} checksum=$checksum',
  );
}

Future<void> main() async {
  for (final size in [2048, 32768]) {
    await run(size == 2048 ? 10000 : 4000, size, transfer: false);
    await run(size == 2048 ? 10000 : 4000, size, transfer: true);
  }
}

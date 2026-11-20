import 'dart:async';
import 'dart:io';

import 'package:duanju_app/live_flv_format.dart';
import 'package:duanju_app/live_flv_relay.dart';
import 'package:duanju_app/live_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'live_flv_format_test.dart' as fixture;

const shortRenew = Duration(milliseconds: 150);
Future<T> bounded<T>(Future<T> future) {
  final stack = StackTrace.current;
  return future.timeout(
    const Duration(seconds: 3),
    onTimeout: () =>
        Error.throwWithStackTrace(TimeoutException('test deadline'), stack),
  );
}

class Origin {
  Origin(this.server);
  final HttpServer server;
  final List<OriginRequest> requests = [];
  final List<Completer<void>> disconnected = [];
  Future<void> Function(OriginRequest request, int index)? handler;
  int active = 0;
  int peak = 0;
  static Future<Origin> start() async {
    final origin = Origin(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    origin.server.listen((httpRequest) async {
      final socket = await httpRequest.response.detachSocket(
        writeHeaders: false,
      );
      final request = OriginRequest(
        httpRequest.headers,
        OriginResponse(socket),
      );
      final index = origin.requests.length;
      origin.requests.add(request);
      final done = Completer<void>();
      origin.disconnected.add(done);
      origin.active++;
      if (origin.active > origin.peak) origin.peak = origin.active;
      socket.listen(
        (_) {},
        onDone: () {
          origin.active--;
          if (!done.isCompleted) done.complete();
        },
        onError: (_) {
          origin.active--;
          if (!done.isCompleted) done.complete();
        },
      );
      try {
        request.response.bufferOutput = false;
        await origin.handler?.call(request, index);
      } catch (_) {
        /* Expected when a relay cancels an upstream socket. */
      }
    });
    addTearDown(() async {
      for (final request in origin.requests) {
        request.response.socket.destroy();
      }
      await origin.server.close(force: true);
    });
    return origin;
  }

  LiveStream stream({
    String path = '/live.flv',
    Map<String, String> headers = const {},
    Duration? renewAfter = shortRenew,
  }) => LiveStream(
    url: 'http://127.0.0.1:${server.port}$path',
    quality: 'source',
    headers: headers,
    renewAfter: renewAfter,
    lineId: path,
  );
  Future<void> send(int index, List<int> bytes) async {
    requests[index].response.add(bytes);
    await requests[index].response.flush();
  }
}

// Keep HttpServer for parsing, but observe the raw peer read side: an idle
// HttpResponse.done does not reliably signal TCP FIN on Windows.
class OriginRequest {
  OriginRequest(this.headers, this.response);
  final HttpHeaders headers;
  final OriginResponse response;
}

class OriginHeaders {
  final values = <String, String>{};
  void set(String name, String value) {
    values[name] = value;
  }
}

class OriginResponse {
  OriginResponse(this.socket) {
    unawaited(socket.done.catchError((_) {}));
  }
  final Socket socket;
  final headers = OriginHeaders();
  int statusCode = 200;
  bool bufferOutput = false;
  bool sent = false;
  void start() {
    if (sent) return;
    sent = true;
    socket.write('HTTP/1.1 $statusCode Test\r\nConnection: close\r\n');
    headers.values.forEach((key, value) => socket.write('$key: $value\r\n'));
    socket.write('\r\n');
  }

  void add(List<int> bytes) {
    start();
    socket.add(bytes);
  }

  void write(String value) {
    start();
    socket.write(value);
  }

  Future<void> flush() {
    start();
    return socket.flush();
  }

  Future<void> close() async {
    start();
    await socket.flush();
    await socket.close();
  }
}

Future<LiveFlvReader> player(LiveFlvRelay relay, {HttpClient? client}) async {
  final http = client ?? HttpClient();
  addTearDown(() => http.close(force: true));
  final request = await http.getUrl(Uri.parse(relay.url));
  final response = await request.close();
  expect(response.statusCode, 200);
  final reader = LiveFlvReader(response, abort: request.abort);
  addTearDown(reader.cancel);
  await bounded(reader.readHeader());
  return reader;
}

Future<LiveFlvTag> media(LiveFlvReader reader) async {
  while (true) {
    final tag = await bounded(reader.next());
    if (tag.media) return tag;
  }
}

void main() {
  test('取消 start 中的首帧等待会立即关闭上游', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final connected = Completer<void>();
    final cancelled = Completer<void>();
    final requests = <HttpRequest>[];
    server.listen((request) {
      requests.add(request);
      connected.complete();
    });
    final starting = LiveFlvRelay.start(
      LiveStream(
        url: 'http://127.0.0.1:${server.port}/wait.flv',
        quality: '',
        headers: const {},
        renewAfter: const Duration(minutes: 4),
      ),
      renew: (current) async => current,
      cancelled: cancelled.future,
    );
    final check = expectLater(starting, throwsA(isA<LiveFlvException>()));
    await connected.future.timeout(const Duration(seconds: 2));
    cancelled.complete();
    await check.timeout(const Duration(seconds: 2));
    for (final request in requests) {
      await request.response.close().catchError((_) {});
    }
    await server.close(force: true);
  });

  test(
    'applies only to declared expiring HTTP(S) FLV, with safe URL validation',
    () {
      LiveStream stream(String url, {Duration? expiry = shortRenew}) =>
          LiveStream(
            url: url,
            quality: '',
            headers: const {},
            renewAfter: expiry,
          );
      for (final url in [
        'http://example.test/a.flv?sign=secret',
        'https://example.test/A.FLV',
      ]) {
        expect(LiveFlvRelay.appliesTo(stream(url)), isTrue);
        expect(LiveFlvRelay.appliesTo(stream(url, expiry: null)), isFalse);
      }
      for (final url in [
        'file:///a.flv',
        'rtmp://a/b.flv',
        'https://a/a.m3u8',
        'http://u:p@a/a.flv',
        'http://a/a.flv#secret',
        'http://a:99999/a.flv',
        'not a url',
      ]) {
        expect(LiveFlvRelay.appliesTo(stream(url)), isFalse);
      }
    },
  );

  test('相同 IDR 载荷但时钟向前仍完成交接', () async {
    final origin = await Origin.start();
    final renewed = Completer<LiveStream>();
    final failures = <Object>[];
    origin.handler = (request, index) async {
      request.response.add(
        fixture.flvStart(time: index == 0 ? 1000 : 1040, id: 1),
      );
      await request.response.flush();
    };
    final relay = await LiveFlvRelay.start(
      origin.stream(),
      renew: (_) async => origin.stream(
        path: '/next.flv',
        renewAfter: const Duration(hours: 1),
      ),
      onRenewed: renewed.complete,
      onFailure: failures.add,
    );
    addTearDown(relay.close);
    final output = await player(relay);
    expect((await media(output)).timestamp, 1000);
    await bounded(renewed.future);
    expect((await media(output)).timestamp, 1040);
    expect(failures, isEmpty);
    expect(origin.peak, lessThanOrEqualTo(2));
  });

  for (final timeline in ['same', 'reset', 'rebased-overlap']) {
    test(
      '$timeline handoff uses one player, no duplicate GOP and monotone time',
      () async {
        final origin = await Origin.start();
        final resolve = Completer<LiveStream>();
        final resolving = Completer<void>();
        final renewed = Completer<LiveStream>();
        final failures = <Object>[];
        origin.handler = (request, index) async {
          if (index == 0) {
            // Send every byte separately to exercise transport fragmentation.
            for (final byte in fixture.flvStart(time: 1000)) {
              request.response.add([byte]);
              await request.response.flush();
            }
          } else {
            final reset = timeline == 'reset';
            final base = timeline == 'rebased-overlap' ? 0 : 1000;
            request.response.add([
              ...fixture.flvStart(time: reset ? 0 : base, id: reset ? 3 : 1),
              if (!reset) ...fixture.frame(base + 20, 2, key: false),
              if (!reset) ...fixture.frame(base + 40, 3),
              ...fixture.frame(reset ? 20 : base + 60, 4, key: false),
            ]);
            await request.response.flush();
          }
        };
        final initial = origin.stream(
          headers: {'X-Room': 'old', 'Referer': 'https://old.test/'},
        );
        final relay = await LiveFlvRelay.start(
          initial,
          renew: (current) {
            expect(identical(current, initial), isTrue);
            resolving.complete();
            return resolve.future;
          },
          onRenewed: renewed.complete,
          onFailure: failures.add,
        );
        addTearDown(relay.close);
        final output = await player(relay);
        expect((await media(output)).data.last, 1);
        await origin.send(0, fixture.frame(1020, 2, key: false));
        expect((await media(output)).data.last, 2);
        await bounded(resolving.future);
        final replacement = origin.stream(
          path: '/next.flv',
          headers: {'X-Room': 'new'},
          renewAfter: const Duration(hours: 1),
        );
        resolve.complete(replacement);
        expect(await bounded(renewed.future), same(replacement));
        final third = await media(output);
        final fourth = await media(output);
        expect([third.data.last, fourth.data.last], [3, 4]);
        expect(third.timestamp, timeline == 'reset' ? 1021 : 1040);
        expect(fourth.timestamp, third.timestamp + 20);
        expect(origin.requests, hasLength(2));
        expect(origin.peak, lessThanOrEqualTo(2));
        expect(origin.requests[0].headers.value('x-room'), 'old');
        expect(origin.requests[1].headers.value('x-room'), 'new');
        expect(origin.requests[1].headers.value('referer'), isNull);
        expect(failures, isEmpty);
        await relay.close();
        await bounded(Future.wait(origin.disconnected.map((c) => c.future)));
      },
    );
  }

  for (final changed in ['video', 'audio', 'flags']) {
    test(
      '$changed configuration change reports failure and retains old readable stream',
      () async {
        final origin = await Origin.start();
        final failure = Completer<Object>();
        var renewals = 0;
        origin.handler = (request, index) async {
          final bytes = fixture.flvStart(
            time: index == 0 ? 100 : 0,
            video: index > 0 && changed == 'video'
                ? [...fixture.avc.take(21), 1]
                : fixture.avc,
            audio: index > 0 && changed == 'audio'
                ? [0xaf, 0, 0x11, 0x90]
                : fixture.aac,
          );
          if (index > 0 && changed == 'flags') bytes[4] = 1;
          request.response.add(bytes);
          await request.response.flush();
        };
        final relay = await LiveFlvRelay.start(
          origin.stream(),
          renew: (_) async => origin.stream(),
          onFailure: failure.complete,
          onRenewed: (_) => renewals++,
        );
        addTearDown(relay.close);
        final output = await player(relay);
        await media(output);
        expect(
          await bounded(failure.future),
          fixture.code('configuration-changed'),
        );
        await origin.send(0, fixture.frame(120, 2, key: false));
        expect((await media(output)).data.last, 2);
        expect(renewals, 0);
        expect(origin.requests, hasLength(2));
      },
    );
  }

  test(
    'sequence configuration change in active connection is fatal before output',
    () async {
      final origin = await Origin.start();
      origin.handler = (r, _) async {
        r.response.add(fixture.flvStart());
        await r.response.flush();
      };
      final failure = Completer<Object>();
      final relay = await LiveFlvRelay.start(
        origin.stream(renewAfter: const Duration(hours: 1)),
        renew: (s) async => s,
        onFailure: failure.complete,
      );
      addTearDown(relay.close);
      final output = await player(relay);
      await media(output);
      await origin.send(0, fixture.flvTag(8, 120, [0xaf, 0, 0x11, 0x90]));
      expect(
        await bounded(failure.future),
        fixture.code('configuration-changed'),
      );
      await relay.close();
    },
  );

  test(
    'HTTP renewal failure has three attempts, redacts errors and preserves old reader',
    () async {
      final origin = await Origin.start();
      origin.handler = (r, i) async {
        if (i == 0) {
          r.response.add(fixture.flvStart());
          await r.response.flush();
        } else {
          r.response.statusCode = 403;
          r.response.write('signed-secret');
          await r.response.close();
        }
      };
      final failure = Completer<Object>();
      var calls = 0;
      final relay = await LiveFlvRelay.start(
        origin.stream(),
        renew: (_) async {
          calls++;
          return origin.stream(
            path: '/next.flv?signature=signed-secret',
            headers: {'Authorization': 'header-secret'},
          );
        },
        onFailure: failure.complete,
      );
      addTearDown(relay.close);
      final output = await player(relay);
      await media(output);
      final error = await bounded(failure.future);
      expect(error.toString(), isNot(contains('secret')));
      expect(calls, 3);
      await origin.send(0, fixture.frame(120, 2));
      expect((await media(output)).data.last, 2);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(calls, 3);
      expect(origin.peak, lessThanOrEqualTo(2));
    },
  );

  test(
    'private random path, Host, query, method and duplicate player protection',
    () async {
      final origin = await Origin.start();
      origin.handler = (r, _) async {
        r.response.add(fixture.flvStart());
        await r.response.flush();
      };
      final relay = await LiveFlvRelay.start(
        origin.stream(renewAfter: const Duration(hours: 1)),
        renew: (s) async => s,
      );
      addTearDown(relay.close);
      final uri = Uri.parse(relay.url);
      expect(uri.host, '127.0.0.1');
      expect(uri.path, matches(RegExp(r'^/[a-f0-9]{48}\.flv$')));
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      Future<int> request(String method, Uri target, {String? host}) async {
        final r = await http.openUrl(method, target);
        if (host != null) r.headers.set('Host', host);
        final response = await r.close();
        await response.drain<void>();
        return response.statusCode;
      }

      expect(await request('GET', uri.replace(path: '/wrong.flv')), 404);
      expect(await request('GET', uri.replace(query: 'secret=1')), 404);
      expect(await request('GET', uri, host: 'evil.test'), 404);
      expect(await request('POST', uri), 405);
      expect(await request('HEAD', uri), 405);
      final output = await player(relay);
      await media(output);
      expect(await request('GET', uri), 409);
      expect(origin.requests, hasLength(1));
    },
  );

  for (final lateError in [false, true]) {
    test(
      'close during resolver consumes late ${lateError ? 'error' : 'value'} without resurrection',
      () async {
        final origin = await Origin.start();
        origin.handler = (r, _) async {
          r.response.add(fixture.flvStart());
          await r.response.flush();
        };
        final entered = Completer<void>();
        final resolve = Completer<LiveStream>();
        var callbacks = 0;
        final relay = await LiveFlvRelay.start(
          origin.stream(),
          renew: (_) {
            entered.complete();
            return resolve.future;
          },
          onRenewed: (_) => callbacks++,
          onFailure: (_) => callbacks++,
        );
        addTearDown(relay.close);
        await bounded(entered.future);
        await bounded(relay.close());
        await relay.close();
        if (lateError) {
          resolve.completeError(StateError('secret'));
        } else {
          resolve.complete(origin.stream(path: '/late.flv'));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(callbacks, 0);
        expect(origin.requests, hasLength(1));
        final http = HttpClient();
        addTearDown(() => http.close(force: true));
        await expectLater(
          http.getUrl(Uri.parse(relay.url)),
          throwsA(isA<SocketException>()),
        );
      },
    );
  }

  test(
    'close aborts old and stalled candidate response, including late HTTP bytes',
    () async {
      final origin = await Origin.start();
      final entered = Completer<void>();
      origin.handler = (r, i) async {
        if (i == 0) {
          r.response.add(fixture.flvStart());
          await r.response.flush();
        } else {
          entered.complete();
        }
      };
      var callbacks = 0;
      final relay = await LiveFlvRelay.start(
        origin.stream(),
        renew: (_) async => origin.stream(),
        onFailure: (_) => callbacks++,
      );
      addTearDown(relay.close);
      await bounded(entered.future);
      await bounded(relay.close());
      try {
        await origin.send(1, fixture.flvStart());
      } catch (_) {
        /* Closed socket. */
      }
      await bounded(Future.wait(origin.disconnected.map((c) => c.future)));
      expect(callbacks, 0);
      expect(origin.peak, lessThanOrEqualTo(2));
    },
  );

  test(
    'player disconnect tears down the local server and upstream reader',
    () async {
      final origin = await Origin.start();
      origin.handler = (r, _) async {
        r.response.add(fixture.flvStart());
        await r.response.flush();
      };
      final relay = await LiveFlvRelay.start(
        origin.stream(renewAfter: const Duration(hours: 1)),
        renew: (s) async => s,
      );
      addTearDown(relay.close);
      final http = HttpClient();
      final output = await player(relay, client: http);
      await media(output);
      await output.cancel();
      http.close(force: true);
      // No further upstream bytes: the detached read side must observe FIN.
      await bounded(origin.disconnected.first.future);
      await bounded(relay.close());
    },
  );

  test(
    'initial stalled HTTP headers hit connection deadline and release socket',
    () async {
      final origin = await Origin.start();
      origin.handler = (_, _) async {};
      await expectLater(
        LiveFlvRelay.start(origin.stream(), renew: (s) async => s),
        throwsA(fixture.code('operation-timeout')),
      );
      await bounded(origin.disconnected.first.future);
    },
  );

  test(
    'initial prefetch tag limit rejects endless metadata before a keyframe',
    () async {
      final origin = await Origin.start();
      origin.handler = (r, _) async {
        r.response.add([
          ...fixture.flvHeader,
          ...fixture.flvTag(9, 0, fixture.avc),
          for (var i = 0; i < LiveFlvLimits.maxPrefetchTags; i++)
            ...fixture.flvTag(18, 0, [1]),
        ]);
        await r.response.flush();
      };
      await expectLater(
        LiveFlvRelay.start(origin.stream(), renew: (s) async => s),
        throwsA(fixture.code('prefetch-limit')),
      );
    },
  );

  test(
    'separate relays never inherit another room headers and redirects are not followed',
    () async {
      final origin = await Origin.start();
      origin.handler = (r, _) async {
        r.response.add(fixture.flvStart());
        await r.response.flush();
      };
      final one = await LiveFlvRelay.start(
        origin.stream(
          headers: {'X-Room': 'one'},
          renewAfter: const Duration(hours: 1),
        ),
        renew: (s) async => s,
      );
      addTearDown(one.close);
      final two = await LiveFlvRelay.start(
        origin.stream(renewAfter: const Duration(hours: 1)),
        renew: (s) async => s,
      );
      addTearDown(two.close);
      expect(origin.requests[0].headers.value('x-room'), 'one');
      expect(origin.requests[1].headers.value('x-room'), isNull);
      expect(one.url, isNot(two.url));
      origin.handler = (r, _) async {
        r.response.statusCode = 302;
        r.response.headers.set(
          'Location',
          origin.stream(path: '/redirected.flv').url,
        );
        await r.response.close();
      };
      await expectLater(
        LiveFlvRelay.start(origin.stream(), renew: (s) async => s),
        throwsA(fixture.code('http-status')),
      );
      expect(origin.requests, hasLength(3));
    },
  );

  test(
    'forward same timeline without overlap preserves decode timestamps',
    () async {
      final origin = await Origin.start();
      final resolve = Completer<LiveStream>();
      origin.handler = (r, i) async {
        r.response.add(fixture.flvStart(time: i == 0 ? 1000 : 1040, id: i + 1));
        await r.response.flush();
      };
      final relay = await LiveFlvRelay.start(
        origin.stream(),
        renew: (_) => resolve.future,
      );
      addTearDown(relay.close);
      final output = await player(relay);
      await media(output);
      resolve.complete(origin.stream(renewAfter: null));
      expect((await media(output)).timestamp, 1040);
    },
  );

  test(
    'candidate must have AAC config and an IDR; old stream keeps advancing',
    () async {
      final origin = await Origin.start();
      final candidate = Completer<void>();
      var renewed = 0;
      origin.handler = (r, i) async {
        if (i == 0) {
          r.response.add(fixture.flvStart());
        } else {
          r.response.add([
            ...fixture.flvHeader,
            ...fixture.flvTag(9, 0, fixture.avc),
            ...fixture.frame(0, 3),
          ]);
        }
        await r.response.flush();
        if (i > 0) candidate.complete();
      };
      final relay = await LiveFlvRelay.start(
        origin.stream(),
        renew: (_) async => origin.stream(renewAfter: null),
        onRenewed: (_) => renewed++,
      );
      addTearDown(relay.close);
      final output = await player(relay);
      await media(output);
      await bounded(candidate.future);
      await origin.send(0, fixture.frame(120, 2));
      expect((await media(output)).data.last, 2);
      expect(renewed, 0);
      await origin.send(1, [
        ...fixture.flvTag(8, 0, fixture.aac),
        ...fixture.frame(20, 4),
      ]);
      final tag = await media(output);
      expect(tag.data.last, 4);
      expect(tag.timestamp, 121);
      expect(renewed, 1);
    },
  );

  test(
    'resolver timeout is reported once; late result cannot create a candidate',
    () async {
      final origin = await Origin.start();
      origin.handler = (r, _) async {
        r.response.add(fixture.flvStart());
        await r.response.flush();
      };
      final resolve = Completer<LiveStream>();
      final failed = Completer<Object>();
      var calls = 0;
      final relay = await LiveFlvRelay.start(
        origin.stream(),
        renew: (_) {
          calls++;
          return resolve.future;
        },
        onFailure: failed.complete,
      );
      addTearDown(relay.close);
      // No downstream reader yet: this isolates the resolver deadline from the
      // independent five-second active-body deadline.
      expect(
        await failed.future.timeout(const Duration(seconds: 10)),
        fixture.code('operation-timeout'),
      );
      resolve.complete(origin.stream());
      final output = await player(relay);
      expect((await media(output)).data.last, 1);
      expect(origin.requests, hasLength(1));
      expect(calls, 1);
    },
  );

  test('active body read timeout reports and closes both sides', () async {
    final origin = await Origin.start();
    origin.handler = (r, _) async {
      r.response.add(fixture.flvStart());
      await r.response.flush();
    };
    final failed = Completer<Object>();
    final relay = await LiveFlvRelay.start(
      origin.stream(renewAfter: const Duration(hours: 1)),
      renew: (s) async => s,
      onFailure: failed.complete,
    );
    addTearDown(relay.close);
    final output = await player(relay);
    await media(output);
    expect(
      await failed.future.timeout(const Duration(seconds: 7)),
      fixture.code('read-timeout'),
    );
    await bounded(origin.disconnected.first.future);
  });

  test(
    'slow downstream applies backpressure instead of draining unlimited tags',
    () async {
      final origin = await Origin.start();
      final sendMore = Completer<void>();
      var sent = 0;
      origin.handler = (r, _) async {
        r.response.add(fixture.flvStart());
        await r.response.flush();
        await sendMore.future;
        final payload = List<int>.filled(512 * 1024, 0);
        payload[0] = 1;
        for (var i = 0; i < 256; i++) {
          r.response.add(fixture.flvTag(18, i, payload));
          await r.response.flush();
          sent++;
        }
      };
      final relay = await LiveFlvRelay.start(
        origin.stream(renewAfter: const Duration(hours: 1)),
        renew: (s) async => s,
      );
      addTearDown(relay.close);
      final output = await player(relay);
      await media(output);
      sendMore.complete();
      // The player is deliberately not pulling any further tag. This assertion
      // allows large OS socket buffers but not an unbounded 128-MiB Dart queue.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(sent, lessThan(256));
      await bounded(relay.close());
      await bounded(origin.disconnected.first.future);
    },
  );

  test(
    'multiple renewals retain one player and never exceed two upstream sockets',
    () async {
      final origin = await Origin.start();
      origin.handler = (r, i) async {
        r.response.add(fixture.flvStart(time: 100 + 40 * i, id: i + 1));
        await r.response.flush();
      };
      var renewals = 0;
      final relay = await LiveFlvRelay.start(
        origin.stream(),
        renew: (current) async {
          renewals++;
          expect(
            current.lineId,
            renewals == 1 ? '/live.flv' : '/$renewals.flv',
          );
          return origin.stream(
            path: '/${renewals + 1}.flv',
            renewAfter: renewals == 2 ? null : shortRenew,
          );
        },
      );
      addTearDown(relay.close);
      final output = await player(relay);
      final tags = [
        await media(output),
        await media(output),
        await media(output),
      ];
      expect(tags.map((t) => t.data.last), [1, 2, 3]);
      expect(tags.map((t) => t.timestamp), [100, 140, 180]);
      expect(origin.peak, lessThanOrEqualTo(2));
      expect(origin.requests, hasLength(3));
      await relay.close();
      await bounded(Future.wait(origin.disconnected.map((c) => c.future)));
    },
  );

  test(
    'prefetch byte limit stops large metadata with bounded retained queue',
    () async {
      final origin = await Origin.start();
      origin.handler = (r, _) async {
        r.response.add([
          ...fixture.flvHeader,
          ...fixture.flvTag(9, 0, fixture.avc),
        ]);
        await r.response.flush();
        final bytes = fixture.flvTag(
          18,
          0,
          List<int>.filled(LiveFlvLimits.maxTag, 0),
        );
        for (var i = 0; i < 4; i++) {
          r.response.add(bytes);
          await r.response.flush();
        }
      };
      await expectLater(
        LiveFlvRelay.start(origin.stream(), renew: (s) async => s),
        throwsA(fixture.code('prefetch-limit')),
      );
      await bounded(origin.disconnected.first.future);
    },
  );
}

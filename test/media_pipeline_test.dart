import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/media_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

final _media = <String, dynamic>{
  'format': {'duration': '12'},
  'streams': [
    {'codec_type': 'video', 'codec_name': 'h264'},
  ],
};

class _ProbeSession implements FFprobeSessionHandle {
  int starts = 0;
  int cancels = 0;
  Completer<void>? starting;
  Completer<void>? cancelling;
  bool cancelFails = false;
  late void Function(Map<String, dynamic>?) complete;

  @override
  Future<void> start() {
    starts++;
    return starting?.future ?? Future<void>.value();
  }

  @override
  Future<void> cancel() {
    cancels++;
    if (cancelFails) return Future<void>.error(StateError('cancel failed'));
    return cancelling?.future ?? Future<void>.value();
  }
}

Matcher _failure(String text) => isA<AppFailure>().having(
  (failure) => failure.toString(),
  'message',
  contains(text),
);

FFmpegExecutor _executor(_ProbeSession session) => FFmpegExecutor(
  probeSessionFactory: (arguments, complete) async {
    expect(arguments.last, 'input.mp4');
    expect(arguments, contains('file,crypto,data'));
    session.complete = complete;
    return session;
  },
);

class _RunSession implements FFmpegSessionHandle {
  int starts = 0;
  int cancels = 0;
  Completer<void>? starting;
  Completer<void>? cancelling;
  late void Function(int?) complete;
  late void Function(String) log;
  late void Function(double) time;

  @override
  Future<void> start() { starts++; return starting?.future ?? Future.value(); }
  @override
  Future<void> cancel() { cancels++; return cancelling?.future ?? Future.value(); }
}

FFmpegSessionFactory _runFactory(_RunSession session) => (_, complete, log, time) async {
  session.complete = complete;
  session.log = log;
  session.time = time;
  return session;
};

void main() {
  testWidgets('探测正常完成并清理超时计时器', (tester) async {
    final session = _ProbeSession();
    final executor = _executor(session);
    final result = executor.probe('input.mp4');
    await tester.pump();
    expect(session.starts, 1);
    session.complete(_media);
    final probe = await result;
    expect(probe.duration, 12);
    expect(probe.videoCodec, 'h264');
    await tester.pump(const Duration(seconds: 31));
    await executor.cancel();
    expect(session.cancels, 0);
  });

  testWidgets('取消立即结束等待，不等待原生取消完成', (tester) async {
    final session = _ProbeSession()..cancelling = Completer<void>();
    final executor = _executor(session);
    final result = executor.probe('input.mp4');
    final checked = expectLater(result, throwsA(_failure('已取消')));
    await tester.pump();
    await executor.cancel();
    await checked;
    expect(session.cancels, 1);
    session.complete(_media);
    session.cancelling!.complete();
    await tester.pump();
  });

  testWidgets('取消早于会话 ID 返回时补做取消且不启动旧会话', (tester) async {
    final created = Completer<FFprobeSessionHandle>();
    final oldSession = _ProbeSession();
    final newSession = _ProbeSession();
    var calls = 0;
    final executor = FFmpegExecutor(
      probeSessionFactory: (_, complete) {
        if (calls++ == 0) {
          oldSession.complete = complete;
          return created.future;
        }
        newSession.complete = complete;
        return Future.value(newSession);
      },
    );
    final oldResult = executor.probe('old.mp4');
    final checked = expectLater(oldResult, throwsA(_failure('已取消')));
    await executor.cancel();
    await checked;
    final newResult = executor.probe('new.mp4');
    var newCompleted = false;
    unawaited(newResult.then((_) => newCompleted = true));
    await tester.pump();
    created.complete(oldSession);
    await tester.pump();
    expect(oldSession.starts, 0);
    expect(oldSession.cancels, 1);
    oldSession.complete(_media);
    oldSession.complete(null);
    await tester.pump();
    expect(newCompleted, isFalse);
    expect(newSession.cancels, 0);
    newSession.complete(_media);
    expect((await newResult).duration, 12);
  });

  testWidgets('探测超时会取消实际会话', (tester) async {
    final session = _ProbeSession()..cancelFails = true;
    final executor = _executor(session);
    final result = executor.probe('input.mp4');
    final checked = expectLater(result, throwsA(_failure('探测超时')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    await checked;
    expect(session.cancels, 1);
    session.complete(_media);
    await tester.pump();
  });

  testWidgets('创建会话卡住也有上限，迟到会话只取消不启动', (tester) async {
    final created = Completer<FFprobeSessionHandle>();
    final session = _ProbeSession();
    final executor = FFmpegExecutor(
      probeTimeout: const Duration(seconds: 2),
      probeSessionFactory: (_, complete) {
        session.complete = complete;
        return created.future;
      },
    );
    final result = executor.probe('input.mp4');
    final checked = expectLater(result, throwsA(_failure('探测超时')));
    await tester.pump(const Duration(seconds: 2));
    await checked;
    created.complete(session);
    await tester.pump();
    expect(session.starts, 0);
    expect(session.cancels, 1);
  });

  testWidgets('取消发生在原生启动确认前时再次定向取消', (tester) async {
    final session = _ProbeSession()..starting = Completer<void>();
    final executor = _executor(session);
    final result = executor.probe('input.mp4');
    final checked = expectLater(result, throwsA(_failure('已取消')));
    await tester.pump();
    await executor.cancel();
    await checked;
    expect(session.cancels, 1);
    session.starting!.complete();
    await tester.pump();
    expect(session.cancels, 2);
  });

  testWidgets('不同执行器的探测和取消相互隔离', (tester) async {
    final firstSession = _ProbeSession();
    final secondSession = _ProbeSession();
    final first = _executor(firstSession);
    final second = _executor(secondSession);
    final firstResult = first.probe('input.mp4');
    final checked = expectLater(firstResult, throwsA(_failure('已取消')));
    final secondResult = second.probe('input.mp4');
    await tester.pump();
    await first.cancel();
    await checked;
    expect(firstSession.cancels, 1);
    expect(secondSession.cancels, 0);
    secondSession.complete(_media);
    expect((await secondResult).videoCodec, 'h264');
  });

  testWidgets('空探测结果保留原有错误提示', (tester) async {
    final session = _ProbeSession();
    final result = _executor(session).probe('input.mp4');
    final checked = expectLater(result, throwsA(_failure('无法读取本地视频信息')));
    await tester.pump();
    session.complete(null);
    await checked;
    expect(session.cancels, 0);
  });

  testWidgets('创建会话失败不会遗留计时器或未处理异常', (tester) async {
    final executor = FFmpegExecutor(
      probeSessionFactory: (_, _) async => throw StateError('create failed'),
    );
    await expectLater(
      executor.probe('input.mp4'),
      throwsA(_failure('无法读取本地视频信息')),
    );
    await tester.pump(const Duration(seconds: 31));
  });


  testWidgets('取消立即返回，原生退出前仍保留文件占用', (tester) async {
    final session = _RunSession();
    final executor = FFmpegExecutor(sessionFactory: _runFactory(session));
    final checked = expectLater(executor.run(['out.mp4']), throwsA(_failure('已取消')));
    await tester.pump();
    await executor.cancel();
    await checked;
    var idle = false;
    final exited = executor.waitForIdle().then((_) => idle = true);
    await tester.pump();
    expect(idle, isFalse);
    session.complete(255);
    await exited;
    expect(idle, isTrue);
  });

  testWidgets('探测取消后迟到结束也能释放占用', (tester) async {
    final session = _ProbeSession();
    final executor = _executor(session);
    final checked = expectLater(executor.probe('input.mp4'), throwsA(_failure('已取消')));
    await tester.pump();
    await executor.cancel();
    await checked;
    var idle = false;
    final exited = executor.waitForIdle().then((_) => idle = true);
    await tester.pump();
    expect(idle, isFalse);
    session.complete(_media);
    await exited;
    expect(idle, isTrue);
  });
  testWidgets('运行 statistics 回退与完成后的迟到回调被隔离', (tester) async {
    final session = _RunSession();
    final executor = FFmpegExecutor(sessionFactory: _runFactory(session));
    final values = <double>[];
    final result = executor.run(['out.mp4'], duration: 10, progress: values.add);
    await tester.pump();
    session.time(8);
    session.time(0);
    session.time(double.nan);
    session.time(12);
    expect(values, [.8, .99]);
    session.complete(0);
    await result;
    session.time(1);
    expect(values, [.8, .99]);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('运行创建卡住超时，迟到 ID 只取消不启动', (tester) async {
    final created = Completer<FFmpegSessionHandle>();
    final session = _RunSession();
    final executor = FFmpegExecutor(
      sessionTimeout: const Duration(seconds: 2),
      sessionFactory: (_, complete, log, time) {
        session.complete = complete;
        return created.future;
      },
    );
    final checked = expectLater(executor.run([]), throwsA(_failure('创建会话')));
    await tester.pump(const Duration(seconds: 2));
    await checked;
    created.complete(session);
    await tester.pump();
    expect(session.starts, 0);
    expect(session.cancels, 1);
    session.complete(0);
  });

  testWidgets('启动卡住超时且启动确认后再次定向取消', (tester) async {
    final session = _RunSession()..starting = Completer<void>();
    final executor = FFmpegExecutor(
      sessionTimeout: const Duration(seconds: 2),
      sessionFactory: _runFactory(session),
    );
    final checked = expectLater(executor.run([]), throwsA(_failure('启动会话')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await checked;
    expect(session.cancels, 1);
    session.starting!.complete();
    await tester.pump();
    expect(session.cancels, 2);
  });

  testWidgets('完成回调或返回码读取卡住有总超时', (tester) async {
    final session = _RunSession();
    final executor = FFmpegExecutor(
      runTimeout: const Duration(seconds: 2),
      sessionFactory: _runFactory(session),
    );
    final checked = expectLater(executor.run([]), throwsA(_failure('等待处理结果')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await checked;
    expect(session.cancels, 1);
  });

  testWidgets('取消不等原生完成且旧会话不能影响重启', (tester) async {
    final created = Completer<FFmpegSessionHandle>();
    final old = _RunSession()..cancelling = Completer<void>();
    final next = _RunSession();
    var calls = 0;
    final executor = FFmpegExecutor(sessionFactory: (args, complete, log, time) {
      if (calls++ == 0) { old.complete = complete; return created.future; }
      return _runFactory(next)(args, complete, log, time);
    });
    final checked = expectLater(executor.run([]), throwsA(_failure('已取消')));
    await executor.cancel();
    await checked;
    final restarted = executor.run([]);
    await tester.pump();
    created.complete(old);
    await tester.pump();
    expect(old.starts, 0);
    expect(old.cancels, 1);
    old.complete(1);
    expect(next.cancels, 0);
    next.complete(0);
    await restarted;
    old.cancelling!.complete();
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('失败保留有限脱敏日志，不包含密钥或完整命令', (tester) async {
    final session = _RunSession();
    final executor = FFmpegExecutor(sessionFactory: _runFactory(session));
    final checked = expectLater(executor.run([]), throwsA(isA<AppFailure>().having(
      (error) => error.toString(), 'bounded diagnostic', allOf(
        contains('等待处理结果'), contains('error 9'),
        isNot(contains('error 0')), isNot(contains('sensitive')),
        isNot(contains('/private/')), isNot(contains('ffmpeg -i')),
      ),
    )));
    await tester.pump();
    for (var i = 0; i < 10; i++) { session.log('error $i'); }
    session.log('token=sensitive');
    session.log('ffmpeg -i /private/input.mp4');
    session.log("Cannot open '/private/input.mp4'");
    session.complete(1);
    await checked;
  });

  testWidgets('运行中取消不等待卡住的原生取消，迟到回调无效', (tester) async {
    final session = _RunSession()..cancelling = Completer<void>();
    final executor = FFmpegExecutor(sessionFactory: _runFactory(session));
    final values = <double>[];
    final checked = expectLater(
      executor.run([], duration: 10, progress: values.add),
      throwsA(_failure('已取消')),
    );
    await tester.pump();
    session.time(4);
    await executor.cancel();
    await checked;
    session.time(9);
    session.complete(0);
    expect(values, [.4]);
    expect(session.cancels, 1);
    session.cancelling!.complete();
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('启动异常吞掉原生异常内容并清理会话', (tester) async {
    final session = _RunSession()..starting = Completer<void>();
    final executor = FFmpegExecutor(sessionFactory: _runFactory(session));
    final checked = expectLater(executor.run([]), throwsA(_failure('启动会话')));
    await tester.pump();
    session.starting!.completeError(StateError('sensitive platform error'));
    await checked;
    expect(session.cancels, 1);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('运行创建失败会结束等待', (tester) async {
    final executor = FFmpegExecutor(sessionFactory: (_, _, _, _) async =>
        throw StateError('platform create failed'));
    await expectLater(executor.run([]), throwsA(_failure('创建会话')));
    await tester.pump(const Duration(seconds: 31));
  });
}

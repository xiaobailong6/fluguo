import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/native_protocol.dart';
import 'package:duanju_app/native_request_pool.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> buildInfo() => {
  'allSources': allSourcesEnabled,
  'protocolVersion': 1,
  'minCompatibleVersion': 1,
  'capabilities': nativeRequiredCapabilities.toList(),
};

class ProtocolWorker implements NativeRequestWorker {
  ProtocolWorker(this.response);
  final Map<String, dynamic> response;
  final calls = <String>[];
  final _dead = Completer<void>();
  @override
  Future<void> get dead => _dead.future;
  @override
  Future<Map<String, dynamic>> execute(String body) async {
    calls.add((jsonDecode(body) as Map)['action'] as String);
    return response;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final incompatible = throwsA(
    isA<AppFailure>().having(
      (failure) => failure.code,
      'code',
      'protocol_mismatch',
    ),
  );

  test('当前版和未来向后兼容版通过，不要求应用显示版本相等', () {
    validateNativeProtocol(buildInfo(), allSources: allSourcesEnabled);
    validateNativeProtocol({
      ...buildInfo(),
      'protocolVersion': 3,
      'version': 'future',
    }, allSources: allSourcesEnabled);
  });

  for (final change in <String, Map<String, dynamic>>{
    '旧协议': {'protocolVersion': 0},
    '新不兼容协议': {'protocolVersion': 3, 'minCompatibleVersion': 2},
    '倒置范围': {'minCompatibleVersion': 2},
    '零下限': {'minCompatibleVersion': 0},
    '非法类型': {'protocolVersion': '1'},
    '缺少能力': {
      'capabilities': ['structuredErrors'],
    },
    '非法能力类型': {'capabilities': 'structuredErrors'},
    '版别不符': {'allSources': !allSourcesEnabled},
  }.entries) {
    test('${change.key}拒绝启动', () {
      expect(
        () => validateNativeProtocol({
          ...buildInfo(),
          ...change.value,
        }, allSources: allSourcesEnabled),
        incompatible,
      );
    });
  }

  test('缺失协议字段的同版别旧库不能通过', () {
    expect(
      () => validateNativeProtocol({
        'allSources': allSourcesEnabled,
      }, allSources: allSourcesEnabled),
      incompatible,
    );
  });

  test('真实 initialize 路径先验证协议，失败不调用路径插件或初始化业务', () async {
    final worker = ProtocolWorker({
      'ok': true,
      'data': {'allSources': allSourcesEnabled},
    });
    final repository = NativeRepository(
      background: true,
      dispatcher: NativeRequestDispatcher(() async => worker),
    );
    await expectLater(repository.initialize(), incompatible);
    expect(worker.calls, ['protocol']);
  });

  test('旧库不识别 protocol 时给出安装包提示', () async {
    final worker = ProtocolWorker({'ok': false, 'error': '应用核心尚未就绪'});
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(() async => worker),
    );
    await expectLater(repository.checkProtocol(), incompatible);
    expect(worker.calls, ['protocol']);
  });

  test('协议查询保留超时错误，不谎报不兼容', () async {
    final worker = ProtocolWorker({
      'ok': false,
      'error': 'timeout',
      'code': 'timeout',
    });
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(() async => worker),
    );
    await expectLater(
      repository.checkProtocol(),
      throwsA(
        isA<AppFailure>().having((failure) => failure.code, 'code', 'timeout'),
      ),
    );
  });
}

import 'app_failure.dart';

/// 协议号独立于应用版本；新增可选字段不升破坏性版本。
const nativeProtocolVersion = 1;
const nativeRequiredCapabilities = {
  'structuredErrors',
  'catalogWarningDetails',
};

/// 先查询纯协议信息，再允许初始化目录与后台任务；同版别旧 DLL 也不能混用。
void validateNativeProtocol(
  Map<String, dynamic> build, {
  required bool allSources,
}) {
  if (build['allSources'] != allSources) {
    throw const AppFailure(
      '应用与原生核心的站源版本不一致，请使用完整安装包重新安装',
      code: 'protocol_mismatch',
    );
  }
  final version = build['protocolVersion'];
  final minimum = build['minCompatibleVersion'];
  final capabilities = build['capabilities'];
  if (version is! int ||
      minimum is! int ||
      minimum < 1 ||
      minimum > version ||
      version < nativeProtocolVersion ||
      minimum > nativeProtocolVersion ||
      capabilities is! List ||
      !nativeRequiredCapabilities.every(capabilities.contains)) {
    throw const AppFailure(
      '应用与原生核心不兼容，请使用完整安装包重新安装',
      code: 'protocol_mismatch',
    );
  }
}

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 在GPU原生采样阶段交换色度，避免CPU lavfi滤镜与硬解输出格式不兼容。
const playbackChromaShaderSource = '''
//!HOOK NATIVE
//!BIND HOOKED
//!DESC FlGuo swap chroma
vec4 hook() {
    return HOOKED_tex(HOOKED_pos).xzyw;
}
''';

/// 同一进程只准备一次；主播放器与预览播放器共用同一个在途任务。
/// 初始化失败不缓存失败Future，后续显式重试仍可恢复。
class PlaybackChromaShader {
  PlaybackChromaShader({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  Future<String>? _pending;

  Future<String> prepare() =>
      _pending ??= _prepare().catchError((Object error) {
        _pending = null;
        throw error;
      });

  Future<String> _prepare() async {
    final directory = await _directory();
    await directory.create(recursive: true);
    final file = File(path.join(directory.path, 'fluguo_swap_chroma_v1.glsl'));
    // 文件名带版本，修改shader时可切换新文件，避免改写已被播放器加载的旧文件。
    if (!await file.exists() ||
        await file.readAsString() != playbackChromaShaderSource) {
      await file.writeAsString(playbackChromaShaderSource, flush: true);
    }
    return file.path;
  }
}

final playbackChromaShader = PlaybackChromaShader();

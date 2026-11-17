import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// 词典固定于 Xanerix/guoapp 5a7a116530fcf4242bfc6da08209585e267629cb。
// 图片归属及完整 Apache-2.0 许可见 assets/danmaku_emoji/LICENSE。
const Map<String, String> danmakuEmojiCodepoints = {
  '爽': '1f60c',
  '偷笑': '1f60f',
  '没看够': '1f97a',
  '笑': '1f604',
  '笑哭': '1f602',
  '尬笑': '1f605',
  '奸笑': '1f63c',
  '捂脸': '1f926',
  '爱慕': '1f60d',
  '飞吻': '1f618',
  '鼓掌': '1f44f',
  '赞': '1f44d',
  '送花': '1f490',
  '震惊': '1f631',
  '思考': '1f914',
  '抓狂': '1f62b',
  '怒': '1f620',
  '害羞': '1f60a',
  '哭': '1f622',
  '快哭了': '1f979',
  '求爆更': '1f64f',
  'OK': '1f44c',
  '什么': '2753',
  '流泪': '1f62d',
  '大笑': '1f606',
  '微笑': '1f642',
  '坏笑': '1f608',
  '白眼': '1f644',
  '疑问': '2754',
  '闭嘴': '1f910',
  '色': '1f61b',
  '调皮': '1f61c',
  '难过': '1f614',
  '馋': '1f924',
  '晕': '1f635',
  '流汗': '1f613',
  '生病': '1f912',
  '睡着': '1f634',
  '狗头': '1f436',
  '比心': '1f91f',
  '火': '1f525',
  '加油': '1f4aa',
  '抱抱': '1f917',
  '吃瓜': '1f349',
  '无语': '1f611',
  '666': '1f44c',
  '爱心': '2764-fe0f',
  '拳头': '1f44a',
  '狂笑': '1f923',
  '惊喜': '1f929',
};

final _pattern = RegExp(r'\[([^\[\]\s]{1,8})\]');
final _assets = {
  for (final code in danmakuEmojiCodepoints.values)
    'assets/danmaku_emoji/$code.png',
};
const danmakuEmojiLicense = 'assets/danmaku_emoji/LICENSE';
bool _licenseRegistered = false;

void registerDanmakuEmojiLicense() {
  if (_licenseRegistered) return;
  _licenseRegistered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Noto Emoji (Google LLC)',
    ], await rootBundle.loadString(danmakuEmojiLicense));
  });
}

class DanmakuSegment {
  const DanmakuSegment.text(this.text) : asset = null;
  const DanmakuSegment.emoji(this.text, this.asset);

  /// 即使是表情也保留原始 [名称]，别名和失败回退不反查、不改写。
  final String text;
  final String? asset;
}

String? danmakuEmojiAsset(String name) {
  final code = danmakuEmojiCodepoints[name];
  return code == null ? null : 'assets/danmaku_emoji/$code.png';
}

List<DanmakuSegment> parseDanmakuSegments(String text) {
  final segments = <DanmakuSegment>[];
  var cursor = 0;
  for (final match in _pattern.allMatches(text)) {
    final asset = danmakuEmojiAsset(match.group(1)!);
    if (asset == null) continue;
    if (match.start > cursor) {
      segments.add(DanmakuSegment.text(text.substring(cursor, match.start)));
    }
    segments.add(DanmakuSegment.emoji(match.group(0)!, asset));
    cursor = match.end;
  }
  if (cursor < text.length) {
    segments.add(DanmakuSegment.text(text.substring(cursor)));
  }
  return List.unmodifiable(segments);
}

/// 只缓存白名单的 49 张 64px 图片（约 784 KiB 解码内存），不缓存任意文字。
/// 同一资源（含别名）的并发请求共享一次解码；失败也记忆，避免逐条重试。
/// 默认实例随进程复用；测试/独立实例可 dispose，迟到解码立即释放。
class DanmakuEmojiCache extends ChangeNotifier {
  DanmakuEmojiCache({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;
  static final shared = DanmakuEmojiCache();
  final AssetBundle _bundle;
  final _pending = <String, Future<void>>{};
  final _images = <String, ui.Image?>{};
  bool _closed = false;

  ui.Image? image(String asset) => _images[asset];

  Future<void> load(String asset) {
    if (_closed || !_assets.contains(asset) || _images.containsKey(asset)) {
      return Future.value();
    }
    return _pending.putIfAbsent(asset, () => _load(asset));
  }

  Future<void> _load(String asset) async {
    ui.Image? image;
    try {
      final bytes = await _bundle.load(asset);
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        targetWidth: 64,
        targetHeight: 64,
      );
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      // 缺失/损坏资源都保留 [名称]；不替换成无关的 Unicode 表情。
    }
    _pending.remove(asset);
    if (_closed) {
      image?.dispose();
      return;
    }
    _images[asset] = image;
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    for (final image in _images.values) {
      image?.dispose();
    }
    _images.clear();
    super.dispose();
  }
}

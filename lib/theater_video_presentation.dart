import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

typedef PreviewVideoFrame = ({
  int epoch,
  Size? displaySize,
  Rect? texture,
  int? textureId,
  bool ready,
});

/// 使用同一个 videoParams 事件中的成对显示尺寸，不能混合新宽与旧高。
Size? previewDisplaySize(VideoParams parameters) {
  final width = parameters.dw;
  final height = parameters.dh;
  if (width == null || height == null || width <= 1 || height <= 1) {
    return null;
  }
  final rotation = (parameters.rotate ?? 0) % 180;
  return rotation == 90
      ? Size(height.toDouble(), width.toDouble())
      : Size(width.toDouble(), height.toDouble());
}

/// 每次换剧都清理尺寸，不让复用播放器的旧纹理先参与新媒体布局。
class TheaterVideoPresentation extends ValueNotifier<PreviewVideoFrame> {
  TheaterVideoPresentation()
    : super((
        epoch: 0,
        displaySize: null,
        texture: null,
        textureId: null,
        ready: false,
      ));

  int _epoch = 0;
  bool _accepting = false;
  bool _opened = false;
  Size? _display;
  Rect? _texture;
  int? _textureId;

  void begin() {
    _epoch++;
    _accepting = true;
    _opened = false;
    _display = null;
    _publish();
  }

  void parametersChanged(VideoParams parameters) {
    if (!_accepting) return;
    _display = previewDisplaySize(parameters);
    _publish();
  }

  void textureChanged(Rect? texture, int? textureId) {
    _texture = texture;
    _textureId = textureId;
    _publish();
  }

  void opened() {
    if (!_accepting) return;
    _opened = true;
    _publish();
  }

  void stop() {
    _epoch++;
    _accepting = false;
    _opened = false;
    _display = null;
    _publish();
  }

  void _publish() {
    final display = _display;
    final texture = _texture;
    var synchronized = false;
    if (_accepting &&
        _opened &&
        display != null &&
        texture != null &&
        _textureId != null &&
        _textureId! >= 0 &&
        texture.width.isFinite &&
        texture.height.isFinite &&
        texture.width > 1 &&
        texture.height > 1) {
      final displayRatio = display.width / display.height;
      final textureRatio = texture.width / texture.height;
      // 允许纹理整数取整，但不允许横竖旧比例或1x1初始化表面穿透。
      synchronized = (textureRatio / displayRatio - 1).abs() <= .015;
    }
    value = (
      epoch: _epoch,
      displaySize: display,
      texture: texture,
      textureId: _textureId,
      ready: synchronized,
    );
  }
}

/// 保持 Video/Texture 挂载，只遮住未同步帧；不能用 Offstage 阻断原生首帧。
class StablePreviewSurface extends StatefulWidget {
  const StablePreviewSurface({
    super.key,
    required this.presentation,
    required this.videoBuilder,
  });
  final TheaterVideoPresentation presentation;
  final Widget Function(double? aspectRatio) videoBuilder;

  @override
  State<StablePreviewSurface> createState() => _StablePreviewSurfaceState();
}

class _StablePreviewSurfaceState extends State<StablePreviewSurface> {
  PreviewVideoFrame? _revealed;
  PreviewVideoFrame? _scheduled;

  @override
  void initState() {
    super.initState();
    widget.presentation.addListener(_changed);
  }

  @override
  void didUpdateWidget(StablePreviewSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.presentation, widget.presentation)) return;
    oldWidget.presentation.removeListener(_changed);
    widget.presentation.addListener(_changed);
    _revealed = null;
    _scheduled = null;
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      _revealed = null;
      _scheduled = null;
    });
  }

  @override
  void dispose() {
    widget.presentation.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.presentation.value;
    if (frame.ready && _revealed != frame && _scheduled != frame) {
      _scheduled = frame;
      // 先让显式比例和原生纹理完成同一帧布局，再开放画面，不插入固定延时。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.presentation.value != frame || !frame.ready) {
          return;
        }
        setState(() => _revealed = frame);
      });
    }
    final size = frame.displaySize;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.videoBuilder(size == null ? null : size.width / size.height),
          if (!frame.ready || _revealed != frame)
            const Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  key: ValueKey('preview-frame-cover'),
                  color: Color(0xFF000000),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 同一直播房间/分区在连续缩放窗口时只产生有限个解码宽度。
/// 以物理像素向上取档，沿用直播图原有的 1200px 上限；另一维由解码器保持比例。
int liveThumbnailWidth(double logicalWidth, double devicePixelRatio) {
  const tiers = [128, 192, 256, 384, 512, 768, 1024, 1200];
  final pixels = logicalWidth * devicePixelRatio;
  if (pixels.isNaN || pixels <= 0) return tiers.first;
  return tiers.firstWhere((width) => width >= pixels, orElse: () => tiers.last);
}

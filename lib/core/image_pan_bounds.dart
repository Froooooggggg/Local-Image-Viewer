import 'dart:math' as math;
import 'dart:ui';

/// 图片在视口内平移时的边界计算。
///
/// 抽成纯函数是为了**可测试**：这段几何关系我写错过两次，两次都表现为
/// "图片乱移 + 一帧就闪到下一张"，而这类问题看代码很难发现，
/// 只有对着具体数值算一遍才靠得住。
class ImagePanBounds {
  const ImagePanBounds._();

  /// 图片在 1× 时的实际显示尺寸。
  ///
  /// `BoxFit.contain` 既会放大也会缩小：
  ///   * 大图被缩小到刚好放进视口 → 占满一个方向、另一个方向留白
  ///   * 小图保持原始像素（不放大）
  ///
  /// 返回 Size.zero 表示尺寸不可用。
  static Size displaySize({
    required double imageWidth,
    required double imageHeight,
    required Size viewport,
  }) {
    if (imageWidth <= 0 || imageHeight <= 0 || viewport.isEmpty) {
      return Size.zero;
    }
    final fit = math.min(
      math.min(viewport.width / imageWidth, viewport.height / imageHeight),
      1.0, // 小图不放大
    );
    return Size(imageWidth * fit, imageHeight * fit);
  }

  /// 缩放后允许的最大平移量（各方向）。
  ///
  /// 边界 = (显示尺寸 × 缩放倍数 − 视口) / 2，负值取 0。
  ///
  /// **两个条件都要满足才能平移**：缩放倍数 > 1，且放大后的图片确实比视口大。
  /// 例如一张刚好填满视口的图，1× 时 maxX = 0（不能左右移动，合理）；
  /// 2× 时才有一半视口宽度的移动余地。
  static Offset maxPan({
    required double imageWidth,
    required double imageHeight,
    required Size viewport,
    required double scale,
  }) {
    if (scale <= 1.001) return Offset.zero;

    final base = displaySize(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      viewport: viewport,
    );
    if (base.isEmpty) return Offset.zero;

    final maxX = math.max(0.0, (base.width * scale - viewport.width) / 2);
    final maxY = math.max(0.0, (base.height * scale - viewport.height) / 2);
    return Offset(maxX, maxY);
  }

  /// 把平移量夹到允许范围内。
  static Offset clamp({
    required Offset pan,
    required double imageWidth,
    required double imageHeight,
    required Size viewport,
    required double scale,
  }) {
    final max = maxPan(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      viewport: viewport,
      scale: scale,
    );
    return Offset(
      pan.dx.clamp(-max.dx, max.dx).toDouble(),
      pan.dy.clamp(-max.dy, max.dy).toDouble(),
    );
  }
}

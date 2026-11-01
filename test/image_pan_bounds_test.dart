import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_gallery_viewer/core/image_pan_bounds.dart';

/// 平移边界的几何计算。
///
/// 为什么专门测它：这段关系我写错过两次，两次的表现都是
/// "图片乱移 + 一帧就闪到下一张"，而看代码很难发现 —— 只有对着具体
/// 数值算一遍才靠得住。
void main() {
  // 竖屏手机视口（逻辑像素）
  const viewport = Size(400, 800);

  group('displaySize（contain 之后的尺寸）', () {
    test('大图被缩小到刚好放进视口', () {
      // 2000×4000 的竖图：高度先受限，缩到 400×800
      final s = ImagePanBounds.displaySize(
        imageWidth: 2000,
        imageHeight: 4000,
        viewport: viewport,
      );
      expect(s.width, closeTo(400, 0.01));
      expect(s.height, closeTo(800, 0.01));
    });

    test('宽图按宽度受限，高度留白', () {
      // 4000×1000 的横图 → 400×100
      final s = ImagePanBounds.displaySize(
        imageWidth: 4000,
        imageHeight: 1000,
        viewport: viewport,
      );
      expect(s.width, closeTo(400, 0.01));
      expect(s.height, closeTo(100, 0.01));
    });

    test('小图不放大，保持原始像素', () {
      final s = ImagePanBounds.displaySize(
        imageWidth: 100,
        imageHeight: 50,
        viewport: viewport,
      );
      expect(s.width, 100);
      expect(s.height, 50);
    });

    test('尺寸不可用时返回零', () {
      expect(
        ImagePanBounds.displaySize(
          imageWidth: 0,
          imageHeight: 100,
          viewport: viewport,
        ),
        Size.zero,
      );
      expect(
        ImagePanBounds.displaySize(
          imageWidth: 100,
          imageHeight: 100,
          viewport: Size.zero,
        ),
        Size.zero,
      );
    });
  });

  group('maxPan（放大后的可移动范围）', () {
    test('1× 时不能平移（两个方向都是 0）', () {
      final m = ImagePanBounds.maxPan(
        imageWidth: 2000,
        imageHeight: 4000,
        viewport: viewport,
        scale: 1.0,
      );
      expect(m.dx, 0);
      expect(m.dy, 0);
    });

    test('竖图放大 2×：左右可移动半个视口宽，上下可移动半个视口高', () {
      // 显示尺寸 400×800，2× → 800×1600
      // maxX = (800-400)/2 = 200，maxY = (1600-800)/2 = 400
      final m = ImagePanBounds.maxPan(
        imageWidth: 2000,
        imageHeight: 4000,
        viewport: viewport,
        scale: 2.0,
      );
      expect(m.dx, closeTo(200, 0.01));
      expect(m.dy, closeTo(400, 0.01));
    });

    test('刚好填满视口的图在 1× 时不可移动，2× 时可移动半个视口', () {
      // 这正是之前写错的情形：contain 后已填满，再乘倍数会把 1× 也算成放大
      const w = 400.0, h = 800.0;
      final at1 = ImagePanBounds.maxPan(
        imageWidth: w,
        imageHeight: h,
        viewport: viewport,
        scale: 1.0,
      );
      expect(at1, Offset.zero, reason: '1× 且刚好填满 → 不能移动');

      final at2 = ImagePanBounds.maxPan(
        imageWidth: w,
        imageHeight: h,
        viewport: viewport,
        scale: 2.0,
      );
      expect(at2.dx, closeTo(200, 0.01));
      expect(at2.dy, closeTo(400, 0.01));
    });

    test('横图放大后只有左右有移动余地（高度已含在视口内）', () {
      // 4000×1000 → 显示 400×100；2× → 800×200
      // maxX = (800-400)/2 = 200；maxY = (200-800)/2 < 0 → 0
      final m = ImagePanBounds.maxPan(
        imageWidth: 4000,
        imageHeight: 1000,
        viewport: viewport,
        scale: 2.0,
      );
      expect(m.dx, closeTo(200, 0.01));
      expect(m.dy, 0, reason: '高度仍小于视口，不应有上下移动余地');
    });

    test('放大幅度不足以超出视口时不可移动', () {
      // 显示 400×100，放大到 1.5× → 600×150，左右可动
      final m = ImagePanBounds.maxPan(
        imageWidth: 4000,
        imageHeight: 1000,
        viewport: viewport,
        scale: 1.5,
      );
      expect(m.dx, closeTo(100, 0.01)); // (600-400)/2
      expect(m.dy, 0);
    });
  });

  group('clamp（夹取平移量）', () {
    test('超出范围会被夹到边界（缩放后到底能拖多远）', () {
      final c = ImagePanBounds.clamp(
        pan: const Offset(9999, -9999),
        imageWidth: 2000,
        imageHeight: 4000,
        viewport: viewport,
        scale: 2.0,
      );
      expect(c.dx, closeTo(200, 0.01));
      expect(c.dy, closeTo(-400, 0.01));
    });

    test('范围内保持不变', () {
      final c = ImagePanBounds.clamp(
        pan: const Offset(50, -80),
        imageWidth: 2000,
        imageHeight: 4000,
        viewport: viewport,
        scale: 2.0,
      );
      expect(c, const Offset(50, -80));
    });

    test('1× 时任何平移都被归零', () {
      final c = ImagePanBounds.clamp(
        pan: const Offset(100, 100),
        imageWidth: 2000,
        imageHeight: 4000,
        viewport: viewport,
        scale: 1.0,
      );
      expect(c, Offset.zero);
    });

    test('回归：边界不能小到"一拖就贴边"', () {
      // 曾经的错误实现算出边界只有零点几像素，导致平移立刻被判为贴边、
      // 一帧就跨过翻页阈值直接跳页。这里确保 2× 时有实质的移动余地。
      final c = ImagePanBounds.clamp(
        pan: const Offset(150, 300),
        imageWidth: 2000,
        imageHeight: 4000,
        viewport: viewport,
        scale: 2.0,
      );
      expect(c.dx, closeTo(150, 0.01), reason: '150 在 (0, 200) 内，不应被夹住');
      expect(c.dy, closeTo(300, 0.01), reason: '300 在 (0, 400) 内，不应被夹住');
    });
  });
}

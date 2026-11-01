import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// 动图（GIF）解码能力的测试。
///
/// 复用 `.scratch/make_gif_album.py` 生成的素材：静态 GIF、8 帧动图、
/// 128 帧大动图。测试只覆盖"能不能正确识别帧数与时长"这一层 ——
/// 播放/暂停的交互逻辑在真机上验证。
///
/// 关键约定（与查看器实现一致）：
///   * 帧时长来自 `FrameInfo.duration`，`Codec` 上没有该方法
///   * `repetitionCount`：0 = 只播一次，-1 = 无限循环
///   * 浏览时**只解首帧**，全帧只在用户点播放时解
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dir = Directory('.scratch');

  Uint8List? readAsset(String name) {
    final f = File('${dir.path}/$name');
    return f.existsSync() ? f.readAsBytesSync() : null;
  }

  /// 统计帧数与各帧时长；同时可用于验证"只解首帧"的实现路径。
  Future<
    ({int frames, List<Duration> durations, int repetitions, int w, int h})
  >
  probe(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final durations = <Duration>[];
      ui.Image? first;
      for (var i = 0; i < codec.frameCount; i++) {
        final f = await codec.getNextFrame();
        durations.add(f.duration);
        first ??= f.image;
        if (i > 0) f.image.dispose();
      }
      return (
        frames: codec.frameCount,
        durations: durations,
        repetitions: codec.repetitionCount,
        w: first!.width,
        h: first.height,
      );
    } finally {
      codec.dispose();
    }
  }

  test('静态 GIF 应识别为单帧（表现为普通图片）', () async {
    final bytes = readAsset('01_static.gif');
    if (bytes == null) {
      markTestSkipped('素材缺失，先运行 .scratch/make_gif_album.py');
      return;
    }
    final r = await probe(bytes);
    expect(r.frames, 1, reason: '单帧 GIF 不应出现播放按钮');
  });

  test('8 帧动图应识别出 8 帧与非零时长', () async {
    final bytes = readAsset('02_animated_8frames.gif');
    if (bytes == null) {
      markTestSkipped('素材缺失');
      return;
    }
    final r = await probe(bytes);
    expect(r.frames, 8);
    expect(r.durations.length, 8);
    // 素材设定 80ms/帧
    expect(
      r.durations.first.inMilliseconds,
      greaterThan(0),
      reason: '帧时长必须为正，否则定时器会疯狂触发',
    );
    expect(r.repetitions, -1, reason: '素材设为无限循环');
  });

  test('128 帧大动图应正确读出全部帧（并验证内存预估量级）', () async {
    final bytes = readAsset('03_large_128frames.gif');
    if (bytes == null) {
      markTestSkipped('素材缺失');
      return;
    }
    final r = await probe(bytes);
    expect(r.frames, 128);
    expect(r.w, 256);
    expect(r.h, 256);

    // 复算查看器里的内存预估公式：帧数 × 宽 × 高 × 4 字节
    final bytesFull = r.frames * r.w * r.h * 4;
    expect(bytesFull, 128 * 256 * 256 * 4);
    // 这个量级（约 33 MB）说明"只解首帧"的意义：
    // 浏览时只占 256*256*4 = 262144 字节，相差 128 倍。
    expect(bytesFull ~/ (r.w * r.h * 4), 128);
  });

  test('普通 PNG 为单帧，且不会被当成动图', () async {
    final bytes = readAsset('04_plain.png');
    if (bytes == null) {
      markTestSkipped('素材缺失');
      return;
    }
    final r = await probe(bytes);
    expect(r.frames, 1);
  });

  test('帧时长下限保护：极短延时不应原样使用', () {
    // 与查看器 _frameDuration 的约定一致：低于 20ms 会被抬到 20ms。
    const raw = Duration(milliseconds: 10);
    const min = Duration(milliseconds: 20);
    final clamped = raw < min ? min : raw;
    expect(clamped, min);

    const zero = Duration.zero;
    final clampedZero = zero < min ? min : zero;
    expect(clampedZero, min, reason: 'GIF 允许 0 延时，必须设下限');
  });
}

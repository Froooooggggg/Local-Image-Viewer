import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// 校验测试包里的 PNG 生成逻辑：程序造出来的 PNG 必须能被真实解码器解码，
/// 否则真机点击只会显示「无法解码」，测试数据本身就是坏的。
///
/// 这里故意重放与 .scratch/zipprobe/bin/make_test_album.dart 相同的生成逻辑，
/// 确保造包脚本产出的字节是合法 PNG。
Uint8List solidPng(int w, int h, int r, int g, int b) {
  final raw = BytesBuilder();
  final row = Uint8List(w * 3 + 1);
  for (var x = 0; x < w; x++) {
    row[1 + x * 3] = r;
    row[2 + x * 3] = g;
    row[3 + x * 3] = b;
  }
  for (var y = 0; y < h; y++) {
    raw.add(row);
  }
  final idatData = const ZLibEncoder().encode(raw.toBytes());

  final ihdr = Uint8List(13);
  final bd = ByteData.sublistView(ihdr);
  bd.setUint32(0, w);
  bd.setUint32(4, h);
  ihdr[8] = 8;
  ihdr[9] = 2;
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  Uint8List chunk(String type, List<int> data) {
    final out = BytesBuilder();
    final len = Uint8List(4);
    ByteData.sublistView(len).setUint32(0, data.length);
    out.add(len);
    final typeBytes = type.codeUnits;
    out.add(typeBytes);
    out.add(data);
    final crc = Uint8List(4);
    ByteData.sublistView(crc).setUint32(0, getCrc32([...typeBytes, ...data]));
    out.add(crc);
    return out.toBytes();
  }

  return Uint8List.fromList([
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    ...chunk('IHDR', ihdr),
    ...chunk('IDAT', idatData),
    ...chunk('IEND', const []),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('生成的 PNG 能被真实解码，且尺寸正确', () async {
    for (final spec in [
      [1200, 400],
      [400, 1200],
      [800, 800],
      [1600, 200],
      [200, 1600],
    ]) {
      final w = spec[0];
      final h = spec[1];
      final bytes = solidPng(w, h, 200, 80, 80);

      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, w, reason: '${w}x$h 宽度应一致');
      expect(frame.image.height, h, reason: '${w}x$h 高度应一致');
      frame.image.dispose();
      codec.dispose();
    }
  });

  test('生成器产出的包能被解析器正确索引', () {
    // 与造包脚本一致：18 张图片 + 2 个非图片
    final archive = Archive();
    for (var i = 1; i <= 18; i++) {
      final bytes = solidPng(100 + i, 50 + i, 10, 20, 30);
      archive.addFile(
        ArchiveFile('test_album/img_$i.png', bytes.length, bytes),
      );
    }
    for (final name in ['test_album/readme.txt', 'test_album/info.md']) {
      final bytes = 'text'.codeUnits;
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    final encoded = ZipEncoder().encode(archive)!;

    // 用编码结果直接再解码一次，确认往返一致（结构层面）。
    final decoded = ZipDecoder().decodeBytes(encoded);
    expect(decoded.files.length, 20);

    String ext(String n) => n.substring(n.lastIndexOf('.') + 1).toLowerCase();
    final images = decoded.files
        .where(
          (f) => const {
            'jpg',
            'jpeg',
            'png',
            'webp',
            'bmp',
            'gif',
          }.contains(ext(f.name)),
        )
        .toList();
    expect(images.length, 18, reason: '应识别 18 张图片');
  });
}

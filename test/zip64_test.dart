import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_gallery_viewer/core/archive_reader.dart';
import 'package:simple_gallery_viewer/core/byte_source.dart';

/// Zip64 解析测试。
///
/// 为什么重要：用户的图集包里有 10 GB / 6.7 GB 的 zip，**超过 4 GB 必须使用
/// Zip64 格式** —— 此时 EOCD 里的中央目录偏移与大小是 0xFFFFFFFF 哨兵值，
/// 真实值只能从 Zip64 EOCD Locator + Zip64 EOCD Record 读取。
/// 这段代码之前完全没有被真实文件覆盖过。
void main() {
  test('条目数超过 65535（触发 Zip64）时仍能正确索引', () async {
    final archive = Archive();
    const count = 70000; // > 0xFFFF，强制编码器写 Zip64
    for (var i = 0; i < count; i++) {
      final bytes = <int>[0xFF, 0xD8, 0xFF, i % 251];
      final f = ArchiveFile('a$i.jpg', bytes.length, bytes);
      f.compress = false; // 存储方式，编码更快
      archive.addFile(f);
    }

    final encoded = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final bd = ByteData.sublistView(encoded);

    // 先确认这份数据确实是 Zip64 形态，否则本测试没有意义。
    var eocd = -1;
    for (var i = encoded.length - 22; i >= 0; i--) {
      if (bd.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    expect(eocd, greaterThan(0), reason: '应能找到 EOCD');
    final totalInEocd = bd.getUint16(eocd + 10, Endian.little);
    expect(
      totalInEocd,
      0xffff,
      reason: '条目数超限时 EOCD 应写哨兵值 0xFFFF，说明这是 Zip64 数据',
    );
    // Zip64 EOCD Locator 紧邻 EOCD 之前
    expect(
      bd.getUint32(eocd - 20, Endian.little),
      0x07064b50,
      reason: 'EOCD 之前应是 Zip64 EOCD Locator',
    );

    final source = MemoryByteSource(encoded);
    try {
      final index = await ZipIndex.openSource(source);
      expect(index.totalEntries, count, reason: 'Zip64 中央目录应被完整解析，条目数不得截断');
      expect(index.imageCount, count);
    } finally {
      await source.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('Zip64 数据也能按需提取单张图片', () async {
    final archive = Archive();
    const count = 70000;
    for (var i = 0; i < count; i++) {
      final bytes = <int>[0xFF, 0xD8, 0xFF, i % 251];
      final f = ArchiveFile('a$i.jpg', bytes.length, bytes);
      f.compress = false;
      archive.addFile(f);
    }
    final encoded = Uint8List.fromList(ZipEncoder().encode(archive)!);

    final source = MemoryByteSource(encoded);
    try {
      final index = await ZipIndex.openSource(source);
      // 取首尾两张，验证偏移计算在 Zip64 下也正确
      final first = await index.imageEntries.first.read(source);
      expect(first, equals([0xFF, 0xD8, 0xFF, 0]));
      final last = await index.imageEntries.last.read(source);
      expect(last, equals([0xFF, 0xD8, 0xFF, (count - 1) % 251]));
    } finally {
      await source.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

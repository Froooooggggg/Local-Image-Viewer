import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_gallery_viewer/core/archive_reader.dart';
import 'package:simple_gallery_viewer/core/byte_source.dart';

/// 内嵌 Zip64 扩展字段的解析测试。
///
/// 背景（真实缺陷）：用户的 1999 张图压缩包里，**前 1236 张能读、之后全部失败**。
///
/// 成因：按 zip 规范（APPNOTE 4.5.3），Zip64 扩展字段中**只包含**那些在中央
/// 目录里被写成 0xFFFFFFFF 的字段，顺序固定但**按需出现**。
/// 旧实现无条件依次读三个 8 字节（未压缩大小、压缩大小、本地头偏移），
/// 因此在"只有本地头偏移溢出"的常见情形下（>4 GB 的内嵌 ZIP64 包）读到错位的
/// 垃圾值，导致 localHeaderOffset 完全错误 —— 越过 4 GB 的条目起全部读不出来。
///
/// 这里直接手工构造 zip 字节：真实的 4 GB 文件无法在单元测试里生成。
void main() {
  const le = Endian.little;

  /// 手工构造一个 zip。
  ///
  /// [onlyOffsetIsZip64] 为 true 时复现缺陷场景：中央目录里的
  /// compressedSize / uncompressedSize 是**真实值**，只有 localHeaderOffset
  /// 是 0xFFFFFFFF，因此 Zip64 扩展字段里**只有 8 字节的偏移**。
  /// 为 false 时三个字段都是哨兵，扩展字段里有 24 字节。
  Uint8List buildInlinedZip64({
    required bool onlyOffsetIsZip64,
    required int localHeaderOffset,
    required List<int> payload,
  }) {
    const name = 'a.jpg';
    final nameBytes = Uint8List.fromList(name.codeUnits);
    final payloadLen = payload.length;

    final out = BytesBuilder();
    void u16(int v) =>
        out.add((ByteData(2)..setUint16(0, v, le)).buffer.asUint8List());
    void u32(int v) =>
        out.add((ByteData(4)..setUint32(0, v, le)).buffer.asUint8List());
    void u64(int v) =>
        out.add((ByteData(8)..setUint64(0, v, le)).buffer.asUint8List());

    // ---- 本地文件头（就在文件开头，偏移 0）----
    u32(0x04034b50);
    u16(45); // version needed (4.5 = zip64)
    u16(0); // flags
    u16(0); // method = 存储
    u16(0); // time
    u16(0x21); // date（随便给个合法值）
    u32(0); // crc32（不校验）
    u32(payloadLen); // compressed size
    u32(payloadLen); // uncompressed size
    u16(nameBytes.length);
    u16(0); // extra len
    out.add(nameBytes);
    out.add(payload);

    final centralOffset = out.length;

    // ---- 中央目录条目 ----
    u32(0x02014b50);
    u16(45); // version made by
    u16(45); // version needed
    u16(0); // flags
    u16(0); // method
    u16(0); // time
    u16(0x21); // date
    u32(0); // crc32
    if (onlyOffsetIsZip64) {
      u32(payloadLen); // 真实压缩大小
      u32(payloadLen); // 真实未压缩大小
    } else {
      u32(0xffffffff);
      u32(0xffffffff);
    }
    u16(nameBytes.length);
    final extraLen = onlyOffsetIsZip64 ? 12 : 28; // 4 字节头 + 8 或 24
    u16(extraLen);
    u16(0); // comment len
    u16(0); // disk number
    u16(0); // internal attrs
    u32(0); // external attrs
    u32(0xffffffff); // local header offset ← 哨兵
    out.add(nameBytes);

    // Zip64 扩展字段：id=1，size=8 或 24
    final zip64PayloadLen = onlyOffsetIsZip64 ? 8 : 24;
    u16(1);
    u16(zip64PayloadLen);
    if (!onlyOffsetIsZip64) {
      u64(payloadLen); // uncompressed
      u64(payloadLen); // compressed
    }
    u64(localHeaderOffset); // 本地头偏移 —— 唯一真正需要的字段

    final centralSize = out.length - centralOffset;

    // ---- EOCD ----
    u32(0x06054b50);
    u16(0);
    u16(0);
    u16(1);
    u16(1);
    u32(centralSize);
    u32(centralOffset);
    u16(0);

    return out.takeBytes();
  }

  test('只有本地头偏移溢出时（内嵌 ZIP64）能正确定位并读出', () async {
    // 模拟"本地头偏移已越过 4 GB"：哨兵值在中央目录里是 0xFFFFFFFF，
    // 真实偏移放在 Zip64 扩展字段里。
    const realOffset = 0; // 本地头真的在文件开头
    final payload = List<int>.generate(4096, (i) => (i * 7 + 3) & 0xFF);
    final zip = buildInlinedZip64(
      onlyOffsetIsZip64: true,
      localHeaderOffset: realOffset,
      payload: payload,
    );

    final source = MemoryByteSource(zip);
    try {
      final index = await ZipIndex.openSource(source);
      expect(index.imageCount, 1);

      final entry = index.imageEntries.first;
      // 这是缺陷的核心：旧实现会把 offset 读成垃圾值。
      expect(
        entry.localHeaderOffset,
        realOffset,
        reason: '本地头偏移必须从 Zip64 扩展字段正确解出',
      );

      final got = await entry.read(source);
      expect(got.length, payload.length);
      expect(got, equals(payload));
    } finally {
      await source.close();
    }
  });

  test('三个字段都是哨兵时（完整 ZIP64）仍能正确定位', () async {
    const realOffset = 0;
    final payload = List<int>.generate(2048, (i) => (i * 13 + 5) & 0xFF);
    final zip = buildInlinedZip64(
      onlyOffsetIsZip64: false,
      localHeaderOffset: realOffset,
      payload: payload,
    );

    final source = MemoryByteSource(zip);
    try {
      final index = await ZipIndex.openSource(source);
      final entry = index.imageEntries.first;
      expect(entry.localHeaderOffset, realOffset);
      expect(entry.compressedSize, payload.length);
      expect(entry.uncompressedSize, payload.length);

      final got = await entry.read(source);
      expect(got, equals(payload));
    } finally {
      await source.close();
    }
  });

  test('回归：大偏移值（>4 GiB）能被完整解析为 64 位', () async {
    // 本地头偏移超过 32 位：若按 32 位截断就会指向错误位置。
    const bigOffset = 6 * 1024 * 1024 * 1024; // 6 GiB
    final payload = List<int>.generate(256, (i) => i & 0xFF);
    final zip = buildInlinedZip64(
      onlyOffsetIsZip64: true,
      localHeaderOffset: bigOffset,
      payload: payload,
    );

    final source = MemoryByteSource(zip);
    try {
      final index = await ZipIndex.openSource(source);
      final entry = index.imageEntries.first;
      expect(entry.localHeaderOffset, bigOffset, reason: '不应被截断成 32 位');
    } finally {
      await source.close();
    }
  });
}

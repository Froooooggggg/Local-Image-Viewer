import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_gallery_viewer/core/archive_reader.dart';
import 'package:simple_gallery_viewer/core/byte_source.dart';

/// 验证"按整个条目读取"在条目体积较大时是否成立。
///
/// 背景：原生侧 `readBytes` 有一个 16 MB 的单次分配上限（为了避免 Java 侧
/// 分配失败导致引擎崩溃）。而 zip 条目是**按压缩后大小整体读取**的，
/// 因此单个条目超过该上限时会被静默截断 —— 表现就是"某些图片读不出来"。
/// 模拟原生侧的**单次分配上限**：任何超过 [cap] 的请求都会被截断。
///
/// 真实的 `content://` 读取就是这样：原生 `readBytes` 按请求长度一次性分配
/// `ByteArray`，超过上限的请求只会拿到前一段，且**不会报错**。
/// 这正是"超大压缩包里靠后的图片固定读不出来"的成因 ——
/// 条目按压缩后大小整体读取，超过上限即被静默截断。
class CappedByteSource implements ByteSource {
  CappedByteSource(this._inner, this.cap);

  final ByteSource _inner;
  final int cap;
  int truncations = 0;

  @override
  Future<int> length() => _inner.length();

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (count > cap) {
      truncations++;
      return _inner.read(offset, cap);
    }
    return _inner.read(offset, count);
  }

  @override
  Future<TailChunk> readTail(int maxBytes) => _inner.readTail(maxBytes);

  @override
  Future<void> close() => _inner.close();

  @override
  String get describe => 'Capped(${_inner.describe}, cap=$cap)';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 生成一个**不可压缩**的载荷：随机字节无法被 deflate 压缩，
  /// 因此"压缩后大小"≈"原始大小"，正好用来构造超大条目。
  Uint8List incompressible(int size, int seed) {
    final out = Uint8List(size);
    var s = seed;
    for (var i = 0; i < size; i++) {
      s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
      out[i] = (s >> 16) & 0xFF;
    }
    return out;
  }

  Uint8List buildZip(Map<String, Uint8List> files, {bool deflate = true}) {
    final archive = Archive();
    files.forEach((name, bytes) {
      final f = ArchiveFile(name, bytes.length, bytes);
      f.compress = deflate;
      archive.addFile(f);
    });
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  test('条目远小于上限时正常读取', () async {
    final payload = incompressible(512 * 1024, 1); // 512 KB
    final zip = buildZip({'a.jpg': payload});
    final source = MemoryByteSource(zip);
    try {
      final index = await ZipIndex.openSource(source);
      final got = await index.imageEntries.first.read(source);
      expect(got.length, payload.length);
    } finally {
      await source.close();
    }
  });

  test('条目压缩后超过 16 MB 时仍必须完整读出', () async {
    // 20 MB 不可压缩载荷 → 压缩后也在 20 MB 左右，超过原生 16 MB 上限。
    const size = 20 * 1024 * 1024;
    final payload = incompressible(size, 7);
    final zip = buildZip({'big.jpg': payload});
    final source = MemoryByteSource(zip);
    try {
      final index = await ZipIndex.openSource(source);
      final entry = index.imageEntries.first;

      // 前提确认：这个条目的确超过上限
      expect(
        entry.compressedSize,
        greaterThan(16 * 1024 * 1024),
        reason: '构造的条目应超过 16 MB，否则测不到该缺陷',
      );

      final got = await entry.read(source);
      expect(got.length, size, reason: '大条目不应被截断');
      // 抽样比对，避免全量比较过慢
      expect(got.sublist(0, 64), equals(payload.sublist(0, 64)));
      expect(got.sublist(size - 64), equals(payload.sublist(size - 64)));
    } finally {
      await source.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('大量条目中靠后的条目也能正确读取（偏移正确性）', () async {
    // 1000+ 条目，检查最后几条的偏移解析没有累积误差。
    const count = 1200;
    final files = <String, Uint8List>{};
    for (var i = 0; i < count; i++) {
      files['img_$i.jpg'] = incompressible(3 * 1024, i + 1);
    }
    final zip = buildZip(files);
    final source = MemoryByteSource(zip);
    try {
      final index = await ZipIndex.openSource(source);
      expect(index.imageCount, count);

      // 抽查靠后的若干条
      for (final i in [count - 1, count - 2, count - 10, count ~/ 2]) {
        final entry = index.imageEntries[i];
        final got = await entry.read(source);
        expect(got.length, 3 * 1024, reason: '第 $i 条长度应正确');
        expect(
          got.sublist(0, 32),
          equals(files[entry.fileName]!.sublist(0, 32)),
          reason: '第 $i 条内容应正确（偏移解析）',
        );
      }
    } finally {
      await source.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('存储方式（不压缩）的大条目也能完整读出', () async {
    const size = 20 * 1024 * 1024;
    final payload = incompressible(size, 99);
    final zip = buildZip({'stored.jpg': payload}, deflate: false);
    final source = MemoryByteSource(zip);
    try {
      final index = await ZipIndex.openSource(source);
      final entry = index.imageEntries.first;
      expect(entry.method, 0, reason: '应为存储方式');
      final got = await entry.read(source);
      expect(got.length, size);
    } finally {
      await source.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('一次读整个大条目 → 会被原生上限截断并明确报错', () async {
    const size = 20 * 1024 * 1024;
    final payload = incompressible(size, 21);
    final zip = buildZip({'big.jpg': payload});
    final inner = MemoryByteSource(zip);
    // 上限 8 MB，条目约 20 MB → 一次请求必然被截断
    final capped = CappedByteSource(inner, 8 * 1024 * 1024);
    try {
      final index = await ZipIndex.openSource(capped);
      final entry = index.imageEntries.first;

      // 直接绕过分块读取，模拟"一次读整个条目"的旧行为
      final raw = await capped.read(
        await entry.resolveDataOffset(capped),
        entry.compressedSize,
      );
      expect(
        raw.length,
        lessThan(entry.compressedSize),
        reason: '前提：该来源确实会截断大请求',
      );
      expect(capped.truncations, greaterThan(0));
    } finally {
      await capped.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('经分块读取后，大条目在受限来源下也能完整读出', () async {
    const size = 20 * 1024 * 1024;
    final payload = incompressible(size, 22);
    final zip = buildZip({'big.jpg': payload});
    final inner = MemoryByteSource(zip);
    final capped = CappedByteSource(inner, 8 * 1024 * 1024);
    try {
      final index = await ZipIndex.openSource(capped);
      final entry = index.imageEntries.first;
      expect(entry.compressedSize, greaterThan(8 * 1024 * 1024));

      // 这是修复后的路径：read() 内部会分块读取再拼接
      final got = await entry.read(capped);
      expect(got.length, size, reason: '分块读取后应完整');
      expect(got.sublist(0, 64), equals(payload.sublist(0, 64)));
      expect(got.sublist(size - 64), equals(payload.sublist(size - 64)));
      expect(capped.truncations, 0, reason: '不应再发出超过上限的请求');
    } finally {
      await capped.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('多个大条目 + 靠后的条目，在受限来源下都能读出', () async {
    // 复现用户场景：包里既有大条目，也有靠后的条目。
    final payloadBigA = incompressible(12 * 1024 * 1024, 31);
    final payloadBigB = incompressible(11 * 1024 * 1024, 32);
    final payloadTail = incompressible(500 * 1024, 33);
    final files = <String, Uint8List>{
      'a_big.jpg': payloadBigA,
      'b_small.jpg': Uint8List.fromList(List.filled(1000, 7)),
      'c_big.jpg': payloadBigB,
      'z_tail.jpg': payloadTail, // 靠后的条目
    };
    final zip = buildZip(files);
    final inner = MemoryByteSource(zip);
    final capped = CappedByteSource(inner, 8 * 1024 * 1024);
    try {
      final index = await ZipIndex.openSource(capped);
      expect(index.imageCount, 4);

      for (final name in ['a_big.jpg', 'c_big.jpg', 'z_tail.jpg']) {
        final entry = index.imageEntries.firstWhere((e) => e.fileName == name);
        final got = await entry.read(capped);
        expect(got.length, files[name]!.length, reason: '$name 应完整读出');
        expect(
          got.sublist(0, 32),
          equals(files[name]!.sublist(0, 32)),
          reason: '$name 内容应为该条目自己的数据',
        );
      }
      expect(capped.truncations, 0);
    } finally {
      await capped.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_gallery_viewer/core/archive_reader.dart';
import 'package:simple_gallery_viewer/core/byte_source.dart';

/// 这些测试用 `archive` 包的**编码器**生成 zip，再用我们自己的解析器读取，
/// 从而与一个独立实现交叉验证，而不是自证自话。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sgv_zip_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 生成 zip 字节。
  Uint8List buildZipBytes({
    required Map<String, List<int>> files,
    bool store = false,
  }) {
    final archive = Archive();
    files.forEach((name, bytes) {
      final file = ArchiveFile(name, bytes.length, bytes);
      file.compress = !store;
      archive.addFile(file);
    });
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  /// 生成一个含图片与非图片条目的 zip 文件，返回其路径。
  String buildZip({required Map<String, List<int>> files, bool store = false}) {
    final encoded = buildZipBytes(files: files, store: store);
    final path = '${tmp.path}${Platform.pathSeparator}fixture.zip';
    File(path).writeAsBytesSync(encoded);
    return path;
  }

  List<int> payload(int seed, int length) {
    // 可压缩且可预测的内容
    final out = <int>[];
    for (var i = 0; i < length; i++) {
      out.add((seed + i) % 251);
    }
    return out;
  }

  test('索引出图片条目并过滤非图片', () async {
    final png = <int>[0x89, 0x50, 0x4E, 0x47, ...payload(1, 500)];
    final jpg = <int>[0xFF, 0xD8, 0xFF, ...payload(2, 700)];
    final readme = 'hello world'.codeUnits;

    final path = buildZip(
      files: {
        'a/cover.png': png,
        'a/page1.jpg': jpg,
        'a/readme.txt': readme,
        'a/notes/info.md': readme,
      },
    );

    final source = FileByteSource(path);
    final index = await ZipIndex.openSource(source);
    await source.close();

    expect(index.totalEntries, 4);
    expect(index.imageCount, 2);
    expect(index.imageEntries.map((e) => e.name).toSet(), {
      'a/cover.png',
      'a/page1.jpg',
    });
    // 目录条目被忽略
    expect(index.allEntries.any((e) => e.name.endsWith('/')), isFalse);
  });

  test('按需提取的字节与原始内容完全一致（deflate）', () async {
    final png = <int>[0x89, 0x50, 0x4E, 0x47, ...payload(7, 4096)];
    final jpg = <int>[0xFF, 0xD8, 0xFF, ...payload(9, 8192)];
    final path = buildZip(files: {'x.png': png, 'y.jpg': jpg});

    final source = FileByteSource(path);
    final index = await ZipIndex.openSource(source);
    try {
      for (final entry in index.imageEntries) {
        final expectBytes = entry.name == 'x.png' ? png : jpg;
        final actual = await entry.read(source);
        expect(
          actual.length,
          expectBytes.length,
          reason: '${entry.name} 解压长度应一致',
        );
        expect(actual, equals(expectBytes), reason: '${entry.name} 内容应逐字节一致');
        expect(entry.method, 8, reason: '应为 deflate');
      }
    } finally {
      await source.close();
    }
  });

  test('存储方式（method=0）也能正确提取', () async {
    final bytes = <int>[0xFF, 0xD8, 0xFF, ...payload(3, 1024)];
    final path = buildZip(files: {'stored.jpg': bytes}, store: true);

    final source = FileByteSource(path);
    final index = await ZipIndex.openSource(source);
    expect(index.imageCount, 1);
    expect(index.imageEntries.first.method, 0);
    try {
      expect(await index.imageEntries.first.read(source), equals(bytes));
    } finally {
      await source.close();
    }
  });

  test('文件名与扩展名解析', () async {
    final path = buildZip(
      files: {
        'deep/nested/dir/Page_01.JPEG': payload(4, 100),
        'i.webp': payload(5, 100),
      },
    );
    final source = FileByteSource(path);
    final index = await ZipIndex.openSource(source);
    await source.close();

    final jpeg = index.imageEntries.firstWhere((e) => e.name.contains('JPEG'));
    expect(jpeg.fileName, 'Page_01.JPEG');
    // 大写扩展名也应被识别为图片
    expect(jpeg.isImage, isTrue);

    expect(index.imageEntries.map((e) => e.fileName).toSet(), {
      'Page_01.JPEG',
      'i.webp',
    });
  });

  test('非 zip 文件抛出 FormatException 而不是静默成功', () async {
    final path = '${tmp.path}${Platform.pathSeparator}not-a-zip.bin';
    File(path).writeAsBytesSync(List.generate(4096, (i) => i % 256));

    final source = FileByteSource(path);
    await expectLater(
      ZipIndex.openSource(source),
      throwsA(isA<FormatException>()),
    );
    await source.close();
  });

  test('解析出的修改时间在合理范围内', () async {
    final path = buildZip(files: {'t.jpg': payload(6, 64)});
    final source = FileByteSource(path);
    final index = await ZipIndex.openSource(source);
    await source.close();
    final t = index.imageEntries.first.lastModified;
    expect(t.year, greaterThanOrEqualTo(1980));
    expect(t.year, lessThanOrEqualTo(2100));
  });

  test('同一份数据经内存来源解析，结果与文件来源一致', () async {
    final bytes = buildZipBytes(
      files: {
        'm/one.jpg': payload(11, 2048),
        'm/two.png': payload(12, 1024),
        'm/skip.txt': payload(13, 32),
      },
    );

    final filePath = '${tmp.path}${Platform.pathSeparator}mem.zip';
    File(filePath).writeAsBytesSync(bytes);

    final fileSource = FileByteSource(filePath);
    final fileIndex = await ZipIndex.openSource(fileSource);

    final memSource = MemoryByteSource(Uint8List.fromList(bytes));
    final memIndex = await ZipIndex.openSource(memSource);

    expect(memIndex.imageCount, fileIndex.imageCount);
    expect(
      memIndex.imageEntries.map((e) => e.name).toList(),
      fileIndex.imageEntries.map((e) => e.name).toList(),
    );

    try {
      for (var i = 0; i < memIndex.imageEntries.length; i++) {
        final fromMem = await memIndex.imageEntries[i].read(memSource);
        final fromFile = await fileIndex.imageEntries[i].read(fileSource);
        expect(fromMem, equals(fromFile), reason: '第 $i 张内容应一致');
      }
    } finally {
      // 必须在比较完成之后再关闭：提取是按需读的，提前关闭会读不到数据。
      await memSource.close();
      await fileSource.close();
    }
  });

  test('长度不可用（返回 0）时仍能解析 —— 真实 SAF 提供方的回归', () async {
    // 背景：实测小米 externalstorage 对部分文档取不到长度，sizeOf 返回 0。
    // 旧实现据此抛出"文件太小，不是有效的 zip"，导致单个导入能成、
    // 批量导入里同一批文件却全部失败。
    final bytes = buildZipBytes(
      files: {'a.jpg': payload(21, 1200), 'b.png': payload(22, 800)},
    );

    final source = _NoLengthSource(bytes);
    // 前提确认：这个来源确实报不出长度
    expect(await source.length(), 0);

    final index = await ZipIndex.openSource(source);
    expect(index.imageCount, 2, reason: '长度不可用不应影响索引');

    // 内容必须能正确提取
    final a = index.imageEntries.firstWhere((e) => e.fileName == 'a.jpg');
    final got = await a.read(source);
    final want = payload(21, 1200);
    expect(got.length, want.length, reason: '长度应一致');
    expect(got, equals(want), reason: '内容应逐字节一致');
    await source.close();
  });

  test('尾部读取在长度不可用时也能定位到文件末尾', () async {
    final bytes = buildZipBytes(files: {'x.jpg': payload(31, 400)});
    final source = _NoLengthSource(bytes);
    final tail = await source.readTail(128 * 1024);
    expect(tail.isEmpty, isFalse);
    // 尾部区块的末端必须正好是文件末尾
    expect(tail.startOffset + tail.bytes.length, bytes.length);
    await source.close();
  });
}

/// 模拟"报不出长度"的 SAF 来源。
///
/// 真实的 `content://` 提供方（实测小米 externalstorage）会对部分文档
/// 返回长度 0，同时在越界读取时返回空——这个测试替身复现该行为，
/// 用来保证 zip 解析不依赖长度。
class _NoLengthSource implements ByteSource {
  _NoLengthSource(this._data);

  final Uint8List _data;

  @override
  Future<int> length() async => 0; // 关键：永远报不出长度

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (count <= 0 || offset < 0 || offset >= _data.length) {
      return Uint8List(0); // 越界返回空，与原生的容错行为一致
    }
    final end = (offset + count).clamp(0, _data.length);
    return Uint8List.sublistView(_data, offset, end);
  }

  @override
  Future<TailChunk> readTail(int maxBytes) async {
    if (_data.isEmpty) return TailChunk(0, Uint8List(0));
    final start = _data.length > maxBytes ? _data.length - maxBytes : 0;
    return TailChunk(start, Uint8List.sublistView(_data, start));
  }

  @override
  Future<void> close() async {}

  @override
  String get describe => 'nolength:${_data.length}B';
}

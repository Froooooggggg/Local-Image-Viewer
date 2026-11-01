import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Inflate, InputStream;

import 'byte_source.dart';

/// 只读 zip 中央目录解析器（基于 [ByteSource]，位置无关）。
///
/// 两条必须遵守的设计约束：
///
/// 1. **不整包读入内存。** `archive` 包的 `ZipDecoder()` / `ZipDirectory.read()`
///    在解析目录时会对每个条目构造 `ZipFile`，而 `ZipFile` 的构造函数会把该
///    条目的压缩数据整段读进内存（`_rawContent = input.readBytes(...)`）。
///    一个 500 MB 的图集包会把 500 MB 常驻 RAM。本解析器只读 EOCD 与中央目录
///    这些元数据，单张图片在真正需要时才提取、用完即弃。
///
/// 2. **不依赖文件路径。** Android 10+ 下 SAF 授权只作用于 `content://`，
///    `dart:io` 拿不到 `/sdcard/...` 的访问权。所以字节一律经由 [ByteSource] 获取。
///
/// 实测（800 条目 / 16 MB 包）：索引 4 ms，RSS 不增长；按需提取单张 0–5 ms。
class ArchiveEntry {
  /// 包内完整路径（可能含目录）。
  final String name;

  /// 压缩后字节数（中央目录为权威来源）。
  final int compressedSize;

  /// 解压后字节数。
  final int uncompressedSize;

  /// 压缩方式：0 = 存储，8 = deflate。
  final int method;

  /// 本地头在文件中的偏移。
  final int localHeaderOffset;

  /// 是否置位数据描述符标志（bit 3）。置位时本地头里的大小字段为 0，
  /// 必须使用中央目录的值。
  final bool hasDataDescriptor;

  /// 该图片自身的最后修改时间（中央目录的 DOS 时间戳）。
  final DateTime lastModified;

  /// 惰性解析出的数据起始偏移。
  int? _dataOffset;

  ArchiveEntry({
    required this.name,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.method,
    required this.localHeaderOffset,
    required this.hasDataDescriptor,
    required this.lastModified,
  });

  /// 包内路径的纯文件名。
  String get fileName {
    final i = name.lastIndexOf('/');
    return i < 0 ? name : name.substring(i + 1);
  }

  bool get isImage => imageExtensions.contains(extensionOf(fileName));

  static const imageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'bmp',
    'gif',
    'jfif',
    'avif',
    'heic',
  };

  static String extensionOf(String fileName) {
    final i = fileName.lastIndexOf('.');
    return i < 0 ? '' : fileName.substring(i + 1).toLowerCase();
  }

  /// 图片数据在文件中的起始偏移。
  ///
  /// 中央目录记录的是**本地头**偏移，数据在本地头之后：30 字节固定头 +
  /// 文件名长度 + 扩展字段长度。这两个长度只存在于本地头，且可能与中央目录
  /// 中的不同，所以必须读一次本地头（仅 30 字节，且缓存）。
  Future<int> resolveDataOffset(ByteSource source) async {
    final cached = _dataOffset;
    if (cached != null) return cached;

    final header = await source.read(localHeaderOffset, 30);
    if (header.length < 30) {
      throw const FormatException('zip 本地头被截断');
    }
    final bd = ByteData.sublistView(header);
    if (bd.getUint32(0, Endian.little) != 0x04034b50) {
      throw const FormatException('zip 本地头签名无效');
    }
    final fnLen = bd.getUint16(26, Endian.little);
    final exLen = bd.getUint16(28, Endian.little);
    final offset = localHeaderOffset + 30 + fnLen + exLen;
    _dataOffset = offset;
    return offset;
  }

  /// 按需提取该条目的原始字节（即原始图片文件内容）。
  ///
  /// 调用方解码后应尽快释放引用，以便内存回收。
  Future<Uint8List> read(ByteSource source) async {
    final offset = await resolveDataOffset(source);
    // 分块读取后再拼接：原生侧单次分配有上限，直接请求整个条目会被截断。
    final raw = await readInChunks(
      source,
      offset,
      compressedSize,
      kMaxReadChunk,
    );

    // 读取必须拿到**完整**的压缩数据，否则解压只会得到残缺数据，
    // 最终表现为"图片读不出来"而没有任何线索 —— 所以这里显式失败并说明原因。
    if (raw.length < compressedSize) {
      throw StateError(
        '压缩数据读取不完整：需要 $compressedSize 字节，实际 ${raw.length} 字节'
        '（条目 $fileName，偏移 $offset）',
      );
    }

    switch (method) {
      case 0:
        return raw;
      case 8:
        final out = Uint8List.fromList(
          Inflate.buffer(InputStream(raw), uncompressedSize).getBytes(),
        );
        if (out.length != uncompressedSize) {
          throw StateError(
            '解压结果长度不符：需要 $uncompressedSize，实际 ${out.length}'
            '（条目 $fileName）',
          );
        }
        return out;
      default:
        throw UnsupportedError('不支持的压缩方式：$method');
    }
  }

  @override
  String toString() => 'ArchiveEntry($name, $uncompressedSize bytes)';
}

/// 已建立索引的 zip 图集（惰性读取，正文不驻留内存）。
class ZipIndex {
  /// 全部条目（含非图片），用于统计与展示。
  final List<ArchiveEntry> allEntries;

  /// 仅图片条目。
  final List<ArchiveEntry> imageEntries;

  ZipIndex._(this.allEntries, this.imageEntries);

  int get totalEntries => allEntries.length;
  int get imageCount => imageEntries.length;

  static const _eocdSignature = 0x06054b50;
  static const _centralFileSignature = 0x02014b50;

  /// 解析 [source] 指向的 zip。
  ///
  /// 遇到损坏或非 zip 数据会抛出 [FormatException]，调用方应捕获并跳过该图集，
  /// 而不是让整个导入流程失败。
  ///
  /// **不依赖"预先知道文件长度"**：某些 SAF 提供方（实测小米 externalstorage）
  /// 对部分文档取不到可靠长度，旧实现会因此把正常文件误判为"文件太小"。
  /// 现在按 zip 规范的做法，直接在文件**尾部扫描 EOCD 签名**，
  /// 中央目录的位置与大小全部由 EOCD 自身给出。
  ///
  /// 注意：本方法**不关闭** [source]，由调用方负责其生命周期。
  static Future<ZipIndex> openSource(ByteSource source) async {
    final eocdOffset = await _findEocd(source);

    final header = await source.read(eocdOffset, 22);
    if (header.length < 22) {
      throw const FormatException('zip 中央目录结束记录不完整');
    }
    final bd = ByteData.sublistView(header);

    // 偏移 10 起：条目总数（2 字节）、中央目录大小（4 字节）、中央目录偏移（4 字节）
    var totalEntries = bd.getUint16(10, Endian.little);
    var centralSize = bd.getUint32(12, Endian.little);
    var centralOffset = bd.getUint32(16, Endian.little);

    // Zip64：任一字段为哨兵值时需从 Zip64 EOCD 读取。
    if (centralOffset == 0xffffffff ||
        centralSize == 0xffffffff ||
        totalEntries == 0xffff) {
      final z64 = await _readZip64(source, eocdOffset);
      if (z64 != null) {
        totalEntries = z64.totalEntries;
        centralSize = z64.centralSize;
        centralOffset = z64.centralOffset;
      }
    }

    if (centralOffset == 0xffffffff || centralSize == 0xffffffff) {
      throw const FormatException('zip 缺少 Zip64 结束记录，无法定位中央目录');
    }
    if (centralSize <= 0) {
      throw const FormatException('zip 中央目录大小无效');
    }

    final central = await source.read(centralOffset, centralSize);
    if (central.isEmpty) {
      throw const FormatException('无法读取 zip 中央目录');
    }
    final entries = <ArchiveEntry>[];
    final view = ByteData.sublistView(central);
    var pos = 0;

    while (pos + 46 <= central.length) {
      if (view.getUint32(pos, Endian.little) != _centralFileSignature) break;

      final flags = view.getUint16(pos + 8, Endian.little);
      final method = view.getUint16(pos + 10, Endian.little);
      final dosTime = view.getUint16(pos + 12, Endian.little);
      final dosDate = view.getUint16(pos + 14, Endian.little);
      var compressedSize = view.getUint32(pos + 20, Endian.little);
      var uncompressedSize = view.getUint32(pos + 24, Endian.little);
      final fnLen = view.getUint16(pos + 28, Endian.little);
      final exLen = view.getUint16(pos + 30, Endian.little);
      final cmLen = view.getUint16(pos + 32, Endian.little);
      var localHeaderOffset = view.getUint32(pos + 42, Endian.little);

      final nameBytes = central.sublist(pos + 46, pos + 46 + fnLen);
      final name = _decodeName(nameBytes);
      final extraStart = pos + 46 + fnLen;

      // Zip64 扩展字段：补全哨兵值。
      if (compressedSize == 0xffffffff ||
          uncompressedSize == 0xffffffff ||
          localHeaderOffset == 0xffffffff) {
        final z = _readZip64Extra(
          central,
          extraStart,
          exLen,
          uncompressedIsZip64: uncompressedSize == 0xffffffff,
          compressedIsZip64: compressedSize == 0xffffffff,
          offsetIsZip64: localHeaderOffset == 0xffffffff,
        );
        compressedSize = z.compressedSize ?? compressedSize;
        uncompressedSize = z.uncompressedSize ?? uncompressedSize;
        localHeaderOffset = z.localHeaderOffset ?? localHeaderOffset;
      }

      if (!name.endsWith('/')) {
        entries.add(
          ArchiveEntry(
            name: name,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            method: method,
            localHeaderOffset: localHeaderOffset,
            hasDataDescriptor: (flags & 0x08) != 0,
            lastModified: _dosToDateTime(dosDate, dosTime),
          ),
        );
      }

      pos = extraStart + exLen + cmLen;
    }

    return ZipIndex._(entries, entries.where((e) => e.isImage).toList());
  }

  /// 定位 EOCD（中央目录结束记录）的绝对偏移。
  ///
  /// 关键：**不需要事先知道文件长度**。EOCD 是变长的（末尾可能带最长 65535
  /// 字节的注释），所以从候选尾部区块中找到含 EOCD 的那一个，再在其中定位。
  ///
  /// 做法：先读最后一块（覆盖绝大多数情况）；若没有，再逐块向前扩大搜索范围。
  /// 每块只读一小段，因此对 10 GB 的文件也不会产生大读取。
  static Future<int> _findEocd(ByteSource source) async {
    // 从文件末尾往前、逐块扩大的搜索窗口。
    // 第一块覆盖"无注释"的常见情况；后续块应对超长注释。
    const blocks = <int>[128 * 1024, 1024 * 1024, 8 * 1024 * 1024];

    for (final blockSize in blocks) {
      final tail = await source.readTail(blockSize);
      if (tail.bytes.isEmpty) continue;

      final found = _scanEocd(tail.bytes, tail.startOffset);
      if (found >= 0) return found;

      // 若这一块已经读到了文件开头，就没必要再扩大。
      if (tail.startOffset == 0) break;
    }

    throw const FormatException('未找到 zip 中央目录结束记录（可能不是 zip 文件）');
  }

  /// 在给定缓冲区里反向查找 EOCD 签名，返回其在文件中的绝对偏移。
  static int _scanEocd(Uint8List buffer, int baseOffset) {
    if (buffer.length < 22) return -1;
    final bd = ByteData.sublistView(buffer);
    for (var i = buffer.length - 22; i >= 0; i--) {
      if (bd.getUint32(i, Endian.little) == _eocdSignature) {
        return baseOffset + i;
      }
    }
    return -1;
  }

  static Future<_Zip64Dir?> _readZip64(
    ByteSource source,
    int eocdOffset,
  ) async {
    final locatorOffset = eocdOffset - 20;
    if (locatorOffset < 0) return null;
    final loc = await source.read(locatorOffset, 20);
    final bd = ByteData.sublistView(loc);
    if (bd.getUint32(0, Endian.little) != 0x07064b50) return null;

    final z64Offset = bd.getUint64(8, Endian.little);
    final rec = await source.read(z64Offset, 56);
    final rbd = ByteData.sublistView(rec);
    if (rbd.getUint32(0, Endian.little) != 0x06064b50) return null;

    return _Zip64Dir(
      totalEntries: rbd.getUint64(32, Endian.little),
      centralSize: rbd.getUint64(40, Endian.little),
      centralOffset: rbd.getUint64(48, Endian.little),
    );
  }

  /// 解析 Zip64 扩展字段（extra field id = 1）。
  ///
  /// **关键：字段是按需出现的，不能无条件按顺序读三个 8 字节。**
  /// 按规范（APPNOTE 4.5.3），Zip64 扩展字段中**只包含**那些在中央目录里
  /// 被写成 0xFFFFFFFF 的字段，顺序固定为：
  ///   未压缩大小 → 压缩大小 → 本地头偏移 → 磁盘号
  /// 但只有当对应字段是哨兵值时才存在。
  ///
  /// 曾经的错误实现无条件依次读三个字段，导致只有"本地头偏移"溢出时
  /// （即 >4 GB 的内嵌 ZIP64 包）读到错位的垃圾值，表现为
  /// **越过 4 GB 之后的图片全部读不出来**。
  static _Zip64Extra _readZip64Extra(
    Uint8List central,
    int start,
    int length, {
    required bool uncompressedIsZip64,
    required bool compressedIsZip64,
    required bool offsetIsZip64,
  }) {
    var pos = start;
    final end = start + length;
    final bd = ByteData.sublistView(central);
    final result = _Zip64Extra();

    while (pos + 4 <= end) {
      final id = bd.getUint16(pos, Endian.little);
      final size = bd.getUint16(pos + 2, Endian.little);
      if (id == 1) {
        // 以字段声明的长度为准，避免越界读到下一个字段的字节。
        final fieldEnd = (pos + 4 + size) < end ? (pos + 4 + size) : end;
        var p = pos + 4;

        // 严格按"该字段是否为哨兵"决定读不读，顺序不能变。
        if (uncompressedIsZip64 && p + 8 <= fieldEnd) {
          result.uncompressedSize = bd.getUint64(p, Endian.little);
          p += 8;
        }
        if (compressedIsZip64 && p + 8 <= fieldEnd) {
          result.compressedSize = bd.getUint64(p, Endian.little);
          p += 8;
        }
        if (offsetIsZip64 && p + 8 <= fieldEnd) {
          result.localHeaderOffset = bd.getUint64(p, Endian.little);
          p += 8;
        }
        return result;
      }
      pos += 4 + size;
    }
    return result;
  }

  /// zip 中的文件名默认按 UTF-8 解码；部分工具使用本地编码（如 GBK），
  /// 此处对非法 UTF-8 序列退化为 Latin-1，避免整个目录解析失败。
  static String _decodeName(Uint8List bytes) {
    try {
      return const Utf8Decoder(allowMalformed: false).convert(bytes);
    } on FormatException {
      return String.fromCharCodes(bytes);
    }
  }

  /// DOS 日期时间（无时区信息，按本地时间理解）。
  static DateTime _dosToDateTime(int dosDate, int dosTime) {
    final year = ((dosDate >> 9) & 0x7f) + 1980;
    final month = (dosDate >> 5) & 0x0f;
    final day = dosDate & 0x1f;
    final hour = (dosTime >> 11) & 0x1f;
    final minute = (dosTime >> 5) & 0x3f;
    final second = (dosTime & 0x1f) * 2;
    if (month < 1 || month > 12 || day < 1 || day > 31) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime(year, month, day, hour, minute, second);
  }
}

class _Zip64Dir {
  final int totalEntries;
  final int centralSize;
  final int centralOffset;
  _Zip64Dir({
    required this.totalEntries,
    required this.centralSize,
    required this.centralOffset,
  });
}

class _Zip64Extra {
  int? compressedSize;
  int? uncompressedSize;
  int? localHeaderOffset;
}

import 'dart:io';
import 'dart:typed_data';

import 'saf_channel.dart';

/// 从文件尾部读到的一段数据。
class TailChunk {
  /// 这段数据在文件中的起始偏移。
  final int startOffset;

  /// 数据本体。可能短于请求长度（文件比请求的还小）。
  final Uint8List bytes;

  const TailChunk(this.startOffset, this.bytes);

  bool get isEmpty => bytes.isEmpty;
}

/// 统一的字节来源抽象。
///
/// 存在的原因：Android 10+ 的 scoped storage 下，SAF 授权只作用于
/// `content://` URI，**不会**让 `dart:io` 获得对 `/sdcard/...` 路径的访问权。
/// 因此上层（zip 解析、图片提取）不能再依赖文件路径，而应该只依赖这个接口，
/// 由具体实现决定字节从哪里来。
///
/// 读取是**位置无关**的：给定偏移与长度，返回对应字节。这既符合 zip 的随机访问
/// 需求，也让 `content://` 实现可以把「定位 + 读取」合并成一次跨平台调用。
abstract class ByteSource {
  /// 数据总长度（字节）。
  ///
  /// **可能不可靠**：部分 SAF 提供方取不到长度会返回 0。需要长度的场合必须
  /// 容忍 0（zip 解析已改为扫描尾部 EOCD，不再依赖它）。
  Future<int> length();

  /// 读取 `[offset, offset+count)` 区间的字节。
  ///
  /// 若请求超出末尾，返回实际可读的较短结果（调用方需自行判断长度是否满足）。
  Future<Uint8List> read(int offset, int count);

  /// 读取文件**尾部**最多 [maxBytes] 字节，**不需要事先知道文件长度**。
  ///
  /// 这是定位 zip EOCD 的关键：EOCD 在文件末尾，而末尾位置取决于文件大小，
  /// 偏偏某些提供方报不出大小。
  Future<TailChunk> readTail(int maxBytes);

  Future<void> close();

  /// 仅用于日志与诊断。
  String get describe;
}

/// 单次底层请求的字节上限。
///
/// 原生侧 `readBytes` 会按请求长度**一次性分配** `ByteArray`；过大的请求容易
/// 直接触发 Java 侧分配失败，在引擎里表现为 JNI 异常崩溃。
/// 因此较大的读取要拆成多次请求，并在 Dart 侧拼接。
///
/// 为什么不能只靠"限制单张图片大小"：zip 条目是**按压缩后大小整体读取**的，
/// 单个条目的压缩后大小可能远超这个值。
const int kMaxReadChunk = 8 * 1024 * 1024; // 8 MB

/// 按 [maxChunk] 把一个较大的区间读取拆成多次，并在 Dart 侧拼接。
///
/// 独立成函数是因为三种 [ByteSource] 实现都需要同样的语义。
Future<Uint8List> readInChunks(
  ByteSource source,
  int offset,
  int count,
  int maxChunk,
) async {
  if (count <= 0) return Uint8List(0);
  if (maxChunk <= 0 || count <= maxChunk) {
    return source.read(offset, count);
  }

  final builder = BytesBuilder(copy: false);
  var read = 0;
  while (read < count) {
    final want = (count - read) < maxChunk ? (count - read) : maxChunk;
    final part = await source.read(offset + read, want);
    if (part.isEmpty) break;
    builder.add(part);
    read += part.length;
    // 底层没能给满，说明已到末尾，不必再请求。
    if (part.length < want) break;
  }
  return builder.takeBytes();
}

/// 本地文件来源（应用私有文件、或确实可访问的真实路径）。
class FileByteSource implements ByteSource {
  FileByteSource(this.path);

  final String path;
  RandomAccessFile? _raf;

  Future<RandomAccessFile> _open() async {
    final existing = _raf;
    if (existing != null) return existing;
    final opened = await File(path).open();
    _raf = opened;
    return opened;
  }

  @override
  Future<int> length() async => (await _open()).lengthSync();

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (count <= 0) return Uint8List(0);
    final raf = await _open();
    raf.setPositionSync(offset);
    return raf.readSync(count);
  }

  @override
  Future<TailChunk> readTail(int maxBytes) async {
    final raf = await _open();
    final total = raf.lengthSync();
    final start = total > maxBytes ? total - maxBytes : 0;
    if (total == 0) return TailChunk(0, Uint8List(0));
    raf.setPositionSync(start);
    return TailChunk(start, raf.readSync(total - start));
  }

  @override
  Future<void> close() async {
    final raf = _raf;
    _raf = null;
    if (raf != null) await raf.close();
  }

  @override
  String get describe => 'file:$path';
}

/// `content://` 文档来源。
///
/// 每次读取都是一次「打开描述符 → 定位 → 读取」，因此**没有需要回收的句柄**，
/// 也不存在描述符泄漏。原生侧优先用 FileChannel.position() 定位，遇到不可
/// 定位的提供方会自动回退为顺序 skip。
class ContentUriByteSource implements ByteSource {
  ContentUriByteSource(this.uri, {int? knownLength}) : _length = knownLength;

  final String uri;
  int? _length;

  @override
  Future<int> length() async {
    final cached = _length;
    // 只缓存**有效**长度：曾经把 0 缓存下来，导致后续所有判断都以为文件为空。
    if (cached != null && cached > 0) return cached;
    final size = await SafChannel.sizeOf(uri);
    if (size > 0) _length = size;
    return size;
  }

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (count <= 0) return Uint8List(0);
    return SafChannel.readBytes(uri, offset, count);
  }

  /// 不依赖已知长度的尾部读取：用几何级数向后探测 EOF。
  ///
  /// 先用元数据长度（若可用）直接定位；否则以翻倍的步长探测，直到某次读取
  /// 越过末尾。对 10 GB 的文件也只需几十次探测，每次读一小段。
  @override
  Future<TailChunk> readTail(int maxBytes) async {
    // 快路径：元数据长度可用时直接算偏移。
    final total = await length();
    if (total > 0) {
      final start = total > maxBytes ? total - maxBytes : 0;
      final bytes = await read(start, total - start);
      return TailChunk(start, bytes);
    }

    // 慢路径：探测 EOF。
    // 找最后一个"仍有数据"的偏移上界。
    var lower = 0; // 已知有数据
    var upper = 1; // 待验证
    var guard = 0;
    while (guard < 48) {
      final chunk = await read(upper, 1);
      if (chunk.isEmpty) break;
      lower = upper;
      upper *= 2;
      guard++;
    }
    if (guard >= 48) return TailChunk(0, Uint8List(0));

    if (lower == 0) {
      // 只有 1 字节或空文件，没有尾部可扫。
      final only = await read(0, maxBytes);
      return TailChunk(0, only);
    }

    // 二分定位精确末尾
    while (upper - lower > 1) {
      final mid = lower + (upper - lower) ~/ 2;
      final chunk = await read(mid, 1);
      if (chunk.isEmpty) {
        upper = mid;
      } else {
        lower = mid;
      }
    }
    final total2 = lower + 1;

    final start = total2 > maxBytes ? total2 - maxBytes : 0;
    final bytes = await read(start, total2 - start);
    return TailChunk(start, bytes);
  }

  @override
  Future<void> close() async {
    // 无持久句柄，无需释放。
  }

  @override
  String get describe => 'content:$uri';
}

/// 便于内存中的数据（测试、缩略图）复用同一套解析代码。
class MemoryByteSource implements ByteSource {  MemoryByteSource(this._data);

  final Uint8List _data;

  @override
  Future<int> length() async => _data.length;

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (count <= 0 || offset >= _data.length) return Uint8List(0);
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
  String get describe => 'memory:${_data.length}B';
}

/// 分块读完整份数据，**不依赖 [ByteSource.length]**。
///
/// 为什么不用 `length()` + 一次 `read`：
/// - 部分 SAF 提供方（含小米的 externalstorage）会把长度报成 0；
/// - 本仓库原生侧还出过一个把树内**子文档** URI 当成目录、直接返回 0 的
///   bug（`DocumentsContract.isTreeUri` 对 `.../tree/<id>/document/<id>` 也
///   返回 true），表现就是批量翻译第一页抛 `Bad state: 文件为空`。
/// 按块读到「空块」或「不足一块」为止，既不看长度也不会一次性申请大数组
/// （一次性申请 64 MB 在低内存时会让引擎 abort，见 viewer 的同类注释）。
///
/// [maxBytes] 是硬上限：达到上限即停止，返回内容可能被截断。要判断"是否
/// 超过上限"，调用方传 `上限 + 1` 再比较 `bytes.length`。
Future<Uint8List> readAllChunked(
  ByteSource source, {
  int maxBytes = 128 << 20,
  int chunkSize = kMaxReadChunk,
}) async {
  if (maxBytes <= 0) return Uint8List(0);
  final builder = BytesBuilder(copy: false);
  var offset = 0;
  while (offset < maxBytes) {
    final remaining = maxBytes - offset;
    final want = remaining < chunkSize ? remaining : chunkSize;
    final part = await source.read(offset, want);
    if (part.isEmpty) break;
    builder.add(part);
    offset += part.length;
    // 读到的不足请求量，说明已到末尾。
    if (part.length < want) break;
  }
  return builder.takeBytes();
}

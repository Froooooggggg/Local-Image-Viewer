import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'byte_source.dart';

/// 文件内容哈希，用于**按内容**判断是否为同一个压缩包。
///
/// 为什么不能按路径判重：Android 的系统文件选择器会把文件交给应用一个
/// `content://` 文档，路径会随文件移动而改变；同一份内容散落在不同位置时，
/// 只有内容本身能稳定标识「是不是同一个包」。
class ContentHash {
  /// 每次向来源请求的块大小。既避免整包载入内存，也不至于调用过碎。
  static const _chunkSize = 512 * 1024;

  /// 流式计算 [source] 的 SHA-256。
  ///
  /// 逐块读取并以流的方式喂给哈希器，因此**内存占用与压缩包大小无关**：
  /// 一个 500 MB 的包不会先被读进内存再哈希。
  static Future<String> ofSource(ByteSource source) async {
    final digest = await sha256.bind(_chunks(source)).first;
    return digest.toString();
  }

  /// 把 [ByteSource] 适配成字节流。
  static Stream<List<int>> _chunks(ByteSource source) async* {
    final total = await source.length();
    var offset = 0;
    while (offset < total) {
      final want = (total - offset).clamp(0, _chunkSize);
      final chunk = await source.read(offset, want);
      if (chunk.isEmpty) break;
      offset += chunk.length;
      yield chunk;
    }
  }

  /// 由给定字节计算 SHA-256。
  static String ofBytes(List<int> bytes) => sha256.convert(bytes).toString();

  /// 由字符串计算（用于把「文件夹内一组文件的清单」折叠成一个稳定标识）。
  static String ofString(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// 便于测试：直接对内存数据求哈希。
  static Future<String> ofMemory(Uint8List bytes) =>
      ofSource(MemoryByteSource(bytes));
}

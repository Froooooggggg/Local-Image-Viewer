import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 封面与预览图的生成与缓存。
///
/// 全部写入 **App 私有缓存目录**（`getApplicationCacheDirectory()`），
/// 不触碰用户相册或任何原始文件——这是本应用的硬约束。
class ThumbCache {
  ThumbCache._(this._dir);

  final Directory _dir;

  /// 正在生成的封面任务，避免同一图集被并发生成多次。
  final Map<String, Future<String?>> _pending = {};

  static ThumbCache? _instance;

  static Future<ThumbCache> instance() async {
    final cached = _instance;
    if (cached != null) return cached;
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'covers'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return _instance = ThumbCache._(dir);
  }

  /// 生成缩略图的目标最长边。列表页封面不需要原图尺寸。
  static const int coverMaxEdge = 512;

  String _coverPath(String galleryId) => p.join(_dir.path, '$galleryId.thumb');

  /// 已有封面文件则直接返回；否则由 [loader] 提供原始字节并生成。
  ///
  /// [loader] 只在需要生成时调用一次。
  Future<String?> cover(
    String galleryId,
    Future<Uint8List?> Function() loader, {
    bool force = false,
  }) {
    final path = _coverPath(galleryId);
    if (!force && File(path).existsSync()) {
      return Future.value(path);
    }
    final inFlight = _pending[galleryId];
    if (inFlight != null) return inFlight;

    final task = _generate(path, loader).whenComplete(() {
      _pending.remove(galleryId);
    });
    _pending[galleryId] = task;
    return task;
  }

  Future<String?> _generate(
    String outPath,
    Future<Uint8List?> Function() loader,
  ) async {
    try {
      final bytes = await loader();
      if (bytes == null || bytes.isEmpty) return null;
      final thumb = await _downscaleToFile(bytes, outPath);
      return thumb;
    } catch (_) {
      // 损坏图片、不支持格式等不应影响列表展示，静默降级。
      return null;
    }
  }

  ///
  /// 关键点：用 `instantiateImageCodec` 的 `targetWidth/targetHeight` 在**解码阶段**
  /// 降采样，而不是先解出全尺寸位图再缩放——后者对一张 4000×3000 的照片要
  /// 占用约 48 MB，正是内存目标的头号杀手。
  Future<String?> _downscaleToFile(Uint8List bytes, String outPath) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: coverMaxEdge,
        allowUpscaling: false,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      // 先清掉旧文件与残留临时文件：rename 到已存在的目标在 Windows 上会失败。
      _prepareTarget(outPath);
      final tmp = File('$outPath.tmp');
      tmp.writeAsBytesSync(data.buffer.asUint8List(), flush: true);
      // 原子替换，避免半成品缩略图被读到。
      tmp.renameSync(outPath);
      return outPath;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  /// 删除某个图集的封面。
  ///
  /// 注意：`File.renameSync` 到已存在的目标在 Windows 上会失败，因此生成新封面
  /// 之前必须先清掉旧的；`cover(force: true)` 内部会调用本方法。
  void evict(String galleryId) {
    final f = File(_coverPath(galleryId));
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {
        // 缓存删除失败不影响主流程。
      }
    }
  }

  /// 生成封面时先移除旧文件，避免 Windows 上重命名失败。
  void _prepareTarget(String outPath) {
    final existing = File(outPath);
    if (existing.existsSync()) {
      try {
        existing.deleteSync();
      } catch (_) {}
    }
    final tmp = File('$outPath.tmp');
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync();
      } catch (_) {}
    }
  }

  /// 缓存目录当前占用的字节数，用于设置页展示。
  int usedBytes() {
    if (!_dir.existsSync()) return 0;
    var total = 0;
    for (final entity in _dir.listSync()) {
      if (entity is File) total += entity.lengthSync();
    }
    return total;
  }

  /// 清空封面缓存。只删除 App 私有缓存，绝不涉及用户文件。
  void clear() {
    if (!_dir.existsSync()) return;
    for (final entity in _dir.listSync()) {
      if (entity is File) {
        try {
          entity.deleteSync();
        } catch (_) {}
      }
    }
  }
}

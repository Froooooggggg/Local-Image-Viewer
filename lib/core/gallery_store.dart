import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// 图集索引的持久化。
///
/// 为什么不用 SharedPreferences（这是压测暴露出的主要瓶颈）：
/// 它把所有内容放在**一个 XML 字符串**里，整个常驻内存、**每次保存都重写
/// 整个文件**。导入 1000 个图集时，索引会长到几十 MB，而每导入一个都要
/// 把整份索引重新序列化并重写一次 —— 总代价是 O(n²)，表现就是"越到后面越卡"。
/// 实测中断时索引已达 29 MB / 80847 条记录。
///
/// 改为**一个图集一个文件**：
///   * 新增/修改只重写该图集自己的文件 → O(1)
///   * 不需要把整份索引塞进一个字符串
///   * 单条损坏只影响该图集，不会让全部记录解析失败
///
/// 只使用极小的键值（排序、亮度、预加载张数等）仍然放在 SharedPreferences 里，
/// 那些数据量小且改动不频繁。
class GalleryStore {
  GalleryStore._(this._dir);

  final Directory _dir;

  static const _suffix = '.gallery.json';

  static Future<GalleryStore> open() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'galleries'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return GalleryStore._(dir);
  }

  File _fileFor(String id) => File(p.join(_dir.path, '$id$_suffix'));

  /// 是否在后台 isolate 中解析。
  ///
  /// 生产环境保持 true（28 MB 级别的索引在主 isolate 上解析会卡死界面）。
  /// 组件测试里把 `Isolate.run` 的 Future 在 fake-async 时钟下永远不会完成，
  /// 会让 `pumpAndSettle` 一直等下去，因此测试会关掉它。
  @visibleForTesting
  static bool useIsolate = true;

  /// 读取全部图集。
  ///
  /// **在后台 isolate 中完成读文件与 JSON 解析**：一个图集的索引可以有好几 MB
  /// （里面是几千到几万条图片记录），实测 5 个图集就有 28 MB。在主 isolate 上
  /// 同步解析这么多 JSON 会把界面完全卡死 —— 启动时会一直停在加载圈上。
  ///
  /// 单条解析失败会被跳过，不影响其余记录。
  Future<List<Gallery>> loadAllAsync() async {
    if (!_dir.existsSync()) return <Gallery>[];
    // 一条记录都没有时不必开 isolate，省掉启动开销。
    if (!_hasAnyFile()) return <Gallery>[];
    if (!useIsolate) return _loadAllSync(_dir.path);
    return Isolate.run(() => _loadAllSync(_dir.path));
  }

  bool _hasAnyFile() {
    try {
      for (final e in _dir.listSync()) {
        if (e is File && e.path.endsWith(_suffix)) return true;
      }
    } catch (_) {}
    return false;
  }

  /// 同步版本，仅用于隔离区内部与测试。
  static List<Gallery> _loadAllSync(String dirPath) {
    final out = <Gallery>[];
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return out;

    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith(_suffix)) continue;
      try {
        final raw = entity.readAsStringSync();
        if (raw.isEmpty) continue;
        out.add(Gallery.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } catch (_) {
        // 损坏的单条记录不应导致整体加载失败。
      }
    }
    return out;
  }

  /// 同步读取（保留给测试与需要即时结果的场合）。
  List<Gallery> loadAll() => _loadAllSync(_dir.path);

  void save(Gallery gallery) {
    try {
      final target = _fileFor(gallery.id);
      // 先写临时文件再改名：避免写入过程中被中断留下半截 JSON。
      final tmp = File('${target.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(gallery.toJson()), flush: true);
      if (target.existsSync()) target.deleteSync();
      tmp.renameSync(target.path);
    } catch (_) {
      // 单个图集写失败不应中断导入流程。
    }
  }

  void delete(String id) {
    try {
      final f = _fileFor(id);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 清空全部索引文件（仅用于迁移或测试）。
  void clear() {
    if (!_dir.existsSync()) return;
    for (final entity in _dir.listSync()) {
      if (entity is File && entity.path.endsWith(_suffix)) {
        try {
          entity.deleteSync();
        } catch (_) {}
      }
    }
  }

  int fileCount() {
    if (!_dir.existsSync()) return 0;
    return _dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith(_suffix))
        .length;
  }
}

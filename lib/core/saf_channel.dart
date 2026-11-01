import 'package:flutter/services.dart';

/// Storage Access Framework 通道。
///
/// 为什么不用 `file_picker`：它把文件复制一份到 App 私有缓存，并且**不申请
/// 可持久化授权**（`FilePickerDelegate.java` 里没有任何 `FLAG_GRANT_*`）。
/// 结果是每次导入路径都变、缓存一清图集就打不开。这里自己起选择器并调用
/// `takePersistableUriPermission`，让授权长期有效，从而可以直接读原文件。
class SafChannel {
  SafChannel._();

  static const _channel = MethodChannel('simple_gallery_viewer/saf');

  /// 用户通过系统选择器选中的一个文档或目录。
  static Future<SafPick?> pickZip() async {
    final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('pickZip');
    return r == null ? null : SafPick._from(r);
  }

  static Future<SafPick?> pickFolder() async {
    final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('pickFolder');
    return r == null ? null : SafPick._from(r);
  }

  /// 选一个**可写**的输出目录。
  ///
  /// 与 [pickFolder] 的唯一区别是选择器同时申请写授权，并把读写都持久化。
  /// 批量翻译的成品图与 `manifest.json` 只会落在这个目录里；本应用不会
  /// 删除或改写用户的任何原始文件。
  static Future<SafPick?> pickOutputTree() async {
    final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'pickOutputTree',
    );
    return r == null ? null : SafPick._from(r);
  }

  /// 在目录 [parentUri] 下创建（或复用同名的）子目录，返回其 URI。
  static Future<String?> createDirectory(String parentUri, String name) async {
    return _channel.invokeMethod<String>('createDirectory', {
      'parentUri': parentUri,
      'name': name,
    });
  }

  /// 在目录 [parentUri] 下创建文件（同名文件会被替换），返回其 URI。
  static Future<String?> createFile(
    String parentUri,
    String name, {
    required String mime,
  }) async {
    return _channel.invokeMethod<String>('createFile', {
      'parentUri': parentUri,
      'name': name,
      'mime': mime,
    });
  }

  /// 覆盖写入一个已存在的文档。
  static Future<bool> writeBytes(String uri, Uint8List bytes) async {
    try {
      final ok = await _channel.invokeMethod<bool>('writeBytes', {
        'uri': uri,
        'bytes': bytes,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 原子写：先写临时文件再改名，保证读到的永远是完整内容。
  static Future<String?> writeFileAtomic(
    String parentUri,
    String name, {
    required String mime,
    required Uint8List bytes,
  }) async {
    return _channel.invokeMethod<String>('writeFileAtomic', {
      'parentUri': parentUri,
      'name': name,
      'mime': mime,
      'bytes': bytes,
    });
  }

  /// 文档是否存在（续跑时用来确认成品图还在）。
  static Future<bool> exists(String uri) async {
    try {
      final ok = await _channel.invokeMethod<bool>('exists', {'uri': uri});
      return ok ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 删除一个 `content://` 文件。**目录会被原生拒绝**。
  ///
  /// 目前只有「重译第 N–M 页」用它删掉那一段旧的 `page-NNNN.jpg`。
  /// 上层必须先确认这个 URI 来自译文目录的 `listTree`、且文件名匹配
  /// 页图命名规则——这里不做语义校验，只做传输。
  static Future<bool> deleteFile(String uri) async {
    try {
      final ok = await _channel.invokeMethod<bool>('deleteFile', {'uri': uri});
      return ok ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 读取 `content://` 文档的字节区间。
  static Future<Uint8List> readBytes(String uri, int offset, int length) async {
    try {
      final data = await _channel.invokeMethod<Uint8List>('readBytes', {
        'uri': uri,
        'offset': offset,
        'length': length,
      });
      return data ?? Uint8List(0);
    } on PlatformException {
      // 越界或提供方不支持该偏移时，视为"读不到数据"而不是异常。
      return Uint8List(0);
    }
  }

  /// 文档总长度。
  ///
  /// 这是判重所需的全部信息之一（另一个是显示名）：长度只是一次元数据查询，
  /// 不需要读文件内容，因此导入判重几乎没有 I/O 开销。
  static Future<int> sizeOf(String uri) async {
    final v = await _channel.invokeMethod<num>('sizeOf', {'uri': uri});
    return v?.toInt() ?? 0;
  }

  /// 列出一个目录（树 URI 或目录文档）的直接子项。
  static Future<List<SafChild>> listTree(String uri) async {
    final list = await _channel.invokeMethod<List<dynamic>>('listTree', {
      'uri': uri,
    });
    if (list == null) return const [];
    return list
        .cast<Map<dynamic, dynamic>>()
        .map(SafChild._from)
        .toList(growable: false);
  }

  /// 取一个目录的上一级目录的树 URI；已是顶层时返回 null。
  ///
  /// 用于"文件夹图集读不到时，往上一级去找它"。
  static Future<String?> parentTreeUri(String uri) async {
    try {
      return await _channel.invokeMethod<String>('parentTreeUri', {'uri': uri});
    } catch (_) {
      return null;
    }
  }

  /// 系统当前可用内存（字节）；取不到时返回 null。
  ///
  /// 用于播放动图前的预判：播放需要"帧数 × 单帧字节"的连续内存，
  /// 超过可用内存会把进程直接拖死。
  static Future<int?> availableMemory() async {
    try {
      return await _channel.invokeMethod<int>('availableMemory');
    } catch (_) {
      return null;
    }
  }

  /// 当前已持久化的授权列表（用于诊断与"重新授权"提示）。
  static Future<List<String>> persistedPermissions() async {
    final list = await _channel.invokeMethod<List<dynamic>>(
      'persistedPermissions',
    );
    if (list == null) return const [];
    return list
        .cast<Map<dynamic, dynamic>>()
        .map((m) => m['uri'] as String)
        .toList(growable: false);
  }

  static Future<bool> releasePersistable(String uri) async {
    final ok = await _channel.invokeMethod<bool>('releasePersistable', {
      'uri': uri,
    });
    return ok ?? false;
  }
}

/// 选择器返回的结果。
class SafPick {
  final String uri;

  /// 显示名。部分提供方（实测小米 externalstorage 对某些文档）不返回
  /// `DISPLAY_NAME`，此时会退回从 URI 末段解析，可能不完整。
  final String name;

  /// 文档字节长度；未知为 0。
  ///
  /// 判重依赖它，且 zip 解析需要用它判断文件是否合法，因此原生侧做了多路兜底。
  final int size;

  /// 是否成功取得**可持久化**授权。为 false 时本次会话仍可读，
  /// 但应用重启后可能失效，UI 应提示用户重新选择。
  final bool persisted;

  final bool isDirectory;

  SafPick({
    required this.uri,
    required this.name,
    required this.persisted,
    required this.isDirectory,
    this.size = 0,
  });

  factory SafPick._from(Map<dynamic, dynamic> m) => SafPick(
    uri: m['uri'] as String,
    name: (m['name'] as String?) ?? '未命名',
    size: (m['size'] as num?)?.toInt() ?? 0,
    persisted: (m['persisted'] as bool?) ?? false,
    isDirectory: (m['isDirectory'] as bool?) ?? false,
  );
}

/// 目录中的一个子项。
class SafChild {
  final String uri;
  final String name;
  final bool isDirectory;
  final int size;

  /// 最后修改时间（毫秒，0 表示提供方没给）。
  ///
  /// 文件夹来源的图片按"时间"排序依赖它；缺失时该排序对这些图集无效。
  final int lastModified;

  SafChild({
    required this.uri,
    required this.name,
    required this.isDirectory,
    required this.size,
    this.lastModified = 0,
  });

  factory SafChild._from(Map<dynamic, dynamic> m) => SafChild(
    uri: m['uri'] as String,
    name: (m['name'] as String?) ?? '',
    isDirectory: (m['isDirectory'] as bool?) ?? false,
    size: (m['size'] as num?)?.toInt() ?? 0,
    lastModified: (m['lastModified'] as num?)?.toInt() ?? 0,
  );

  /// 扩展名（小写，不含点）。
  String get extension {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  bool get isZip => !isDirectory && extension == 'zip';
}

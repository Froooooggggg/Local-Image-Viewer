import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

/// 译文文件名的规则：`page-0001.jpg`（动图原样复制则是 `.gif`）。
///
/// 与 TranslationJob.pageFileName 保持一致；迁移旧数据时也靠它反推页序。
final RegExp _pageFilePattern = RegExp(
  r'^page-(\d+)\.(jpg|png|gif)$',
  caseSensitive: false,
);

int? _asInt(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

String? _asString(Object? v) => v is String ? v : null;

/// 一页译文在翻译存放目录里的位置。
///
/// 只记文件名与 SAF URI：目录本身可能因为系统改写名字而换 URI，
/// 每次翻译都会重新解析后写回 [TranslationSet]。
class TranslationPageEntry {
  const TranslationPageEntry({
    required this.index,
    required this.file,
    required this.uri,
    this.copied = false,
    this.translated = 0,
    this.failed = 0,
  });

  /// 原图集里的页序（0 基）。
  final int index;

  /// 文件名，如 page-0001.jpg。
  final String file;

  /// SAF 文件 URI，阅读器直接用它读译文。
  final String uri;

  /// true = 动图原样复制，不是译文（阅读器照样当译文叠上去）。
  final bool copied;

  /// 成功翻出来的行数。
  final int translated;

  /// 没翻出来的行数。
  final int failed;

  /// 从文件名反推页序：`page-0003.jpg` → 2。认不出返回 null。
  static int? indexFromFileName(String file) {
    final m = _pageFilePattern.firstMatch(file.trim());
    final n = m == null ? null : int.tryParse(m.group(1)!);
    if (n == null || n <= 0) return null;
    return n - 1;
  }

  Map<String, dynamic> toJson() => {
    'index': index,
    'file': file,
    'uri': uri,
    'copied': copied,
    'translated': translated,
    'failed': failed,
  };

  /// 容错解析：字段缺失或类型不对都不抛，尽量从文件名把页序找回来。
  static TranslationPageEntry fromJson(Map<String, dynamic> j) {
    final file = _asString(j['file']) ?? '';
    return TranslationPageEntry(
      index: _asInt(j['index']) ?? indexFromFileName(file) ?? -1,
      file: file,
      uri: _asString(j['uri']) ?? '',
      copied: j['copied'] == true || file.toLowerCase().endsWith('.gif'),
      translated: _asInt(j['translated']) ?? 0,
      failed: _asInt(j['failed']) ?? 0,
    );
  }
}

/// 一本原图集的翻译集：登记译文目录，以及「哪一页有译文、文件在哪」。
///
/// 不再建图集、不再往列表里加一本：译文属于原图集，所以把索引里那本
/// 翻译图集移除后，译文依旧看得到。
class TranslationSet {
  TranslationSet({
    required this.galleryId,
    required this.dirUri,
    required this.dirName,
    this.source = 'ja',
    this.target = 'zh',
    int? updatedAtMs,
    Map<int, TranslationPageEntry>? pages,
  }) : updatedAtMs = updatedAtMs ?? DateTime.now().millisecondsSinceEpoch,
       pages = pages ?? <int, TranslationPageEntry>{};

  /// 原图集的 id。
  final String galleryId;

  /// 译文目录的 SAF tree URI。
  String dirUri;

  /// 译文目录的显示名（实际盘上可能被系统改写，例如 `111_AITranslate_`）。
  String dirName;

  /// 源语言 / 目标语言，只用于界面展示，读取译文不依赖。
  String source;
  String target;

  /// 最后更新时间（毫秒）。
  int updatedAtMs;

  /// 页序 → 译文条目。
  final Map<int, TranslationPageEntry> pages;

  Map<String, dynamic> toJson() => {
    'galleryId': galleryId,
    'dirUri': dirUri,
    'dirName': dirName,
    'source': source,
    'target': target,
    'updatedAtMs': updatedAtMs,
    // 按页序写，读起来直观，也保证同样的数据编码结果稳定。
    'pages': (pages.values.toList()..sort((a, b) => a.index.compareTo(b.index)))
        .map((e) => e.toJson())
        .toList(),
  };

  /// 容错解析：字段缺失/类型错一律取默认值，不能让一条坏记录毁掉整个索引。
  static TranslationSet fromJson(Map<String, dynamic> j, {String? fallbackId}) {
    final set = TranslationSet(
      galleryId: _asString(j['galleryId']) ?? fallbackId ?? '',
      dirUri: _asString(j['dirUri']) ?? '',
      dirName: _asString(j['dirName']) ?? '',
      source: _asString(j['source']) ?? 'ja',
      target: _asString(j['target']) ?? 'zh',
      updatedAtMs: _asInt(j['updatedAtMs']),
    );
    final raw = j['pages'];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final entry = TranslationPageEntry.fromJson(
          item.cast<String, dynamic>(),
        );
        // 没有 URI 的条目读不出来（文件当时没建成），登记了只会空转。
        if (entry.index < 0 || entry.uri.isEmpty) continue;
        set.pages[entry.index] = entry;
      }
    }
    return set;
  }
}

/// 翻译集索引（单例，存在 SharedPreferences 里）。
///
/// 只负责「哪本图集、哪一页、文件在哪」；目录与照片始终是用户的，
/// 这里任何操作都不删除、不移动文件。
class TranslationSetStore {
  TranslationSetStore._();

  static final TranslationSetStore instance = TranslationSetStore._();

  static const String storageKey = 'translation.sets.v1';

  final Map<String, TranslationSet> _sets = {};
  bool _loaded = false;

  /// 每次写盘 +1：界面监听它，译文角标 / 页数随之刷新。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool get isLoaded => _loaded;

  TranslationSet? of(String galleryId) => _sets[galleryId];

  /// 这本图集有没有可看的译文。
  bool has(String galleryId) => _sets[galleryId]?.pages.isNotEmpty ?? false;

  int pageCountOf(String galleryId) => _sets[galleryId]?.pages.length ?? 0;

  /// 第一页有译文的页序；没有译文返回 null。
  int? firstPageOf(String galleryId) {
    final pages = _sets[galleryId]?.pages;
    if (pages == null || pages.isEmpty) return null;
    var min = pages.keys.first;
    for (final k in pages.keys) {
      if (k < min) min = k;
    }
    return min;
  }

  TranslationPageEntry? pageOf(String galleryId, int index) =>
      _sets[galleryId]?.pages[index];

  /// 登记（或更新）译文目录。目录解析永远由调用方负责，这里只存结果。
  Future<void> ensureSet({
    required String galleryId,
    required String dirUri,
    required String dirName,
    required String source,
    required String target,
  }) async {
    final existing = _sets[galleryId];
    if (existing == null) {
      _sets[galleryId] = TranslationSet(
        galleryId: galleryId,
        dirUri: dirUri,
        dirName: dirName,
        source: source,
        target: target,
      );
      await _save();
      return;
    }
    var changed = false;
    if (dirUri.isNotEmpty && existing.dirUri != dirUri) {
      existing.dirUri = dirUri;
      changed = true;
    }
    if (dirName.isNotEmpty && existing.dirName != dirName) {
      existing.dirName = dirName;
      changed = true;
    }
    if (source.isNotEmpty && existing.source != source) {
      existing.source = source;
      changed = true;
    }
    if (target.isNotEmpty && existing.target != target) {
      existing.target = target;
      changed = true;
    }
    if (!changed) return;
    existing.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
    await _save();
  }

  /// 记下一页译文。`uri` 为空表示这一页没写出文件，不登记。
  Future<void> recordPage({
    required String galleryId,
    required TranslationPageEntry entry,
  }) async {
    if (entry.uri.isEmpty) return;
    final set = _sets[galleryId] ??= TranslationSet(
      galleryId: galleryId,
      dirUri: '',
      dirName: '',
    );
    set.pages[entry.index] = entry;
    set.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
    await _save();
  }

  /// 接管一份已经建好的翻译集（迁移用）。
  ///
  /// 已存在的翻译集不会被覆盖：只补缺页，新记下的译文优先。
  Future<void> adopt(TranslationSet set) async {
    final existing = _sets[set.galleryId];
    if (existing == null) {
      _sets[set.galleryId] = set;
      await _save();
      return;
    }
    var changed = false;
    if (existing.dirUri.isEmpty && set.dirUri.isNotEmpty) {
      existing.dirUri = set.dirUri;
      changed = true;
    }
    if (existing.dirName.isEmpty && set.dirName.isNotEmpty) {
      existing.dirName = set.dirName;
      changed = true;
    }
    for (final e in set.pages.entries) {
      if (existing.pages.containsKey(e.key)) continue;
      existing.pages[e.key] = e.value;
      changed = true;
    }
    if (!changed) return;
    existing.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
    await _save();
  }

  /// 只清索引，**不删任何文件**：译文目录与照片原地保留，
  /// 以后重新翻译会在同一目录里续写。
  Future<void> remove(String galleryId) async {
    if (_sets.remove(galleryId) == null) return;
    await _save();
  }

  /// 删掉若干页的记录（「重译第 N–M 页」用）。
  ///
  /// 这里**只动内存里的翻译集**：对应图片由调用方决定删不删。
  /// 返回真正被删掉的页数；整本清空后 `has()` 会变 false，
  /// 阅读器的「看译文」按钮随之消失。
  Future<int> removePages(String galleryId, Set<int> indices) async {
    if (indices.isEmpty) return 0;
    final set = _sets[galleryId];
    if (set == null) return 0;
    var removed = 0;
    for (final i in indices) {
      if (set.pages.remove(i) != null) removed++;
    }
    if (removed == 0) return 0;
    set.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
    await _save();
    return removed;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final e in decoded.entries) {
        final id = e.key;
        final value = e.value;
        if (id is! String || value is! Map) continue;
        final set = TranslationSet.fromJson(
          value.cast<String, dynamic>(),
          fallbackId: id,
        );
        if (set.galleryId.isEmpty) continue;
        _sets[set.galleryId] = set;
      }
    } catch (_) {
      // 索引坏了就当没有：译文文件都还在，重翻会写回同一个目录。
      // 不能让一条坏记录把整个翻译功能挡住。
    }
    revision.value++;
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = <String, dynamic>{
        for (final e in _sets.entries) e.key: e.value.toJson(),
      };
      await prefs.setString(storageKey, jsonEncode(map));
    } catch (_) {
      // 写盘失败不影响本次会话：内存里的索引还能继续用。
    }
    revision.value++;
  }

  /// 测试用：把单例恢复到「还没 load」的状态。
  @visibleForTesting
  void resetForTesting() {
    _sets.clear();
    _loaded = false;
    revision.value++;
  }
}

/// 由旧版「翻译图集」造出一条翻译集（迁移用，只读旧索引，不碰文件）。
///
/// 旧版把译文导入成了一本独立图集，页面文件名固定为 page-NNNN.jpg/gif。
/// 这里按文件名反推原图集页序，把 URI 指回磁盘上已经存在的那些文件，
/// 于是移除那本图集的索引之后，译文仍然从原图集里看得到。
TranslationSet? translationSetFromLegacyGallery(
  Gallery translated, {
  required String galleryId,
}) {
  final pages = <int, TranslationPageEntry>{};
  for (final image in translated.images) {
    final file = image.fileName;
    final index = TranslationPageEntry.indexFromFileName(file);
    if (index == null) continue;
    pages[index] = TranslationPageEntry(
      index: index,
      file: file,
      uri: image.path,
      // 动图不翻译、原样复制，阅读器直接把它当译文叠上去。
      copied: file.toLowerCase().endsWith('.gif'),
    );
  }
  if (pages.isEmpty) return null;
  return TranslationSet(
    galleryId: galleryId,
    dirUri: translated.sourcePath,
    dirName: translated.title,
    pages: pages,
  );
}

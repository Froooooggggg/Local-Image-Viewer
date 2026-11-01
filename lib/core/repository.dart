import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show ValueNotifier, debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'archive_reader.dart';
import 'byte_source.dart';
import 'content_hash.dart';
import 'gallery_store.dart';
import 'models.dart';
import 'saf_channel.dart';
import 'thumb_cache.dart';

/// 导入失败/跳过的机器可读原因。
///
/// 不再用「消息文本里包含某个词」来判断结果类型：那种做法一旦文案改动或
/// 出现同义表达就会误分类（曾经把真实错误混进"读取失败"里查不出原因）。
enum ImportOutcome {
  ok,
  duplicate,

  /// 压缩包/文件夹里没有图片。
  empty,

  /// 不是有效的 zip、不支持的结构。
  invalid,

  /// 读取或权限问题。
  io,

  /// 来源不存在或已被移动。
  missing,

  /// 传入了目录，应走批量导入。
  wrongKind,
}

/// 导入结果，用于向用户反馈。
class ImportResult {
  final ImportOutcome outcome;
  final String message;
  final Gallery? gallery;

  const ImportResult(this.outcome, this.message, [this.gallery]);

  bool get ok => outcome == ImportOutcome.ok;
}

/// 批量导入的结果汇总。
class BatchImportReport {
  final int imported;
  final int duplicates;
  final int failed;
  final int empty;

  /// 成功导入的图集（便于 UI 立即展示或提示）。
  final List<Gallery> galleries;

  /// 失败项的原因，形如 `标题：原因`。
  ///
  /// 必须保留具体原因：只报"读取失败 N 个"无法定位问题（曾经因此查不到
  /// 真实错误）。
  final List<String> failures;

  /// 是否被用户中途取消。
  final bool cancelled;

  const BatchImportReport({
    required this.imported,
    required this.duplicates,
    required this.failed,
    required this.empty,
    required this.galleries,
    this.failures = const [],
    this.cancelled = false,
  });

  bool get nothingFound =>
      imported == 0 && duplicates == 0 && failed == 0 && empty == 0;

  /// 供 snackbar 展示的一句话摘要。
  String get summary {
    final parts = <String>[];
    if (cancelled) parts.add('已取消');
    if (imported > 0) parts.add('导入 $imported 个');
    if (duplicates > 0) parts.add('跳过重复 $duplicates 个');
    if (empty > 0) parts.add('无图片 $empty 个');
    if (failed > 0) parts.add('读取失败 $failed 个');
    if (parts.isEmpty) return '没有找到可导入的内容';

    if (failures.isNotEmpty) {
      // 附上首个失败原因，便于用户直接看到并反馈。
      return '${parts.join('，')}\n（失败原因：${failures.first}）';
    }
    return parts.join('，');
  }
}

/// 批量导入时的候选项：一个子文件夹，或一个 .zip 文件。
///
/// [path] 是 `content://` URI（SAF 文档），不再是文件系统路径 ——
/// Android 10+ 下应用没有存储权限，拿不到可用的真实路径。
class ImportCandidate {
  final String path;
  final String title;
  final bool isZip;
  final int size;

  const ImportCandidate._(this.path, this.title, this.isZip, this.size);

  factory ImportCandidate.zip(String path, String title, {int size = 0}) =>
      ImportCandidate._(path, title, true, size);

  factory ImportCandidate.folder(String path, String title, {int size = 0}) =>
      ImportCandidate._(path, title, false, size);

  @override
  String toString() => '${isZip ? "zip" : "folder"}:$title';
}

/// 「更新图集」的结果类型。
enum UpdateOutcome {
  /// 发现了新增图片并已并入。
  updated,

  /// 没有新图片。
  upToDate,

  /// 该类型图集不支持更新（例如压缩包）。
  unsupported,

  /// 读取失败（授权失效、目录被移动等）。
  failed,
}

class UpdateResult {
  final UpdateOutcome outcome;
  final String message;
  final int addedCount;

  const UpdateResult(this.outcome, this.message, {this.addedCount = 0});

  bool get changed => outcome == UpdateOutcome.updated || addedCount > 0;
}

/// 批量操作的结果汇总。
class BatchActionResult {
  final int succeeded;
  final int skipped;

  /// 失败项及原因，形如 `标题：原因`。
  final List<String> failures;

  const BatchActionResult({
    required this.succeeded,
    this.skipped = 0,
    this.failures = const [],
  });

  String get summary {
    final parts = <String>[];
    if (succeeded > 0) parts.add('成功 $succeeded 个');
    if (skipped > 0) parts.add('跳过 $skipped 个');
    if (failures.isNotEmpty) parts.add('失败 ${failures.length} 个');
    if (parts.isEmpty) return '没有可操作的图集';
    if (failures.isNotEmpty) {
      return '${parts.join('，')}\n（${failures.first}）';
    }
    return parts.join('，');
  }
}

/// 图集仓库：持久化、导入、排序、收藏夹。
///
/// 硬约束：本类**不包含任何删除或移动用户文件的操作**。唯一的删除动作是
/// [removeGallery]，它只从软件索引里摘掉记录（并清掉 App 私有缓存里的封面），
/// 磁盘上的原始 zip / 文件夹原封不动。
class GalleryRepository {
  GalleryRepository._();

  static final GalleryRepository instance = GalleryRepository._();

  final List<Gallery> _galleries = [];
  final List<Collection> _collections = [];

  /// 仓库内容的变更通知。
  ///
  /// 解决的问题：`collections`/`galleries` 只是读取数据的 getter，
  /// 仓库内部改了它们**不会**让界面重建。再加上根壳用 `IndexedStack`
  /// 让三个页面一直存活，切 tab 也不会重建 —— 于是"在别处加了收藏夹，
  /// 必须重启应用才能看到"。
  ///
  /// 约定：任何会改变 `collections` 或 `galleries` 内容的写操作，
  /// 结束后都要调用 [notifyChanged]。界面加监听即可自动刷新。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 通知界面：仓库内容变了。
  void notifyChanged() {
    revision.value++;
  }

  AppSettings _settings = AppSettings();
  ThumbCache? _thumbs;
  SharedPreferences? _prefs;
  GalleryStore? _store;

  /// identity → 图集 的索引，使查重为 O(1)。
  final Map<String, Gallery> _identityIndex = {};

  /// 来源路径哈希 → 图集，用于兜底查重。
  final Map<String, Gallery> _sourceIndex = {};

  /// 批量导入期间置为 true：此时不逐条落盘，结束后统一写一次。
  bool _batching = false;

  /// 用户是否请求取消导入。
  ///
  /// 需求：导入过程中提供取消按钮。取消是**协作式**的：
  /// 在每一项的边界处检查，已完成的项保留，不再开始新的项。
  ///
  /// 生命周期：由 [beginImport] 在**开始一次新导入时**清零。
  /// 刻意不在这里自动重置 —— 否则"扫描目录"阶段点的取消会被丢掉
  /// （扫描可能很慢，用户在界面上看到的已经是"正在扫描目录…"）。
  bool _cancelRequested = false;

  /// 开始一次新的导入：清除上一次的取消状态。
  ///
  /// 必须在导入**开始之前**调用，而不是在批量循环内部 ——
  /// 后者会吞掉扫描阶段发出的取消请求。
  void beginImport() => _cancelRequested = false;

  /// 请求取消当前导入（由 UI 的取消按钮调用）。
  void requestCancelImport() => _cancelRequested = true;

  /// 当前导入是否已被用户取消。
  bool get importCancelled => _cancelRequested;

  /// 列表顺序缓存。
  ///
  /// 必须缓存：`galleries` 在 UI 构建与查找中被频繁访问，
  /// 每次重排 600+ 个图集（每个还带几千张图的清单）会明显拖慢甚至卡死。
  List<Gallery>? _orderedCache;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// 使列表顺序缓存失效。任何会改变图集集合或排序设置的操作都要调用。
  void _invalidateOrder() => _orderedCache = null;

  /// 列表页使用的图集顺序。
  ///
  /// 排序依据来自设置（导入顺序 / 导入时间，可正逆向）；
  /// 用户在批量操作里手动"换位"过的图集（[Gallery.sortIndex] 非空）优先按它排。
  List<Gallery> get galleries {
    final cached = _orderedCache;
    if (cached != null) return List.unmodifiable(cached);
    final computed = _computeOrder();
    _orderedCache = computed;
    return List.unmodifiable(computed);
  }

  List<Gallery> _computeOrder() {
    final ranked = <Gallery>[];
    final rest = <Gallery>[];
    // 保留原始下标：`importedAt` 只有毫秒精度，同一批导入的图集时间会相等，
    // 需要一个确定性的兜底比较，否则顺序会变得任意（实测会乱成 s2,s0,s1）。
    final originalIndex = <String, int>{};
    for (var i = 0; i < _galleries.length; i++) {
      final g = _galleries[i];
      originalIndex[g.id] = i;
      if (g.sortIndex == null) {
        rest.add(g);
      } else {
        ranked.add(g);
      }
    }
    if (ranked.isNotEmpty) {
      ranked.sort((a, b) => a.sortIndex!.compareTo(b.sortIndex!));
    }

    final by = _settings.gallerySort;
    final desc = _settings.galleryDescending;
    rest.sort((a, b) {
      var r = 0;
      switch (by) {
        case GallerySortField.importOrder:
          // 直接用原始下标，精确表达"第几个导入的"。
          r = (originalIndex[a.id] ?? 0).compareTo(originalIndex[b.id] ?? 0);
        case GallerySortField.importTime:
          r = a.importedAt.compareTo(b.importedAt);
          if (r == 0) {
            // 时间相同（同批导入）时回落到导入顺序，保证结果稳定。
            r = (originalIndex[a.id] ?? 0).compareTo(originalIndex[b.id] ?? 0);
          }
      }
      return desc ? -r : r;
    });

    // 手动排过序的整体排在前面，未排过的按设置排序。
    return [...ranked, ...rest];
  }

  List<Collection> get collections => List.unmodifiable(_collections);
  AppSettings get settings => _settings;

  /// 旧版把整个索引塞在 SharedPreferences 的这个键里（迁移用）。
  static const _kGalleriesLegacy = 'galleries.v1';
  static const _kCollections = 'collections.v1';
  static const _kSettings = 'settings.v1';

  Future<void> load() async {
    if (_loaded) return;
    _prefs = await SharedPreferences.getInstance();

    // 缓存目录不可用（平台通道缺失、磁盘异常等）不应让整个应用卡在加载中：
    // 没有封面缓存也能正常阅读，只是列表没有缩略图。
    try {
      _thumbs = await ThumbCache.instance();
    } catch (e) {
      _thumbs = null;
      // ignore: avoid_print
      print('[简单图集查看器] 封面缓存不可用，已降级运行：$e');
    }

    _store = await GalleryStore.open();

    // 图集索引来自"一个图集一个文件"的存储（见 gallery_store.dart）。
    // 走异步版本：解析在后台 isolate 完成，否则 28 MB 级别的索引会把
    // 主 isolate 卡死，启动时一直停在加载圈上。
    final fromStore = await _store!.loadAllAsync();
    for (final g in fromStore) {
      _galleries.add(g);
    }
    // 必须先建好索引，下面的迁移才能正确判重（否则会把已有图集再加一遍）。
    _rebuildIdentityIndex();

    // 迁移：旧的索引整份存在 SharedPreferences 的一个字符串列表里。
    // 首次升级时搬到新存储，并清掉旧键，避免重复读取与体积浪费。
    final legacy = _prefs!.getStringList(_kGalleriesLegacy);
    if (legacy != null && legacy.isNotEmpty) {
      final movedGalleries = <Gallery>[];
      for (final raw in legacy) {
        try {
          final g = Gallery.fromJson(jsonDecode(raw) as Map<String, dynamic>);
          // 新存储里没有这个才补上（同一个图集可能两边都有）。
          if (_identityIndex.containsKey(g.id)) continue;
          _galleries.add(g);
          movedGalleries.add(g);
        } catch (_) {}
      }
      // 批量写：一次循环落盘，避免逐条打开文件的开销。
      for (final g in movedGalleries) {
        _store!.save(g);
      }
      _rebuildIdentityIndex();
      // 成功迁移后才清掉旧键；失败则保留，下次还能再试。
      await _prefs!.remove(_kGalleriesLegacy);
      // ignore: avoid_print
      print(
        '[SGV] 索引已迁移到独立文件存储：${movedGalleries.length} 条'
        '（原有 ${fromStore.length} 条）',
      );
    }

    _rebuildIdentityIndex();

    for (final raw
        in _prefs!.getStringList(_kCollections) ?? const <String>[]) {
      try {
        _collections.add(
          Collection.fromJson(jsonDecode(raw) as Map<String, dynamic>),
        );
      } catch (_) {}
    }
    final s = _prefs!.getString(_kSettings);
    if (s != null) {
      try {
        _settings = AppSettings.fromJson(jsonDecode(s) as Map<String, dynamic>);
      } catch (_) {}
    }
    _loaded = true;
    _invalidateOrder();
  }

  /// 重建 identity → gallery 的索引，使查重从 O(n) 降到 O(1)。
  ///
  /// 压测暴露的问题：导入 1000 个图集时，每个都要线性扫过已有全部图集
  /// （且会遍历每个图集的图片清单），整体退化为 O(n²)。
  void _rebuildIdentityIndex() {
    _identityIndex.clear();
    for (final g in _galleries) {
      _identityIndex[g.id] = g;
      final hash = g.contentHash;
      if (hash != null && hash.isNotEmpty) _identityIndex[hash] = g;
    }
    _sourceIndex.clear();
    for (final g in _galleries) {
      _sourceIndex[Gallery.identityOf(g.sourcePath)] = g;
    }
  }

  /// 只写图集与设置。
  ///
  /// 图集本体已经改为**按需单文件写入**（谁变了写谁），因此这里不再全量重写；
  /// 集合与设置数据量很小，继续放在 SharedPreferences。
  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setStringList(
      _kCollections,
      _collections.map((c) => jsonEncode(c.toJson())).toList(),
    );
    await prefs.setString(_kSettings, jsonEncode(_settings.toJson()));
  }

  /// 保存单个图集（O(1)：只重写它自己的文件）。
  Future<void> _persistGallery(Gallery gallery) async {
    _store?.save(gallery);
  }

  Future<void> saveSettings() async {
    // 排序设置变了，列表顺序缓存必须失效。
    _invalidateOrder();
    await _persist();
  }

  // ------------------------------------------------------- 免责声明确认

  static const _kDisclaimerAccepted = 'disclaimer.accepted.v1';

  /// 用户是否已在首次启动时同意免责声明。
  ///
  /// 用独立键而不是塞进 AppSettings：它是一个一次性的确认状态，
  /// 与用户可调的偏好无关，也不该被"恢复默认设置"之类的操作重置。
  bool get disclaimerAccepted => _prefs?.getBool(_kDisclaimerAccepted) ?? false;

  /// 记录用户已同意免责声明（首次启动弹窗点"同意并继续"时调用）。
  Future<void> acceptDisclaimer() async {
    await _prefs?.setBool(_kDisclaimerAccepted, true);
  }

  /// 预设标签：在设置里预先定义，便于给图集快速打标签。
  Future<void> addPresetTag(String tag) async {
    final t = tag.trim();
    if (t.isEmpty || _settings.presetTags.contains(t)) return;
    _settings.presetTags = [..._settings.presetTags, t];
    await _persist();
  }

  Future<void> removePresetTag(String tag) async {
    _settings.presetTags = _settings.presetTags.where((t) => t != tag).toList();
    await _persist();
  }

  /// 仅用于测试：清空内存中的状态并允许重新加载。
  ///
  /// 仓库是单例，多个测试之间会互相污染（图集持续累积），因此测试在
  /// setUp 里必须调用它。
  @visibleForTesting
  void resetForTesting() {
    _galleries.clear();
    _identityIndex.clear();
    _sourceIndex.clear();
    _batching = false;
    _store = null;
    _collections.clear();
    _settings = AppSettings();
    _thumbs = null;
    _prefs = null;
    _loaded = false;
  }

  // ---------------------------------------------------------------- 导入

  /// 按**身份**查重（主要依据），O(1)。
  ///
  /// 身份由 [signatureOf] 生成：文件名 + 字节长度。同一个压缩包无论被移动到
  /// 哪个目录都能被认出；而内容不同的同名文件不会被误判。
  Gallery? findByIdentity(String identity) => _identityIndex[identity];

  /// 按图集 id 查找。
  ///
  /// 翻译关系只存 id（不存路径），界面每次都要用它把 id 换回图集，
  /// 所以这里走已经建好的 identity 索引，O(1)。
  Gallery? byId(String id) => _identityIndex[id];

  /// **旧版**：建立 / 解除「原图集 ⇄ 翻译图集」的双向关联。
  ///
  /// 1.3.7 起译文直接挂在原图集上，翻译流程不再调用它；只剩旧数据迁移时
  /// 用它清掉残留的关联 id。只写索引，不碰任何文件。
  /// 传 null 表示解除（翻译图集被移出列表时用）。
  Future<void> markTranslated(Gallery original, Gallery? translated) async {
    if (translated == null) {
      final old = original.translatedToId;
      original.translatedToId = null;
      await _persistGallery(original);
      if (old != null) {
        final prev = byId(old);
        if (prev != null) {
          prev.translatedFromId = null;
          await _persistGallery(prev);
        }
      }
    } else {
      original.translatedToId = translated.id;
      translated.translatedFromId = original.id;
      await _persistGallery(translated);
      await _persistGallery(original);
    }
    notifyChanged();
  }

  /// 更新图集的译文页数并落盘。
  ///
  /// 页数大于 0 就代表「这本有译文」（角标、阅读器叠放都看它）。翻译服务
  /// 每写完一页调一次，所以值没变时不写盘、不通知。
  Future<void> setTranslatedPages(Gallery g, int n) async {
    final next = n < 0 ? 0 : n;
    if (g.translatedPages == next) return;
    g.translatedPages = next;
    await _persistGallery(g);
    notifyChanged();
  }

  /// 计算一个压缩包的**轻量身份**：文件名 + 字节长度。
  ///
  /// 为什么不用内容哈希：算哈希要把整个包完整读一遍，一个几百 MB 的图集包
  /// 要读几百 MB 磁盘 —— 对"导入时判重"这个目的来说代价过高。
  ///
  /// 也不用**仅**文件名：`content://` 文档的 id 是不透明的数字，取不出原名；
  /// 且不同内容完全可能同名（例如 `1208727.zip` 与 `1208727 (1).zip`），
  /// 只看名字会把新包误判成已导入而拒绝。
  ///
  /// 「文件名 + 长度」既完全不需要读内容（长度只需一次查询），又足够稳：
  /// 要产生误判，需要两个不同压缩包同名**且**字节数完全相同。
  static String signatureOf({required String name, required int length}) {
    final normalizedName = name.trim().toLowerCase();
    return ContentHash.ofString('$normalizedName|$length');
  }

  /// 按来源 URI 查重（兜底），O(1)。
  ///
  /// 仅用于老数据：它们没有身份记录。URI 会随文件移动而变化，不能作为
  /// 长期判重依据。
  Gallery? findBySource(String sourcePath) =>
      _sourceIndex[Gallery.identityOf(sourcePath)];

  /// 为一个来源（`content://` URI 或真实文件路径）建立字节来源。
  ///
  /// [resolver] 仅用于测试：让测试把伪造的 URI 映射到内存数据，
  /// 从而在没有设备的情况下覆盖导入与阅读逻辑。返回 null 表示走默认实现。
  static ByteSource? Function(String source)? resolver;

  static ByteSource byteSourceFor(String source, {int? knownLength}) {
    final custom = resolver?.call(source);
    if (custom != null) return custom;
    if (source.startsWith('content://')) {
      return ContentUriByteSource(source, knownLength: knownLength);
    }
    return FileByteSource(source);
  }

  /// 安全地打开一个字节来源：即使调用方忘记关闭，也不会泄漏句柄。
  static Future<T> withSource<T>(
    String source,
    Future<T> Function(ByteSource) body, {
    int? knownLength,
  }) async {
    final s = byteSourceFor(source, knownLength: knownLength);
    try {
      return await body(s);
    } finally {
      await s.close();
    }
  }

  /// 导入一个 .zip 压缩包（经由系统选择器拿到的 SAF 文档）。
  ///
  /// 加密包不做支持（按需求砍掉）。判重以**内容哈希**为准：
  /// 因为我们持有可持久化的 URI 授权，读的是**原文件本身**，不再复制副本，
  /// 因此不会出现「缓存被清后图集打不开」的问题。
  Future<ImportResult> importZip(SafPick pick) async {
    if (pick.isDirectory) {
      return const ImportResult(ImportOutcome.wrongKind, '这是一个文件夹，请用批量导入');
    }

    // 经由 byteSourceFor 建立来源，这样测试可以注入内存实现；
    // 生产环境对 content:// 会得到 ContentUriByteSource。
    // 选择器已经顺带取回长度，直接复用，省一次跨通道查询。
    final ByteSource source = byteSourceFor(
      pick.uri,
      knownLength: pick.size > 0 ? pick.size : null,
    );

    // 判重依据：**文件名 + 字节长度**，不读文件内容。
    //
    // 只取长度是一次廉价的元数据查询（content:// 走一次 query），
    // 相比把整个包读一遍算哈希，开销可以忽略。
    final String identity;
    try {
      final length = await source.length();
      identity = signatureOf(name: _baseName(pick.name), length: length);
    } catch (e) {
      await source.close();
      return ImportResult(ImportOutcome.io, '无法读取文件信息：$e');
    }

    final dup = findByIdentity(identity) ?? findBySource(pick.uri);
    if (dup != null) {
      await source.close();
      return ImportResult(ImportOutcome.duplicate, '该文件已经导入过了', dup);
    }

    final ZipIndex index;
    try {
      index = await ZipIndex.openSource(source);
    } on FormatException catch (e) {
      await source.close();
      return ImportResult(ImportOutcome.invalid, '无法读取该压缩包：${e.message}');
    } catch (e) {
      await source.close();
      return ImportResult(ImportOutcome.io, '无法读取该压缩包：$e');
    }

    if (index.imageCount == 0) {
      await source.close();
      return const ImportResult(ImportOutcome.empty, '该压缩包里没有可显示的图片');
    }

    final gallery = Gallery(
      id: identity,
      contentHash: identity,
      sourcePath: pick.uri,
      kind: GalleryKind.zip,
      title: _titleFromName(_baseName(pick.name)),
      images: _sorted(
        index.imageEntries
            .asMap()
            .entries
            .map(
              (e) => GalleryImage(
                path: e.value.name,
                modified: e.value.lastModified,
                size: e.value.uncompressedSize,
                entryIndex: e.key,
              ),
            )
            .toList(),
      ),
    );

    _register(gallery);

    // 封面直接从原文件提取第一张，不额外复制整包。
    unawaited(_buildZipCover(gallery));
    await source.close();
    return ImportResult(ImportOutcome.ok, '已导入「${gallery.title}」', gallery);
  }

  /// 把图集登记进内存索引，并按需落盘。
  ///
  /// 批量导入期间（[_batching]）只登记不落盘，结束后统一写一次 ——
  /// 否则每个图集都触发一次全量写入，整体退化成 O(n²)。
  void _register(Gallery gallery) {
    _galleries.add(gallery);
    _identityIndex[gallery.id] = gallery;
    final hash = gallery.contentHash;
    if (hash != null && hash.isNotEmpty) _identityIndex[hash] = gallery;
    _sourceIndex[Gallery.identityOf(gallery.sourcePath)] = gallery;
    _invalidateOrder();

    if (!_batching) _store?.save(gallery);
  }

  /// 容错版本的导入：内部完成资源释放，适合批量场景。
  Future<ImportResult> importZipSafe(SafPick pick) => importZip(pick);

  /// 扫描一个 SAF 目录树，返回可导入的候选项：
  ///
  ///  * 每个**子文件夹** → 一个图集（读取其中全部图片，含更深层子目录）
  ///  * 每个 **.zip 文件** → 一个图集
  ///
  /// 该文件夹自身直接放的图片不会被读取（与需求一致：读的是子目录）。
  Future<List<ImportCandidate>> scanFolder(String treeUri) async {
    final children = await SafChannel.listTree(treeUri);
    final candidates = <ImportCandidate>[];
    for (final c in children) {
      if (c.isDirectory) {
        candidates.add(ImportCandidate.folder(c.uri, c.name, size: 0));
      } else if (c.isZip) {
        candidates.add(
          ImportCandidate.zip(c.uri, _titleFromName(c.name), size: c.size),
        );
      }
    }
    candidates.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return candidates;
  }

  /// 批量导入一个文件夹里的所有压缩包与所有子文件夹。
  ///
  /// 每个压缩包 / 子文件夹单独成为一个图集；查重同样按内容哈希生效。
  /// [onProgress] 会在每处理完一项后回调，便于 UI 显示进度。
  Future<BatchImportReport> importFolderBatch(
    String treeUri, {
    void Function(int done, int total, String title)? onProgress,
  }) async {
    // 取消状态由 [beginImport] 在导入开始时清零，这里只读取。
    // 扫描期间用户就可能已经点了取消（扫描可能很慢）。
    final candidates = await scanFolder(treeUri);
    if (_cancelRequested) {
      // ignore: avoid_print
      print('[SGV] 在扫描阶段被取消');
      return const BatchImportReport(
        imported: 0,
        duplicates: 0,
        failed: 0,
        empty: 0,
        galleries: [],
        cancelled: true,
      );
    }

    var imported = 0, duplicates = 0, failed = 0, empty = 0;
    final added = <Gallery>[];
    final failures = <String>[];
    // ignore: avoid_print
    print('[SGV] 批量导入开始：候选 ${candidates.length} 项');

    // 关键性能开关：整批期间不逐条落盘，结束后统一写一次。
    //
    // 之前每导入一个图集都会全量重写索引，导入 1000 个就是 O(n²) 次写入，
    // 压测表现为"越到后面越卡"。
    _batching = true;
    try {
      for (var i = 0; i < candidates.length; i++) {
        // 协作式取消：每一项开始时检查，已完成的保留、不再开始新的。
        if (_cancelRequested) {
          // ignore: avoid_print
          print('[SGV] 用户取消了导入，已完成 $imported 项');
          break;
        }
        final c = candidates[i];
        onProgress?.call(i, candidates.length, c.title);

        final ImportResult r;
        if (c.isZip) {
          r = await importZip(
            SafPick(
              uri: c.path,
              name: '${c.title}.zip',
              persisted: true,
              isDirectory: false,
            ),
          );
        } else {
          r = await importSubfolder(c.path, c.title);
        }

        // 按机器可读的 outcome 分类，而不是匹配消息文本：
        // 文本匹配一旦文案改动就会误分类（曾经把真实错误混进"读取失败"里）。
        switch (r.outcome) {
          case ImportOutcome.ok:
            imported++;
            if (r.gallery != null) added.add(r.gallery!);
          case ImportOutcome.duplicate:
            duplicates++;
          case ImportOutcome.empty:
            empty++;
          case ImportOutcome.invalid:
          case ImportOutcome.io:
          case ImportOutcome.missing:
          case ImportOutcome.wrongKind:
            failed++;
            failures.add('${c.title}：${r.message}');
        }
      }
    } finally {
      // 无论成功与否都恢复，并**只在此刻**把本批新增的图集写入磁盘。
      _batching = false;
      for (final g in added) {
        _store?.save(g);
      }
    }

    // ignore: avoid_print
    print(
      '[SGV] 批量导入结束：成功=$imported 重复=$duplicates '
      '无图片=$empty 失败=$failed',
    );
    for (final f in failures) {
      // ignore: avoid_print
      print('[SGV] 失败明细：$f');
    }

    onProgress?.call(candidates.length, candidates.length, '完成');

    final wasCancelled = _cancelRequested;
    _cancelRequested = false;

    return BatchImportReport(
      imported: imported,
      duplicates: duplicates,
      failed: failed,
      empty: empty,
      galleries: added,
      failures: failures,
      cancelled: wasCancelled,
    );
  }

  /// 把单个子文件夹作为一个图集导入（读取其内全部图片，含更深层目录）。
  ///
  /// 判重依据：**文件夹名 + 该文件夹内图片清单（文件名 + 大小）**。
  /// 不读任何图片内容，只用目录枚举得到的元数据，开销只有一次列目录。
  Future<ImportResult> importSubfolder(String folderUri, String title) async {
    final images = await _readFolderImages(folderUri);
    if (images.isEmpty) {
      return ImportResult(ImportOutcome.empty, '「$title」里没有找到图片');
    }

    // 只依赖文件名与大小（都来自目录枚举），不触碰图片内容。
    final identity = _folderIdentity(title, images);

    final dup = findByIdentity(identity) ?? findBySource(folderUri);
    if (dup != null) {
      return ImportResult(ImportOutcome.duplicate, '该文件夹已经导入过了', dup);
    }

    final gallery = Gallery(
      id: identity,
      contentHash: identity,
      sourcePath: folderUri,
      kind: GalleryKind.folder,
      title: title,
      images: _sorted(images),
    );

    _register(gallery);
    unawaited(_buildFolderCover(gallery));
    return ImportResult(ImportOutcome.ok, '已导入「${gallery.title}」', gallery);
  }

  /// 把**一个文件夹本身**的图片作为一个图集导入：**不进入子目录**。
  ///
  /// 与 [importSubfolder] 的区别，也是这个功能存在的意义：
  /// importSubfolder 用于这里放的是"每个子文件夹各成一个图集"的场景；
  /// 本方法则是把用户直接选中的那个目录里的图片当成一个图集，
  /// 子目录里的内容一概不管。
  Future<ImportResult> importSingleFolder(
    String folderUri,
    String title,
  ) async {
    final images = await _readFolderImages(folderUri, recurse: false);
    debugPrint('[import] 单层扫描 uri=$folderUri 命中图片=${images.length}');
    if (images.isEmpty) {
      return ImportResult(ImportOutcome.empty, '「$title」目录下没有图片（不含子目录）');
    }

    final identity = _folderIdentity(title, images);
    final dup = findByIdentity(identity) ?? findBySource(folderUri);
    if (dup != null) {
      return ImportResult(ImportOutcome.duplicate, '该文件夹已经导入过了', dup);
    }

    final gallery = Gallery(
      id: identity,
      contentHash: identity,
      sourcePath: folderUri,
      kind: GalleryKind.folder,
      // 标记为"单层"：更新时只扫这一层，不递归。
      singleLevel: true,
      title: title,
      images: _sorted(images),
    );

    _register(gallery);
    unawaited(_buildFolderCover(gallery));
    return ImportResult(ImportOutcome.ok, '已导入「${gallery.title}」', gallery);
  }

  /// 图集的身份：**文件夹名 + 图片清单（文件名 + 大小）**。
  ///
  /// 只依赖目录枚举得到的元数据，**不读任何图片内容**。
  ///
  /// 为什么必须带上文件夹名（这是一个已修复的真实缺陷）：
  /// 同一部作品的同一批图放在不同文件夹里是很常见的（分卷、备份、
  /// 不同汉化组的同名整理）。若只用图片清单当身份，这些文件夹会互相
  /// 判成"已导入过"，实测导致用户导入 1000 个文件夹时有 300 个被误拒。
  ///
  /// 带上文件夹名后语义才正确：
  ///   * 同一个文件夹再次导入 → 判为重复（符合预期）
  ///   * 同名文件夹在不同位置（备份/分卷副本）→ 判为重复（合理）
  ///   * 不同名字的文件夹即使图片清单相同 → 视为不同图集（正确）
  static String _folderIdentity(String folderName, List<GalleryImage> images) {
    final fingerprint =
        (images.map((i) => '${i.fileName}:${i.size}').toList()..sort()).join(
          '|',
        );
    final normalizedName = folderName.trim().toLowerCase();
    return ContentHash.ofString('$normalizedName#$fingerprint');
  }

  /// 重新扫描来源目录，把**新增**的图片并入图集。
  ///
  /// 需求：「更新」按键 —— 扫描图集对应目录下是否有新增文件。
  ///
  /// 语义选择：只做**增量添加**，不删除已有条目。这样既满足"发现新文件"，
  /// 又不会因为临时读不到某张图而把记录抹掉（宁可留着也绝不误删）。
  /// 压缩包图集无法重扫内容（重新枚举代价高且包内容通常不变），会明确拒绝。
  Future<UpdateResult> updateGallery(Gallery gallery) async {
    if (gallery.kind != GalleryKind.folder) {
      return const UpdateResult(
        UpdateOutcome.unsupported,
        '压缩包图集不支持更新（压缩包内容不会自己变）。'
        '如需重新读取，请移除后重新导入。',
      );
    }

    final List<GalleryImage> scanned;
    try {
      scanned = await _readFolderImages(
        gallery.sourcePath,
        recurse: !gallery.singleLevel,
      );
    } catch (e) {
      return UpdateResult(UpdateOutcome.failed, '无法读取目录：$e');
    }

    if (scanned.isEmpty) {
      return const UpdateResult(
        UpdateOutcome.failed,
        '目录里没有读到图片（可能授权已失效或文件被移动）',
      );
    }

    // 名称 + 大小 作为"同一张图"的判据。
    final known = <String>{
      for (final img in gallery.images) '${img.fileName}:${img.size}',
    };

    final added = <GalleryImage>[];
    for (final img in scanned) {
      final key = '${img.fileName}:${img.size}';
      if (known.contains(key)) continue;
      known.add(key);
      added.add(img);
    }

    if (added.isEmpty) {
      return UpdateResult(
        UpdateOutcome.upToDate,
        '已是最新（共 ${gallery.images.length} 张）',
      );
    }

    gallery.images = _sorted([...gallery.images, ...added]);
    await _persistGallery(gallery);
    notifyChanged();

    return UpdateResult(
      UpdateOutcome.updated,
      '新增 ${added.length} 张，共 ${gallery.images.length} 张',
      addedCount: added.length,
    );
  }

  /// 递归读取一个 SAF 目录里的图片（只认图片，其它文件一律不管）。
  ///
  /// 这是「文件夹导入」在 Android 10+ 下的正确做法：SAF 授权只作用于
  /// `content://`，把树 URI 转成真实路径再走 `dart:io` 会 Permission denied。
  ///
  /// [recurse] 为 false 时**只读该目录这一层**，不进入子目录。
  Future<List<GalleryImage>> _readFolderImages(
    String treeUri, {
    bool recurse = true,
  }) async {
    final out = <GalleryImage>[];
    await _collectDocImages(treeUri, out, recurse: recurse);
    return out;
  }

  Future<void> _collectDocImages(
    String uri,
    List<GalleryImage> out, {
    bool recurse = true,
  }) async {
    final List<SafChild> children;
    try {
      children = await SafChannel.listTree(uri);
    } catch (e) {
      // 权限不足或提供方异常时跳过该目录，不中断整体导入。
      // 这里曾经把异常吞得干干净净，结果"导入后说没有图片"完全无法定位：
      // 先打一行日志，出问题时能直接从 logcat 看出是目录读不了。
      debugPrint('[import] listTree 失败 uri=$uri err=$e');
      return;
    }
    if (children.isEmpty) {
      debugPrint('[import] 目录为空 uri=$uri');
    }
    for (final c in children) {
      if (c.isDirectory) {
        if (recurse) await _collectDocImages(c.uri, out, recurse: true);
        continue;
      }
      if (ArchiveEntry.imageExtensions.contains(c.extension)) {
        out.add(
          GalleryImage(
            path: c.uri,
            // 真实文件名来自 SAF 的显示名，不能从 URI 反推。
            displayName: c.name,
            // 修改时间由原生侧一并返回；此前写死 0，导致文件夹图集的
            // "按图片时间"排序完全无效（全都相等）。缺失时退回 0。
            modified: c.lastModified > 0
                ? DateTime.fromMillisecondsSinceEpoch(c.lastModified)
                : DateTime.fromMillisecondsSinceEpoch(0),
            size: c.size,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------- 来源修复

  /// 验证图集的来源是否仍然可读。
  ///
  /// 用于查看器里的"验证文件是否存在"：授权被撤销、文件被删除或移动时，
  /// 读取会失败，这里做一次轻量探测（只读 1 字节）。
  Future<bool> verifySource(Gallery gallery) async {
    try {
      if (gallery.isFolder) {
        // 目录：能枚举出东西就算存在。
        final children = await SafChannel.listTree(gallery.sourcePath);
        return children.isNotEmpty;
      }
      await withSource(
        gallery.sourcePath,
        (source) => source.read(0, 1),
        knownLength: 1,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 在上级目录里查找同名文件夹。
  ///
  /// 需求：文件夹图集读不到时，往上一级去找这个文件夹（可能被移动了）。
  ///
  /// 做法：从该图集的**父目录**开始逐级向上，在每一级的子目录中按名字查找，
  /// 最多向上 [maxLevels] 级。命中后返回一个新的可读 URI。
  ///
  /// [onProgress] 报告当前搜索到第几级；[isCancelled] 返回 true 时立即停止
  /// （用户手动取消，后续处理等同于"否"）。
  Future<String?> findFolderInParents(
    Gallery gallery, {
    int maxLevels = 3,
    void Function(int level, int maxLevels)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!gallery.isFolder) return null;
    final wanted = gallery.title.trim().toLowerCase();
    if (wanted.isEmpty) return null;

    var current = gallery.sourcePath;
    for (var level = 1; level <= maxLevels; level++) {
      if (isCancelled?.call() ?? false) return null;
      onProgress?.call(level, maxLevels);

      // 上一级目录
      String? parent;
      try {
        parent = await SafChannel.parentTreeUri(current);
      } catch (_) {
        parent = null;
      }
      if (parent == null || parent == current) break; // 已到顶层，无法再往上

      // 在上一级的子目录里找同名的
      final List<SafChild> children;
      try {
        children = await SafChannel.listTree(parent);
      } catch (_) {
        break;
      }
      for (final c in children) {
        if (isCancelled?.call() ?? false) return null;
        if (!c.isDirectory) continue;
        if (c.name.trim().toLowerCase() == wanted) return c.uri;
      }

      current = parent;
    }
    return null;
  }

  /// 按新来源重新读取一个文件夹图集（等同于"更新"，但来源已变）。
  ///
  /// 用于"找到了被移动的文件夹"之后重载：把 [newUri] 作为新的来源，
  /// 重新枚举内容并替换图片清单。
  Future<UpdateResult> reloadFromUri(Gallery gallery, String newUri) async {
    final List<GalleryImage> scanned;
    try {
      scanned = await _readFolderImages(newUri, recurse: !gallery.singleLevel);
    } catch (e) {
      return UpdateResult(UpdateOutcome.failed, '无法读取目录：$e');
    }
    if (scanned.isEmpty) {
      return const UpdateResult(UpdateOutcome.failed, '该目录里没有读到图片');
    }

    gallery.sourcePath = newUri;
    gallery.images = _sorted(scanned, gallery: gallery);
    await _persistGallery(gallery);
    notifyChanged();
    return UpdateResult(
      UpdateOutcome.updated,
      '已重新载入 ${scanned.length} 张',
      addedCount: scanned.length,
    );
  }

  // ---------------------------------------------------------------- 封面

  /// 从压缩包里提取第一张图片作为封面。
  ///
  /// 直接读原文件（`content://`），不复制整包 —— 复制一份 500 MB 的包只为
  /// 拿一张缩略图是不可接受的。
  Future<void> _buildZipCover(Gallery gallery) async {
    final thumbs = _thumbs;
    if (thumbs == null) return;

    final path = await thumbs.cover(gallery.id, () async {
      return withSource(gallery.sourcePath, (source) async {
        final index = await ZipIndex.openSource(source);
        if (index.imageEntries.isEmpty) return null;
        return index.imageEntries.first.read(source);
      });
    });
    if (path != null) {
      gallery.coverCachePath = path;
      // 只写这一个图集的文件，不再全量重写索引。
      await _persistGallery(gallery);
    }
  }

  /// 文件夹来源的封面：直接读第一个子文档。
  Future<void> _buildFolderCover(Gallery gallery) async {
    final thumbs = _thumbs;
    if (thumbs == null || gallery.images.isEmpty) return;
    final first = gallery.images.first;

    final path = await thumbs.cover(gallery.id, () async {
      return withSource(first.path, (source) => source.read(0, 1 << 20));
    });
    if (path != null) {
      gallery.coverCachePath = path;
      // 只写这一个图集的文件，不再全量重写索引。
      await _persistGallery(gallery);
    }
  }

  /// 为缺失封面的图集补齐封面（列表滚动到可见页时按需调用）。
  Future<void> ensureCovers(Iterable<Gallery> items) async {
    for (final g in items) {
      if (g.coverCachePath != null && File(g.coverCachePath!).existsSync()) {
        continue;
      }
      if (g.isFolder) {
        await _buildFolderCover(g);
      } else {
        // 打开失败（授权被撤销、文件被删）时仅表现为无封面。
        await _buildZipCover(g);
      }
    }
  }

  // ---------------------------------------------------------------- 排序

  /// 排序图片。**优先用图集专属设置**，没有则跟随全局设置。
  ///
  /// 需求：封面（图集内图片）排序既要有全局设置，也要能给单个图集单独指定。
  List<GalleryImage> _sorted(List<GalleryImage> images, {Gallery? gallery}) {
    final field = gallery?.sortField ?? _settings.sortField;
    final desc = gallery?.sortDescending ?? _settings.descending;

    final list = List<GalleryImage>.from(images);
    switch (field) {
      case SortField.modified:
        list.sort((a, b) => a.modified.compareTo(b.modified));
      case SortField.name:
        list.sort(
          (a, b) => _naturalCompare(
            a.fileName.toLowerCase(),
            b.fileName.toLowerCase(),
          ),
        );
    }
    if (desc) {
      return list.reversed.toList();
    }
    return list;
  }

  /// 按当前设置重新排列**所有图集内**的图片。
  ///
  /// 只改内存、不写磁盘：图片顺序完全由设置决定，进查看器时又会重排一次，
  /// 因此没有持久化的必要。之前这里对 600+ 个图集逐个写文件（其中有的带
  /// 几千条图片记录），改一次排序设置就会明显卡顿。
  Future<void> resortAll() async {
    for (final g in _galleries) {
      g.images = _sorted(g.images);
    }
  }

  /// 只对**将要打开**的那一个图集重排图片。
  ///
  /// 进查看器前调用即可，避免为了一次阅读而重排全部图集。
  void resortOne(Gallery gallery) {
    gallery.images = _sorted(gallery.images, gallery: gallery);
  }

  /// 设置**单个图集专属**的图片排序（覆盖全局设置）。
  ///
  /// [field] / [descending] 传 null 表示该维度跟随全局设置。
  /// 会立即重排该图集并持久化（只写这一个图集的文件）。
  Future<void> setGallerySort(
    Gallery gallery, {
    SortField? field,
    bool? descending,
  }) async {
    gallery.sortField = field;
    gallery.sortDescending = descending;
    gallery.images = _sorted(gallery.images, gallery: gallery);
    await _persistGallery(gallery);
    notifyChanged();
  }

  /// 批量设置图集专属排序。逐个写各自的文件。
  Future<BatchActionResult> batchSetGallerySort(
    List<Gallery> galleries, {
    SortField? field,
    bool? descending,
  }) async {
    for (final g in galleries) {
      g.sortField = field;
      g.sortDescending = descending;
      g.images = _sorted(g.images, gallery: g);
    }
    // 逐个写自己的文件；不涉及任何文件系统操作。
    for (final g in galleries) {
      _store?.save(g);
    }
    notifyChanged();
    return BatchActionResult(succeeded: galleries.length);
  }

  /// 某图集当前生效的排序（用于界面展示）。
  ({SortField field, bool descending}) effectiveSortOf(Gallery g) => (
    field: g.sortField ?? _settings.sortField,
    descending: g.sortDescending ?? _settings.descending,
  );

  /// 名称排序：让 `2.jpg` 排在 `10.jpg` 前面（自然序），而不是字典序。
  static int _naturalCompare(String a, String b) {
    var i = 0, j = 0;
    while (i < a.length && j < b.length) {
      final ca = a.codeUnitAt(i);
      final cb = b.codeUnitAt(j);
      if (_isDigit(ca) && _isDigit(cb)) {
        var x = 0, y = 0;
        while (i < a.length && _isDigit(a.codeUnitAt(i))) {
          x = x * 10 + (a.codeUnitAt(i) - 48);
          i++;
        }
        while (j < b.length && _isDigit(b.codeUnitAt(j))) {
          y = y * 10 + (b.codeUnitAt(j) - 48);
          j++;
        }
        if (x != y) return x.compareTo(y);
      } else {
        if (ca != cb) return ca.compareTo(cb);
        i++;
        j++;
      }
    }
    return (a.length - i).compareTo(b.length - j);
  }

  static bool _isDigit(int c) => c >= 48 && c <= 57;

  // ---------------------------------------------------------------- 修改

  Future<void> rename(Gallery gallery, String newTitle) async {
    final t = newTitle.trim();
    if (t.isEmpty) return;
    gallery.title = t;
    await _persistGallery(gallery);
    notifyChanged();
  }

  Future<void> markOpened(Gallery gallery) async {
    gallery.lastOpened = DateTime.now();
    // 只写这一个图集的文件。每次点开图集都会调用本方法，
    // 若在此全量重写索引，索引一大就会明显卡顿。
    await _persistGallery(gallery);
  }

  /// 记录图的**观看进度**（读到第几张）。
  ///
  /// 只在**退出查看器**时调用一次，不在每次翻页时写盘：
  /// 翻页是高频操作，每次都写索引文件会明显拖慢阅读。
  ///
  /// 越界下标会被夹住；图片清单为空时不记录。
  /// 若保存后索引里的"更新时间"变了，界面需要刷新（返回 true）。
  Future<bool> markProgress(Gallery gallery, int index) async {
    if (gallery.images.isEmpty) return false;
    final clamped = index.clamp(0, gallery.images.length - 1);
    if (gallery.lastIndex == clamped) return false;
    gallery.lastIndex = clamped;
    await _persistGallery(gallery);
    return true;
  }

  /// 从软件索引中移除图集记录。
  ///
  /// **只删除索引与 App 私有缓存中的封面**，磁盘上的 zip / 文件夹不会被
  /// 删除或移动。UI 上的措辞也必须明确这一点。
  Future<void> removeFromIndex(Gallery gallery) async {
    _galleries.removeWhere((g) => g.id == gallery.id);
    _identityIndex.remove(gallery.id);
    if (gallery.contentHash != null) {
      _identityIndex.remove(gallery.contentHash);
    }
    _sourceIndex.remove(Gallery.identityOf(gallery.sourcePath));
    for (final c in _collections) {
      c.galleryIds.remove(gallery.id);
    }
    _thumbs?.evict(gallery.id);
    // 只删除该图集自己的索引文件与封面缓存，磁盘上的原文件不受影响。
    _store?.delete(gallery.id);
    _invalidateOrder();
    await _persist();
    notifyChanged();
  }

  // ---------------------------------------------------------------- 批量操作

  /// 批量把图集加入 / 移出收藏夹。
  ///
  /// 只改变软件内显示，**不动任何文件**。
  Future<BatchActionResult> batchToggleCollection(
    Collection collection,
    List<Gallery> galleries, {
    required bool add,
  }) async {
    var ok = 0, skipped = 0;
    for (final g in galleries) {
      final contains = collection.galleryIds.contains(g.id);
      if (add && contains) {
        skipped++;
        continue;
      }
      if (!add && !contains) {
        skipped++;
        continue;
      }
      if (add) {
        collection.galleryIds.add(g.id);
      } else {
        collection.galleryIds.remove(g.id);
      }
      ok++;
    }
    await _persist();
    notifyChanged();
    return BatchActionResult(succeeded: ok, skipped: skipped);
  }

  /// 批量给图集打标签（按**增量**应用）。
  ///
  /// [add] 是每个目标图集都要加上的标签，[remove] 是要移除的标签。
  ///
  /// 为什么用增量而不是"最终列表 + append"：编辑器的初始状态是多本图集标签的
  /// **并集**，取消勾选某个标签的语义是"从这些图集上删掉它"。旧实现只并入、
  /// 从不移除，导致**标签只能加不能删**。
  Future<BatchActionResult> batchSetTags(
    List<Gallery> galleries, {
    List<String> add = const [],
    List<String> remove = const [],
  }) async {
    final toAdd = add.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    final toRemove = remove
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();

    if (toAdd.isEmpty && toRemove.isEmpty) {
      return const BatchActionResult(succeeded: 0, failures: ['没有改动']);
    }

    var changed = 0;
    for (final g in galleries) {
      final before = g.tags.join('|');
      final next = <String>{
        ...g.tags.where((t) => !toRemove.contains(t)),
        ...toAdd,
      }.toList();
      g.tags = next;
      // 每个图集只写自己的文件。
      _store?.save(g);
      if (g.tags.join('|') != before) changed++;
    }
    notifyChanged();
    return BatchActionResult(
      succeeded: changed == 0 ? galleries.length : changed,
    );
  }

  /// 单个图集按增量设置标签的便捷封装。
  Future<void> applyTagDelta(
    Gallery gallery, {
    required List<String> add,
    required List<String> remove,
  }) async {
    await batchSetTags([gallery], add: add, remove: remove);
  }

  /// 批量移动图集到指定位置（仅改变软件内的显示顺序）。
  ///
  /// 实现方式是给每个图集写入一个递增的 `sortIndex`，之后列表按它排序。
  /// 这**不会移动或重命名任何文件**，只是软件内的排列。
  Future<BatchActionResult> batchMove(
    List<Gallery> galleries, {
    required int targetIndex,
  }) async {
    if (galleries.isEmpty) {
      return const BatchActionResult(succeeded: 0, failures: ['没有选中的图集']);
    }
    // 记录手动顺序：从目标位置开始，按当前选中顺序插入序号。
    final order = List<Gallery>.from(_galleries);
    final moving = galleries.toSet();

    // 剩余的图集保持相对顺序，选中的图集整体插到 targetIndex 处。
    final rest = order.where((g) => !moving.contains(g)).toList();
    final insertAt = targetIndex.clamp(0, rest.length);
    final moved = order.where(moving.contains).toList();
    rest.insertAll(insertAt, moved);

    for (var i = 0; i < rest.length; i++) {
      rest[i].sortIndex = i;
      _store?.save(rest[i]);
    }
    // 手动顺序变了，列表缓存必须失效。
    _invalidateOrder();
    notifyChanged();
    return BatchActionResult(succeeded: moved.length);
  }

  /// 批量移除图集记录（只删索引与封面缓存，**不动磁盘文件**）。
  Future<BatchActionResult> batchRemoveFromIndex(
    List<Gallery> galleries,
  ) async {
    for (final g in galleries.toList()) {
      await removeFromIndex(g);
    }
    return BatchActionResult(succeeded: galleries.length);
  }

  /// 批量更新图集：重扫各自目录并并入新增图片。
  ///
  /// 逐个处理，单项失败不影响其余（与批量导入一致的容错策略）。
  Future<BatchActionResult> batchUpdate(
    List<Gallery> galleries, {
    void Function(int done, int total, String title)? onProgress,
  }) async {
    var ok = 0;
    final failures = <String>[];
    final total = galleries.length;

    for (var i = 0; i < total; i++) {
      final g = galleries[i];
      onProgress?.call(i, total, g.title);
      final r = await updateGallery(g);
      switch (r.outcome) {
        case UpdateOutcome.updated:
        case UpdateOutcome.upToDate:
          ok++;
        case UpdateOutcome.unsupported:
        case UpdateOutcome.failed:
          failures.add('${g.title}：${r.message}');
      }
    }

    onProgress?.call(total, total, '完成');
    notifyChanged();
    return BatchActionResult(
      succeeded: ok,
      skipped: total - ok - failures.length,
      failures: failures,
    );
  }

  // ---------------------------------------------------------------- 收藏夹

  Future<Collection> createCollection(String name) async {
    final c = Collection(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim().isEmpty ? '新收藏夹' : name.trim(),
    );
    _collections.add(c);
    await _persist();
    notifyChanged();
    return c;
  }

  Future<void> renameCollection(Collection c, String name) async {
    if (name.trim().isEmpty) return;
    c.name = name.trim();
    await _persist();
    notifyChanged();
  }

  Future<void> deleteCollection(Collection c) async {
    _collections.remove(c);
    await _persist();
    notifyChanged();
  }

  Future<void> toggleInCollection(Collection c, Gallery g) async {
    if (c.galleryIds.contains(g.id)) {
      c.galleryIds.remove(g.id);
    } else {
      c.galleryIds.add(g.id);
    }
    await _persist();
    notifyChanged();
  }

  List<Gallery> galleriesOf(Collection c) =>
      _galleries.where((g) => c.galleryIds.contains(g.id)).toList();

  // ---------------------------------------------------------------- 工具

  /// 由显示名得到图集标题（去掉扩展名）。
  static String _titleFromName(String name) {
    final base = _baseName(name);
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  /// 取路径或 URI 串的最后一段，得到可读文件名。
  ///
  /// 必须谨慎解码：真实 SAF URI 里可能含有非法的百分号序列（例如文件名本身
  /// 带 `%`），对整个 URI 调 `Uri.decodeComponent` 会抛
  /// `illegal percent encoding in URI`。这里先切出末段再尝试解码，
  /// 且解码失败时退回原样，绝不抛异常。
  static String _baseName(String raw) {
    var segment = raw;

    // 优先走 URI 解析：pathSegments 已经解码过。
    try {
      final uri = Uri.parse(raw);
      if (uri.pathSegments.isNotEmpty) {
        segment = uri.pathSegments.last;
        if (segment.isNotEmpty) return _stripToLastComponent(segment);
      }
    } catch (_) {
      // 不是合法 URI（或编码非法）时退回字符串切分。
    }

    segment = _lastComponent(raw);
    try {
      segment = Uri.decodeComponent(segment);
    } catch (_) {
      // 非法百分号编码：保持原样，不抛。
    }
    return _stripToLastComponent(_lastComponent(segment));
  }

  /// 按 `/` 与 `\` 取最后一段。
  static String _lastComponent(String value) {
    final slash = value.lastIndexOf('/');
    final backslash = value.lastIndexOf(r'\');
    final cut = slash > backslash ? slash : backslash;
    return cut >= 0 && cut < value.length - 1
        ? value.substring(cut + 1)
        : value;
  }

  /// 真实 SAF 文档 id 常见形态是 `<id>%2F<真实文件名>`，
  /// 解码后仍可能带一层目录分隔，这里再取一次末段。
  static String _stripToLastComponent(String value) {
    final decoded = value.replaceAll('%2F', '/').replaceAll('%2f', '/');
    return _lastComponent(decoded);
  }

  /// 供 UI 展示的缓存占用。
  int cacheUsedBytes() => _thumbs?.usedBytes() ?? 0;

  /// 清空缩略图缓存（仅 App 私有缓存）。
  Future<void> clearThumbCache() async {
    _thumbs?.clear();
    for (final g in _galleries) {
      g.coverCachePath = null;
      _store?.save(g);
    }
    await _persist();
  }
}

/// 便于 UI 读取原始字节的小工具。
typedef ByteLoader = Future<Uint8List?> Function();

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 图集来源类型。
enum GalleryKind {
  /// 一个 .zip 压缩包。
  zip,

  /// 文件系统中的一个文件夹（读取其**子目录**）。
  folder,
}

/// 图集内的单张图片（仅元数据，正文按需读取）。
class GalleryImage {
  /// 在 zip 中的包内路径，或文件夹来源的 `content://` 文档 URI。
  final String path;

  /// 展示名（真实文件名）。
  ///
  /// 必须单独保存：文件夹来源的 [path] 是 `content://` URI，其末段通常是
  /// 不透明的文档 id（如 `1234%2Fphoto.jpg`），无法用于显示或排序。
  final String? displayName;

  /// 排序与展示用的修改时间（zip 内为该图自身的 DOS 时间）。
  final DateTime modified;

  /// 未压缩字节数；未知时为 0。
  final int size;

  /// zip 条目下标；文件夹来源为 -1。
  final int entryIndex;

  const GalleryImage({
    required this.path,
    required this.modified,
    this.displayName,
    this.size = 0,
    this.entryIndex = -1,
  });

  String get fileName {
    final explicit = displayName;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final i = path.lastIndexOf('/');
    final j = path.lastIndexOf(Platform.pathSeparator);
    final cut = i > j ? i : j;
    final base = cut < 0 ? path : path.substring(cut + 1);
    // content:// 文档 id 常见形态是 "<id>%2F<真实文件名>"，尽量取出可读部分。
    //
    // 解码必须容错：真实 URI 可能含非法的百分号序列（例如文件名自带 `%`），
    // 那时 Uri.decodeComponent 会抛 illegal percent encoding in URI。
    var decoded = base;
    try {
      decoded = Uri.decodeComponent(base);
    } catch (_) {
      decoded = base.replaceAll('%2F', '/').replaceAll('%2f', '/');
    }
    final slash = decoded.lastIndexOf('/');
    return slash < 0 ? decoded : decoded.substring(slash + 1);
  }

  Map<String, dynamic> toJson() => {
    'p': path,
    'n': displayName,
    'm': modified.millisecondsSinceEpoch,
    's': size,
    'e': entryIndex,
  };

  static GalleryImage fromJson(Map<String, dynamic> j) => GalleryImage(
    path: j['p'] as String,
    displayName: j['n'] as String?,
    modified: DateTime.fromMillisecondsSinceEpoch(j['m'] as int),
    size: (j['s'] as num?)?.toInt() ?? 0,
    entryIndex: (j['e'] as num?)?.toInt() ?? -1,
  );
}

/// 一个图集。
class Gallery {
  /// 稳定唯一 id。压缩包来源为**内容哈希**（同一个包换位置、改名字都能认出来）；
  /// 文件夹来源为子目录清单的合成哈希。
  final String id;

  /// 原始来源标识：zip 文件路径（或选择器给的 URI），或文件夹目录 URI。
  ///
  /// 非 final：文件夹被移动后，查看器里的"上级目录查找"会找到新位置并更新它。
  String sourcePath;

  /// 内容哈希（SHA-256）。老数据可能为空，此时判重退回按路径比较。
  String? contentHash;

  final GalleryKind kind;

  /// 可自定义的显示名。默认为压缩包 / 文件夹名称。
  String title;

  /// 图集内的图片（已按当前排序规则排好）。
  List<GalleryImage> images;

  /// 用户标签，用于搜索。
  List<String> tags;

  /// 文件夹来源专用：是否**只读该目录这一层**（不进入子目录）。
  ///
  /// 影响「更新」时的扫描范围，必须持久化，否则更新会把子目录的图片也吞进来。
  bool singleLevel;

  /// 手动排列序号。用户在批量操作里"移动"图集时写入。
  ///
  /// null 表示未手动排过，此时沿用导入顺序。
  /// 只影响软件内显示顺序，**不涉及任何文件操作**。
  int? sortIndex;

  /// **本图集专属**的图片排序方式。
  ///
  /// null 表示跟随"设置"里的全局排序。非 null 时覆盖全局设置，
  /// 仅对这个图集生效（需求：封面单独排序，个体设置）。
  SortField? sortField;

  /// 本图集专属的排序方向。null 表示跟随全局设置。
  ///
  /// 与 [sortField] 分开存：用户可以只改方向、不动方式。
  bool? sortDescending;

  /// 是否有专属排序（任一字段被设置过）。
  bool get hasOwnSort => sortField != null || sortDescending != null;

  /// 面向用户的一句话说明，例如「按名称 · 逆向（本图集）」。
  String ownSortLabel(SortField globalField, bool globalDesc) {
    final f = sortField ?? globalField;
    final d = sortDescending ?? globalDesc;
    final name = f == SortField.modified ? '按图片时间' : '按文件名';
    final dir = d ? '逆向' : '正向';
    return hasOwnSort ? '$name · $dir（本图集）' : '$name · $dir（跟随全局）';
  }

  /// 导入时间。列表页可按它排序（需求：按时间或导入顺序，可正逆向）。
  DateTime importedAt;

  /// 封面缩略图在 App 私有缓存中的路径（可能尚未生成）。
  String? coverCachePath;

  /// 最近一次打开时间。
  DateTime? lastOpened;

  /// **观看进度**：上次读到第几张（0 基）。null 表示还没读过。
  ///
  /// 只记录一个下标 —— 它虽然每次翻页都变，但只在**退出查看器**时落盘一次，
  /// 避免每翻一页都写一次索引文件。
  int? lastIndex;

  /// **旧版**的「翻译图集」id（原图集 → 翻译图集）。
  ///
  /// 1.3.7 起译文直接挂在原图集上（见 TranslationSetStore），新代码不再写
  /// 这个字段；保留只为读旧索引、做一次性迁移。
  String? translatedToId;

  /// **旧版**翻译图集指回**原图集**的 id（翻译图集 → 原图集）。
  ///
  /// 同样只用于迁移旧数据：迁移完这本图集会从索引里摘掉（文件不动）。
  String? translatedFromId;

  /// 本图集是否是一本（旧版）翻译产物。正常数据里已不会为 true。
  bool get isTranslated => translatedFromId != null;

  /// 这本图集已经翻出过多少页译文（0 = 还没翻译）。
  ///
  /// 只记数量：具体哪一页、文件在哪，由 TranslationSetStore 按图集 id 记录。
  int translatedPages;

  /// 这本图集有没有译文可看（封面角标、阅读器叠放都看它）。
  ///
  /// 别和 [isTranslated] 混：[isTranslated] 说的是「我自己就是翻译产物」，
  /// [hasTranslation] 说的是「我身上有译文」。后者才是界面该用的。
  bool get hasTranslation => translatedPages > 0;

  /// 观看进度（0..1）；没有进度时返回 0。
  double get progress {
    if (lastIndex == null || images.isEmpty) return 0;
    final i = lastIndex!.clamp(0, images.length - 1);
    return (i + 1) / images.length;
  }

  /// 是否已读到（或越过）最后一张。
  bool get isFinished =>
      lastIndex != null && images.isNotEmpty && lastIndex! >= images.length - 1;

  /// 是否为文件夹来源（文件夹不生成图片列表缓存，读取更快）。
  bool get isFolder => kind == GalleryKind.folder;

  Gallery({
    required this.id,
    required this.sourcePath,
    required this.kind,
    required this.title,
    this.contentHash,
    this.images = const [],
    this.tags = const [],
    this.singleLevel = false,
    this.sortIndex,
    this.sortField,
    this.sortDescending,
    DateTime? importedAt,
    this.coverCachePath,
    this.lastOpened,
    this.lastIndex,
    this.translatedToId,
    this.translatedFromId,
    this.translatedPages = 0,
  }) : importedAt = importedAt ?? DateTime.now();

  int get imageCount => images.length;

  /// 按来源路径计算的旧式标识。
  ///
  /// **仅作为老数据的兜底**：路径会因系统选择器复制、文件移动而变化，
  /// 不能作为长期判重依据（这正是「换个位置还能重复导入」的根因）。
  static String identityOf(String sourcePath) {
    final normalized = sourcePath.replaceAll('\\', '/').toLowerCase().trim();
    return sha1.convert(utf8.encode(normalized)).toString();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'src': sourcePath,
    'hash': contentHash,
    'kind': kind.name,
    'title': title,
    'img': images.map((e) => e.toJson()).toList(),
    'tags': tags,
    'single': singleLevel,
    'sort': sortIndex,
    // 本图集专属排序；null 时不写入，保持 JSON 紧凑
    'sortField': sortField?.name,
    'sortDesc': sortDescending,
    'importedAt': importedAt.millisecondsSinceEpoch,
    'cover': coverCachePath,
    'opened': lastOpened?.millisecondsSinceEpoch,
    'lastIdx': lastIndex,
    // 翻译关系（两个方向都存，任一侧被移除后另一侧也能自愈）
    'trTo': translatedToId,
    'trFrom': translatedFromId,
    // 译文页数：1.3.7 起用它判断「有没有译文」，不再依赖翻译图集
    'trPages': translatedPages,
  };

  static Gallery fromJson(Map<String, dynamic> j) => Gallery(
    id: j['id'] as String,
    sourcePath: j['src'] as String,
    contentHash: j['hash'] as String?,
    kind: GalleryKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => GalleryKind.zip,
    ),
    title: j['title'] as String,
    images: ((j['img'] as List?) ?? const [])
        .map((e) => GalleryImage.fromJson(e as Map<String, dynamic>))
        .toList(),
    tags: ((j['tags'] as List?) ?? const []).cast<String>(),
    singleLevel: (j['single'] as bool?) ?? false,
    sortIndex: (j['sort'] as num?)?.toInt(),
    sortField: j['sortField'] == null
        ? null
        : SortField.values.firstWhere(
            (f) => f.name == j['sortField'],
            orElse: () => SortField.modified,
          ),
    sortDescending: j['sortDesc'] as bool?,
    importedAt: j['importedAt'] == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.fromMillisecondsSinceEpoch(j['importedAt'] as int),
    coverCachePath: j['cover'] as String?,
    lastOpened: j['opened'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(j['opened'] as int),
    lastIndex: (j['lastIdx'] as num?)?.toInt(),
    translatedToId: j['trTo'] as String?,
    translatedFromId: j['trFrom'] as String?,
    // 旧索引没有这个键；类型写坏时也当 0，不能让一本图集读不出来
    translatedPages: j['trPages'] is num
        ? (j['trPages'] as num).toInt().clamp(0, 1 << 30)
        : 0,
  );
}

/// 用户自定义收藏夹。只影响软件内显示，**绝不移动或删除任何文件**。
class Collection {
  final String id;
  String name;
  final List<String> galleryIds;

  Collection({required this.id, required this.name, List<String>? galleryIds})
    : galleryIds = galleryIds ?? [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'items': galleryIds,
  };

  static Collection fromJson(Map<String, dynamic> j) => Collection(
    id: j['id'] as String,
    name: j['name'] as String,
    galleryIds: ((j['items'] as List?) ?? const []).cast<String>(),
  );
}

/// 阅读模式。
enum ReadingMode {
  /// 左右滑动翻页（漫画阅读器式）。
  paged,

  /// 上下滚动连续查看。
  scroll,
}

/// 排序字段。
enum SortField {
  /// 每张图片自身的修改时间。
  modified,

  /// 文件命名。
  name,
}

/// 模糊匹配算法。
///
/// 两者应对的是不同的错法：
///   * [subsequence]：字符顺序必须一致。适合"记得开头几个字、想快速筛"，
///     也适合长查询当子串出现的情况；**对字母对调无能为力**。
///   * [tokenFuzzy]：**以词为单位**比较。查询被切成词，逐个去匹配标题里的词
///     （允许拼错、允许只命中一部分），因此：
///       - 词序无关（`World Hello` 也能被 `helloworld` 找到）
///       - 只命中标题里的某一个词也算命中
///       - 长标题不再是障碍（比的是词，不是整串）
///     实测 2 万条全量打分约 10ms，因此这一项可以做得很彻底。
enum FuzzyAlgorithm {
  /// 子序列匹配 + 位置奖励（参照 fzf）。
  subsequence,

  /// 词级模糊匹配（对调字母、词序、部分命中都能处理）。
  tokenFuzzy,
}

/// 搜索方式。
enum SearchMode {
  /// 普通包含匹配（最轻量）。
  plain,

  /// 模糊匹配，具体算法由 [AppSettings.fuzzyAlgorithm] 决定。
  fuzzy,

  /// 正则表达式匹配。
  regex,
}

/// 图集在列表页的排序依据。
enum GallerySortField {
  /// 按导入顺序（第几个被导入）。
  importOrder,

  /// 按导入时间（记录写入的时间），以及"最近打开时间"。
  importTime,
}

/// 全局设置。
class AppSettings {
  /// 图片在**图集内**的排序字段。
  SortField sortField;

  /// 是否逆向（降序）。
  bool descending;

  /// 图集在**列表页**的排序依据。
  GallerySortField gallerySort;

  /// 图集列表是否逆向。
  bool galleryDescending;

  /// 预设标签：在设置里预先定义，便于给图集快速打标签。
  List<String> presetTags;

  /// 阅读模式。
  ReadingMode readingMode;

  /// 前后预加载张数，上限 100。
  int preloadCount;

  /// 超出当前张多少张后自动卸载，上限不限。
  int unloadDistance;

  /// App 内亮度倍率，1.0 为原始亮度。
  double brightness;

  /// 每个图集列表页包含的图集数。
  int pageSize;

  /// 读到动图时是否**自动播放**。
  ///
  /// 默认 false：动图默认暂停，由用户点按钮播放。开启后读到时直接播放，
  /// 除非内存预判认定播放会把应用卡死 —— 那时仍保持暂停并说明原因。
  bool autoPlayGif;

  /// 是否启用**模糊搜索**。
  ///
  /// 默认关闭：模糊匹配要对每个图集的标题与标签逐字符扫描，明显比
  /// "包含"匹配贵。需求也明确说了这是选择性开启。
  bool fuzzySearch;

  /// 模糊匹配使用哪种算法（设置里可选）。
  FuzzyAlgorithm fuzzyAlgorithm;

  /// 是否启用**正则搜索**（也可以用 `[]` 前缀单次启用）。
  bool regexSearch;

  /// 搜索**最多显示**多少条。0 表示不限（有多少显示多少）。
  ///
  /// 默认 0：结果本来就按匹配质量排序，分数低的自然排在后面，
  /// 因此不需要靠"限制条数"来收窄，也不需要事后补足。
  int searchLimit;

  AppSettings({
    this.sortField = SortField.name,
    this.descending = false,
    this.gallerySort = GallerySortField.importTime,
    this.galleryDescending = true,
    this.presetTags = const [],
    this.readingMode = ReadingMode.paged,
    this.preloadCount = 3,
    this.unloadDistance = 8,
    this.brightness = 1.0,
    this.pageSize = 100,
    this.autoPlayGif = false,
    this.fuzzySearch = false,
    this.fuzzyAlgorithm = FuzzyAlgorithm.subsequence,
    this.regexSearch = false,
    this.searchLimit = 0,
  });

  /// 预加载硬上限（需求：最高 100 张）。
  static const int maxPreload = 100;

  Map<String, dynamic> toJson() => {
    'sort': sortField.name,
    'desc': descending,
    'gSort': gallerySort.name,
    'gDesc': galleryDescending,
    'presetTags': presetTags,
    'mode': readingMode.name,
    'preload': preloadCount,
    'unload': unloadDistance,
    'bright': brightness,
    'pageSize': pageSize,
    'autoGif': autoPlayGif,
    'fuzzy': fuzzySearch,
    'fuzzyAlgo': fuzzyAlgorithm.name,
    'regex': regexSearch,
    'searchLimit': searchLimit,
  };

  static AppSettings fromJson(Map<String, dynamic> j) => AppSettings(
    sortField: SortField.values.firstWhere(
      (s) => s.name == j['sort'],
      orElse: () => SortField.name,
    ),
    descending: j['desc'] as bool? ?? false,
    gallerySort: GallerySortField.values.firstWhere(
      (s) => s.name == j['gSort'],
      orElse: () => GallerySortField.importTime,
    ),
    galleryDescending: j['gDesc'] as bool? ?? true,
    presetTags: ((j['presetTags'] as List?) ?? const []).cast<String>(),
    readingMode: ReadingMode.values.firstWhere(
      (m) => m.name == j['mode'],
      orElse: () => ReadingMode.paged,
    ),
    preloadCount: ((j['preload'] as num?)?.toInt() ?? 3).clamp(1, maxPreload),
    unloadDistance: (j['unload'] as num?)?.toInt() ?? 8,
    brightness: ((j['bright'] as num?)?.toDouble() ?? 1.0).clamp(0.15, 1.0),
    pageSize: (j['pageSize'] as num?)?.toInt() ?? 100,
    autoPlayGif: j['autoGif'] as bool? ?? false,
    fuzzySearch: j['fuzzy'] as bool? ?? false,
    fuzzyAlgorithm: FuzzyAlgorithm.values.firstWhere(
      (a) => a.name == j['fuzzyAlgo'],
      orElse: () => FuzzyAlgorithm.subsequence,
    ),
    regexSearch: j['regex'] as bool? ?? false,
    searchLimit: (j['searchLimit'] as num?)?.toInt() ?? 0,
  );
}

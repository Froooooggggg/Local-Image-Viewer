import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show PlatformException;

import '../archive_reader.dart';
import '../byte_source.dart';
import '../models.dart';
import '../repository.dart';
import '../saf_channel.dart';
import 'bridge_client.dart';
import 'bridge_config.dart';

/// 单页处理结果，也是 `manifest.json` 里 `pages[]` 的一项。
class TranslationPageResult {
  const TranslationPageResult({
    required this.index,
    required this.sourceName,
    required this.output,
    this.uri = '',
    this.width = 0,
    this.height = 0,
    this.lines = 0,
    this.translated = 0,
    this.failed = 0,
    this.elapsedMs = 0,
    this.renderMissing = false,
    this.copied = false,
    this.noText = false,
    this.error,
  });

  /// 题目在图集里的下标（0 基）。
  final int index;
  final String sourceName;

  /// 成品文件名，例如 `page-0001.jpg`。
  final String output;

  /// 成品文件的 SAF URI；失败或早退时为空字符串。
  ///
  /// 译文改挂在原图集上之后，阅读器就靠这个 URI 去读，不再靠图集索引。
  final String uri;

  final int width;
  final int height;

  /// 服务端识别出的行数。
  final int lines;

  /// 翻译成功的行数。
  final int translated;

  /// 翻译失败的行数（行级失败，不影响整页）。
  final int failed;

  final int elapsedMs;

  /// 服务端没返回渲染图（`render` 字段缺失），此时存的是原图。
  final bool renderMissing;

  /// 这一页是**原样复制**的动图（GIF 不翻译，只搬过去）。
  final bool copied;

  /// 这一页**没有可翻译的文字**（服务端一块都没翻出来）。
  ///
  /// 这不是失败：整页都是画、或者只有拟声词的页本来就没得翻。
  /// 单独记一个状态，UI 用「无有效内容」显示，不计入失败数，
  /// 也不累计连续失败次数。
  final bool noText;

  /// 整页失败的原因；成功时为 null。
  final String? error;

  /// 有没有产出**可用的成品图**。
  ///
  /// `noText` 页既没报错也没有成品，按「不算成功」处理：退出码、进度、
  /// 以及续跑时的 `_resumed` 判定都靠这个 getter。
  bool get ok => error == null && !noText;

  Map<String, dynamic> toJson() => {
    'index': index,
    'sourceName': sourceName,
    'output': output,
    'uri': uri,
    'width': width,
    'height': height,
    'lines': lines,
    'translated': translated,
    'failed': failed,
    'elapsedMs': elapsedMs,
    'renderMissing': renderMissing,
    'copied': copied,
    'noText': noText,
    'error': error,
  };

  static TranslationPageResult fromJson(Map<String, dynamic> j) =>
      TranslationPageResult(
        index: (j['index'] as num?)?.toInt() ?? 0,
        sourceName: (j['sourceName'] as String?) ?? '',
        output: (j['output'] as String?) ?? '',
        uri: (j['uri'] as String?) ?? '',
        width: (j['width'] as num?)?.toInt() ?? 0,
        height: (j['height'] as num?)?.toInt() ?? 0,
        lines: (j['lines'] as num?)?.toInt() ?? 0,
        translated: (j['translated'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        elapsedMs: (j['elapsedMs'] as num?)?.toInt() ?? 0,
        renderMissing: j['renderMissing'] == true,
        copied: j['copied'] == true,
        noText: j['noText'] == true,
        error: j['error'] as String?,
      );
}

/// 进度快照。UI 只读它，不直接读 job 内部状态。
class TranslationProgress {
  const TranslationProgress({
    required this.total,
    required this.processed,
    required this.done,
    required this.failed,
    required this.skipped,
    required this.currentName,
    required this.elapsed,
    this.noText = 0,
    this.paused = false,
    this.lastError,
  });

  final int total;
  final int processed;
  final int done;
  final int failed;

  /// 没有可翻文字的页数（不算失败）。
  final int noText;

  /// 续跑时跳过的页数（上次已完成）。
  final int skipped;
  final String currentName;
  final Duration elapsed;
  final bool paused;
  final String? lastError;

  double get fraction => total == 0 ? 0 : processed / total;

  /// 剩余时间估算：按已处理页的平均耗时推算；没数据时返回 null。
  Duration? get eta {
    if (processed == 0 || total == 0) return null;
    final per = elapsed.inMilliseconds / processed;
    final left = total - processed;
    if (left <= 0) return Duration.zero;
    return Duration(milliseconds: (per * left).round());
  }
}

/// 一次批量任务的结果。
class TranslationOutcome {
  const TranslationOutcome({
    required this.outputTreeUri,
    required this.outputDirUri,
    required this.outputDirName,
    required this.done,
    required this.failed,
    required this.skipped,
    required this.cancelled,
    required this.pages,
    this.noText = 0,
    this.paused = false,
    this.fatalError,
  });

  final String outputTreeUri;
  final String outputDirUri;
  final String outputDirName;
  final int done;
  final int failed;
  final int skipped;

  /// 没有可翻文字的页数（不算失败）。
  final int noText;
  final bool cancelled;

  /// 因为"暂停"而结束（不是译完、也不是出错）。
  ///
  /// 暂停一律结束本次 run，由下一次 run 从 manifest 接着做：否则这个
  /// Future 会在这里挂着不返回，服务层就没法再开新任务了。
  final bool paused;

  final List<TranslationPageResult> pages;

  /// 整批中断的原因（配对失效、目录不可写等）；正常跑完为 null。
  final String? fatalError;

  bool get hasOutput => done > 0 || skipped > 0;
}

/// 批量翻译任务。
///
/// 设计要点：
///  * **严格串行**。服务端只有一条处理通道，并发请求只会拿回 409。
///  * **每页落一次 manifest**。中途被杀进程后，重启能跳过已完成的页。
///  * **先下载渲染图再进入下一页**。服务端只缓存几份几分钟，晚拿就是 410。
///  * 可暂停/继续/取消，可单页重试；失败连续 3 页自动暂停，避免空跑几百页。
class TranslationJob {
  TranslationJob({
    required this.gallery,
    required this.client,
    required this.config,
    required this.outputTreeUri,
    String? outputDirUri,
    String? outputDirName,
    String? source,
    String? target,
    int? maxSide,
    int? minChars,
    this.fromIndex,
    this.toIndex,
    this.onProgress,
    this.onPageDone,
  }) : source = source ?? config.source,
       target = target ?? config.target,
       maxSide = maxSide ?? config.maxSide,
       minChars = minChars ?? config.minChars,
       _outDirUri = outputDirUri,
       _outDirName = outputDirName;

  final Gallery gallery;
  final BridgeClient client;
  final BridgeConfig config;

  /// 用户在系统选择器里选的输出目录（SAF 树 URI）。
  final String outputTreeUri;

  final String source;
  final String target;
  final int maxSide;
  final int minChars;

  /// 只处理这一段页（0 基、闭区间）。`null` = 从第一页/到最后一页。
  ///
  /// 「重译第 N–M 页」靠它把工作量限制在用户选的那一段：范围外的页
  /// **不会被顺带重翻**，也不会出现在进度分母里。
  final int? fromIndex;
  final int? toIndex;

  int _rangeFrom = 0;
  int _rangeTo = -1;

  bool _inRange(int i) => i >= _rangeFrom && i <= _rangeTo;

  /// 进度回调；在任务所在 isolate 的微任务里同步调用，UI 侧要自己 setState。
  final void Function(TranslationProgress progress)? onProgress;

  /// 每处理完一页（无论成败）回调一次。
  ///
  /// 上层用它做检查点：写任务状态、把这一页登记进翻译集。
  /// **不能在这里做耗时很久的事**：它挡在下一页之前。
  final Future<void> Function(TranslationPageResult page)? onPageDone;

  final List<TranslationPageResult> _pages = [];

  String? _outDirUri;
  String? _outDirName;

  bool _paused = false;
  bool _cancelled = false;
  bool _finished = false;
  String? _fatalError;

  DateTime? _startedAt;

  /// 正在处理（或刚处理完）的文件名，用于进度文案。
  String _currentName = '';

  /// 最近一条状态提示（重试、暂停原因等）。
  String? _statusMessage;

  /// 上一次运行已经做完、这次直接跳过的页下标。
  final Set<int> _resumed = {};

  /// 连续失败计数：达到阈值就暂停，别让用户回来看到几百页报错。
  int _consecutiveFailures = 0;

  /// 首次收到 409 的时间；用来区分「服务短暂忙」和「busy 泄漏卡死」。
  DateTime? _busySince;

  /// 单次请求最多重试次数（不含首次）。
  static const int _maxRetries = 3;

  /// 连续多少页失败后自动暂停。
  static const int _failureStreakLimit = 3;

  /// 409 持续多久后判定服务端卡死（文档给的是 90 秒）。
  static const Duration _busyStuckAfter = Duration(seconds: 90);

  /// 409 连续重试多少次后判定卡死（文档给的是 9 次）。
  static const int _busyStuckAttempts = 9;

  /// 单页图片体积上限，与服务端 32 MiB 的限制对齐。
  static const int _maxImageBytes = 32 * 1024 * 1024;

  /// 动图原样复制的上限（不复用静态图那 32 MiB 的限制外，还会分块读）。
  static const int _maxGifBytes = 128 * 1024 * 1024;

  String? get fatalError => _fatalError;
  String? get outputDirUri => _outDirUri;
  String? get outputDirName => _outDirName;
  List<TranslationPageResult> get pages => List.unmodifiable(_pages);

  /// 请求暂停：当前这一页做完就结束本次 run（manifest 已落盘，可续跑）。
  void pause() {
    if (_finished || _cancelled) return;
    _paused = true;
    _statusMessage = '已暂停';
    _emit();
  }

  void cancel() {
    _cancelled = true;
    _paused = false;
  }

  /// 执行整批。
  Future<TranslationOutcome> run() async {
    _finished = false;
    _cancelled = false;
    _paused = false;
    _fatalError = null;
    _pages.clear();
    _consecutiveFailures = 0;
    _busySince = null;
    _startedAt = DateTime.now();
    _currentName = '';
    _statusMessage = null;
    _resumed.clear();

    final images = gallery.images;
    if (images.isEmpty) {
      return _finish(cancelled: false, fatal: '这个图集里没有图片');
    }

    // 先把区间钳到合法范围：调用方可能给了越界的页码。
    _rangeFrom = (fromIndex ?? 0).clamp(0, images.length - 1);
    _rangeTo = (toIndex ?? images.length - 1).clamp(_rangeFrom, images.length - 1);

    // 目录名固定为「原标题<AITranslate>」，因此重复翻译会落回同一个目录，
    // 天然获得"续写同一个译文目录"的语义（需求：类似更新操作）。
    _outDirName ??= translatedDirName(gallery.title);

    if (_outDirUri == null) {
      try {
        _outDirUri = await SafChannel.createDirectory(
          outputTreeUri,
          _outDirName!,
        );
      } on PlatformException catch (e) {
        // 原生抛的是 MKDIR_FAILED；最可能的原因是上次选的目录只拿到了
        // 读授权（旧版本只持久化读），重启后写标志已经失效。
        return _finish(
          cancelled: false,
          fatal: '无法在所选目录里建文件夹（${e.message ?? e.code}）。'
              '请到设置里重新选一次「译文存放位置」。',
        );
      } catch (e) {
        return _finish(cancelled: false, fatal: '无法创建输出目录：$e');
      }
      if (_outDirUri == null) {
        return _finish(cancelled: false, fatal: '无法创建输出目录（授权可能已失效）');
      }
    }

    // 先放标记再写页：媒体扫描器是按目录里的 .nomedia 判断收不收录的，
    // 反过来做的话，前面几页已经进了相册。
    await ensureNoMedia(_outDirUri!);

    // 续跑：读上次的 manifest，把已完成的页标记为 skipped。
    await _loadManifest();

    final skipDone = Set<int>.from(_resumed);

    ByteSource? zipSource;
    try {
      if (gallery.kind == GalleryKind.zip) {
        zipSource = GalleryRepository.byteSourceFor(gallery.sourcePath);
      }

      for (var i = _rangeFrom; i <= _rangeTo; i++) {
        if (_cancelled) break;

        // 暂停：立刻结束本次 run（不原地等）。已做完的页已经写进 manifest，
        // 用户点「继续」时由新的 run 接着往下做；这样 pause() 之后
        // run() 会真的返回，服务层才能开新任务。
        if (_paused) break;

        if (skipDone.contains(i)) continue;

        await _processPage(i, images[i], zipSource);
        await _saveManifest();

        if (_fatalError != null) break;
        if (_consecutiveFailures >= _failureStreakLimit) {
          _paused = true;
          _statusMessage =
              '连续 $_consecutiveFailures 页失败，已自动暂停；'
              '处理后点「继续」会从这一页接着来';
          _emit();
          break;
        }
      }
    } finally {
      await zipSource?.close();
    }

    await _saveManifest();
    return _finish(
      cancelled: _cancelled,
      fatal: _fatalError,
      paused: _paused && !_cancelled,
    );
  }

  /// 只重跑某一页（失败重试用）。
  Future<void> retryPage(int index) async {
    if (_outDirUri == null) return;
    if (index < 0 || index >= gallery.images.length) return;
    _rangeFrom = index;
    _rangeTo = index;
    ByteSource? zipSource;
    try {
      if (gallery.kind == GalleryKind.zip) {
        zipSource = GalleryRepository.byteSourceFor(gallery.sourcePath);
      }
      _pages.removeWhere((p) => p.index == index);
      _consecutiveFailures = 0;
      await _processPage(index, gallery.images[index], zipSource);
    } finally {
      await zipSource?.close();
    }
    await _saveManifest();
  }

  /// 译文目录名：`<原标题><AITranslate>`。
  ///
  /// 刻意**不带时间戳**：同一个图集反复翻译必须落回同一个目录，
  /// 否则每点一次就多出一本来，用户也没法"接着加到这本图集里"。
  ///
  /// 名字末尾的 `<AITranslate>` 是需求指定的标记。尖括号在 Android 的
  /// 文件名里合法，但部分文件管理器显示怪异 —— 那是用户自己选的写法。
  static String translatedDirName(String title) =>
      '${sanitizeTitle(title)}<AITranslate>';

  /// 旧名（保留一个入口，避免外部还在用）。
  @Deprecated('用 translatedDirName：翻译目录不再带时间戳')
  static String buildOutputDirName(String title, DateTime now) =>
      translatedDirName(title);

  /// 去掉路径分隔符与各个系统保留字符，并把长度截到 40 个字符。
  static String sanitizeTitle(String title) {
    var s = title.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F]'), '_').trim();
    // 连续下划线压成一个，避免名字像乱码。
    s = s.replaceAll(RegExp(r'_{2,}'), '_');
    if (s.isEmpty) s = '未命名';
    if (s.length > 40) s = s.substring(0, 40);
    return s;
  }

  /// 从 `manifest.json` 里删掉若干页的记录（「重译」用）。
  ///
  /// 只改 JSON，不动任何图片。返回真正删掉的条数。
  /// 读不到 / 解析不了就静默放弃：manifest 损坏最多让下次多翻几页，
  /// 不值得为它打断用户操作。
  static Future<int> forgetPagesInManifest(
    String dirUri,
    Set<int> indices,
  ) async {
    if (dirUri.isEmpty || indices.isEmpty) return 0;
    final List<SafChild> children;
    try {
      children = await SafChannel.listTree(dirUri);
    } catch (e) {
      debugPrint('[SGV-重译] 读译文目录失败，跳过 manifest：$e');
      return 0;
    }
    SafChild? manifest;
    for (final c in children) {
      if (c.name == 'manifest.json') manifest = c;
    }
    if (manifest == null) return 0;
    try {
      final size = await SafChannel.sizeOf(manifest.uri);
      if (size <= 0 || size > 8 * 1024 * 1024) return 0;
      final bytes = await SafChannel.readBytes(manifest.uri, 0, size);
      if (bytes.isEmpty) return 0;
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is! Map<String, dynamic>) return 0;
      final pages = decoded['pages'];
      if (pages is! List) return 0;
      final kept = <dynamic>[];
      var removed = 0;
      for (final p in pages) {
        final idx = p is Map ? (p['index'] as num?)?.toInt() : null;
        if (idx != null && indices.contains(idx)) {
          removed++;
        } else {
          kept.add(p);
        }
      }
      if (removed == 0) return 0;
      final next = Map<String, dynamic>.from(decoded)..['pages'] = kept;
      final json = const JsonEncoder.withIndent('  ').convert(next);
      await SafChannel.writeFileAtomic(
        dirUri,
        'manifest.json',
        mime: 'application/json',
        bytes: Uint8List.fromList(utf8.encode(json)),
      );
      debugPrint('[SGV-重译] manifest 删掉 $removed 条记录');
      return removed;
    } catch (e) {
      debugPrint('[SGV-重译] 改 manifest 失败：$e');
      return 0;
    }
  }

  /// 判断一个目录名是不是本应用建的译文目录。  ///
  /// 正常是 `原标题<AITranslate>`；`<` `>` 在 exFAT / SD 卡上会被提供方改写成
  /// 下划线，所以 `_AITranslate_` 也要认（1.3.5 起就按这个规则复用目录）。
  static bool isTranslatedDirName(String name) {
    final lower = name.toLowerCase();
    return lower.contains('<aitranslate>') || lower.contains('_aitranslate_');
  }

  /// 译文目录里的「别被相册收录」标记文件名。
  static const String noMediaFileName = '.nomedia';

  /// 给译文目录补一个 `.nomedia`（幂等）。
  ///
  /// 不加这个文件的话，系统媒体扫描器会把每一张 `page-0001.jpg` 当成用户自己的
  /// 照片收进相册，图集一多相册就被译文刷屏（用户实际反馈过）。
  /// 只写这一个 0 字节的标记文件，不碰任何图片；失败只打日志，不影响翻译。
  ///
  /// 返回 true 表示这次真的新建了标记。
  static Future<bool> ensureNoMedia(String dirUri) async {
    if (dirUri.isEmpty) return false;
    try {
      final children = await SafChannel.listTree(dirUri);
      // 已经有就不动：重复 createFile 会先删旧文件，没必要冒这个风险。
      if (children.any((c) => c.name == noMediaFileName)) return false;
    } catch (e) {
      debugPrint('[SGV-翻译] 读输出目录失败，跳过 .nomedia：$e');
      return false;
    }
    try {
      final uri = await SafChannel.createFile(
        dirUri,
        noMediaFileName,
        mime: 'application/octet-stream',
      );
      if (uri == null || uri.isEmpty) return false;
      final ok = await SafChannel.writeBytes(uri, Uint8List(0));
      debugPrint('[SGV-翻译] 已给译文目录加 .nomedia（写入=$ok）：$dirUri');
      return ok;
    } catch (e) {
      debugPrint('[SGV-翻译] 写 .nomedia 失败（不影响翻译）：$e');
      return false;
    }
  }

  /// 只翻译某一页（阅读器里的「翻译这一张」用）。
  ///
  /// 复用批量任务的同一套流程与 manifest：单图翻译的结果与批量翻到这一页
  /// 完全一致，下次批量续跑时会把它当作"已完成"直接跳过。
  ///
  /// 返回 null 表示连输出目录都建不出来。
  Future<TranslationPageResult?> translateOne(int index) async {
    if (index < 0 || index >= gallery.images.length) return null;
    _startedAt ??= DateTime.now();
    _rangeFrom = index;
    _rangeTo = index;

    if (_outDirUri == null) {
      _outDirName ??= translatedDirName(gallery.title);
      try {
        _outDirUri = await SafChannel.createDirectory(
          outputTreeUri,
          _outDirName!,
        );
      } catch (_) {
        return null;
      }
      if (_outDirUri == null) return null;
    }
    // 单图翻译也要补标记：这条路可能是一本图集第一次落盘的地方。
    await ensureNoMedia(_outDirUri!);
    // 每次都读一遍 manifest：单图翻译可能发生在批量任务没跑过的目录里，
    // 不读的话下一次批量会把这一页重做一遍。
    _pages.clear();
    _resumed.clear();
    await _loadManifest();

    ByteSource? zipSource;
    try {
      if (gallery.kind == GalleryKind.zip) {
        zipSource = GalleryRepository.byteSourceFor(gallery.sourcePath);
      }
      _pages.removeWhere((p) => p.index == index);
      await _processPage(index, gallery.images[index], zipSource);
    } finally {
      await zipSource?.close();
    }
    await _saveManifest();
    for (final p in _pages) {
      if (p.index == index) return p;
    }
    return null;
  }

  // ------------------------------------------------------------ 内部实现

  Future<void> _processPage(
    int index,
    GalleryImage image,
    ByteSource? zipSource,
  ) async {
    final started = DateTime.now();
    // 动图（GIF）不做识别与翻译：服务端只处理单帧图，动图送去也只会被
    // 压成一张静态图，等于毁掉原文件。这里原样复制，保持页序对齐。
    final isGif = _isGif(image);
    final outputName = pageFileName(index, gif: isGif);

    _currentName = image.fileName;
    _emit();

    Uint8List? bytes;
    try {
      bytes = await _readImageBytes(image, zipSource, allowLarge: isGif);
    } catch (e) {
      _addResult(
        TranslationPageResult(
          index: index,
          sourceName: image.fileName,
          output: outputName,
          error: '读取图片失败：$e',
        ),
      );
      _consecutiveFailures++;
      return;
    }
    if (bytes == null) {
      _addResult(
        TranslationPageResult(
          index: index,
          sourceName: image.fileName,
          output: outputName,
          error: '图片超过 32 MiB，服务端不收',
        ),
      );
      _consecutiveFailures++;
      return;
    }

    if (isGif) {
      try {
        final fileUri = await SafChannel.createFile(
          _outDirUri!,
          outputName,
          mime: 'image/gif',
        );
        if (fileUri == null) {
          throw StateError('无法在输出目录里创建 $outputName');
        }
        if (!await SafChannel.writeBytes(fileUri, bytes)) {
          throw StateError('写入 $outputName 失败');
        }
        _addResult(
          TranslationPageResult(
            index: index,
            sourceName: image.fileName,
            output: outputName,
            uri: fileUri,
            copied: true,
            elapsedMs: DateTime.now().difference(started).inMilliseconds,
          ),
        );
        _consecutiveFailures = 0;
      } catch (e) {
        _addResult(
          TranslationPageResult(
            index: index,
            sourceName: image.fileName,
            output: outputName,
            error: '复制动图失败：$e',
          ),
        );
        _consecutiveFailures++;
      }
      return;
    }

    try {
      // 服务端全局串行，这里逐页顺序请求；重试策略见 _callWithRetry。
      var result = await _translateWithRetry(bytes);

      // 一块都没翻出来：服务端只会给一张「把原文擦掉、却没贴译文」的图。
      // 存下来比不存更糟（用户会以为翻译坏了），所以这里只记录不落盘。
      final failedLines = result.lines.where((l) => !l.ok).length;
      if (result.translatedCount == 0) {
        _logPage(index, 'no_text', result, started);
        _addResult(
          TranslationPageResult(
            index: index,
            sourceName: image.fileName,
            output: outputName,
            lines: result.lines.length,
            translated: 0,
            failed: failedLines,
            elapsedMs: DateTime.now().difference(started).inMilliseconds,
            // 不是失败：纯画面页本来就没得翻。UI 显示「无有效内容」。
            noText: true,
          ),
        );
        // 空白页/纯画面页不是服务故障，不累计连续失败，否则一话里连着
        // 三张彩页就会把整批暂停掉。
        return;
      }

      Uint8List? renderBytes;

      final render = result.render;
      if (render != null) {
        try {
          renderBytes = await _fetchRenderWithResend(render, bytes);
        } on BridgeException catch (e) {
          // 出图被淘汰/过期：重发同一页再取一次。
          if (e.isRenderGone) {
            result = await _translateWithRetry(bytes);
            final again = result.render;
            if (again != null) {
              renderBytes = await _fetchRenderWithResend(again, bytes);
            }
          } else {
            rethrow;
          }
        }
      }

      // 拿不到成品图就这页不写：本项目**没有本地渲染器**，写原图等于把
      // 一张没翻译的页混进译文序列，比留一个可见的失败更糟。
      if (renderBytes == null) {
        _logPage(index, 'render_missing', result, started);
        _consecutiveFailures++;
        _addResult(
          TranslationPageResult(
            index: index,
            sourceName: image.fileName,
            output: outputName,
            lines: result.lines.length,
            translated: result.translatedCount,
            failed: failedLines,
            renderMissing: true,
            elapsedMs: DateTime.now().difference(started).inMilliseconds,
            error: '服务端没有返回成品图（render 为空），这页未写入；'
                '点重试可以只重做这一页',
          ),
        );
        return;
      }

      _logPage(index, 'ok', result, started);
      final payload = renderBytes;

      // 写成品图。命名固定成 page-NNNN.jpg：服务端返回的就是 JPEG。
      final fileUri = await SafChannel.createFile(
        _outDirUri!,
        outputName,
        mime: 'image/jpeg',
      );
      if (fileUri == null) {
        throw StateError('无法在输出目录里创建 $outputName');
      }
      final wrote = await SafChannel.writeBytes(fileUri, payload);
      if (!wrote) {
        throw StateError('写入 $outputName 失败');
      }

      _addResult(
        TranslationPageResult(
          index: index,
          sourceName: image.fileName,
          output: outputName,
          uri: fileUri,
          width: result.width,
          height: result.height,
          lines: result.lines.length,
          translated: result.translatedCount,
          failed: failedLines,
          elapsedMs: DateTime.now().difference(started).inMilliseconds,
        ),
      );
      _consecutiveFailures = 0;
    } on BridgeException catch (e) {
      _logError(index, e);
      // 整批都做不下去的只有两类：配对失效（401）和服务端卡住（503/504）。
      // 413（太大）、415（格式）、409（重试耗尽）、500 都只算这一页失败——
      // 把它们升级成 fatal 会让一页坏图毁掉整本。
      if (e.isUnauthorized) {
        _consecutiveFailures++;
        _fatalError = '配对码不对或已失效，请到设置里重新粘贴配对信息';
      } else if (e.isSettingsTimeout || e.isInferenceTimeout) {
        _consecutiveFailures++;
        _paused = true;
        _statusMessage = e.isInferenceTimeout
            ? '模型推理超时（这一页没翻完），已暂停；点「继续」会重试这一页'
            : '翻译 App 一时读不到自己的设置，已暂停；过一会儿点「继续」重试这一页';
      } else {
        _consecutiveFailures++;
      }
      _addResult(
        TranslationPageResult(
          index: index,
          sourceName: image.fileName,
          output: outputName,
          elapsedMs: DateTime.now().difference(started).inMilliseconds,
          error: _pageErrorText(e),
        ),
      );
    } on BridgeUnreachable catch (e) {
      _consecutiveFailures++;
      _addResult(
        TranslationPageResult(
          index: index,
          sourceName: image.fileName,
          output: outputName,
          elapsedMs: DateTime.now().difference(started).inMilliseconds,
          error: '${e.hint}（${e.cause}）',
        ),
      );
    } catch (e) {
      _consecutiveFailures++;
      _addResult(
        TranslationPageResult(
          index: index,
          sourceName: image.fileName,
          output: outputName,
          elapsedMs: DateTime.now().difference(started).inMilliseconds,
          error: '处理失败：$e',
        ),
      );
    }
  }

  /// 把单页错误翻译成给用户看的一句话（区分「太大」「格式」「忙」等）。
  static String _pageErrorText(BridgeException e) {
    if (e.isTooLarge) return '图片超过服务端上限：${e.message}';
    if (e.isUnsupportedMedia) {
      return '服务端不支持这个图片格式（${e.message}）；'
          '这页需要先转成 JPEG 再翻';
    }
    if (e.isBusy) return '翻译端一直在忙，这页没翻成：${e.message}';
    return '${_statusLabel(e.status)}：${e.message}';
  }

  static String _statusLabel(int status) => switch (status) {
    400 => '请求参数不对',
    408 => '服务端处理超时',
    413 => '图片太大',
    415 => '图片格式不支持',
    500 => '翻译服务内部错误',
    502 => '翻译失败',
    503 => '服务端读不到设置',
    504 => '模型推理超时',
    _ => 'HTTP $status',
  };

  /// 每页一行日志：只记页码 / 块数 / 状态 / 耗时，不记 token 与译文内容。
  void _logPage(
    int index,
    String outcome,
    BridgeImageResult result,
    DateTime started,
  ) {
    debugPrint(
      '[SGV-翻译] 第 ${index + 1}/${gallery.images.length} 页 $outcome：'
      '块=${result.lines.length} 翻出=${result.translatedCount} '
      'render=${result.render == null ? 'missing' : 'server'} '
      '耗时=${DateTime.now().difference(started).inMilliseconds}ms',
    );
  }

  void _logError(int index, BridgeException e) {
    debugPrint(
      '[SGV-翻译] 第 ${index + 1}/${gallery.images.length} 页失败：'
      'HTTP=${e.status} code=${e.code} msg=${e.message}',
    );
  }

  /// 调用图片翻译，按文档给出的重试规则退避。
  Future<BridgeImageResult> _translateWithRetry(Uint8List bytes) async {
    var attempt = 0;
    while (true) {
      try {
        final result = await client.translateImage(
          bytes,
          source: source,
          target: target,
          render: true,
          maxSide: maxSide,
          minChars: minChars,
        );
        _busySince = null;
        return result;
      } on BridgeException catch (e) {
        // 409 忙：正常短暂忙仍按 Retry-After 重试；但如果同一个任务里
        // 持续 90 秒 / 连续 9 次都 409，说明服务端 busy 泄漏了，继续
        // 重试只会让用户看到无穷无尽的「N 秒后重试」。
        if (e.isBusy) {
          _busySince ??= DateTime.now();
          final stuckByTime =
              DateTime.now().difference(_busySince!) >= _busyStuckAfter;
          final stuckByCount = attempt + 1 >= _busyStuckAttempts;
          if (stuckByTime || stuckByCount) {
            _paused = true;
            _statusMessage =
                '翻译端似乎卡住了（一直返回“正在处理另一页”）。'
                '手机端请到最近任务里强制停止「同传互译」再重新打开；'
                '连的是 PC 就重启 PC 上的翻译服务。然后点继续。';
            _emit();
            rethrow;
          }
        } else {
          _busySince = null;
        }

        // 408 / 5xx：等 2 秒重试一次。
        // 504 是模型推理超时，重试同一页多半还是超时，直接交给上层暂停。
        // 503 是服务端一时读不到设置，只再试一次，别连着轰。
        // 401 / 413 / 415 / 410 等：不该重试，交给上层。
        final retryable =
            e.isBusy ||
            e.status == 408 ||
            (e.status >= 500 && !e.isInferenceTimeout);
        final maxAttempts = e.isBusy
            ? _busyStuckAttempts
            : (e.isSettingsTimeout ? 2 : _maxRetries + 1);
        if (!retryable || attempt + 1 >= maxAttempts) rethrow;
        attempt++;
        final wait = e.isBusy
            ? Duration(seconds: e.retryAfterSeconds ?? 1)
            : const Duration(seconds: 2);
        _statusMessage = '服务端忙，${wait.inSeconds} 秒后重试（$attempt/$_maxRetries）';
        _emit();
        await Future<void>.delayed(wait);
      }
    }
  }

  Future<Uint8List> _fetchRenderWithResend(
    BridgeRenderRef ref,
    Uint8List originalBytes,
  ) async {
    try {
      return await client.fetchRender(ref.path);
    } on BridgeException catch (e) {
      if (!e.isRenderGone) rethrow;
      // 410：出图缓存已淘汰。真实情况极罕见（我们拿到 id 就立刻下载），
      // 这里只重试一次下载；仍失败就由调用方退回原图。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return client.fetchRender(ref.id);
    }
  }

  Future<Uint8List?> _readImageBytes(
    GalleryImage image,
    ByteSource? zipSource, {
    bool allowLarge = false,
  }) async {
    if (gallery.kind == GalleryKind.zip) {
      final source = zipSource;
      if (source == null) throw StateError('压缩包来源未打开');
      final index = await ZipIndex.openSource(source);
      final entry = index.imageEntries[image.entryIndex];
      if (!allowLarge && entry.uncompressedSize > _maxImageBytes) return null;
      return entry.read(source);
    }

    final source = GalleryRepository.byteSourceFor(
      image.path,
      // 记录里的字节数是导入时由 SAF 枚举拿到的，通常可靠；仍为 0 就不传，
      // 让实现自己去问（问不到也不会影响读取，见下面的分块读）。
      knownLength: image.size > 0 ? image.size : null,
    );
    try {
      // 刻意**不用** `length()`：树内子文档 URI 曾被报成 0 字节，于是这里
      // 直接抛「文件为空」，批量翻译第一页就失败。改成按块读到 EOF，
      // 长度只用来判断"是否超过上限"，不再作为"能不能读"的依据。
      final cap = allowLarge ? _maxGifBytes : _maxImageBytes;
      final bytes = await readAllChunked(
        source,
        maxBytes: allowLarge ? cap : cap + 1,
      );
      if (bytes.isEmpty) {
        throw StateError('读不到图片内容：${image.fileName}');
      }
      if (!allowLarge && bytes.length > cap) return null;
      return bytes;
    } finally {
      await source.close();
    }
  }

  /// 是不是动图（按扩展名判断）。
  ///
  /// 只认 .gif：其它格式（webp/apng）在本应用的图集来源里极少，且
  /// 服务端对它们的处理与静态图一致，误判成"原样复制"反而更糟。
  static bool _isGif(GalleryImage image) =>
      image.fileName.toLowerCase().endsWith('.gif');

  void _addResult(TranslationPageResult r) {
    _pages.removeWhere((p) => p.index == r.index);
    _pages.add(r);
    _pages.sort((a, b) => a.index.compareTo(b.index));
    _emit();
    // 检查点回调走 unawaited：它由上层负责落状态，但绝不能拖住下一页。
    final cb = onPageDone;
    if (cb != null) unawaited(cb(r));
  }

  /// 读取上次的 manifest；损坏或不存在时静默忽略（当作全新一批）。
  Future<void> _loadManifest() async {
    final uri = await _manifestUri();
    if (uri == null) return;
    try {
      final size = await SafChannel.sizeOf(uri);
      if (size <= 0 || size > 8 * 1024 * 1024) return;
      final bytes = await SafChannel.readBytes(uri, 0, size);
      if (bytes.isEmpty) return;
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is! Map<String, dynamic>) return;
      if ((decoded['source'] as String?) != source ||
          (decoded['target'] as String?) != target) {
        // 语言变了就不复用旧进度：成品图是另一种语言的，混在一起会误导。
        return;
      }
      for (final p in (decoded['pages'] as List<dynamic>? ?? const [])) {
        if (p is Map<String, dynamic>) {
          final page = TranslationPageResult.fromJson(p);
          // 文件被用户删掉的不算已完成，重新做。
          var stillThere = true;
          if (page.ok && page.output.isNotEmpty) {
            stillThere = await _outputExists(page.output);
          }
          _pages.add(page);
          // 上次已完成且成品还在：本次直接跳过，但仍然留在 manifest 里，
          // 否则重写 manifest 会把这批记录抹掉。
          if (stillThere && page.ok) _resumed.add(page.index);
        }
      }
    } catch (_) {
      _pages.clear();
    }
  }

  Future<bool> _outputExists(String name) async {
    final dir = _outDirUri;
    if (dir == null) return false;
    try {
      final children = await SafChannel.listTree(dir);
      return children.any((c) => c.name == name);
    } catch (_) {
      return false;
    }
  }

  /// 写出 manifest.json（原子写，见原生 writeFileAtomic 的注释）。
  Future<void> _saveManifest() async {
    final dir = _outDirUri;
    if (dir == null) return;
    final json = const JsonEncoder.withIndent('  ').convert({
      'api': 1,
      'source': source,
      'target': target,
      'createdAt': _createdAtIso(),
      'pages': _pages.map((p) => p.toJson()).toList(growable: false),
    });
    try {
      await SafChannel.writeFileAtomic(
        dir,
        'manifest.json',
        mime: 'application/json',
        bytes: Uint8List.fromList(utf8.encode(json)),
      );
    } catch (_) {
      // manifest 写失败不该中断翻译：成品图仍在，用户至少能看到结果。
    }
  }

  String _createdAtIso() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final hh = abs.inHours.toString().padLeft(2, '0');
    final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}'
        'T${two(now.hour)}:${two(now.minute)}:${two(now.second)}$sign$hh:$mm';
  }

  /// manifest 的 URI：目录里的固定文件名。
  Future<String?> _manifestUri() => _findChild('manifest.json');

  Future<String?> _findChild(String name) async {
    final dir = _outDirUri;
    if (dir == null) return null;
    try {
      final children = await SafChannel.listTree(dir);
      for (final c in children) {
        if (c.name == name) return c.uri;
      }
    } catch (_) {}
    return null;
  }

  /// 成品文件名：`page-0001.jpg`，按图集内的页序（不是请求序号）。
  ///
  /// 动图原样复制时用 `.gif`，序号保持一致 —— 译文与原图集的
  /// 页序严格对齐，用户翻到第 N 张看到的还是第 N 张。
  static String pageFileName(int index, {bool gif = false}) =>
      'page-${(index + 1).toString().padLeft(4, '0')}.${gif ? 'gif' : 'jpg'}';

  /// 把当前状态投给 UI。
  ///
  /// `done` 只统计**本次**做完的页；上次遗留的算 `skipped`，这样进度条
  /// 「本次已完成 / 总数」与实际耗时才对得上。
  void _emit() {
    final done = _pages
        .where(
          (p) => _inRange(p.index) && p.ok && !_resumed.contains(p.index),
        )
        .length;
    final noText = _pages.where((p) => _inRange(p.index) && p.noText).length;
    final failed = _pages
        .where((p) => _inRange(p.index) && !p.ok && !p.noText)
        .length;
    final skipped = _resumed.where(_inRange).length;
    onProgress?.call(
      TranslationProgress(
        total: _rangeLength,
        processed: done + failed + noText + skipped,
        done: done,
        failed: failed,
        noText: noText,
        skipped: skipped,
        currentName: _currentName,
        elapsed: DateTime.now().difference(_startedAt ?? DateTime.now()),
        paused: _paused,
        lastError: _statusMessage,
      ),
    );
  }

  /// 本次区间内的页数（进度分母）。
  int get _rangeLength => _rangeTo < _rangeFrom ? 0 : _rangeTo - _rangeFrom + 1;

  TranslationOutcome _finish({
    required bool cancelled,
    String? fatal,
    bool paused = false,
  }) {
    _finished = true;
    final done = _pages
        .where(
          (p) => _inRange(p.index) && p.ok && !_resumed.contains(p.index),
        )
        .length;
    final noText = _pages.where((p) => _inRange(p.index) && p.noText).length;
    final failed = _pages
        .where((p) => _inRange(p.index) && !p.ok && !p.noText)
        .length;
    return TranslationOutcome(
      outputTreeUri: outputTreeUri,
      outputDirUri: _outDirUri ?? '',
      outputDirName: _outDirName ?? '',
      done: done,
      failed: failed,
      noText: noText,
      skipped: _resumed.where(_inRange).length,
      cancelled: cancelled,
      paused: paused,
      pages: List.unmodifiable(_pages),
      fatalError: fatal,
    );
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../byte_source.dart';
import '../models.dart';
import '../repository.dart';
import '../saf_channel.dart';
import 'bridge_client.dart';
import 'bridge_config.dart';
import 'translation_job.dart';
import 'translation_set.dart';
import 'translation_task.dart';

/// 「测试连接」的失败类别：界面据此给不同的排障文案。
enum ProbeFailureKind {
  /// 还没配对（没有 token）。
  notPaired,

  /// TCP 连不上：进程没跑，或互联开关没开。
  refused,

  /// 连上了但一直没响应：多半被系统冻结/服务卡死。
  timeout,

  /// 401：token 变了。
  unauthorized,

  /// 服务在线但状态不对（开关、模型、版本）。
  notReady,
}

/// 「测试连接」的结果。
class BridgeProbeResult {
  const BridgeProbeResult.ok(this.health)
    : error = null,
      hint = null,
      kind = null;

  const BridgeProbeResult.failure(
    this.error, {
    this.hint,
    this.kind = ProbeFailureKind.notReady,
  }) : health = null;

  final BridgeHealth? health;
  final String? error;

  /// 排障建议（该去哪儿打开开关 / 该做什么）。
  final String? hint;

  /// 失败类别；成功时为 null。
  final ProbeFailureKind? kind;

  bool get ok => health != null;
}

/// 启动一次翻译的结果。
class TranslationStartResult {
  const TranslationStartResult.ok(this.task) : error = null;
  const TranslationStartResult.failure(this.error) : task = null;

  final TranslationTask? task;
  final String? error;

  bool get ok => task != null;
}

/// 「重译第 N–M 页」的结果。
///
/// 与 [TranslationStartResult] 的区别：多两个统计量，用来告诉用户这一次
/// 到底清掉了多少东西（删除是不可见的，必须回报）。
class RetranslateResult {
  const RetranslateResult.ok({
    required this.clearedPages,
    required this.deletedFiles,
    required this.task,
  }) : error = null;

  const RetranslateResult.failure(this.error)
    : clearedPages = 0,
      deletedFiles = 0,
      task = null;

  /// 清掉的记录页数。
  final int clearedPages;

  /// 删掉的译文图片数。
  final int deletedFiles;

  final TranslationTask? task;
  final String? error;

  bool get ok => task != null;
}

/// 单图翻译（阅读器里点「翻译这一张」）的结果。
class SingleTranslateResult {  const SingleTranslateResult.ok(this.page) : error = null;
  const SingleTranslateResult.failure(this.error) : page = null;

  final TranslationPageResult? page;
  final String? error;

  bool get ok => page != null;
}

/// 全局翻译服务：**整个应用只有一个实例**，任务与界面生命周期解耦。
///
/// 设计目标（对应验收标准）：
///  * 翻译在后台跑，用户可以去翻别的图集，进度条常驻在底部导航上方；
///  * 「翻译处理」页能暂停 / 继续 / 终止，并展示每一本的状态；
///  * 暂停与终止都不会丢已经译好的页：译文登记在原图集的翻译集里，
///    下次接着往同一批文件里加；
///  * 应用重启后任务记录还在，点「继续」从断点接着翻。
class TranslationService {
  TranslationService._();

  static final TranslationService instance = TranslationService._();

  /// 当前正在跑的任务；null 表示空闲。界面监听它来画进度条。
  ///
  /// 用 [_ActiveNotifier] 而不是裸 `ValueNotifier`：进度是在**同一个
  /// task 实例上改字段**，裸 ValueNotifier 判定「值没变」就不通知，
  /// 底部进度条会一直停在开始时的样子。
  final ActiveTaskNotifier active = ActiveTaskNotifier(null);

  /// 所有任务（按更新时间倒序）。
  final ValueNotifier<List<TranslationTask>> tasks =
      ValueNotifier<List<TranslationTask>>(const []);

  final _repo = GalleryRepository.instance;

  /// 译文索引：每本原图集一条记录，不再导入「翻译图集」。
  final _sets = TranslationSetStore.instance;

  TranslationJob? _job;
  bool _loaded = false;

  /// 之前是否成功探通过服务。health 超时时用来区分「从来没连上」和
  /// 「之前好好的，现在可能卡死了」。
  bool _probedOk = false;

  /// 是否还有一次 run 没结束。
  ///
  /// 同时看 [active] 和 [_job]：点「暂停」只是给任务打标，正在处理的那一页
  /// 要跑完、run 才会返回，这段收尾时间里不能再开新任务。
  bool get busy => active.value != null || _job != null;

  /// 启动时加载历史任务。应用被强杀时状态会停在「翻译中」，
  /// 这里统一改成「已终止」，让用户能手动继续。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final list = await TranslationTaskStore.load();
    var changed = false;
    for (final t in list) {
      if (t.state == TranslationTaskState.running) {
        t.state = TranslationTaskState.stopped;
        t.lastError = '上次没有正常结束（应用被关闭），可以点继续接着翻';
        t.updatedAt = DateTime.now();
        changed = true;
      }
    }
    if (changed) await TranslationTaskStore.save(list);
    tasks.value = list;
    // 旧数据的迁移放在这里：界面一启动就完成，阅读器不会再看到旧关联。
    await initSets();
  }

  /// 迁移 1.3.6 及以前的「翻译图集」：把译文改登记到原图集上，再把那本
  /// 图集从索引里摘掉（**只摘索引，文件一张不动**）。
  ///
  /// 旧版本靠「翻译图集」这本书承载译文，用户一旦把它移出列表，译文就
  /// 永远看不到了。迁移后译文跟着原图集走，与列表里有没有那本书无关。
  /// 幂等：迁移过的图集 translatedToId 已清空，下次启动什么都不做。
  Future<void> initSets() async {
    await _sets.load();
    // 图集索引可能还在读：迁移依赖它，先等它就绪（最多 5 秒）。
    for (var i = 0; i < 50 && !_repo.isLoaded; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!_repo.isLoaded) return; // 在空列表上迁移会误判，留到下次启动

    for (final g in [..._repo.galleries]) {
      final oldId = g.translatedToId;
      if (oldId == null) continue;
      final old = _repo.byId(oldId);
      if (old != null && !identical(old, g)) {
        // 已经按新方式记过译文的图集不覆盖，只把旧关联清掉。
        if (!_sets.has(g.id)) {
          final set = translationSetFromLegacyGallery(old, galleryId: g.id);
          if (set != null) await _sets.adopt(set);
        }
        // 一页译文都认不出来（文件名被改过）时保留那本图集：
        // 直接摘索引会让那些文件在软件里彻底看不到。
        if (_sets.has(g.id)) await _repo.removeFromIndex(old);
      }
      // 清双向关联；译文页数改由翻译集统计。
      await _repo.markTranslated(g, null);
      await _repo.setTranslatedPages(g, _sets.pageCountOf(g.id));
    }

    // 没人认领的旧翻译图集（原图集已不在列表里）：同样只摘索引。
    for (final g in [..._repo.galleries]) {
      final from = g.translatedFromId;
      if (from == null || from == g.id) continue;
      await _repo.removeFromIndex(g);
    }
  }

  /// 某个图集对应的任务（一个图集只有一条翻译记录）。
  TranslationTask? taskFor(String galleryId) {
    for (final t in tasks.value) {
      if (t.galleryId == galleryId) return t;
    }
    return null;
  }

  /// 检测/连接本机的「同传互译」服务。
  ///
  /// 同机方案没有长连接可维持：所谓"已连接"就是配对码有效 + 服务在线。
  /// 因此这里按需探一次 health（端口以服务端回报为准），配对码会一直沿用，
  /// 只有服务重启或改端口时才需要重新配对。
  Future<BridgeProbeResult> probe() async {
    final config = await BridgeConfigStore.load();
    if (!config.hasToken) {
      return const BridgeProbeResult.failure(
        '还没有配对翻译服务',
        hint: '在「同传互译」或 PC 端的「图集互联 → 配对」里点「复制」，再回到这里点「粘贴配对信息」。',
        kind: ProbeFailureKind.notPaired,
      );
    }
    final client = BridgeClient(
      host: config.host,
      port: config.port,
      token: config.token,
    );
    try {
      final health = await client.health();
      final gate = versionGate(health);
      if (gate != null) {
        return BridgeProbeResult.failure(
          gate,
          hint: '请更新翻译服务（手机端需 0.8.0 及以上）；互联协议要求 api=1。',
        );
      }
      if (!health.bridgeEnabled) {
        return const BridgeProbeResult.failure(
          '服务在线，但「图集互联」开关没打开',
          hint: '去翻译端的「设置 → 图集互联」把开关打开（服务端要重启监听）。',
        );
      }
      if (!health.translateReady) {
        return const BridgeProbeResult.failure(
          '服务在线，但翻译模型还没准备好',
          hint: '等翻译端把模型加载完，或先在那边翻译一句话再回来。',
        );
      }
      if (!health.visionReady) {
        return const BridgeProbeResult.failure(
          '服务在线，但 OCR 模型还没准备好',
          hint: '图片翻译要先能识字：等翻译端把视觉模型加载完再试。',
        );
      }
      _probedOk = true;
      return BridgeProbeResult.ok(health);
    } on BridgeUnreachable catch (e) {
      final timedOut = e.cause is TimeoutException;
      return BridgeProbeResult.failure(
        timedOut
            ? '翻译服务 3 秒内没响应'
            : '翻译服务没运行，或手机与电脑不在同一局域网',
        hint: timedOut
            ? '检查电脑是否休眠、Windows 防火墙是否放行 8098，'
                  '手机端则到最近任务里把「同传互译」强制停止再打开。'
            : (_probedOk
                  ? '服务之前是通的，现在连不上：可能进程被回收，或者电脑/手机的 IP 变了。'
                  : '确认翻译服务在跑；远程连接还要确认两台设备在同一 Wi-Fi、'
                        '且填的是电脑的局域网地址。'),
        kind: timedOut ? ProbeFailureKind.timeout : ProbeFailureKind.refused,
      );
    } on BridgeException catch (e) {
      if (e.isUnauthorized) {
        return const BridgeProbeResult.failure(
          '配对码不对，请重新粘贴配对信息',
          hint: '翻译端重装、清过数据或重新配对后配对码会变：重新复制一次 JSON 再粘贴。',
          kind: ProbeFailureKind.unauthorized,
        );
      }
      return BridgeProbeResult.failure(e.message);
    } catch (e) {
      return BridgeProbeResult.failure('连接失败：$e');
    } finally {
      client.close();
    }
  }

  /// 版本/协议门槛：返回 null 表示这一版服务可以继续用，否则返回要显示的原因。
  ///
  /// 抽成纯函数是为了能单测。两条规则：
  /// 1. `api != 1` 一律拒绝——字段语义可能已经变了。
  /// 2. 手机端「同传互译」要求 0.8.0+（0.8.0 之前没有 busy 看门狗与 health 缓存，
  ///    接着用只会重演「永久 409」）；**PC 服务的版本线是另一条**（现在是 `0.1.0`），
  ///    不能拿 0.8.0 去卡它，否则远程 PC 永远连不上。
  static String? versionGate(BridgeHealth health) {
    if (health.api != 1) return '翻译服务协议不兼容（需要 api=1）';
    if (health.app.contains('PC')) return null;
    if (_olderThan(health.version, const [0, 8, 0])) {
      return '翻译服务版本太旧（${health.version}）';
    }
    return null;
  }

  /// `version` 是否低于 [min]（只比主.次.修订，`0.8.0-beta` 的后缀忽略）。
  ///
  /// 解析不出数字时返回 false：宁可让服务自己报错，也不要因为版本号格式
  /// 变化就把能用的服务挡在门外。
  static bool _olderThan(String version, List<int> min) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(version);
    if (m == null) return false;
    for (var i = 0; i < 3; i++) {
      final v = int.tryParse(m.group(i + 1) ?? '');
      if (v == null) return false;
      if (v != min[i]) return v < min[i];
    }
    return false;
  }

  /// 启动或继续一个图集的翻译。
  Future<TranslationStartResult> start({
    required Gallery gallery,
    required BridgeConfig config,
    int? fromIndex,
    int? toIndex,
  }) async {
    // 刚点过「继续」时上一次 run 可能还在收尾（正在结束当前页），
    // 等它退干净再开工，别让两个 run 同时往一个目录里写。
    for (var i = 0; i < 60 && _job != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (busy) {
      return const TranslationStartResult.failure('已有翻译任务在进行，请先在「翻译处理」里暂停或终止它');
    }
    final tree = config.outputTreeUri;
    if (tree == null || tree.isEmpty) {
      return const TranslationStartResult.failure(
        '还没有选择译文的存放位置，请先到「设置 → 翻译」里选一个目录',
      );
    }
    final token = config.token;
    if (token.isEmpty) {
      return const TranslationStartResult.failure('还没有配对翻译服务，请先在设置里粘贴配对信息');
    }

    final existing = taskFor(gallery.id);

    // 目录优先按名字在本机重新解析：SAF 里存下来的子目录 URI 在
    // 应用重启后不保证还能直接用，但树授权是持久化的，重新找一遍更稳。
    var dirUri = existing?.outputDirUri ?? '';
    var dirName =
        existing?.outputDirName ??
        TranslationJob.translatedDirName(gallery.title);
    var resolved = await _resolveDir(tree, dirName);
    // 名字匹配不上（比如提供方把 `<` `>` 换成了别的）时，退回上次记下的
    // 目录 URI —— 否则每译一页都会新建一个 `xxx (2)` 之类的目录。
    if (resolved == null && dirUri.isNotEmpty && await _dirExists(dirUri)) {
      resolved = dirUri;
    }
    if (resolved != null) {
      dirUri = resolved;
      dirName = await _actualDirName(tree, dirUri, dirName);
    } else if (dirUri.isEmpty || !await _dirExists(dirUri)) {
      try {
        dirUri = await SafChannel.createDirectory(tree, dirName) ?? '';
      } on PlatformException catch (e) {
        return TranslationStartResult.failure(
          '无法在所选目录里建文件夹（${e.message ?? e.code}）。'
          '请到设置里重新选一次「译文存放位置」。',
        );
      } catch (e) {
        return TranslationStartResult.failure('无法创建翻译目录：$e');
      }
      if (dirUri.isEmpty) {
        return const TranslationStartResult.failure(
          '无法在所选目录里创建译文文件夹（授权可能已失效）',
        );
      }
      // 提供方可能改过名字（`<AITranslate>` 在 exFAT/SD 卡上不合法，会被
      // 换成 `_AITranslate_` 之类）。以盘上的真实名字为准，否则下次按名字
      // 找不到就又建一个新目录。
      dirName = await _actualDirName(tree, dirUri, dirName);
    }

    // 目录只登记进翻译集：译文挂在原图集上，不再导入成一本新图集。
    await _sets.ensureSet(
      galleryId: gallery.id,
      dirUri: dirUri,
      dirName: dirName,
      source: config.source,
      target: config.target,
    );

    final task =
        existing ??
        TranslationTask(
          galleryId: gallery.id,
          galleryTitle: gallery.title,
          source: config.source,
          target: config.target,
          outputTreeUri: tree,
          outputDirUri: dirUri,
          outputDirName: dirName,
          total: gallery.images.length,
        );
    task.state = TranslationTaskState.running;
    task.total = gallery.images.length;
    task.lastError = null;
    task.updatedAt = DateTime.now();

    active.value = task;
    await _upsert(task);
    unawaited(_run(gallery, config, task, fromIndex, toIndex));
    return TranslationStartResult.ok(task);
  }

  /// 重译第 [from]–[to] 页（0 基、闭区间）：删掉这一段已有的译文成品与
  /// 记录，然后**只重翻这一段**。
  ///
  /// 与「翻译」的区别只有两点：范围被限制住，且重翻之前先清掉旧的
  /// `page-NNNN.jpg`。原始图集全程只读，绝不触碰。
  ///
  /// 返回删掉的译文图片数 + 清掉的记录页数；任一环节失败都可通过
  /// [RetranslateResult.error] 看到原因（例如输出目录已被删）。
  Future<RetranslateResult> retranslate({
    required Gallery gallery,
    required BridgeConfig config,
    required int from,
    required int to,
  }) async {
    if (busy) {
      return const RetranslateResult.failure('已有翻译任务在进行，请先在「翻译处理」里暂停或终止它');
    }
    if (gallery.images.isEmpty) {
      return const RetranslateResult.failure('这个图集里没有图片');
    }
    // 先做配置检查再动文件：宁可什么都不删，也不要删完了才发现没配对。
    if ((config.outputTreeUri ?? '').isEmpty) {
      return const RetranslateResult.failure(
        '还没有选择译文的存放位置，请先到「设置 → 翻译」里选一个目录',
      );
    }
    if (config.token.isEmpty) {
      return const RetranslateResult.failure('还没有配对翻译服务，请先在设置里粘贴配对信息');
    }
    final total = gallery.images.length;
    final lo = from <= to ? from.clamp(0, total - 1) : to.clamp(0, total - 1);
    final hi = from <= to ? to.clamp(0, total - 1) : from.clamp(0, total - 1);
    if (lo > hi) {
      return const RetranslateResult.failure('页码范围不对');
    }
    final indices = <int>{for (var i = lo; i <= hi; i++) i};

    final set = _sets.of(gallery.id);
    final task = taskFor(gallery.id);
    var dirUri = set?.dirUri ?? '';
    if (dirUri.isEmpty) dirUri = task?.outputDirUri ?? '';

    var deletedFiles = 0;
    if (dirUri.isNotEmpty) {
      deletedFiles = await _deletePageFiles(dirUri, indices);
      await TranslationJob.forgetPagesInManifest(dirUri, indices);
    }

    final removed = await _sets.removePages(gallery.id, indices);
    await _repo.setTranslatedPages(gallery, _sets.pageCountOf(gallery.id));

    final started = await start(
      gallery: gallery,
      config: config,
      fromIndex: lo,
      toIndex: hi,
    );
    if (!started.ok) {
      return RetranslateResult.failure(started.error ?? '启动翻译失败');
    }
    return RetranslateResult.ok(
      clearedPages: removed,
      deletedFiles: deletedFiles,
      task: started.task,
    );
  }

  static final RegExp _pageFilePattern = RegExp(
    r'^page-(\d+)\.(jpg|jpeg|png|gif)$',
    caseSensitive: false,
  );

  /// 删掉译文目录里属于 [indices] 的页文件。
  ///
  /// 只认 `page-NNNN.(jpg|png|gif)`，且只在这个图集自己的译文目录里找；
  /// 名字对不上的一律不删（`.nomedia`、`manifest.json` 都在这一类里）。
  Future<int> _deletePageFiles(String dirUri, Set<int> indices) async {
    final List<SafChild> children;
    try {
      children = await SafChannel.listTree(dirUri);
    } catch (e) {
      debugPrint('[SGV-重译] 读译文目录失败，跳过删文件：$e');
      return 0;
    }
    var deleted = 0;
    for (final c in children) {
      if (c.isDirectory) continue;
      final m = _pageFilePattern.firstMatch(c.name);
      if (m == null) continue;
      final n = int.tryParse(m.group(1) ?? '');
      if (n == null || n <= 0) continue;
      // 文件名里的序号是 1 基（page-0001 对应 index 0）。
      if (!indices.contains(n - 1)) continue;
      final ok = await SafChannel.deleteFile(c.uri);
      debugPrint('[SGV-重译] ${ok ? '删除' : '删除失败'} ${c.name}');
      if (ok) deleted++;
    }
    return deleted;
  }

  /// 暂停：任务留在列表里，随时可以继续。
  Future<void> pause() async {
    final task = active.value;
    if (task == null) return;
    _job?.pause();
    task.state = TranslationTaskState.paused;
    task.updatedAt = DateTime.now();
    active.value = task;
    await _upsert(task);
  }

  /// 终止本次任务：已经译好的页都留在译文目录里，下次可以接着加。
  Future<void> stop() async {
    final task = active.value;
    if (task == null) return;
    task.state = TranslationTaskState.stopped;
    task.updatedAt = DateTime.now();
    _job?.cancel();
    active.value = task;
    await _upsert(task);
  }

  /// 读取某一页的译文（没有就返回 null）。
  ///
  /// 译文归属记在 [TranslationSetStore] 里，与列表里有没有「翻译图集」无关：
  /// 索引怎么删，磁盘上的文件都还在。读失败一律当没有，阅读体验优先。
  Future<Uint8List?> loadTranslatedPage(Gallery gallery, int index) async {
    final entry = _sets.pageOf(gallery.id, index);
    if (entry == null || entry.uri.isEmpty) return null;
    try {
      final size = await SafChannel.sizeOf(entry.uri);
      final source = GalleryRepository.byteSourceFor(
        entry.uri,
        knownLength: size > 0 ? size : null,
      );
      final bytes = await readAllChunked(source);
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      // 读不到就当没有译文，阅读体验优先，不弹错。
      return null;
    }
  }

  /// 继续一个已暂停 / 已终止的任务。
  Future<TranslationStartResult> resume(TranslationTask task) async {
    final gallery = _repo.byId(task.galleryId);
    if (gallery == null) {
      return const TranslationStartResult.failure('原图集已从列表移出，无法继续');
    }
    final config = await BridgeConfigStore.load();
    return start(gallery: gallery, config: config);
  }

  /// 翻译**单张**（阅读器里的按钮）。与批量共用目录、manifest 与命名，
  /// 因此下次批量续跑会把这一页当成已完成。
  ///
  /// 这里刻意不弹任何进度框：调用方只在自己的按钮上转圈，阅读不受影响。
  /// 再加一层总超时 —— 翻译端卡死时宁可报错，也不能让阅读器等下去。
  Future<SingleTranslateResult> translatePage({
    required Gallery gallery,
    required int index,
    // 单页外层总超时必须比 BridgeClient.imageTimeout（240 秒）宽松，
    // 否则内层还没超时外层先掐断，用户只会看到「没回应」而不知道是慢。
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (busy) {
      return const SingleTranslateResult.failure('批量翻译正在进行，稍后再说');
    }
    final config = await BridgeConfigStore.load();
    final tree = config.outputTreeUri;
    final token = config.token;
    if (tree == null || tree.isEmpty) {
      return const SingleTranslateResult.failure('还没选择译文的存放位置');
    }
    if (token.isEmpty) {
      return const SingleTranslateResult.failure('还没配对翻译服务');
    }

    // 复用任务里记下的目录 URI：只按名字找太脆——提供方可能把
    // `<AITranslate>` 改写成 `_AITranslate_`，按名字找不到就会每页新建
    // 一个目录，最后出现一堆 `111<AITranslate> (2)`。
    final task = taskFor(gallery.id);
    var dirName = task?.outputDirName ?? TranslationJob.translatedDirName(gallery.title);
    var dirUri = task?.outputDirUri;
    if (dirUri != null && dirUri.isNotEmpty && await _dirExists(dirUri)) {
      dirName = await _actualDirName(tree, dirUri, dirName);
    } else {
      dirUri = await _resolveDir(tree, dirName);
      if (dirUri == null) {
        try {
          dirUri = await SafChannel.createDirectory(tree, dirName);
        } catch (e) {
          return SingleTranslateResult.failure('无法创建翻译目录：$e');
        }
        if (dirUri != null) {
          dirName = await _actualDirName(tree, dirUri, dirName);
        }
      }
    }
    if (dirUri == null) {
      return const SingleTranslateResult.failure('无法创建翻译目录');
    }
    // 单张翻译也要先登记目录，否则译文记不进这本图集的翻译集。
    await _sets.ensureSet(
      galleryId: gallery.id,
      dirUri: dirUri,
      dirName: dirName,
      source: config.source,
      target: config.target,
    );

    final client = BridgeClient(
      host: config.host,
      port: config.port,
      token: config.token,
    );
    final job = TranslationJob(
      gallery: gallery,
      client: client,
      config: config,
      outputTreeUri: tree,
      outputDirUri: dirUri,
      outputDirName: dirName,
      // 单图也要用同一套语言设置，否则会和已译好的页混语言。
      source: config.source,
      target: config.target,
    );
    try {
      final page = await job
          .translateOne(index)
          .timeout(
            timeout,
            onTimeout: () =>
                throw TimeoutException('翻译端超过 ${timeout.inMinutes} 分钟没回应'),
          );
      if (page == null) {
        return const SingleTranslateResult.failure('无法创建翻译目录');
      }
      if (!page.ok) {
        return SingleTranslateResult.failure(page.error ?? '翻译失败');
      }
      await _recordPage(_repo.byId(gallery.id) ?? gallery, page);
      return SingleTranslateResult.ok(page);
    } on TimeoutException catch (e) {
      return SingleTranslateResult.failure('${e.message}，请检查翻译服务是否卡住');
    } on BridgeException catch (e) {
      return SingleTranslateResult.failure(e.message);
    } on BridgeUnreachable catch (e) {
      return SingleTranslateResult.failure('${e.hint}（${e.cause}）');
    } catch (e) {
      return SingleTranslateResult.failure('翻译失败：$e');
    } finally {
      client.close();
    }
  }

  // ------------------------------------------------------------ 内部实现

  Future<void> _run(
    Gallery gallery,
    BridgeConfig config,
    TranslationTask task, [
    int? fromIndex,
    int? toIndex,
  ]) async {
    final client = BridgeClient(
      host: config.host,
      port: config.port,
      token: config.token,
    );
    final job = TranslationJob(
      gallery: gallery,
      client: client,
      config: config,
      outputTreeUri: task.outputTreeUri,
      outputDirUri: task.outputDirUri,
      outputDirName: task.outputDirName,
      source: task.source,
      target: task.target,
      fromIndex: fromIndex,
      toIndex: toIndex,
      onProgress: (p) => _onProgress(task, p),
      onPageDone: (page) => _onPageDone(task, gallery, page),
    );
    _job = job;

    TranslationOutcome outcome;
    try {
      outcome = await job.run();
    } catch (e) {
      task.state = TranslationTaskState.failed;
      task.lastError = '翻译中断：$e';
      task.updatedAt = DateTime.now();
      active.value = null;
      _job = null;
      client.close();
      await _upsert(task);
      return;
    }
    _job = null;
    client.close();

    // 收尾：已经写出的页在 _onPageDone 里逐页登记过了，这里只判定结束状态。
    task.done = outcome.done;
    task.failed = outcome.failed;
    task.noText = outcome.noText;
    task.skipped = outcome.skipped;
    task.currentName = '';
    task.updatedAt = DateTime.now();
    if (outcome.fatalError != null) {
      task.state = TranslationTaskState.failed;
      task.lastError = outcome.fatalError;
    } else if (outcome.cancelled) {
      task.state = TranslationTaskState.stopped;
    } else if (outcome.paused) {
      // 用户点暂停 / 连续失败自动暂停：本次 run 已结束，点「继续」会重新
      // 起一次 run 从 manifest 接着做。
      task.state = TranslationTaskState.paused;
    } else if (task.processed >= task.total) {
      task.state = TranslationTaskState.done;
    } else {
      // 没跑完也没被取消（连续失败自动暂停）：留在"已暂停"。
      task.state = TranslationTaskState.paused;
      task.lastError ??= '连续失败已自动暂停';
    }
    active.value = null;
    await _upsert(task);
  }

  void _onProgress(TranslationTask task, TranslationProgress p) {
    task.total = p.total;
    task.done = p.done;
    task.failed = p.failed;
    task.noText = p.noText;
    task.skipped = p.skipped;
    task.currentName = p.currentName;
    task.updatedAt = DateTime.now();
    active.publish(task);
  }

  Future<void> _onPageDone(
    TranslationTask task,
    Gallery gallery,
    TranslationPageResult page,
  ) async {
    if (page.copied) task.copiedGif = (task.copiedGif + 1).clamp(0, 1 << 30);
    // 不再每页重扫目录：写出的文件 URI 已经跟着结果回来，直接登记即可。
    await _recordPage(gallery, page);
    await _upsert(task);
  }

  /// 把一页成品登记进翻译集，并同步图集的译文页数（角标靠它）。
  ///
  /// `uri` 为空表示这一页没写出文件（早退 / 失败），不登记：
  /// 登记了阅读器只会反复去读一个空 URI。
  Future<void> _recordPage(Gallery gallery, TranslationPageResult page) async {
    if (page.uri.isEmpty) return;
    await _sets.recordPage(
      galleryId: gallery.id,
      entry: TranslationPageEntry(
        index: page.index,
        file: page.output,
        uri: page.uri,
        copied: page.copied,
        translated: page.translated,
        failed: page.failed,
      ),
    );
    await _repo.setTranslatedPages(
      _repo.byId(gallery.id) ?? gallery,
      _sets.pageCountOf(gallery.id),
    );
  }

  /// 移除一条任务记录（**只删记录**，译文与文件都保留）。
  ///
  /// 正在跑的任务不允许移除：那不是"清理记录"，而是会留下一个看不见的
  /// 后台任务在继续写文件。
  Future<void> forget(TranslationTask task) async {
    if (active.value?.id == task.id) return;
    tasks.value = tasks.value.where((t) => t.id != task.id).toList();
    await _persist();
  }

  /// 给**已经存在**的译文目录补 `.nomedia`，让系统相册不再收录译文。
  ///
  /// 1.3.11 起新建的目录在写第一张图之前就会加标记，这个入口是给旧目录用的一次性
  /// 整理：只往「名字像译文目录」的子目录里加一个 0 字节空文件，不删、不改任何图片。
  ///
  /// 返回这次新增标记的目录数。不是译文目录的一律跳过。
  Future<int> hideTranslatedDirs() async {
    final config = await BridgeConfigStore.load();
    final root = config.outputTreeUri ?? '';
    if (root.isEmpty) return 0;
    final List<SafChild> dirs;
    try {
      dirs = await SafChannel.listTree(root);
    } catch (e) {
      debugPrint('[SGV-翻译] 读输出根目录失败：$e');
      return 0;
    }
    var added = 0;
    for (final d in dirs) {
      if (!d.isDirectory) continue;
      if (!TranslationJob.isTranslatedDirName(d.name)) continue;
      if (await TranslationJob.ensureNoMedia(d.uri)) added++;
    }
    debugPrint('[SGV-翻译] 译文目录整理完成：检查 ${dirs.length} 项，新增标记 $added 个');
    return added;
  }

  Future<void> _upsert(TranslationTask task) async {
    final list = [...tasks.value];
    final i = list.indexWhere((t) => t.id == task.id);
    if (i >= 0) {
      list[i] = task;
    } else {
      list.add(task);
    }
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    tasks.value = list;
    await _persist();
  }

  Future<void> _persist() => TranslationTaskStore.save(tasks.value);

  /// 在本机重新解析输出目录：拿名字去树里找同名的子目录。
  ///
  /// 先精确匹配，再按「去掉文件系统不认的字符」后匹配：`<` `>` `:` `*` 等
  /// 在 exFAT / 部分 DocumentsProvider 上会被换掉，导致
  /// `111<AITranslate>` 实际落盘成 `111_AITranslate_`。
  Future<String?> _resolveDir(String treeUri, String name) async {
    final wanted = _normalizeDirName(name);
    List<SafChild> children;
    try {
      children = await SafChannel.listTree(treeUri);
    } catch (_) {
      // 授权失效或目录读不了：交给调用方去创建。
      return null;
    }
    final exact = children
        .where((c) => c.isDirectory && c.name == name)
        .map((c) => c.uri)
        .toList();
    final fuzzy = children
        .where((c) => c.isDirectory && _normalizeDirName(c.name) == wanted)
        .map((c) => c.uri)
        .toList();
    // 精确命中的排前面；同一个 uri 只留一次。
    final candidates = <String>[
      ...exact,
      ...fuzzy.where((u) => !exact.contains(u)),
    ];
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;
    // 多个同名候选（历史上按名字找不到时反复建出来的）：选页数最多的那本，
    // 已有的译文才不会散在几个目录里。
    var best = candidates.first;
    var bestCount = -1;
    for (final uri in candidates) {
      var count = 0;
      try {
        final inner = await SafChannel.listTree(uri);
        count = inner
            .where((e) => !e.isDirectory && e.name.startsWith('page-'))
            .length;
      } catch (_) {
        count = 0;
      }
      if (count > bestCount) {
        bestCount = count;
        best = uri;
      }
    }
    return best;
  }

  /// 读回目录在盘上的真实名字（提供方可能改写过）。
  Future<String> _actualDirName(
    String treeUri,
    String dirUri,
    String fallback,
  ) async {
    try {
      final children = await SafChannel.listTree(treeUri);
      for (final c in children) {
        if (c.isDirectory && c.uri == dirUri) return c.name;
      }
    } catch (_) {
      // 读不到就沿用想要的名字，不影响翻译本身。
    }
    return fallback;
  }

  /// 只保留「各平台都安全」的字符，用于比较名字而不是用来建目录。
  static String _normalizeDirName(String name) {
    final out = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .replaceAll(RegExp(r'[_\s]+'), '')
        .toLowerCase();
    return out.isEmpty ? 'translate' : out;
  }

  Future<bool> _dirExists(String uri) async {
    try {
      await SafChannel.listTree(uri);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 能对「同一个 task 实例改字段」也发出通知的 [ValueNotifier]。
class ActiveTaskNotifier extends ValueNotifier<TranslationTask?> {
  ActiveTaskNotifier(super.value);

  /// 字段已经就地改过之后再调它，强制界面重画。
  void publish(TranslationTask? task) {
    if (identical(value, task)) {
      notifyListeners();
    } else {
      value = task;
    }
  }
}

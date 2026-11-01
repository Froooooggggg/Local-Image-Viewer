import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 一次批量翻译任务的持久化状态。
///
/// 为什么单独存一份而不是只读输出目录里的 `manifest.json`：
///  * manifest 在用户的目录里，可能被改、被删、被同步工具搬走；
///  * 「翻译处理」页需要在不访问 SAF 的情况下立刻列出所有任务与进度；
///  * 暂停 / 终止后要能在重启应用后继续，必须记下输出目录与语言。
///
/// 两边不冲突：manifest 是**页级**的权威记录（续跑依据），这里是**任务级**
/// 的索引（列表展示与断点续传的入口）。
enum TranslationTaskState {
  /// 正在跑。
  running,

  /// 用户点了暂停（可继续）。
  paused,

  /// 用户点了终止（可继续，但要用户主动）。
  stopped,

  /// 全部页处理完了。
  done,

  /// 整批失败（配对失效、目录不可写等），需要处理后重试。
  failed,
}

class TranslationTask {
  TranslationTask({
    required this.galleryId,
    required this.galleryTitle,
    required this.source,
    required this.target,
    required this.outputTreeUri,
    required this.outputDirUri,
    required this.outputDirName,
    this.outputGalleryId,
    this.state = TranslationTaskState.running,
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.noText = 0,
    this.skipped = 0,
    this.copiedGif = 0,
    this.currentName = '',
    this.lastError,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// 任务 id 直接用图集 id：一个图集只有一条翻译记录，
  /// 重复翻译是"续写同一个目录"，不是新开一条任务。
  String get id => galleryId;

  final String galleryId;
  String galleryTitle;
  final String source;
  final String target;
  final String outputTreeUri;

  /// 译文目录（SAF 目录 URI），续跑时直接往里写。
  final String outputDirUri;

  /// 目录名：`<原标题><AITranslate>`。
  final String outputDirName;

  /// 旧版：已经导入索引的翻译图集 id。1.3.7 起不再写入，
  /// 只为读得懂旧任务记录而保留（对照的是 task.outputDirUri）。
  String? outputGalleryId;

  TranslationTaskState state;
  int total;
  int done;
  int failed;

  /// 没有可翻文字、没写出成品的页数。**不算失败**，UI 显示「无有效内容」。
  int noText;
  int skipped;
  int copiedGif;
  String currentName;
  String? lastError;
  final DateTime createdAt;
  DateTime updatedAt;

  /// 还没结束（可以继续 / 需要展示进度）。
  bool get isActive =>
      state == TranslationTaskState.running ||
      state == TranslationTaskState.paused ||
      state == TranslationTaskState.stopped;

  bool get isRunning => state == TranslationTaskState.running;

  int get processed => done + failed + noText + skipped;

  double get fraction => total <= 0 ? 0 : (processed / total).clamp(0.0, 1.0);

  String get stateLabel => switch (state) {
    TranslationTaskState.running => '翻译中',
    TranslationTaskState.paused => '已暂停',
    TranslationTaskState.stopped => '已终止',
    TranslationTaskState.done => '已完成',
    TranslationTaskState.failed => '失败',
  };

  Map<String, dynamic> toJson() => {
    'galleryId': galleryId,
    'galleryTitle': galleryTitle,
    'source': source,
    'target': target,
    'outputTreeUri': outputTreeUri,
    'outputDirUri': outputDirUri,
    'outputDirName': outputDirName,
    'outputGalleryId': outputGalleryId,
    'state': state.name,
    'total': total,
    'done': done,
    'failed': failed,
    'noText': noText,
    'skipped': skipped,
    'copiedGif': copiedGif,
    'currentName': currentName,
    'lastError': lastError,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  static TranslationTask fromJson(Map<String, dynamic> j) => TranslationTask(
    galleryId: (j['galleryId'] as String?) ?? '',
    galleryTitle: (j['galleryTitle'] as String?) ?? '未命名',
    source: (j['source'] as String?) ?? 'ja',
    target: (j['target'] as String?) ?? 'zh',
    outputTreeUri: (j['outputTreeUri'] as String?) ?? '',
    outputDirUri: (j['outputDirUri'] as String?) ?? '',
    outputDirName: (j['outputDirName'] as String?) ?? '',
    outputGalleryId: j['outputGalleryId'] as String?,
    state: TranslationTaskState.values.firstWhere(
      (s) => s.name == j['state'],
      // 老数据里不会有未知状态；真遇到就当成"已终止"，可继续。
      orElse: () => TranslationTaskState.stopped,
    ),
    total: (j['total'] as num?)?.toInt() ?? 0,
    done: (j['done'] as num?)?.toInt() ?? 0,
    failed: (j['failed'] as num?)?.toInt() ?? 0,
    noText: (j['noText'] as num?)?.toInt() ?? 0,
    skipped: (j['skipped'] as num?)?.toInt() ?? 0,
    copiedGif: (j['copiedGif'] as num?)?.toInt() ?? 0,
    currentName: (j['currentName'] as String?) ?? '',
    lastError: j['lastError'] as String?,
    createdAt: j['createdAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(j['createdAt'] as int),
    updatedAt: j['updatedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(j['updatedAt'] as int),
  );
}

/// 任务列表的持久化。数据量很小（最多几十条），放 SharedPreferences 足够。
class TranslationTaskStore {
  static const _key = 'translation.tasks.v1';

  /// 最多保留多少条历史记录。任务本身就是"一个图集一条"，不会无限增长。
  static const int _maxTasks = 100;

  static Future<List<TranslationTask>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const <String>[];
    final out = <TranslationTask>[];
    for (final line in raw) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          out.add(TranslationTask.fromJson(decoded));
        }
      } catch (_) {
        // 单条损坏不该让整份记录失效。
      }
    }
    return out;
  }

  static Future<void> save(List<TranslationTask> tasks) async {
    final prefs = await SharedPreferences.getInstance();
    final sorted = [...tasks]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final limited = sorted.take(_maxTasks);
    await prefs.setStringList(
      _key,
      limited.map((t) => jsonEncode(t.toJson())).toList(growable: false),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/bridge/translation_service.dart';
import '../core/bridge/translation_set.dart';
import '../core/bridge/translation_task.dart';
import '../core/repository.dart';
import 'viewer_page.dart';

/// 「翻译处理」页：翻译任务的后台看板。
///
/// 翻译本身在全球单例 [TranslationService] 里跑，与界面生命周期无关：
/// 用户切到这一页可以暂停 / 继续 / 终止，也可以直接离开去做别的事，
/// 底部导航上方的细进度条会一直显示进度。
class TranslationPage extends StatefulWidget {
  const TranslationPage({super.key});

  @override
  State<TranslationPage> createState() => _TranslationPageState();
}

class _TranslationPageState extends State<TranslationPage> {
  final _service = TranslationService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_service.load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('翻译处理'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => setState(() {}),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<TranslationTask>>(
        valueListenable: _service.tasks,
        builder: (context, tasks, _) {
          if (tasks.isEmpty) return const _EmptyHint();
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            itemCount: tasks.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) => _TaskCard(
              task: tasks[i],
              service: _service,
            ),
          );
        },
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.translate, size: 40, color: Color(0xFF4A4E58)),
            const SizedBox(height: 14),
            const Text(
              '还没有翻译过图集',
              style: TextStyle(fontSize: 15, color: Color(0xFFB9BCC4)),
            ),
            const SizedBox(height: 8),
            Text(
              '在图集的三点菜单里点「翻译」，\n会调用翻译服务把整本翻成你要的语言。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: const Color(0xFF6E7280),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.service});

  final TranslationTask task;
  final TranslationService service;

  @override
  Widget build(BuildContext context) {
    final running = task.state == TranslationTaskState.running;
    final paused = task.state == TranslationTaskState.paused;
    final stopped =
        task.state == TranslationTaskState.stopped ||
        task.state == TranslationTaskState.failed;
    final done = task.state == TranslationTaskState.done;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.galleryTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _StateChip(state: task.state),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              task.outputDirName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF6E7280)),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: task.total == 0 ? null : task.fraction,
                minHeight: 4,
                backgroundColor: const Color(0xFF26262C),
                valueColor: AlwaysStoppedAnimation(
                  done ? const Color(0xFF5E9E6E) : const Color(0xFF6E8BB5),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${task.processed} / ${task.total}'
              ' · 成功 ${task.done}'
              '${task.skipped > 0 ? ' · 续传跳过 ${task.skipped}' : ''}'
              '${task.noText > 0 ? ' · 无有效内容 ${task.noText}' : ''}'
              '${task.failed > 0 ? ' · 失败 ${task.failed}' : ''}'
              '${task.copiedGif > 0 ? ' · 动图直拷 ${task.copiedGif}' : ''}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9DA2AC)),
            ),
            if (running && task.currentName.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '正在翻译 ${task.currentName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(0xFFB9BCC4),
                ),
              ),
            ],
            if (task.lastError != null && task.lastError!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                task.lastError!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(0xFFC98B8B),
                ),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  _fmtTime(task.updatedAt),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF5C606A),
                  ),
                ),
                const Spacer(),
                if (running) ...[
                  _Action(
                    icon: Icons.pause,
                    label: '暂停',
                    onTap: () => unawaited(service.pause()),
                  ),
                  _Action(
                    icon: Icons.stop,
                    label: '终止',
                    onTap: () => _confirmStop(context),
                  ),
                ],
                if (paused)
                  _Action(
                    icon: Icons.play_arrow,
                    label: '继续',
                    onTap: () => _resume(context),
                  ),
                if (stopped) ...[
                  _Action(
                    icon: Icons.play_arrow,
                    label: '继续',
                    onTap: () => _resume(context),
                  ),
                  _Action(
                    icon: Icons.delete_outline,
                    label: '移除记录',
                    onTap: () => _remove(context),
                  ),
                ],
                if (done || task.done > 0 || task.copiedGif > 0)
                  _Action(
                    icon: Icons.photo_library_outlined,
                    label: '查看译文',
                    onTap: () => _openOutput(context),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _resume(BuildContext context) async {
    final r = await service.resume(task);
    if (!context.mounted) return;
    if (!r.ok) {
      _snack(context, r.error ?? '无法继续');
    }
  }

  Future<void> _confirmStop(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('终止翻译？'),
        content: const Text('已经翻好的页会保留，下次点「继续」可以接着往下翻。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续翻译'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('终止'),
          ),
        ],
      ),
    );
    if (ok == true) unawaited(service.stop());
  }

  /// 打开**原图集**并定位到第一页译文。
  ///
  /// 1.3.7 起译文挂在原图集上，不再有单独的「翻译图集」；这里直接开
  /// 阅读器，不依赖图集列表页是否处于可见状态。
  void _openOutput(BuildContext context) {
    final gallery = GalleryRepository.instance.byId(task.galleryId);
    if (gallery == null) {
      _snack(context, '原图集已从列表移出，译文文件还在原目录里');
      return;
    }
    final page = TranslationSetStore.instance.firstPageOf(task.galleryId);
    if (page == null) {
      _snack(context, '译文还没生成，先翻一页再看');
      return;
    }
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ViewerPage(
            gallery: gallery,
            initialIndex: page,
            startTranslated: true,
          ),
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除这条任务记录？'),
        content: const Text('只移除记录，已经翻译好的译文和文件都不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok == true) await service.forget(task);
  }

  static void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});

  final TranslationTaskState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      TranslationTaskState.running => ('翻译中', const Color(0xFF6E8BB5)),
      TranslationTaskState.paused => ('已暂停', const Color(0xFFB99A5E)),
      TranslationTaskState.stopped => ('已终止', const Color(0xFF8A8F99)),
      TranslationTaskState.done => ('已完成', const Color(0xFF5E9E6E)),
      TranslationTaskState.failed => ('失败', const Color(0xFFC98B8B)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, height: 1.2),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 17),
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 9),
        minimumSize: const Size(0, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: const Color(0xFFB9BCC4),
      ),
    );
  }
}

String _fmtTime(DateTime t) {
  final now = DateTime.now();
  final sameDay =
      now.year == t.year && now.month == t.month && now.day == t.day;
  final hm =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (sameDay) return '今天 $hm';
  return '${t.month}-${t.day} $hm';
}

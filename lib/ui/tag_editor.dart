import 'package:flutter/material.dart';

import '../core/repository.dart';

/// 标签编辑的结果：明确区分「要加上的」与「要移除的」。
///
/// 为什么不能只传一个最终列表：编辑器的初始状态是各图集标签的**并集**，
/// 而取消勾选某个标签的语义是"从这些图集上把它删掉"。
/// 旧实现只回传最终列表 + append 模式（只并入、从不移除），
/// 导致**取消勾选完全无效、标签只能加不能删**。
class TagEditResult {
  const TagEditResult({required this.add, required this.remove});

  /// 需要添加到每个目标图集的标签。
  final List<String> add;

  /// 需要从每个目标图集移除的标签。
  final List<String> remove;

  bool get isEmpty => add.isEmpty && remove.isEmpty;
}

/// 标签编辑对话框（单图集与批量共用）。
///
/// 需求：设置里预设标签，给图集快速打标签。
/// 这里把预设标签做成可点选的 chip —— 点一下加上，再点一下标记为移除。
Future<TagEditResult?> showTagEditor(
  BuildContext context, {
  required String title,
  List<String> initial = const [],
  bool allowPresetManagement = true,
}) async {
  return showDialog<TagEditResult>(
    context: context,
    builder: (_) => _TagEditorDialog(
      title: title,
      initial: initial,
      allowPresetManagement: allowPresetManagement,
    ),
  );
}

class _TagEditorDialog extends StatefulWidget {
  const _TagEditorDialog({
    required this.title,
    required this.initial,
    required this.allowPresetManagement,
  });

  final String title;
  final List<String> initial;
  final bool allowPresetManagement;

  @override
  State<_TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<_TagEditorDialog> {
  /// 当前保留的标签（初始为并集）。
  late final Set<String> _kept = {...widget.initial};

  /// 被明确标记移除的标签（原本存在、用户点了取消）。
  final Set<String> _removed = {};

  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _addFromInput() {
    final parts = _controller.text
        .split(RegExp(r'[,，]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    if (parts.isEmpty) return;
    setState(() {
      for (final t in parts) {
        _kept.add(t);
        _removed.remove(t); // 重新加上就不算移除了
      }
      _controller.clear();
    });
  }

  /// 点选 / 取消一个标签。
  void _toggle(String tag, bool on) {
    setState(() {
      if (on) {
        _kept.add(tag);
        _removed.remove(tag);
      } else {
        _kept.remove(tag);
        // 只有原本就存在的标签才需要"显式移除"。
        if (widget.initial.contains(tag)) _removed.add(tag);
      }
    });
  }

  /// 把当前保留的标签加入预设（便于下次一键打上）。
  Future<void> _saveAsPreset() async {
    final repo = GalleryRepository.instance;
    for (final t in _kept) {
      await repo.addPresetTag(t);
    }
    if (mounted) setState(() {});
  }

  /// 快捷新建预设标签：把输入框内容存为预设**并同时选中**。
  ///
  /// 需求：在给图集打标签时可以直接创建标签，不必先跑到设置页去建。
  Future<void> _createPreset() async {
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;
    final repo = GalleryRepository.instance;
    for (final part in raw.split(RegExp(r'[,，]'))) {
      final tag = part.trim();
      if (tag.isEmpty) continue;
      await repo.addPresetTag(tag);
      _kept.add(tag);
      _removed.remove(tag);
    }
    _controller.clear();
    if (mounted) setState(() {});
  }

  TagEditResult _result() =>
      TagEditResult(add: _kept.toList(), remove: _removed.toList());

  @override
  Widget build(BuildContext context) {
    final repo = GalleryRepository.instance;
    final presets = repo.settings.presetTags;
    final navigator = Navigator.of(context);

    // 预设 + 当前已有，一起作为可点选的候选。
    final candidates = <String>{
      ...presets,
      ...widget.initial,
      ..._kept,
    }.toList()..sort();

    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (candidates.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  '还没有标签。可以在「设置 → 标签预设」里提前添加，'
                  '之后点一下就能打上；也可以直接在下面输入。',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8B8F98)),
                ),
              )
            else ...[
              const Text(
                '点选标签（再点一下取消）',
                style: TextStyle(fontSize: 12, color: Color(0xFF8B8F98)),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: candidates.map((t) {
                  final on = _kept.contains(t);
                  final isPreset = presets.contains(t);
                  final chip = FilterChip(
                    label: Text(t, style: const TextStyle(fontSize: 12)),
                    selected: on,
                    onSelected: (v) => _toggle(t, v),
                  );
                  if (!isPreset || !widget.allowPresetManagement) return chip;
                  // FilterChip 没有 onLongPress，用外层手势承载"删除预设"。
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPress: () async {
                      await repo.removePresetTag(t);
                      if (mounted) setState(() {});
                    },
                    child: chip,
                  );
                }).toList(),
              ),
              if (widget.allowPresetManagement && presets.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '长按可删除预设标签',
                    style: TextStyle(fontSize: 11, color: Color(0xFF6E7280)),
                  ),
                ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              onSubmitted: (_) => _addFromInput(),
              decoration: InputDecoration(
                isDense: true,
                hintText: '输入新标签，用逗号分隔',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: _addFromInput,
                ),
              ),
            ),
            // 快捷新建：直接存为预设标签并选中，省去先去设置页创建的步骤。
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                label: const Text('存为预设标签', style: TextStyle(fontSize: 12.5)),
                onPressed: _createPreset,
              ),
            ),
            if (_removed.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '将移除：${_removed.join('、')}',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(0xFFC98A8A),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_kept.isNotEmpty)
          TextButton(onPressed: _saveAsPreset, child: const Text('存为预设')),
        TextButton(
          // 全部清空：既移除已有标签，也放弃新增。
          onPressed: () => navigator.pop<TagEditResult>(
            TagEditResult(add: const [], remove: widget.initial.toList()),
          ),
          child: const Text('清空'),
        ),
        TextButton(
          onPressed: () => navigator.pop<TagEditResult>(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => navigator.pop<TagEditResult>(_result()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

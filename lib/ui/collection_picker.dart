import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/repository.dart';
import 'sheet_shell.dart';

/// 收藏夹选择器（含**快捷新建**）。
///
/// 需求：在给图集加收藏夹时可以直接新建，不必先跑到「收藏夹」页去创建。
///
/// 返回选中的收藏夹；用户取消则返回 null。
/// 当用户选择"新建收藏夹…"时，会就地弹出命名框、创建后立即返回它。
Future<Collection?> showCollectionPicker(
  BuildContext context, {
  required String title,

  /// 已在该收藏夹里的图集 id，用于显示勾选状态（可空）。
  Set<String>? memberIds,

  /// true 时表示"移出收藏夹"，只列出已包含的收藏夹。
  bool onlyContaining = false,
}) {
  return showModalBottomSheet<Collection>(
    context: context,
    isScrollControlled: kSheetIsScrollControlled,
    builder: (ctx) => _CollectionPickerSheet(
      title: title,
      memberIds: memberIds,
      onlyContaining: onlyContaining,
    ),
  );
}

class _CollectionPickerSheet extends StatefulWidget {
  const _CollectionPickerSheet({
    required this.title,
    required this.memberIds,
    required this.onlyContaining,
  });

  final String title;
  final Set<String>? memberIds;
  final bool onlyContaining;

  @override
  State<_CollectionPickerSheet> createState() => _CollectionPickerSheetState();
}

class _CollectionPickerSheetState extends State<_CollectionPickerSheet> {
  final _repo = GalleryRepository.instance;

  /// 命名的输入框控制器（新建收藏夹时用）。
  final _nameController = TextEditingController();
  bool _creating = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = _repo.collections;
    // "移出收藏夹"时只列出确实包含这些图集的收藏夹。
    final list = widget.onlyContaining && widget.memberIds != null
        ? all
              .where((c) => c.galleryIds.any(widget.memberIds!.contains))
              .toList()
        : all;

    return SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text(
              widget.title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),

          // 快捷新建
          if (_creating)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '新收藏夹名称',
                      ),
                      onSubmitted: (_) => _createAndReturn(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _createAndReturn,
                    child: const Text('创建'),
                  ),
                ],
              ),
            )
          else
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('新建收藏夹…'),
              onTap: () => setState(() => _creating = true),
            ),

          if (list.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Text(
                '还没有收藏夹。点上面的「新建收藏夹…」即可创建一个。',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF8B8F98)),
              ),
            ),

          ...list.map((c) {
            final containsAll =
                widget.memberIds != null &&
                widget.memberIds!.isNotEmpty &&
                widget.memberIds!.every(c.galleryIds.contains);
            return ListTile(
              leading: const Icon(Icons.folder_special_outlined),
              title: Text(c.name),
              subtitle: Text('${c.galleryIds.length} 个图集'),
              trailing: containsAll
                  ? const Icon(Icons.check, size: 18, color: Color(0xFF7FB77E))
                  : null,
              onTap: () => Navigator.pop(context, c),
            );
          }),

          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _createAndReturn() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final c = await _repo.createCollection(name);
    if (!mounted) return;
    // 创建后直接返回它：用户点"新建"的意图就是要用它。
    Navigator.pop(context, c);
  }
}

import 'package:flutter/material.dart';

import '../core/models.dart';

/// 图集专属排序的选择结果。
///
/// [field] / [descending] 为 null 表示"跟随全局设置"。
class GallerySortChoice {
  const GallerySortChoice({
    required this.followGlobal,
    this.field,
    this.descending,
  });

  final bool followGlobal;
  final SortField? field;
  final bool? descending;

  /// 选择"跟随全局设置"。
  static const follow = GallerySortChoice(followGlobal: true);
}

/// 弹出「图集图片排序」对话框。
///
/// 需求：图集封面（图集内图片）的排序要能**单独设置**，且排序方式与设置页
/// 里的一致（按图片时间 / 按文件名，正向或逆向）。
///
/// [galleries] 传多个时为批量设置：初始状态取各图集的**共同值**，
/// 若各不相同则显示为"混合"。
Future<GallerySortChoice?> showGallerySortEditor(
  BuildContext context, {
  required List<Gallery> galleries,
  required SortField globalField,
  required bool globalDescending,
}) {
  return showDialog<GallerySortChoice>(
    context: context,
    builder: (_) => _GallerySortDialog(
      galleries: galleries,
      globalField: globalField,
      globalDescending: globalDescending,
    ),
  );
}

class _GallerySortDialog extends StatefulWidget {
  const _GallerySortDialog({
    required this.galleries,
    required this.globalField,
    required this.globalDescending,
  });

  final List<Gallery> galleries;
  final SortField globalField;
  final bool globalDescending;

  @override
  State<_GallerySortDialog> createState() => _GallerySortDialogState();
}

class _GallerySortDialogState extends State<_GallerySortDialog> {
  late bool _followGlobal;

  /// null 表示"混合"（各图集设置不一致），需要用户重新选。
  SortField? _field;
  bool? _descending;

  bool get _multi => widget.galleries.length > 1;

  @override
  void initState() {
    super.initState();
    _followGlobal = widget.galleries.every((g) => !g.hasOwnSort);

    // 取各图集的共同值；不一致则保持 null（混合）。
    final fields = widget.galleries.map((g) => g.sortField).toSet();
    _field = fields.length == 1 ? fields.first : null;

    final descs = widget.galleries.map((g) => g.sortDescending).toSet();
    _descending = descs.length == 1 ? descs.first : null;
  }

  @override
  Widget build(BuildContext context) {
    final navigator = Navigator.of(context);
    final field = _field ?? widget.globalField;
    final descending = _descending ?? widget.globalDescending;

    return AlertDialog(
      title: Text(_multi ? '批量设置图片排序（${widget.galleries.length} 个）' : '图集图片排序'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '只影响这个图集内图片的显示顺序，不改动任何文件。',
              style: TextStyle(fontSize: 12, color: Color(0xFF8B8F98)),
            ),
            const SizedBox(height: 12),

            // 跟随全局 / 单独设置
            RadioGroup<bool>(
              groupValue: _followGlobal,
              onChanged: (v) => setState(() => _followGlobal = v ?? true),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<bool>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: true,
                    title: const Text(
                      '跟随全局设置',
                      style: TextStyle(fontSize: 13.5),
                    ),
                    subtitle: Text(
                      _describe(widget.globalField, widget.globalDescending),
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ),
                  const RadioListTile<bool>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: false,
                    title: Text('单独设置', style: TextStyle(fontSize: 13.5)),
                  ),
                ],
              ),
            ),

            if (!_followGlobal) ...[
              const Divider(height: 20),
              const Text(
                '排序方式',
                style: TextStyle(fontSize: 12, color: Color(0xFF8B8F98)),
              ),
              RadioGroup<SortField>(
                groupValue: field,
                onChanged: (v) => setState(() => _field = v),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<SortField>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: SortField.modified,
                      title: Text('按图片时间', style: TextStyle(fontSize: 13.5)),
                    ),
                    RadioListTile<SortField>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: SortField.name,
                      title: Text('按文件名', style: TextStyle(fontSize: 13.5)),
                    ),
                  ],
                ),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: descending,
                onChanged: (v) => setState(() => _descending = v),
                title: const Text('逆向排序', style: TextStyle(fontSize: 13.5)),
              ),
              if (_multi && (_field == null || _descending == null))
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '选中的图集当前设置不一致，保存后会统一为上面的选择。',
                    style: TextStyle(fontSize: 11.5, color: Color(0xFFC9A227)),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => navigator.pop<GallerySortChoice>(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (_followGlobal) {
              navigator.pop<GallerySortChoice>(GallerySortChoice.follow);
            } else {
              navigator.pop<GallerySortChoice>(
                GallerySortChoice(
                  followGlobal: false,
                  field: field,
                  descending: descending,
                ),
              );
            }
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  static String _describe(SortField f, bool desc) {
    final name = f == SortField.modified ? '按图片时间' : '按文件名';
    return '$name · ${desc ? '逆向' : '正向'}';
  }
}

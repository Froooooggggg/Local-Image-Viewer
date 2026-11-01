import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge/bridge_config.dart';
import '../core/bridge/translation_service.dart';
import '../core/bridge/translation_set.dart';
import '../core/models.dart';

/// 「重译指定页」的完整流程。
///
/// 语义：把第 N–M 页**已经生成的译文图片删掉**，清掉这几页的记录，然后
/// 只重新翻这一段。范围外的页不会被顺带重翻，原始图集全程只读。
///
/// 选择器刻意放在图片查看器**外面**（一个独立对话框），因为它要改的是
/// 落盘的结果，不适合在翻页手势里弹。
Future<void> showRetranslateFlow(
  BuildContext context,
  Gallery gallery,
) async {
  final total = gallery.images.length;
  if (total <= 0) {
    _toast(context, '这个图集里没有图片');
    return;
  }
  final translated = TranslationSetStore.instance.pageCountOf(gallery.id);

  final range = await showDialog<_PageRange>(
    context: context,
    builder: (ctx) => _RetranslateDialog(
      title: gallery.title,
      total: total,
      translated: translated,
    ),
  );
  if (range == null || !context.mounted) return;

  final config = await BridgeConfigStore.load();
  if (!context.mounted) return;
  _toast(context, '正在清理第 ${range.from + 1}–${range.to + 1} 页…');

  final r = await TranslationService.instance.retranslate(
    gallery: gallery,
    config: config,
    from: range.from,
    to: range.to,
  );
  if (!context.mounted) return;

  if (!r.ok) {
    _toast(context, r.error ?? '重译失败');
    return;
  }
  final from = range.from + 1;
  final to = range.to + 1;
  final parts = <String>['已开始重译第 $from–$to 页'];
  if (r.deletedFiles > 0) parts.add('删除旧译文 ${r.deletedFiles} 张');
  if (r.clearedPages > 0) parts.add('清掉记录 ${r.clearedPages} 页');
  parts.add('原始图片未改动');
  _toast(context, parts.join('，'));
}

void _toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// 闭区间的页范围（0 基下标）。
class _PageRange {
  const _PageRange(this.from, this.to);
  final int from;
  final int to;
}

class _RetranslateDialog extends StatefulWidget {
  const _RetranslateDialog({
    required this.title,
    required this.total,
    required this.translated,
  });

  final String title;
  final int total;
  final int translated;

  @override
  State<_RetranslateDialog> createState() => _RetranslateDialogState();
}

class _RetranslateDialogState extends State<_RetranslateDialog> {
  late final TextEditingController _fromCtrl;
  late final TextEditingController _toCtrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fromCtrl = TextEditingController(text: '1');
    _toCtrl = TextEditingController(text: '${widget.total}');
  }

  @override
  void dispose() {
    _fromCtrl.dispose();
    _toCtrl.dispose();
    super.dispose();
  }

  int? get _fromPage {
    final v = int.tryParse(_fromCtrl.text.trim());
    if (v == null) return null;
    return v;
  }

  int? get _toPage {
    final v = int.tryParse(_toCtrl.text.trim());
    if (v == null) return null;
    return v;
  }

  void _selectAll() {
    setState(() {
      _fromCtrl.text = '1';
      _toCtrl.text = '${widget.total}';
      _error = null;
    });
  }

  void _submit() {
    final f = _fromPage;
    final t = _toPage;
    if (f == null || t == null) {
      setState(() => _error = '页码必须是数字');
      return;
    }
    if (f < 1 || t < 1) {
      setState(() => _error = '页码从 1 开始');
      return;
    }
    if (f > widget.total || t > widget.total) {
      setState(() => _error = '这本图集只有 ${widget.total} 页');
      return;
    }
    if (f > t) {
      setState(() => _error = '起始页不能大于结束页');
      return;
    }
    Navigator.pop(context, _PageRange(f - 1, t - 1));
  }

  @override
  Widget build(BuildContext context) {
    final span = (_toPage ?? 0) - (_fromPage ?? 0) + 1;
    return AlertDialog(
      title: const Text('重译指定页'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Color(0xFF9AA0AC)),
            ),
            const SizedBox(height: 10),
            Text(
              '共 ${widget.total} 页'
              '${widget.translated > 0 ? '，已翻译 ${widget.translated} 页' : ''}',
              style: const TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _pageField(_fromCtrl, '从第')),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('—'),
                ),
                Expanded(child: _pageField(_toCtrl, '到第')),
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Text('页'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _selectAll,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('全部', style: TextStyle(fontSize: 12.5)),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0x14FF8A65),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '会删除第 ${_fromPage ?? '?'}–${_toPage ?? '?'} 页已生成的译文图片'
                '${span > 0 ? '（约 $span 张）' : ''}，然后只重新翻这一段。\n'
                '原始图片不会被改动，范围外的译文也不受影响。',
                style: const TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFFE57373)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('开始重译'),
        ),
      ],
    );
  }

  Widget _pageField(TextEditingController c, String label) => TextField(
    controller: c,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    textAlign: TextAlign.center,
    style: const TextStyle(fontSize: 15),
    decoration: InputDecoration(
      isDense: true,
      labelText: label,
      labelStyle: const TextStyle(fontSize: 12),
      border: const OutlineInputBorder(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
    ),
    onChanged: (_) => setState(() => _error = null),
  );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge/bridge_config.dart';
import '../core/bridge/translation_service.dart';
import '../core/bridge/translation_task.dart';
import '../core/models.dart';
import '../core/saf_channel.dart';
import 'sheet_shell.dart';

/// 图集三点菜单里的「翻译」入口。
///
/// 只弹一个确认面板：配对状态、语言、存放位置、要不要继续上次的进度。
/// 真正开始后所有进度都在后台跑，界面只留底部那条细进度条，
/// 用户可以去翻别的图集，不打断阅读。
Future<void> showTranslationStart(BuildContext context, Gallery gallery) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: kSheetIsScrollControlled,
    builder: (_) => SheetShell(child: _StartSheet(gallery: gallery)),
  );
  if (changed != true || !context.mounted) return;
}

class _StartSheet extends StatefulWidget {
  const _StartSheet({required this.gallery});

  final Gallery gallery;

  @override
  State<_StartSheet> createState() => _StartSheetState();
}

class _StartSheetState extends State<_StartSheet> {
  final _service = TranslationService.instance;

  BridgeConfig _config = BridgeConfig();
  TranslationTask? _existing;
  bool _loading = true;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final config = await BridgeConfigStore.load();
    await _service.load();
    if (!mounted) return;
    setState(() {
      _config = config;
      _existing = _service.taskFor(widget.gallery.id);
      _loading = false;
    });
  }

  bool get _paired => _config.token.isNotEmpty;

  /// 配对码末 4 位（不足 4 位就全遮掉）。
  static String _tokenTail(String token) =>
      token.length >= 4 ? token.substring(token.length - 4) : '****';
  bool get _hasDir =>
      (_config.outputTreeUri ?? '').isNotEmpty &&
      _config.outputTreeName != null;

  int get _total => widget.gallery.images.length;
  int get _gifCount => widget.gallery.images
      .where((i) => i.fileName.toLowerCase().endsWith('.gif'))
      .length;

  @override
  Widget build(BuildContext context) {
    final task = _existing;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 2),
          child: Text(
            '翻译「${widget.gallery.title}」',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Text(
            '调用本机或局域网 PC 的翻译服务把 $_total 页翻成另一种语言，'
            '译文存进单独的目录，阅读时直接挂在原图集上。',
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: Color(0xFF8A8F99),
            ),
          ),
        ),
        if (task != null) _resumeBanner(task),
        _row(
          icon: Icons.link,
          label: '翻译服务',
          value: _paired
              ? '已配对 · ${_config.host}:${_config.port}'
                    '（配对码 …${_tokenTail(_config.token)}）'
              : '未配对',
          valueColor: _paired ? null : const Color(0xFFC9A66B),
          actionLabel: _paired ? '重新配对' : '粘贴配对信息',
          onAction: _pastePairing,
        ),
        _row(
          icon: Icons.folder_outlined,
          label: '存放位置',
          value: _hasDir ? _config.outputTreeName! : '未选择',
          valueColor: _hasDir ? null : const Color(0xFFC9A66B),
          actionLabel: '选择',
          onAction: _pickDir,
        ),
        _languageRow(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
          child: Text(
            _estimateText(),
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF6E7280)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: (_loading || _starting || !_paired || !_hasDir)
                      ? null
                      : _start,
                  child: _starting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_startLabel),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  String get _startLabel {
    final t = _existing;
    if (t == null) return '开始翻译';
    return switch (t.state) {
      TranslationTaskState.done => '重新翻译',
      TranslationTaskState.running => '正在翻译',
      _ => '继续翻译',
    };
  }

  String _estimateText() {
    final gif = _gifCount;
    final pages = _total - gif;
    if (pages <= 0) return '这本全是动图，动图不会送去翻译，只原样复制。';
    final low = (pages * 3 / 60).ceil();
    final high = (pages * 10 / 60).ceil();
    final gifText = gif > 0 ? '，其中 $gif 张动图原样复制' : '';
    return '预计 $pages 页需要 $low~$high 分钟$gifText（每页 3~10 秒，视画面复杂度）';
  }

  Widget _resumeBanner(TranslationTask task) {
    final (String text, Color color) = switch (task.state) {
      TranslationTaskState.running => (
        '这本正在翻译中（${task.processed}/${task.total}），可以在「翻译处理」里看进度。',
        const Color(0xFF6E8BB5),
      ),
      TranslationTaskState.done => (
        '这本已经翻译完成过（${task.total} 页）。再翻一次会重新处理所有页，已翻好的页会被覆盖。',
        const Color(0xFFB99A5E),
      ),
      TranslationTaskState.paused => (
        '上次暂停在 ${task.processed}/${task.total}，继续会接着翻剩下的页。',
        const Color(0xFFB99A5E),
      ),
      TranslationTaskState.stopped || TranslationTaskState.failed => (
        '上次没翻完（已完成 ${task.processed}/${task.total}），继续会接着往下翻。',
        const Color(0xFF8A8F99),
      ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, height: 1.5, color: color),
        ),
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 19),
      title: Text(label, style: const TextStyle(fontSize: 13.5)),
      subtitle: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: valueColor ?? const Color(0xFF9DA2AC),
        ),
      ),
      trailing: TextButton(
        onPressed: onAction,
        child: Text(actionLabel, style: const TextStyle(fontSize: 12.5)),
      ),
    );
  }

  Widget _languageRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
      child: Row(
        children: [
          Expanded(child: _langDropdown(isSource: true)),
          const SizedBox(width: 8),
          const Icon(Icons.arrow_forward, size: 16, color: Color(0xFF6E7280)),
          const SizedBox(width: 8),
          Expanded(child: _langDropdown(isSource: false)),
        ],
      ),
    );
  }

  Widget _langDropdown({required bool isSource}) {
    final values = isSource ? kSourceLangs : kTargetLangs;
    final current = isSource ? _config.source : _config.target;
    return DropdownButtonFormField<String>(
      initialValue: values.containsKey(current) ? current : values.keys.first,
      isDense: true,
      decoration: InputDecoration(
        isDense: true,
        labelText: isSource ? '源语言' : '目标语言',
        labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF8A8F99)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF2E2E36)),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      style: const TextStyle(fontSize: 13, color: Color(0xFFE6E6E9)),
      dropdownColor: const Color(0xFF1B1B1F),
      items: [
        for (final e in values.entries)
          DropdownMenuItem(value: e.key, child: Text(e.value)),
      ],
      onChanged: (v) async {
        if (v == null) return;
        setState(() {
          _config = _config.copyWith(
            source: isSource ? v : null,
            target: isSource ? null : v,
          );
        });
        await BridgeConfigStore.save(_config);
      },
    );
  }

  Future<void> _pastePairing() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) {
      _snack('剪贴板是空的。请在翻译端的「设置 → 图集互联 → 配对」里点复制。');
      return;
    }
    final pairing = BridgePairing.tryParse(raw);
    if (pairing == null) {
      _snack('没认出这段配对信息，请在翻译端重新复制一次。');
      return;
    }
    final next = _config.mergedWith(pairing);
    await BridgeConfigStore.save(next);
    if (!mounted) return;
    setState(() => _config = next);
    _snack('已配对 · ${next.host}:${next.port}');
  }

  Future<void> _pickDir() async {
    try {
      final pick = await SafChannel.pickOutputTree();
      if (pick == null) return;
      final next = _config.copyWith(
        outputTreeUri: pick.uri,
        outputTreeName: pick.name,
      );
      await BridgeConfigStore.save(next);
      if (!mounted) return;
      setState(() => _config = next);
    } on PlatformException catch (e) {
      _snack('选择目录失败：${e.message}');
    }
  }

  Future<void> _start() async {
    final task = _existing;
    if (task != null && task.state == TranslationTaskState.done) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('这本已经翻译过了'),
          content: Text(
            '「${widget.gallery.title}」已经翻译完成 ${task.total} 页。'
            '再翻一次会重新处理所有页，已翻好的页会被覆盖。\n\n'
            '要重新翻译吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('不翻了'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('重新翻译'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    setState(() => _starting = true);

    // 先探一次本机服务：配对码是否有效、开关有没有开、模型是否就绪。
    // 这一步失败就不该开始跑，否则第一页就会白失败并污染任务状态。
    final probe = await _service.probe();
    if (!mounted) return;
    if (!probe.ok) {
      setState(() => _starting = false);
      await _showConnectError(probe);
      return;
    }

    final result = await _service.start(
      gallery: widget.gallery,
      config: _config,
    );
    if (!mounted) return;
    setState(() => _starting = false);
    if (!result.ok) {
      _snack(result.error ?? '无法开始翻译');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context, true);
    messenger.showSnackBar(
      const SnackBar(content: Text('已开始翻译，进度在底部条与「翻译处理」页可以看到')),
    );
  }

  Future<void> _showConnectError(BridgeProbeResult probe) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('连接不上翻译服务'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              probe.error ?? '未知错误',
              style: const TextStyle(fontSize: 13.5, height: 1.5),
            ),
            if (probe.hint != null) ...[
              const SizedBox(height: 10),
              Text(
                probe.hint!,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: Color(0xFF8A8F99),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              unawaited(_pastePairing());
            },
            child: const Text('重新配对'),
          ),
        ],
      ),
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// 源语言：auto 放第一位，并说明它对汉字台词的取舍。
// 语言表定义在 bridge_config.dart，设置页与弹层共用一份。

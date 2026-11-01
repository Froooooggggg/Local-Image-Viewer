import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/bridge/bridge_config.dart';
import '../core/bridge/translation_service.dart';
import '../core/gallery_search.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../core/saf_channel.dart';
import 'disclaimer.dart';

/// 设置页：排序、阅读模式、预加载/卸载、亮度、分页与缓存。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _repo = GalleryRepository.instance;

  /// 从构建产物读取的版本号（避免与 pubspec 两处不一致）。
  String _appVersion = '…';

  AppSettings get _s => _repo.settings;

  /// 翻译服务配置（配对码、语言、输出目录）。
  BridgeConfig _bridge = const BridgeConfig();

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadBridge();
  }

  Future<void> _loadBridge() async {
    final c = await BridgeConfigStore.load();
    if (mounted) setState(() => _bridge = c);
  }

  Future<void> _saveBridge(BridgeConfig next) async {
    await BridgeConfigStore.save(next);
    if (mounted) setState(() => _bridge = next);
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _appVersion = '${info.version}+${info.buildNumber}');
      }
    } catch (_) {
      // 读取失败（平台通道缺失等）不影响设置页使用。
      if (mounted) setState(() => _appVersion = '未知');
    }
  }

  Future<void> _apply(Future<void> Function() mutate) async {
    await mutate();
    await _repo.saveSettings();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _section('排序'),
          RadioGroup<SortField>(
            groupValue: _s.sortField,
            onChanged: (v) {
              if (v == null) return;
              _apply(() async {
                _s.sortField = v;
                await _repo.resortAll();
              });
            },
            child: Column(
              children: [
                _radioTile<SortField>(
                  title: '按图片自身时间',
                  subtitle: '使用压缩包内每张图的时间，而不是压缩包的时间',
                  value: SortField.modified,
                ),
                _radioTile<SortField>(
                  title: '按命名',
                  subtitle: '自然序，2 排在 10 之前',
                  value: SortField.name,
                ),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('逆向排序'),
            subtitle: const Text('开启后由后往前排列'),
            value: _s.descending,
            onChanged: (v) => _apply(() async {
              _s.descending = v;
              await _repo.resortAll();
            }),
          ),

          _section('图集排序'),
          RadioGroup<GallerySortField>(
            groupValue: _s.gallerySort,
            onChanged: (v) {
              if (v == null) return;
              _apply(() async => _s.gallerySort = v);
            },
            child: Column(
              children: [
                _radioTile<GallerySortField>(
                  title: '按导入时间',
                  subtitle: '按图集记录写入的时间排列',
                  value: GallerySortField.importTime,
                ),
                _radioTile<GallerySortField>(
                  title: '按导入顺序',
                  subtitle: '按最初导入的先后排列',
                  value: GallerySortField.importOrder,
                ),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('图集列表逆向'),
            subtitle: const Text('开启后新导入的排在前面'),
            value: _s.galleryDescending,
            onChanged: (v) => _apply(() async => _s.galleryDescending = v),
          ),

          _section('标签预设'),
          if (_s.presetTags.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '还没有预设标签。添加后，编辑图集标签时可以点一下直接打上，'
                '不必每次手输。',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF8B8F98)),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: _s.presetTags
                    .map(
                      (t) => InputChip(
                        label: Text(t, style: const TextStyle(fontSize: 12)),
                        onDeleted: () => _apply(() async {
                          await _repo.removePresetTag(t);
                        }),
                      ),
                    )
                    .toList(),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('添加预设标签'),
            onTap: _addPresetTag,
          ),

          _section('阅读方式'),
          RadioGroup<ReadingMode>(
            groupValue: _s.readingMode,
            onChanged: (v) {
              if (v == null) return;
              _apply(() async => _s.readingMode = v);
            },
            child: Column(
              children: [
                _radioTile<ReadingMode>(
                  title: '左右翻页',
                  subtitle: '漫画阅读器式，左滑/右滑换图',
                  value: ReadingMode.paged,
                ),
                _radioTile<ReadingMode>(
                  title: '上下滚动',
                  subtitle: '图片列成一列连续查看',
                  value: ReadingMode.scroll,
                ),
              ],
            ),
          ),

          _section('搜索'),
          SwitchListTile(
            title: const Text('模糊搜索'),
            // 只用短标签，不写功能介绍（介绍性文案没有操作价值）。
            subtitle: const Text(
              '搜索栏用 ** 开头可临时启用',
              style: TextStyle(fontSize: 11.5),
            ),
            value: _s.fuzzySearch,
            onChanged: (v) => _apply(() async => _s.fuzzySearch = v),
          ),
          RadioGroup<FuzzyAlgorithm>(
            groupValue: _s.fuzzyAlgorithm,
            onChanged: (v) {
              if (v == null) return;
              _apply(() async => _s.fuzzyAlgorithm = v);
            },
            child: Column(
              children: [
                _radioTile<FuzzyAlgorithm>(
                  title: '子序列匹配',
                  subtitle: '按 fzf 的规则打分；顺序须一致，字母对调找不到',
                  value: FuzzyAlgorithm.subsequence,
                ),
                _radioTile<FuzzyAlgorithm>(
                  title: '词级模糊匹配',
                  subtitle: '按词比较：词序无关、可拼错、长标题也能找到',
                  value: FuzzyAlgorithm.tokenFuzzy,
                ),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('正则搜索'),
            subtitle: const Text(
              '[num] [en] [ch] [mark] [?]（也认中文写法），段间自动补任意内容',
              style: TextStyle(fontSize: 11.5),
            ),
            value: _s.regexSearch,
            onChanged: (v) => _apply(() async => _s.regexSearch = v),
          ),
          ListTile(
            title: const Text('搜索结果最多显示'),
            subtitle: Text(
              _s.searchLimit <= 0
                  ? '不限（有多少显示多少）'
                  : '最多 ${_s.searchLimit} 条（最低 $kMinSearchLimit 条）',
            ),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: _editSearchLimit,
          ),

          _section('性能'),
          ListTile(
            title: const Text('前后预加载张数'),
            subtitle: Text(
              '当前 ${_s.preloadCount} 张（上限 ${AppSettings.maxPreload}）',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Slider(
              value: _s.preloadCount.toDouble().clamp(1, 100),
              min: 1,
              max: AppSettings.maxPreload.toDouble(),
              divisions: AppSettings.maxPreload - 1,
              label: '${_s.preloadCount}',
              onChanged: (v) => setState(() => _s.preloadCount = v.round()),
              onChangeEnd: (v) =>
                  _apply(() async => _s.preloadCount = v.round()),
            ),
          ),
          ListTile(
            title: const Text('超出多少张后自动卸载'),
            subtitle: Text(
              _s.unloadDistance <= 0
                  ? '不限制（保留全部已解码图片）'
                  : '当前 ${_s.unloadDistance} 张',
            ),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: _editUnloadDistance,
          ),

          _section('显示'),
          ListTile(
            title: const Text('软件内亮度'),
            subtitle: Text('${(_s.brightness * 100).round()}%'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Slider(
              value: _s.brightness.clamp(0.15, 1.0),
              min: 0.15,
              max: 1.0,
              onChanged: (v) => setState(() => _s.brightness = v),
              onChangeEnd: (v) => _apply(() async => _s.brightness = v),
            ),
          ),
          ListTile(
            title: const Text('每页图集数'),
            subtitle: Text('每 ${_s.pageSize} 个图集分一页'),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: _editPageSize,
          ),

          _section('动图'),
          SwitchListTile(
            title: const Text('自动播放 GIF'),
            subtitle: const Text(
              '开启后读到动图会直接播放，不再默认暂停。\n'
              '唯一的例外：内存预判认为播放会把应用卡死时仍保持暂停。',
              style: TextStyle(fontSize: 11.5, height: 1.5),
            ),
            value: _s.autoPlayGif,
            onChanged: (v) => _apply(() async => _s.autoPlayGif = v),
          ),

          _section('翻译'),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('翻译服务（本机 / 局域网 PC）'),
            subtitle: Text(
              _bridge.hasToken ? _pairingSummary() : '未配对',
              style: const TextStyle(fontSize: 11.5, height: 1.5),
            ),
            trailing: TextButton(
              onPressed: _pastePairing,
              child: Text(_bridge.hasToken ? '重新配对' : '粘贴配对信息'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.wifi_tethering),
            title: const Text('测试连接'),
            subtitle: const Text(
              '检查翻译服务是否在线、图集互联开关是否打开',
              style: TextStyle(fontSize: 11.5),
            ),
            trailing: const Icon(Icons.play_arrow, size: 18),
            onTap: _testConnection,
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('译文存放位置'),
            subtitle: Text(
              _bridge.outputTreeName ?? '未选择（翻译前必须先选一个目录）',
              style: const TextStyle(fontSize: 11.5),
            ),
            trailing: TextButton(
              onPressed: _pickOutputDir,
              child: const Text('选择'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.visibility_off_outlined),
            title: const Text('隐藏译文（不在相册显示）'),
            subtitle: const Text(
              '给每个译文文件夹加 .nomedia 标记（0 字节），系统相册就不会把译文当照片收录。'
              '新译文会自动加；这里是把以前留下的目录补一遍。',
              style: TextStyle(fontSize: 11.5),
            ),
            trailing: const Icon(Icons.play_arrow, size: 18),
            onTap: _hideTranslatedDirs,
          ),
          ListTile(
            leading: const Icon(Icons.translate),
            title: const Text('源语言'),
            subtitle: Text(
              _langLabel(kSourceLangs, _bridge.source),
              style: const TextStyle(fontSize: 11.5),
            ),
            onTap: () => _chooseLang(isSource: true),
          ),
          ListTile(
            leading: const Icon(Icons.arrow_forward),
            title: const Text('目标语言'),
            subtitle: Text(
              _langLabel(kTargetLangs, _bridge.target),
              style: const TextStyle(fontSize: 11.5),
            ),
            onTap: () => _chooseLang(isSource: false),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: Text(
              '译文会存进这个目录下的「原名<AITranslate>」文件夹，'
              '阅读时直接挂在原图集上，原图集不会被改动；动图不翻译，原样复制。\n'
              '每个译文文件夹里会放一个 .nomedia 空标记，系统相册不会收录这些图片。',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.55,
                color: Color(0xFF7C8290),
              ),
            ),
          ),

          _section('缓存'),
          ListTile(
            title: const Text('封面缓存占用'),
            subtitle: Text(_formatBytes(_repo.cacheUsedBytes())),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('清空封面缓存'),
            subtitle: const Text('只删除本软件的缓存，不会动任何原文件'),
            onTap: _clearCache,
          ),

          _section('关于'),
          ListTile(
            title: const Text('简易图集查看器'),
            subtitle: Text(
              '版本 $_appVersion\n'
              '本地只读的 zip 图集阅读器。\n'
              '默认不联网，也不修改或删除任何本地文件；\n'
              '只写入本应用的私有目录（索引与封面缓存）。\n'
              '例外：使用「翻译」时会访问你配对好的翻译服务'
              '（本机 127.0.0.1，或同一局域网内的 PC；图片只发给它，不经过互联网），'
              '并把翻译结果写进你选择的那一个目录。',
              style: const TextStyle(fontSize: 12.5, height: 1.5),
            ),
          ),
          ListTile(
            title: const Text('图集数量'),
            subtitle: Text('${_repo.galleries.length} 个'),
          ),

          _section('免责声明'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: DisclaimerText(),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('查看完整免责声明'),
            subtitle: const Text('阅读全文后再决定是否继续使用'),
            onTap: _showFullDisclaimer,
          ),
          ListTile(
            leading: const Icon(Icons.code_outlined),
            title: const Text('技术说明'),
            subtitle: const Text(
              '本声明仅说明风险与责任边界，不构成任何法律意见。',
              style: TextStyle(fontSize: 11.5),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// 完整免责声明。
  Future<void> _showFullDisclaimer() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('免责声明'),
        content: const SingleChildScrollView(child: DisclaimerText(full: true)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('我已阅读'),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: Color(0xFF6E8BB5),
        letterSpacing: 0.4,
      ),
    ),
  );

  /// 单选行。选中状态由外层 [RadioGroup] 统一管理。
  Widget _radioTile<T>({
    required String title,
    required String subtitle,
    required T value,
  }) {
    return RadioListTile<T>(
      value: value,
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
    );
  }

  // ---------------------------------------------------------------- 翻译

  static String _langLabel(Map<String, String> table, String code) =>
      table[code] ?? code;

  /// 配对状态的摘要：只露 host:port 与配对码末 4 位。
  ///
  /// 完整 token 不进任何界面、不进日志——它等同于翻译 App 的访问密码。
  String _pairingSummary() {
    final tail = _bridge.token.length >= 4
        ? _bridge.token.substring(_bridge.token.length - 4)
        : '****';
    return '已配对 · ${_bridge.host}:${_bridge.port} · 配对码 …$tail';
  }

  Future<void> _pastePairing() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) {
      _toast('剪贴板是空的。请在翻译端的「设置 → 图集互联 → 配对」里点复制。');
      return;
    }
    final pairing = BridgePairing.tryParse(raw);
    if (pairing == null) {
      _toast('没认出这段配对信息，请在翻译端重新复制一次。');
      return;
    }
    final next = _bridge.mergedWith(pairing);
    await _saveBridge(next);
    _toast('已配对 · ${next.host}:${next.port}');
  }

  Future<void> _pickOutputDir() async {
    try {
      final pick = await SafChannel.pickOutputTree();
      if (pick == null) return;
      await _saveBridge(
        _bridge.copyWith(outputTreeUri: pick.uri, outputTreeName: pick.name),
      );
      _toast('译文会存到「${pick.name}」');
    } on PlatformException catch (e) {
      _toast('选择目录失败：${e.message}');
    }
  }

  Future<void> _chooseLang({required bool isSource}) async {
    final table = isSource ? kSourceLangs : kTargetLangs;
    final current = isSource ? _bridge.source : _bridge.target;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(isSource ? '源语言' : '目标语言'),
        children: [
          RadioGroup<String>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final e in table.entries)
                  RadioListTile<String>(value: e.key, title: Text(e.value)),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await _saveBridge(
      _bridge.copyWith(
        source: isSource ? picked : null,
        target: isSource ? null : picked,
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 给已经存在的译文目录补 `.nomedia`（一次性整理）。
  ///
  /// 只加 0 字节标记文件，不删、不改任何图片；相册里已经收录的旧条目要等系统
  /// 重新扫描（或重启手机）之后才会消失。
  Future<void> _hideTranslatedDirs() async {
    if ((_bridge.outputTreeUri ?? '').isEmpty) {
      _toast('还没选「译文存放位置」，先选一个目录');
      return;
    }
    _toast('正在整理译文目录…');
    try {
      final added = await TranslationService.instance.hideTranslatedDirs();
      _toast(
        added > 0
            ? '已为 $added 个译文目录加上标记；相册里已收录的旧图，等系统重新扫描后会消失'
            : '译文目录都已经标记过了，没有需要处理的',
      );
    } catch (e) {
      _toast('整理失败：$e');
    }
  }

  /// 测试连接：把服务端回报的关键状态直接说清楚，省得用户猜。
  ///
  /// 失败时按类别给不同文案（连不上 / 超时 / 配对码失效 / 状态未就绪），
  /// 因为这三类在用户那儿的处置方式完全不同。
  Future<void> _testConnection() async {
    _toast('正在连接…');
    final r = await TranslationService.instance.probe();
    if (!mounted) return;
    if (!r.ok) {
      final title = switch (r.kind) {
        ProbeFailureKind.notPaired => '还没有配对',
        ProbeFailureKind.refused => '翻译服务没运行，或不在同一局域网',
        ProbeFailureKind.timeout => '翻译服务 3 秒内没响应',
        ProbeFailureKind.unauthorized => '配对码不对，请重新粘贴配对信息',
        _ => '连接不上翻译服务',
      };
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(
            [r.error, r.hint].whereType<String>().join('\n\n'),
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    final h = r.health!;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('连接正常'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kvRow('服务', '${h.app} ${h.version}'),
            _kvRow('地址', '${_bridge.host}:${h.port}'),
            _kvRow('后端', h.backend.isEmpty ? '未知' : h.backend),
            _kvRow('模型', h.model.isEmpty ? '未加载' : h.model),
            _kvRow('OCR', h.visionReady ? '就绪' : '未就绪'),
            _kvRow('翻译', h.translateReady ? '就绪' : '未就绪'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _kvRow(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 44,
          child: Text(
            k,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF7C8290)),
          ),
        ),
        Expanded(
          child: Text(v, style: const TextStyle(fontSize: 12.5)),
        ),
      ],
    ),
  );

  /// 添加一个预设标签。
  Future<void> _addPresetTag() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加预设标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '多个标签用逗号分隔'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (text == null) return;
    for (final t in text.split(RegExp(r'[,，]'))) {
      await _repo.addPresetTag(t);
    }
    if (mounted) setState(() {});
  }

  Future<void> _editUnloadDistance() async {
    final controller = TextEditingController(text: '${_s.unloadDistance}');
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自动卸载距离'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '距离当前图片超过这个张数后释放其已解码数据。\n'
              '填 0 表示不限制。',
              style: TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: '例如 8'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final parsed = int.tryParse((text ?? '').trim());
    if (parsed != null && parsed >= 0) {
      await _apply(() async => _s.unloadDistance = parsed);
    }
  }

  Future<void> _editPageSize() async {
    final controller = TextEditingController(text: '${_s.pageSize}');
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('每页图集数'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final parsed = int.tryParse((text ?? '').trim());
    if (parsed != null && parsed >= 1) {
      await _apply(() async => _s.pageSize = parsed);
    }
  }

  /// 设置模糊搜索的显示上限。
  ///
  /// 输入 0 表示不限；小于下限时会被抬到下限（需求：最低 10 条，最高不限）。
  Future<void> _editSearchLimit() async {
    final controller = TextEditingController(text: '${_s.searchLimit}');
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('模糊搜索最多显示'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true),
            ),
            const SizedBox(height: 8),
            const Text(
              '输入 0 表示不限（有多少显示多少）。\n'
              '最低 $kMinSearchLimit 条，最高不限。',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF8B8F98)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final parsed = int.tryParse((text ?? '').trim());
    if (parsed == null || parsed < 0) return;
    // 0 保持为"不限"；其余抬到下限。
    final value = parsed == 0
        ? 0
        : (parsed < kMinSearchLimit ? kMinSearchLimit : parsed);
    await _apply(() async => _s.searchLimit = value);
  }

  Future<void> _clearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空封面缓存？'),
        content: const Text(
          '只会删除本应用私有缓存里的封面图，'
          '你的压缩包和图片文件不会被改动。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _repo.clearThumbCache();
      if (mounted) setState(() {});
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

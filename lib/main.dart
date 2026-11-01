import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/bridge/translation_service.dart';
import 'core/bridge/translation_task.dart';
import 'core/repository.dart';
import 'core/saf_channel.dart';
import 'ui/collections_page.dart';
import 'ui/disclaimer.dart';
import 'ui/gallery_list_page.dart';
import 'ui/progress_dialog.dart';
import 'ui/settings_page.dart';
import 'ui/sheet_shell.dart';
import 'ui/translation_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SimpleGalleryViewerApp());
}

class SimpleGalleryViewerApp extends StatelessWidget {
  const SimpleGalleryViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '简易图集查看器',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      // 中文界面：Material 组件（如 Radio、日期选择）依赖 MaterialLocalizations，
      // 缺少它会在运行时断言失败。
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      locale: const Locale('zh', 'CN'),
      home: const RootShell(),
    );
  }
}

/// 简约暗色主题。深夜阅读为主场景，整体对比度刻意压低。
ThemeData buildAppTheme() {
  const surface = Color(0xFF121214);
  const elevated = Color(0xFF1B1B1F);
  const accent = Color(0xFF6E8BB5);

  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
    surface: surface,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: surface,
    appBarTheme: const AppBarTheme(
      backgroundColor: surface,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: Color(0xFFE6E6E9),
      ),
      iconTheme: IconThemeData(color: Color(0xFFE6E6E9)),
    ),
    cardTheme: const CardThemeData(color: elevated),
    dialogTheme: const DialogThemeData(backgroundColor: elevated),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: elevated),
    listTileTheme: const ListTileThemeData(iconColor: Color(0xFFB9BCC4)),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF26262C),
      contentTextStyle: TextStyle(color: Color(0xFFE6E6E9)),
      behavior: SnackBarBehavior.floating,
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFF26262C),
      thickness: 1,
      space: 1,
    ),
  );
}

/// 根壳：底部三个入口（收藏夹 / 图集 / 设置），并承载全局亮度调节。
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final _repo = GalleryRepository.instance;
  int _tab = 1;
  late Future<void> _loading;

  /// 图集列表页的 state：收藏夹里的「在图集列表中定位」需要用到它
  /// （切页由本壳层负责，滚动定位由列表页负责）。
  final _listKey = GlobalKey<GalleryListPageState>();

  /// 本次会话是否已处理过首次启动的免责声明确认。
  bool _disclaimerChecked = false;

  @override
  void initState() {
    super.initState();
    _loading = _repo.load();
    // 翻译任务与界面生命周期无关，启动时先把上次的记录读出来。
    // 迁移旧「翻译图集」要读图集索引，所以等仓库读完再加载。
    unawaited(() async {
      try {
        await _loading;
      } catch (_) {
        // 索引读失败也要让翻译记录可用：initSets 里还有一次就绪检查。
      }
      await TranslationService.instance.load();
    }());
  }

  /// 首次启动时弹出免责声明，要求用户明确同意后才能使用。
  ///
  /// 放在加载完成后、进入主界面之前：这样弹窗出现在一个已经就绪的界面上，
  /// 不会和启动加载动画抢注意力。
  ///
  /// 选"不同意"直接退出应用（而不是放行）—— 避免出现"没同意却已在用"的
  /// 中间状态；也不会记录任何标记，因此下次启动仍会再次询问。
  Future<void> _ensureDisclaimerAccepted() async {
    if (_disclaimerChecked) return;
    _disclaimerChecked = true;
    if (_repo.disclaimerAccepted) return;
    if (!mounted) return;

    final agreed = await showFirstRunDisclaimer(context);
    if (agreed) {
      await _repo.acceptDisclaimer();
      return;
    }
    // 不同意：退出应用。当前版本用 SystemNavigator.pop 让 Activity 退出。
    await SystemNavigator.pop();
  }

  /// 从收藏夹跳转到某个图集在「图集」列表中的位置。
  ///
  /// 切页由本壳层负责，具体滚动定位交给列表页自己 ——
  /// 只有它知道分页大小与网格布局。
  void _locateGallery(String galleryId) {
    setState(() => _tab = 1);
    // 等这一帧的切页生效后再滚动，否则控制器还没 attach 上。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _listKey.currentState?.locateGallery(galleryId);
    });
  }

  /// 打开翻译任务看板。
  ///
  /// 需求变更：不再占一个底部标签页；点底部那条常驻进度条进入。
  /// 里面能暂停/继续/终止，「查看译文」直接在阅读器里打开原图集。
  void _openTranslationTasks() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const TranslationPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _loading,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // 给等待一个明确的说明。图集很多时索引需要解析几秒，
          // 只有一个无文字的转圈会让人以为卡死了。
          return const Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(height: 18),
                  Text(
                    '正在加载图集索引…',
                    style: TextStyle(fontSize: 13.5, color: Color(0xFFB9BCC4)),
                  ),
                  SizedBox(height: 6),
                  Text(
                    '图集较多时首次进入需要几秒',
                    style: TextStyle(fontSize: 11.5, color: Color(0xFF6E7280)),
                  ),
                ],
              ),
            ),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('初始化失败：${snapshot.error}'),
              ),
            ),
          );
        }

        // 软件内亮度：叠一层黑色遮罩，不改系统亮度（可逆、无副作用）。
        final dim = (1.0 - _repo.settings.brightness).clamp(0.0, 0.9);

        // 免责声明在首帧之后再弹，避免在 build 过程中操作 Navigator。
        if (!_disclaimerChecked && !_repo.disclaimerAccepted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            unawaited(_ensureDisclaimerAccepted());
          });
        }

        return Stack(
          children: [
            Scaffold(
              body: IndexedStack(
                index: _tab,
                children: [
                  CollectionsPage(onLocateGallery: _locateGallery),
                  GalleryListPage(key: _listKey),
                  const SettingsPage(),
                ],
              ),
              bottomNavigationBar: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 常驻进度条：批量翻译的进度与入口。
                  // 需求变更：不再单独占一个「翻译处理」标签页，
                  // 翻译结果改成在阅读器里与原图叠放、用顶栏按钮切换；
                  // 任务详情（暂停/终止/续跑）改为点进度条打开。
                  TranslationProgressBar(onOpen: _openTranslationTasks),
                  NavigationBar(
                    selectedIndex: _tab,
                    onDestinationSelected: (i) => setState(() => _tab = i),
                    height: 58,
                    backgroundColor: const Color(0xFF16161A),
                    indicatorColor: const Color(0xFF2A2F3A),
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.bookmarks_outlined),
                        selectedIcon: Icon(Icons.bookmarks),
                        label: '收藏夹',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.grid_view_outlined),
                        selectedIcon: Icon(Icons.grid_view),
                        label: '图集',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.tune_outlined),
                        selectedIcon: Icon(Icons.tune),
                        label: '设置',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (dim > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(color: Colors.black.withValues(alpha: dim)),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 导入入口。
///
/// 两条路都经由自写的 SAF 选择器（而不是 `file_picker`），因为只有自写选择器
/// 才能申请**可持久化**的 URI 授权——否则应用一重启，压缩包就打不开了。
/// 读取全程直接操作原文件，不产生副本。
Future<void> showImportSheet(BuildContext context) async {
  final repo = GalleryRepository.instance;

  final choice = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: kSheetIsScrollControlled,
    builder: (ctx) => SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '导入图集',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.folder_zip_outlined),
            title: const Text('导入 zip 压缩包'),
            subtitle: const Text('选择一个 .zip，直接读取原文件'),
            onTap: () => Navigator.pop(ctx, 'zip'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('导入单个文件夹'),
            subtitle: const Text('把该目录下的图片打包成一个图集（不含子目录）'),
            onTap: () => Navigator.pop(ctx, 'single'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: const Text('批量导入文件夹'),
            subtitle: const Text('该文件夹里的每个 zip 与每个子文件夹各成一个图集'),
            onTap: () => Navigator.pop(ctx, 'folder'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  // 在任何 await 之前取出 Navigator：后续弹进度框只用它，不再触碰 context。
  final navigator = Navigator.of(context, rootNavigator: true);
  // 开始一次新的导入：清除上一次残留的取消状态。
  // 必须在扫描之前调用，否则用户在"正在扫描目录…"阶段点的取消会被丢掉。
  repo.beginImport();

  try {
    if (choice == 'zip') {
      final pick = await SafChannel.pickZip();
      if (pick == null) return;

      final progress = showProgressDialog(navigator, initial: '正在读取压缩包…');
      try {
        final r = await repo.importZip(pick);
        messenger.showSnackBar(
          SnackBar(
            content: Text(_withPermissionHint(r.message, pick.persisted)),
          ),
        );
      } finally {
        await progress.finish();
      }
    } else if (choice == 'single') {
      // 单个文件夹：只读该目录这一层，子目录一概不管。
      // 单个图集的读取无法在中间安全中断，因此不提供取消按钮。
      final pick = await SafChannel.pickFolder();
      if (pick == null) return;

      final progress = showProgressDialog(
        navigator,
        initial: '正在扫描目录…',
        cancellable: false,
      );
      try {
        final r = await repo.importSingleFolder(
          pick.uri,
          _titleFromDisplayName(pick.name),
        );
        messenger.showSnackBar(
          SnackBar(
            content: Text(_withPermissionHint(r.message, pick.persisted)),
          ),
        );
      } finally {
        await progress.finish();
      }
    } else {
      final pick = await SafChannel.pickFolder();
      if (pick == null) return;

      // 批量导入可能持续很久，提供取消按钮（协作式：在每一项边界停止）。
      final progress = showProgressDialog(navigator, initial: '正在扫描目录…');
      try {
        final report = await repo.importFolderBatch(
          pick.uri,
          onProgress: (done, total, title) {
            // 只更新 ValueNotifier，不触碰 context。
            if (progress.handle.cancelled) {
              progress.handle.setText('正在取消…');
              // 把取消请求转达给仓库，它在下一项开始前停止。
              repo.requestCancelImport();
            } else {
              progress.handle.update(done, total, title);
            }
          },
        );
        messenger.showSnackBar(
          SnackBar(
            content: Text(_withPermissionHint(report.summary, pick.persisted)),
          ),
        );
      } finally {
        await progress.finish();
      }
    }
  } on PlatformException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('选择文件失败：${e.message}')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
  }
}

/// 从选择器给的目录名得到图集标题。
String _titleFromDisplayName(String name) =>
    name.trim().isEmpty ? '未命名' : name.trim();

/// 若未能取得持久化授权，明确告知用户：重启后可能需要重新选择。
String _withPermissionHint(String message, bool persisted) {
  if (persisted) return message;
  return '$message（注意：该来源不支持长期授权，重启后可能需重新选择）';
}

/// 底部导航上方的常驻进度条。
///
/// 有任务时显示一行高度：用户在任何页面都能看到翻到第几页，点一下进入
/// 「翻译处理」看板（它已不再是标签页）。没有正在跑的任务但留有历史记录时，
/// 仍显示一条极窄的入口，否则用户再也没有地方打开任务看板。
class TranslationProgressBar extends StatelessWidget {
  const TranslationProgressBar({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final service = TranslationService.instance;
    return AnimatedBuilder(
      // 同时听「当前任务」与「任务列表」：任务结束后 active 仍是它，
      // 但列表变空时入口条也应该消失。
      animation: Listenable.merge([service.active, service.tasks]),
      builder: (context, _) {
        final task = service.active.value;
        if (task == null) {
          if (service.tasks.value.isEmpty) return const SizedBox.shrink();
          return _HistoryEntry(onOpen: onOpen);
        }
        final running = task.state == TranslationTaskState.running;
        final subtitle = running && task.currentName.isNotEmpty
            ? task.currentName
            : task.stateLabel;
        return Material(
          color: const Color(0xFF1B1B1F),
          child: InkWell(
            onTap: onOpen,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: task.total == 0 ? null : task.fraction,
                  minHeight: 2,
                  backgroundColor: const Color(0xFF26262C),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF6E8BB5)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.translate,
                        size: 15,
                        color: Color(0xFF8FA6C4),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '翻译「${task.galleryTitle}」'
                              ' ${task.processed}/${task.total}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFFD6D9DF),
                              ),
                            ),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: Color(0xFF7C8290),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: running ? '暂停' : '继续',
                        visualDensity: VisualDensity.compact,
                        iconSize: 19,
                        onPressed: () {
                          if (running) {
                            unawaited(service.pause());
                          } else if (task.state ==
                              TranslationTaskState.paused) {
                            unawaited(service.resume(task));
                          } else {
                            onOpen();
                          }
                        },
                        icon: Icon(
                          running
                              ? Icons.pause_circle_outline
                              : Icons.play_circle_outline,
                          color: const Color(0xFFB9BCC4),
                        ),
                      ),
                      IconButton(
                        tooltip: '终止',
                        visualDensity: VisualDensity.compact,
                        iconSize: 19,
                        onPressed: running
                            ? () => unawaited(service.stop())
                            : null,
                        icon: const Icon(
                          Icons.stop_circle_outlined,
                          color: Color(0xFFB9BCC4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 没有正在跑的任务、但还留着历史记录时的窄入口。
class _HistoryEntry extends StatelessWidget {
  const _HistoryEntry({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1B1B1F),
      child: InkWell(
        onTap: onOpen,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          child: Row(
            children: [
              Icon(Icons.translate, size: 14, color: Color(0xFF8FA6C4)),
              SizedBox(width: 8),
              Text(
                '翻译处理记录',
                style: TextStyle(fontSize: 11, color: Color(0xFF7C8290)),
              ),
              Spacer(),
              Icon(Icons.chevron_right, size: 15, color: Color(0xFF5A6070)),
            ],
          ),
        ),
      ),
    );
  }
}

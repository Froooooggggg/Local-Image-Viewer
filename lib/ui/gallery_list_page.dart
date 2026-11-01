import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/bridge/translation_set.dart';
import '../core/gallery_search.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../main.dart' show showImportSheet;
import 'auto_scroll_text.dart';
import 'collection_picker.dart';
import 'retranslate_dialog.dart';
import 'sheet_shell.dart';
import 'sort_editor.dart';
import 'tag_editor.dart';
import 'translation_flow.dart';
import 'viewer_page.dart';

/// 图集列表：搜索、分页、封面网格。
///
/// 需求：图集太多时按页划分（默认每页 100 个图集）。
class GalleryListPage extends StatefulWidget {
  const GalleryListPage({super.key});

  @override
  State<GalleryListPage> createState() => GalleryListPageState();
}

class GalleryListPageState extends State<GalleryListPage> {
  final _repo = GalleryRepository.instance;
  final _searchController = TextEditingController();
  String _query = '';

  /// 图集网格的滚动控制器：供 [locateGallery] 定位使用。
  final _gridController = ScrollController();

  /// 网格布局参数（与 build 里的 gridDelegate 保持一致）。
  ///
  /// 抽成常量是为了让 [locateGallery] 能自己算出目标位置 ——
  /// 否则定位就只能"滚到大概的位置"，落不到卡片上。
  static const _kMaxCrossAxisExtent = 190.0;
  static const _kChildAspectRatio = 0.78;
  static const _kCrossAxisSpacing = 10.0;
  static const _kMainAxisSpacing = 10.0;

  int _page = 0;

  /// 多选模式：存放被选中的图集 id。
  ///
  /// 长按封面进入；进入后单击切换选中状态，顶部出现「全选 / 退出」，
  /// 底部出现批量操作栏。
  bool _selecting = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    // 监听仓库变更：查看器里做过的"验证/重载/移除图集"等操作回到列表后
    // 需要立即反映，而不是等到下次重建。
    _repo.revision.addListener(_onRepoChanged);
  }

  void _onRepoChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _repo.revision.removeListener(_onRepoChanged);
    _searchController.dispose();
    _gridController.dispose();
    super.dispose();
  }

  /// **定位到某个图集**：跳到它所在的那一页并滚动到它。
  ///
  /// 由根壳层在切到本页后调用（收藏夹里的「在图集列表中定位」）。
  ///
  /// 三个必须处理的点：
  ///   1. 图集可能被搜索过滤掉 —— 先清空搜索，否则永远找不到；
  ///   2. 它可能在**别的分页**上 —— 先切页，否则滚动也没有意义；
  ///   3. 切页后网格是新的滚动位置 —— 等这一帧渲染完再滚。
  void locateGallery(String galleryId) {
    if (!mounted) return;

    // 1) 清掉搜索，让全部图集都在列表里。
    if (_query.isNotEmpty) {
      _searchController.clear();
      _query = '';
      unawaited(_runSearch());
    }

    final list = _filtered;
    final index = list.indexWhere((g) => g.id == galleryId);
    if (index < 0) {
      // 图集已被移除（收藏夹里残留的引用）：明确告知，而不是默默无反应。
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('这个图集已不在列表中')));
      return;
    }

    final pageSize = _repo.settings.pageSize;
    final targetPage = index ~/ pageSize;
    setState(() {
      _page = targetPage;
      _selecting = false;
      _selected.clear();
    });

    // 2) 等切页后的帧渲染完再滚动。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_gridController.hasClients) return;
      final local = index % pageSize;
      final offset = _gridOffsetFor(local);
      _gridController.animateTo(
        offset.clamp(0.0, _gridController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    });
  }

  /// 按网格布局算出第 [localIndex] 个卡片对应的滚动偏移。
  ///
  /// 复刻 SliverGridDelegateWithMaxCrossAxisExtent 的列数计算：
  /// 先按最大宽度求列数，再据此算每个格子的实际宽高。
  double _gridOffsetFor(int localIndex) {
    final width = MediaQuery.of(context).size.width - 24; // 左右各 12 内边距
    var columns = (width / _kMaxCrossAxisExtent).ceil();
    if (columns < 1) columns = 1;
    final tileWidth = (width - _kCrossAxisSpacing * (columns - 1)) / columns;
    final tileHeight = tileWidth / _kChildAspectRatio;
    final row = localIndex ~/ columns;
    // 减去一小段，让目标卡片不在屏幕最上沿（顶部有搜索栏，贴着会被遮）。
    final raw = row * (tileHeight + _kMainAxisSpacing);
    return raw > 60 ? raw - 60 : 0;
  }

  void _enterSelection(Gallery g) {
    setState(() {
      _selecting = true;
      _selected
        ..clear()
        ..add(g.id);
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelection(Gallery g) {
    setState(() {
      if (!_selected.remove(g.id)) _selected.add(g.id);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  /// 全选**当前页面**的图集（需求如此：只针对当前页）。
  void _selectAllOnPage(List<Gallery> pageItems) {
    setState(() {
      _selecting = true;
      _selected
        ..clear()
        ..addAll(pageItems.map((g) => g.id));
    });
  }

  List<Gallery> _selectedGalleries() =>
      _repo.galleries.where((g) => _selected.contains(g.id)).toList();

  /// 搜索结果是**异步**算出来的（模糊/正则可能走原生侧），因此缓存起来。
  List<Gallery> _searchResult = const [];

  /// 正则语法错误的提示。
  String? _searchError;

  /// 当前正在执行的搜索序号：只有最新一次的结果会被采用，
  /// 避免快速输入时旧结果覆盖新结果。
  int _searchSeq = 0;

  List<Gallery> get _filtered {
    final all = _repo.galleries;
    if (_query.isEmpty) return all;
    // 其余情况都用异步算好的缓存结果。
    return _searchResult;
  }

  /// 重新执行搜索（输入变化时调用）。
  Future<void> _runSearch() async {
    final all = _repo.galleries;
    final settings = _repo.settings;
    final seq = ++_searchSeq;

    if (_query.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _searchResult = all;
          _searchError = null;
        });
      }
      return;
    }

    final input = parseSearchInput(
      _query,
      fuzzySetting: settings.fuzzySearch,
      regexSetting: settings.regexSearch,
      algorithm: settings.fuzzyAlgorithm,
    );

    final outcome = await GallerySearch.run(
      all,
      input,
      limit: settings.searchLimit,
      algorithm: settings.fuzzyAlgorithm,
    );
    if (!mounted || seq != _searchSeq) return;

    // 正则是同步算的，错误单独取一次。
    String? err;
    if (input.mode == SearchMode.regex && input.query.isNotEmpty) {
      err = GallerySearch.regex(all, input.query).error;
    }

    setState(() {
      _searchResult = err != null ? const [] : outcome.galleries;
      _searchError = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final pageSize = _repo.settings.pageSize;
    final pageCount = filtered.isEmpty
        ? 1
        : ((filtered.length - 1) ~/ pageSize) + 1;
    final safePage = _page.clamp(0, pageCount - 1);
    final start = safePage * pageSize;
    final pageItems = filtered.skip(start).take(pageSize).toList();

    // 只为当前页补齐封面，避免一次性扫描全部图集。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_repo.ensureCovers(pageItems));
    });

    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: '退出多选',
                onPressed: _exitSelection,
              ),
              title: Text('已选 ${_selected.length} 个'),
              actions: [
                TextButton(
                  onPressed: () {
                    final allSelected =
                        pageItems.isNotEmpty &&
                        pageItems.every((g) => _selected.contains(g.id));
                    if (allSelected) {
                      // 已全选则取消，便于反悔。
                      setState(() {
                        for (final g in pageItems) {
                          _selected.remove(g.id);
                        }
                        if (_selected.isEmpty) _selecting = false;
                      });
                    } else {
                      _selectAllOnPage(pageItems);
                    }
                  },
                  child: Text(
                    pageItems.isNotEmpty &&
                            pageItems.every((g) => _selected.contains(g.id))
                        ? '取消全选'
                        : '全选本页',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 4),
              ],
            )
          : AppBar(
              title: Text('图集 (${_repo.galleries.length})'),
              actions: [
                IconButton(
                  tooltip: '刷新封面',
                  icon: const Icon(Icons.refresh),
                  onPressed: () async {
                    await _repo.ensureCovers(pageItems);
                    if (mounted) setState(() {});
                  },
                ),
                const SizedBox(width: 4),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(52),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) {
                      setState(() {
                        // **不 trim**：** 与 [] 标记必须原样保留才能被识别，
                        // 由 parseSearchInput 负责在识别后去掉标记与空白。
                        _query = v;
                        _page = 0;
                      });
                      // 搜索可能是异步的（模糊走原生侧），单独触发。
                      unawaited(_runSearch());
                    },
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索图集名称或标签',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() {
                                  _query = '';
                                  _page = 0;
                                  _searchResult = _repo.galleries;
                                  _searchError = null;
                                });
                              },
                            ),
                      filled: true,
                      fillColor: const Color(0xFF1B1B1F),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),
      // 多选时隐藏 FAB，避免与底部操作栏抢位置。
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton(
              onPressed: () async {
                await showImportSheet(context);
                if (mounted) setState(() {});
              },
              tooltip: '导入图集',
              child: const Icon(Icons.add),
            ),
      bottomNavigationBar: _selecting
          ? _SelectionActionBar(
              count: _selected.length,
              onAction: _handleBatchAction,
            )
          : null,
      body: filtered.isEmpty
          ? _EmptyState(hasQuery: _query.isNotEmpty)
          : Column(
              children: [
                // 正则语法错误：明确说明，而不是静默显示空结果。
                if (_searchError != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 13,
                          color: Color(0xFFC98A8A),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _searchError!,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFFC98A8A),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: GridView.builder(
                    controller: _gridController,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 190,
                          childAspectRatio: 0.78,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                    itemCount: pageItems.length,
                    itemBuilder: (context, i) {
                      final g = pageItems[i];
                      return _GalleryTile(
                        gallery: g,
                        selecting: _selecting,
                        selected: _selected.contains(g.id),
                        onChanged: () => setState(() {}),
                        onLongPressSelect: () => _enterSelection(g),
                        onTapSelect: () => _toggleSelection(g),
                      );
                    },
                  ),
                ),
                if (pageCount > 1)
                  _Pager(
                    page: safePage,
                    pageCount: pageCount,
                    total: filtered.length,
                    pageSize: pageSize,
                    onJump: (p) => setState(() => _page = p),
                  ),
              ],
            ),
    );
  }

  /// 处理多选状态下的批量操作。
  Future<void> _handleBatchAction(_BatchAction action) async {
    final targets = _selectedGalleries();
    if (targets.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    switch (action) {
      case _BatchAction.update:
        // 需要读目录，给个进度提示，避免看起来像卡死。
        final progress = showDialog<_BatchAction>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const AlertDialog(
            content: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 16),
                Expanded(child: Text('正在更新…', style: TextStyle(fontSize: 13))),
              ],
            ),
          ),
        );
        final report = await _repo.batchUpdate(targets);
        if (navigator.mounted) navigator.pop();
        await progress;
        messenger.showSnackBar(SnackBar(content: Text(report.summary)));
        _exitSelection();

      case _BatchAction.addToCollection:
      case _BatchAction.removeFromCollection:
        final add = action == _BatchAction.addToCollection;
        // 用共用的选择器：内置"新建收藏夹…"，因此收藏夹为空时**不再提前拦下**，
        // 用户可以直接就地创建（此前是提示"请先去收藏夹页新建"）。
        final memberIds = targets.map((g) => g.id).toSet();
        final picked = await showCollectionPicker(
          context,
          title: add ? '加入收藏夹（${targets.length} 个）' : '移出收藏夹',
          memberIds: memberIds,
          onlyContaining: !add,
        );
        if (picked == null) return;
        final r = await _repo.batchToggleCollection(picked, targets, add: add);
        messenger.showSnackBar(SnackBar(content: Text(r.summary)));
        _exitSelection();

      case _BatchAction.editTags:
        // 多个图集时以标签并集作为初始状态。
        final initial = <String>{};
        for (final g in targets) {
          initial.addAll(g.tags);
        }
        final picked = await showTagEditor(
          context,
          title: '批量编辑标签（${targets.length} 个）',
          initial: initial.toList(),
        );
        if (picked == null || picked.isEmpty) return;
        final r = await _repo.batchSetTags(
          targets,
          add: picked.add,
          remove: picked.remove,
        );
        messenger.showSnackBar(SnackBar(content: Text(r.summary)));
        _exitSelection();

      case _BatchAction.sortImages:
        final choice = await showGallerySortEditor(
          context,
          galleries: targets,
          globalField: _repo.settings.sortField,
          globalDescending: _repo.settings.descending,
        );
        if (choice == null) return;
        final r = await _repo.batchSetGallerySort(
          targets,
          field: choice.followGlobal ? null : choice.field,
          descending: choice.followGlobal ? null : choice.descending,
        );
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              r.succeeded > 0
                  ? (choice.followGlobal
                        ? '${targets.length} 个图集已改为跟随全局排序'
                        : '${targets.length} 个图集已单独设置排序')
                  : '没有改动',
            ),
          ),
        );
        _exitSelection();

      case _BatchAction.move:
        final target = await _askMoveTarget(targets);
        if (target == null) return;
        final r = await _repo.batchMove(targets, targetIndex: target);
        messenger.showSnackBar(SnackBar(content: Text(r.summary)));
        _exitSelection();

      case _BatchAction.remove:
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('从列表移除 ${targets.length} 个图集？'),
            content: const Text(
              '只会移除本软件的记录（含封面缓存），'
              '磁盘上的压缩包与文件夹不会被删除或移动。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('移除'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        final r = await _repo.batchRemoveFromIndex(targets);
        messenger.showSnackBar(SnackBar(content: Text(r.summary)));
        _exitSelection();
    }
    if (mounted) setState(() {});
  }

  /// 询问移动到列表中的哪个位置。
  Future<int?> _askMoveTarget(List<Gallery> targets) async {
    final controller = TextEditingController(text: '1');
    final total = _repo.galleries.length;
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移动到第几位'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '当前共 $total 个图集。填写目标序号（1 = 最前）。\n'
              '只改变软件内显示顺序，不移动任何文件。',
              style: const TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: '例如 1'),
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
            child: const Text('移动'),
          ),
        ],
      ),
    );
    final n = int.tryParse((text ?? '').trim());
    if (n == null || n < 1) return null;
    return n - 1;
  }
}

/// 多选状态下的批量操作种类。
enum _BatchAction {
  update,
  addToCollection,
  removeFromCollection,
  editTags,
  sortImages,
  move,
  remove,
}

/// 底部批量操作栏。
class _SelectionActionBar extends StatelessWidget {
  const _SelectionActionBar({required this.count, required this.onAction});

  final int count;
  final ValueChanged<_BatchAction> onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF16161A),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _btn(Icons.refresh, '更新', _BatchAction.update),
              _btn(
                Icons.bookmark_add_outlined,
                '收藏',
                _BatchAction.addToCollection,
              ),
              _btn(
                Icons.bookmark_remove_outlined,
                '移出',
                _BatchAction.removeFromCollection,
              ),
              _btn(Icons.sell_outlined, '标签', _BatchAction.editTags),
              _btn(Icons.sort, '排序', _BatchAction.sortImages),
              _btn(Icons.swap_vert, '换位', _BatchAction.move),
              _btn(Icons.delete_outline, '移除', _BatchAction.remove),
            ],
          ),
        ),
      ),
    );
  }

  Widget _btn(IconData icon, String label, _BatchAction action) {
    return Expanded(
      child: InkWell(
        onTap: count == 0 ? null : () => onAction(action),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 20,
              color: count == 0
                  ? const Color(0xFF4A4D57)
                  : const Color(0xFFB9BCC4),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                color: count == 0
                    ? const Color(0xFF4A4D57)
                    : const Color(0xFFB9BCC4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasQuery});
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasQuery ? Icons.search_off : Icons.photo_library_outlined,
              size: 44,
              color: const Color(0xFF4A4D57),
            ),
            const SizedBox(height: 14),
            Text(
              hasQuery ? '没有匹配的图集' : '还没有图集',
              style: const TextStyle(fontSize: 15, color: Color(0xFFB9BCC4)),
            ),
            const SizedBox(height: 6),
            Text(
              hasQuery ? '换个关键词，或清除搜索' : '点右下角 + 导入 zip 压缩包或文件夹',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF6E7280)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分页控件。
class _Pager extends StatelessWidget {
  const _Pager({
    required this.page,
    required this.pageCount,
    required this.total,
    required this.pageSize,
    required this.onJump,
  });

  final int page;
  final int pageCount;
  final int total;
  final int pageSize;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      decoration: const BoxDecoration(
        color: Color(0xFF16161A),
        border: Border(top: BorderSide(color: Color(0xFF26262C))),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            onPressed: page > 0 ? () => onJump(page - 1) : null,
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: _pageButtons(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: page < pageCount - 1 ? () => onJump(page + 1) : null,
          ),
        ],
      ),
    );
  }

  /// 页数很多时只显示当前页附近的按钮，避免溢出。
  List<Widget> _pageButtons() {
    final buttons = <Widget>[];
    const window = 2;
    final from = (page - window).clamp(0, pageCount - 1);
    final to = (page + window).clamp(0, pageCount - 1);

    if (from > 0) {
      buttons.add(_dot(0));
      if (from > 1) buttons.add(const _Ellipsis());
    }
    for (var i = from; i <= to; i++) {
      buttons.add(_dot(i));
    }
    if (to < pageCount - 1) {
      if (to < pageCount - 2) buttons.add(const _Ellipsis());
      buttons.add(_dot(pageCount - 1));
    }
    return buttons;
  }

  Widget _dot(int i) {
    final selected = i == page;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: TextButton(
        onPressed: selected ? null : () => onJump(i),
        style: TextButton.styleFrom(
          minimumSize: const Size(34, 30),
          padding: EdgeInsets.zero,
          foregroundColor: selected
              ? const Color(0xFFE6E6E9)
              : const Color(0xFF8B8F98),
          backgroundColor: selected ? const Color(0xFF2A2F3A) : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
        child: Text('${i + 1}', style: const TextStyle(fontSize: 12.5)),
      ),
    );
  }
}

class _Ellipsis extends StatelessWidget {
  const _Ellipsis();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 2),
    child: Text('…', style: TextStyle(color: Color(0xFF6E7280))),
  );
}

/// 单个图集卡片：封面 + 名称 + 张数。
///
/// 交互（按需求）：
///  * 普通模式：单击进入阅读；**长按进入多选**；右上角三点按钮打开菜单。
///  * 多选模式：单击切换选中，不进入阅读。
class _GalleryTile extends StatelessWidget {
  const _GalleryTile({
    required this.gallery,
    required this.onChanged,
    this.selecting = false,
    this.selected = false,
    this.onLongPressSelect,
    this.onTapSelect,
  });

  final Gallery gallery;
  final VoidCallback onChanged;

  /// 当前是否处于多选模式。
  final bool selecting;

  /// 本卡片是否被选中。
  final bool selected;

  final VoidCallback? onLongPressSelect;
  final VoidCallback? onTapSelect;

  @override
  Widget build(BuildContext context) {
    final coverFile = gallery.coverCachePath == null
        ? null
        : File(gallery.coverCachePath!);
    final hasCover = coverFile != null && coverFile.existsSync();

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () async {
        if (selecting) {
          onTapSelect?.call();
          return;
        }
        await GalleryRepository.instance.markOpened(gallery);
        if (!context.mounted) return;
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => ViewerPage(gallery: gallery)));
        onChanged();
      },
      // 长按进入多选（原有的长按菜单已改为三点按钮）。
      onLongPress: onLongPressSelect,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Container(
                    color: const Color(0xFF1B1B1F),
                    child: hasCover
                        ? Image.file(
                            coverFile,
                            fit: BoxFit.cover,
                            // 列表封面不需要原图分辨率，限定解码尺寸以省内存。
                            cacheWidth: 380,
                            filterQuality: FilterQuality.low,
                            errorBuilder: (_, _, _) => const _CoverFallback(),
                          )
                        : const _CoverFallback(),
                  ),
                ),
                // 三点菜单入口：仅普通模式显示，避免与多选的状态标记重叠。
                if (!selecting)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: _TileMenuButton(
                      gallery: gallery,
                      onChanged: onChanged,
                    ),
                  ),
                // 多选状态标记
                if (selecting)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected
                            ? const Color(0xFF6E8BB5)
                            : const Color(0x99000000),
                        border: Border.all(
                          color: selected
                              ? const Color(0xFF6E8BB5)
                              : const Color(0xFFB9BCC4),
                          width: 1.5,
                        ),
                      ),
                      child: selected
                          ? const Icon(
                              Icons.check,
                              size: 14,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
                // 观看进度条：贴在封面底部的一条细线。
                // 比纯文字更直观 —— 扫一眼就知道哪些图集看过一部分。
                if (!selecting && gallery.lastIndex != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(9),
                        ),
                        child: LinearProgressIndicator(
                          value: gallery.progress,
                          minHeight: 3,
                          backgroundColor: const Color(0x66000000),
                          valueColor: AlwaysStoppedAnimation(
                            gallery.isFinished
                                ? const Color(0xFF6E7280)
                                : const Color(0xFF4C8DF6),
                          ),
                        ),
                      ),
                    ),
                  ),
                // 「已翻译」角标：长在原图集上，点它直接在这本图集里看译文
                // （不必开菜单）。判据是 translatedPages > 0。
                if (!selecting && gallery.hasTranslation)
                  Positioned(
                    left: 5,
                    bottom: gallery.lastIndex != null ? 8 : 5,
                    child: _TranslatedBadge(
                      gallery: gallery,
                      onChanged: onChanged,
                    ),
                  ),
                // 选中时给封面压一层淡色，视觉上更明确
                if (selecting && selected)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(9),
                          color: const Color(0x336E8BB5),
                          border: Border.all(
                            color: const Color(0xFF6E8BB5),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 名称放不下时自动滚动显示全文：图集名常常前几十个字符都相同
          // （同一合集的不同卷），用省略号恰好把区别最大的尾部裁掉了。
          AutoScrollText(
            gallery.title,
            style: const TextStyle(fontSize: 13, color: Color(0xFFE6E6E9)),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(
                gallery.isFolder
                    ? Icons.folder_outlined
                    : Icons.folder_zip_outlined,
                size: 12,
                color: const Color(0xFF6E7280),
              ),
              const SizedBox(width: 4),
              Text(
                '${gallery.imageCount} 张',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(0xFF8B8F98),
                ),
              ),
              // 观看进度：读到第几张。没有进度时不显示，避免占位置。
              if (gallery.lastIndex != null && gallery.imageCount > 0) ...[
                const SizedBox(width: 6),
                Text(
                  gallery.isFinished
                      ? '· 已读完'
                      : '· 读到 ${gallery.lastIndex! + 1}',
                  style: TextStyle(
                    fontSize: 11.5,
                    // 已读完用淡色，未读完用亮一点的颜色提示"还有没看的"。
                    color: gallery.isFinished
                        ? const Color(0xFF6E7280)
                        : const Color(0xFF8FB6E8),
                  ),
                ),
              ],
              if (gallery.tags.isNotEmpty) ...[
                const SizedBox(width: 6),
                const Icon(
                  Icons.sell_outlined,
                  size: 11,
                  color: Color(0xFF6E8BB5),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 封面左下角的「已翻译」角标。
///
/// 命中区域独立于整个卡片：点角标在本图集里看译文，点其它地方还是开原图集。
class _TranslatedBadge extends StatelessWidget {
  const _TranslatedBadge({required this.gallery, required this.onChanged});

  final Gallery gallery;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xCC1B2A22),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0x885E9E6E)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.translate, size: 11, color: Color(0xFF8FC9A0)),
            SizedBox(width: 3),
            Text(
              '已翻译',
              style: TextStyle(
                fontSize: 10.5,
                height: 1.1,
                color: Color(0xFF8FC9A0),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点角标：打开**这本原图集**，定位到第一页有译文的页并先显示译文。
  ///
  /// 译文挂在原图集上，不再有「翻译图集」可跳。找不到译文页就什么都不做：
  /// 角标本身已经说明状态，弹错只会打扰。
  Future<void> _open(BuildContext context) async {
    final page = TranslationSetStore.instance.firstPageOf(gallery.id);
    if (page == null) return;
    final repo = GalleryRepository.instance;
    // 用索引里的实例：封面这层拿到的可能是上一次构建的快照。
    final fresh = repo.byId(gallery.id) ?? gallery;
    await repo.markOpened(fresh);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ViewerPage(
          gallery: fresh,
          initialIndex: page,
          startTranslated: true,
        ),
      ),
    );
    onChanged();
  }
}

/// 卡片右上角的三点菜单按钮。
class _TileMenuButton extends StatelessWidget {
  const _TileMenuButton({required this.gallery, required this.onChanged});

  final Gallery gallery;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) =>
      TileMenuButton(gallery: gallery, onChanged: onChanged);
}

/// 封面右上角的三点按钮（图集列表与收藏夹共用同一外观与菜单）。
///
/// 公开出来是为了让收藏夹页面复用 —— 两边行为一致，用户不必学两套。
class TileMenuButton extends StatelessWidget {
  const TileMenuButton({
    super.key,
    required this.gallery,
    required this.onChanged,
    this.onLocate,
  });

  final Gallery gallery;
  final VoidCallback onChanged;

  /// 可选：跳转到该图集在「图集」列表里的位置。
  /// 只有收藏夹这类"引用别处图集"的场合才需要传。
  final VoidCallback? onLocate;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0x88000000),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () =>
            showGalleryMenu(context, gallery, onChanged, onLocate: onLocate),
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: Icon(Icons.more_vert, size: 16, color: Color(0xFFE6E6E9)),
        ),
      ),
    );
  }
}

/// 图集菜单（三点按钮唤起）。原长按菜单的内容迁移到这里，并新增「更新」。
///
/// [onLocate] 非空时会在菜单顶部加一项「在图集列表中定位」——
/// 收藏夹里的图集来自别处，需要能跳回它在完整列表中的位置。
Future<void> showGalleryMenu(
  BuildContext context,
  Gallery gallery,
  VoidCallback onChanged, {
  VoidCallback? onLocate,
}) async {
  final repo = GalleryRepository.instance;
  final messenger = ScaffoldMessenger.of(context);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: kSheetIsScrollControlled,
    builder: (ctx) => SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                gallery.title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (onLocate != null)
            ListTile(
              leading: const Icon(Icons.my_location_outlined),
              title: const Text('在图集列表中定位'),
              subtitle: const Text(
                '跳到「图集」页并滚动到它所在的位置',
                style: TextStyle(fontSize: 11.5),
              ),
              onTap: () {
                Navigator.pop(ctx);
                onLocate();
              },
            ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('更新'),
            subtitle: Text(
              gallery.isFolder ? '重新扫描该目录，看看有没有新增图片' : '压缩包图集不支持更新',
              style: const TextStyle(fontSize: 11.5),
            ),
            onTap: () async {
              Navigator.pop(ctx);
              final r = await repo.updateGallery(gallery);
              messenger.showSnackBar(SnackBar(content: Text(r.message)));
              onChanged();
            },
          ),
          ListTile(
            leading: const Icon(Icons.translate),
            title: const Text('翻译'),
            subtitle: Text(
              repo.byId(gallery.id)?.hasTranslation ?? false
                  ? '这本已经翻译过：点封面角标看译文，点这里可以继续翻'
                  : '调用翻译服务把整本翻成另一种语言，译文挂在原图集上',
              style: const TextStyle(fontSize: 11.5),
            ),
            onTap: () {
              Navigator.pop(ctx);
              // 用外层 context：本菜单的 ctx 在关闭后立刻失效。
              showTranslationStart(context, gallery);
            },
          ),
          ListTile(
            leading: const Icon(Icons.replay),
            title: const Text('重译指定页…'),
            subtitle: const Text(
              '删掉第 N–M 页已生成的译文图片并只重翻这一段；原始图片不动',
              style: TextStyle(fontSize: 11.5),
            ),
            enabled: repo.byId(gallery.id)?.hasTranslation ?? false,
            onTap: () {
              Navigator.pop(ctx);
              showRetranslateFlow(context, gallery);
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('重命名'),
            onTap: () {
              Navigator.pop(ctx);
              _renameGallery(context, gallery, onChanged);
            },
          ),
          ListTile(
            leading: const Icon(Icons.sell_outlined),
            title: const Text('编辑标签'),
            onTap: () {
              Navigator.pop(ctx);
              _editGalleryTags(context, gallery, onChanged);
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_special_outlined),
            title: const Text('加入收藏夹'),
            subtitle: const Text(
              '可在此直接新建收藏夹',
              style: TextStyle(fontSize: 11.5),
            ),
            onTap: () async {
              Navigator.pop(ctx);
              // 需求：三点菜单里也能加入收藏夹（此前只有多选能加）。
              final picked = await showCollectionPicker(
                context,
                title: '加入收藏夹',
                memberIds: {gallery.id},
              );
              if (picked == null) return;
              final r = await repo.batchToggleCollection(picked, [
                gallery,
              ], add: true);
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    r.skipped > 0
                        ? '已经在「${picked.name}」里了'
                        : '已加入「${picked.name}」',
                  ),
                ),
              );
              onChanged();
            },
          ),
          ListTile(
            leading: const Icon(Icons.sort),
            title: const Text('图片排序'),
            subtitle: Text(
              // 显示本图集当前生效的排序，并标明是否跟随全局。
              gallery.ownSortLabel(
                repo.settings.sortField,
                repo.settings.descending,
              ),
              style: const TextStyle(fontSize: 11.5),
            ),
            onTap: () async {
              Navigator.pop(ctx);
              final choice = await showGallerySortEditor(
                context,
                galleries: [gallery],
                globalField: repo.settings.sortField,
                globalDescending: repo.settings.descending,
              );
              if (choice == null) return;
              await repo.setGallerySort(
                gallery,
                field: choice.followGlobal ? null : choice.field,
                descending: choice.followGlobal ? null : choice.descending,
              );
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    choice.followGlobal ? '已改为跟随全局排序' : '已单独设置本图集的图片排序',
                  ),
                ),
              );
              onChanged();
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('信息来源'),
            subtitle: Text(
              gallery.sourcePath,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
          if (gallery.hasTranslation)
            ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('清除翻译关联'),
              subtitle: const Text(
                '只清除关联记录，不删除任何文件',
                style: TextStyle(fontSize: 11.5),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                await TranslationSetStore.instance.remove(gallery.id);
                final g = repo.byId(gallery.id) ?? gallery;
                await repo.setTranslatedPages(g, 0);
                repo.notifyChanged();
                messenger.showSnackBar(
                  const SnackBar(content: Text('已清除翻译关联，译文文件都还在原目录里')),
                );
                onChanged();
              },
            ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Color(0xFFC98A8A)),
            title: const Text(
              '从列表移除',
              style: TextStyle(color: Color(0xFFC98A8A)),
            ),
            // 措辞必须准确：只移除索引，绝不动磁盘文件。
            subtitle: const Text('只移除本软件的记录，不会删除或移动原文件；翻译结果不受影响'),
            onTap: () {
              Navigator.pop(ctx);
              _confirmRemoveGallery(context, gallery, onChanged);
            },
          ),
          const SizedBox(height: 6),
        ],
      ),
    ),
  );
}

Future<void> _renameGallery(
  BuildContext context,
  Gallery gallery,
  VoidCallback onChanged,
) async {
  final controller = TextEditingController(text: gallery.title);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重命名图集'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '图集名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  if (name != null) {
    await GalleryRepository.instance.rename(gallery, name);
    onChanged();
  }
}

Future<void> _editGalleryTags(
  BuildContext context,
  Gallery gallery,
  VoidCallback onChanged,
) async {
  final picked = await showTagEditor(
    context,
    title: '编辑标签',
    initial: gallery.tags,
  );
  if (picked == null || picked.isEmpty) return;
  await GalleryRepository.instance.applyTagDelta(
    gallery,
    add: picked.add,
    remove: picked.remove,
  );
  onChanged();
}

Future<void> _confirmRemoveGallery(
  BuildContext context,
  Gallery gallery,
  VoidCallback onChanged,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('从列表移除？'),
      content: Text(
        '「${gallery.title}」将不再显示在本软件中。\n\n'
        '原文件不会被删除或移动：\n${gallery.sourcePath}',
        style: const TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('移除'),
        ),
      ],
    ),
  );
  if (ok == true) {
    await GalleryRepository.instance.removeFromIndex(gallery);
    onChanged();
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Icon(Icons.image_outlined, size: 26, color: Color(0xFF3C3F49)),
    );
  }
}

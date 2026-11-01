import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/repository.dart';
import 'gallery_list_page.dart';
import 'viewer_page.dart';

/// 收藏夹：把图集归入不同的夹。
///
/// 硬约束：收藏夹**只改变软件内显示**，绝不移动、改名或删除任何文件。
class CollectionsPage extends StatefulWidget {
  const CollectionsPage({super.key, this.onLocateGallery});

  /// 跳转到某个图集在「图集」页里的位置。
  ///
  /// 由根壳层注入：切页由壳层负责，滚动定位由图集列表页负责。
  /// 为空时菜单里不显示"定位"这一项（例如单页调试时）。
  final void Function(String galleryId)? onLocateGallery;

  @override
  State<CollectionsPage> createState() => _CollectionsPageState();
}

class _CollectionsPageState extends State<CollectionsPage> {
  final _repo = GalleryRepository.instance;

  @override
  void initState() {
    super.initState();
    // 监听仓库变更：在别的页面（图集列表的三点菜单 / 多选）新建收藏夹或
    // 增删成员后，这里要立刻反映出来。此前没有监听，加上根壳用 IndexedStack
    // 让页面一直存活，导致"必须重启应用才能看到"。
    _repo.revision.addListener(_onRepoChanged);
  }

  @override
  void dispose() {
    _repo.revision.removeListener(_onRepoChanged);
    super.dispose();
  }

  void _onRepoChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final collections = _repo.collections;

    return Scaffold(
      appBar: AppBar(
        title: Text('收藏夹 (${collections.length})'),
        actions: [
          IconButton(
            tooltip: '新建收藏夹',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: () => _createCollection(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: collections.isEmpty
          ? const _EmptyCollections()
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: collections.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _CollectionTile(
                collection: collections[i],
                onChanged: () => setState(() {}),
                onLocateGallery: widget.onLocateGallery,
              ),
            ),
    );
  }

  Future<void> _createCollection(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建收藏夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '收藏夹名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await _repo.createCollection(name);
      if (mounted) setState(() {});
    }
  }
}

class _EmptyCollections extends StatelessWidget {
  const _EmptyCollections();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmarks_outlined, size: 44, color: Color(0xFF4A4D57)),
            SizedBox(height: 14),
            Text(
              '还没有收藏夹',
              style: TextStyle(fontSize: 15, color: Color(0xFFB9BCC4)),
            ),
            SizedBox(height: 6),
            Text(
              '新建收藏夹后，可把不同图集归入其中。\n只影响本软件的显示，不会移动任何文件。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: Color(0xFF6E7280)),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  const _CollectionTile({
    required this.collection,
    required this.onChanged,
    this.onLocateGallery,
  });

  final Collection collection;
  final VoidCallback onChanged;
  final void Function(String galleryId)? onLocateGallery;

  @override
  Widget build(BuildContext context) {
    final items = GalleryRepository.instance.galleriesOf(collection);

    return ExpansionTile(
      leading: const Icon(Icons.folder_special_outlined),
      title: Text(collection.name),
      subtitle: Text('${items.length} 个图集'),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 20),
        onSelected: (v) async {
          if (v == 'rename') {
            await _rename(context);
          } else if (v == 'delete') {
            await _delete(context);
          }
          onChanged();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('重命名')),
          PopupMenuItem(
            value: 'delete',
            child: Text('删除收藏夹', style: TextStyle(color: Color(0xFFC98A8A))),
          ),
        ],
      ),
      children: [
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '这个收藏夹还是空的。长按图集可以加入收藏夹。',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF6E7280)),
              ),
            ),
          )
        else
          ...items.map(
            (g) => _CollectionGalleryRow(
              gallery: g,
              collection: collection,
              onChanged: onChanged,
              onLocateGallery: onLocateGallery,
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: collection.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名收藏夹'),
        content: TextField(controller: controller, autofocus: true),
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
    if (name != null) {
      await GalleryRepository.instance.renameCollection(collection, name);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除收藏夹「${collection.name}」？'),
        content: const Text('只会删除这个收藏夹分类，图集本身和磁盘文件都不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await GalleryRepository.instance.deleteCollection(collection);
    }
  }
}

/// 收藏夹里的一个图集条目。
///
/// 与图集列表保持一致的快捷操作：点条目看、右侧三点打开**同一个菜单**
/// （更新／重命名／标签／加入收藏夹／图片排序／移出／移除），
/// 外加「在图集列表中定位」—— 收藏夹里的图集来自别处，需要能跳回原位。
class _CollectionGalleryRow extends StatelessWidget {
  const _CollectionGalleryRow({
    required this.gallery,
    required this.collection,
    required this.onChanged,
    this.onLocateGallery,
  });

  final Gallery gallery;
  final Collection collection;
  final VoidCallback onChanged;
  final void Function(String galleryId)? onLocateGallery;

  @override
  Widget build(BuildContext context) {
    final progress = gallery.lastIndex;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      leading: _MiniCover(gallery: gallery),
      title: Text(gallery.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${gallery.imageCount} 张'
        '${progress == null ? '' : (gallery.isFinished ? ' · 已读完' : ' · 读到 ${progress + 1}')}',
        style: const TextStyle(fontSize: 11.5),
      ),
      onTap: () async {
        await GalleryRepository.instance.markOpened(gallery);
        if (!context.mounted) return;
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => ViewerPage(gallery: gallery)));
        onChanged();
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 18),
            tooltip: '移出收藏夹',
            // 只是从夹里移除，不涉及任何文件操作。
            onPressed: () async {
              await GalleryRepository.instance.toggleInCollection(
                collection,
                gallery,
              );
              onChanged();
            },
          ),
          // 与图集列表用同一个组件、同一个菜单 —— 两边行为一致。
          TileMenuButton(
            gallery: gallery,
            onChanged: onChanged,
            onLocate: onLocateGallery == null
                ? null
                : () => onLocateGallery!(gallery.id),
          ),
        ],
      ),
    );
  }
}

/// 收藏夹条目左侧的小封面（复用图集列表已生成的缩略图缓存）。
class _MiniCover extends StatelessWidget {
  const _MiniCover({required this.gallery});

  final Gallery gallery;

  @override
  Widget build(BuildContext context) {
    final path = gallery.coverCachePath;
    return SizedBox(
      width: 34,
      height: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: path == null
            ? const ColoredBox(
                color: Color(0xFF23232A),
                child: Icon(
                  Icons.image_outlined,
                  size: 16,
                  color: Color(0xFF6E7280),
                ),
              )
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                cacheWidth: 68,
                errorBuilder: (_, _, _) => const ColoredBox(
                  color: Color(0xFF23232A),
                  child: Icon(
                    Icons.broken_image_outlined,
                    size: 16,
                    color: Color(0xFF6E7280),
                  ),
                ),
              ),
      ),
    );
  }
}

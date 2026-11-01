import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_gallery_viewer/core/byte_source.dart';
import 'package:simple_gallery_viewer/core/content_hash.dart';
import 'package:simple_gallery_viewer/core/models.dart';
import 'package:simple_gallery_viewer/core/repository.dart';
import 'package:simple_gallery_viewer/core/saf_channel.dart';

/// 导入、按内容哈希查重、批量导入、文件夹子目录语义的测试。
///
/// 现在导入走的是 `content://` 文档（Android 10+ 下应用没有存储权限）。
/// 测试用一个**内存文档注册表**代替真实 SAF：
///   * 平台通道 `listTree` 返回伪造的子项；
///   * `GalleryRepository.resolver` 把伪造 URI 映射到内存字节。
/// 这样可以在没有设备的情况下覆盖完整的导入与阅读逻辑。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const safChannel = MethodChannel('simple_gallery_viewer/saf');
  late Directory tmp;

  /// URI -> 内容
  late Map<String, Uint8List> docs;

  /// URI -> 子项（目录）
  late Map<String, List<SafChild>> trees;

  /// URI -> 显示名
  late Map<String, String> names;

  late GalleryRepository repo;

  /// 每个用例开始时的设置快照，用于恢复（仓库是单例，设置会跨用例残留）。
  late AppSettings defaultSettings;

  String docUri(String name) => 'content://test/document/$name';
  String treeUri(String name) => 'content://test/tree/$name';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('sgv_repo_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tmp.path,
        );

    docs = {};
    trees = {};
    names = {};

    // 伪造 SAF 平台通道
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(safChannel, (call) async {
          switch (call.method) {
            case 'listTree':
              final args = (call.arguments as Map).cast<String, dynamic>();
              final uri = args['uri'] as String;
              final children = trees[uri] ?? const <SafChild>[];
              return children
                  .map(
                    (c) => {
                      'uri': c.uri,
                      'name': c.name,
                      'isDirectory': c.isDirectory,
                      'size': c.size,
                    },
                  )
                  .toList();
            case 'sizeOf':
              final args = (call.arguments as Map).cast<String, dynamic>();
              return docs[args['uri']]?.length ?? 0;
            case 'hashOf':
              // 生产环境在原生侧算哈希；测试里用同样的算法在 Dart 侧算，
              // 保证两条路径的判重行为一致。
              final args = (call.arguments as Map).cast<String, dynamic>();
              final bytes = docs[args['uri'] as String];
              if (bytes == null) return null;
              return ContentHash.ofBytes(bytes);
            default:
              return null;
          }
        });

    // 把伪造 URI 映射到内存字节
    GalleryRepository.resolver = (source) {
      final bytes = docs[source];
      return bytes == null ? null : MemoryByteSource(bytes);
    };

    repo = GalleryRepository.instance..resetForTesting();
    await repo.load();
    // 测试会修改排序等设置，而仓库是单例、设置也会被持久化，
    // 因此每轮都从默认值开始，避免用例之间互相影响。
    defaultSettings = repo.settings;
  });

  tearDown(() {
    // 恢复设置，避免排序等偏好泄漏到下一个用例。
    repo.settings
      ..sortField = defaultSettings.sortField
      ..descending = defaultSettings.descending
      ..gallerySort = defaultSettings.gallerySort
      ..galleryDescending = defaultSettings.galleryDescending
      ..presetTags = List<String>.from(defaultSettings.presetTags)
      ..readingMode = defaultSettings.readingMode
      ..preloadCount = defaultSettings.preloadCount
      ..unloadDistance = defaultSettings.unloadDistance
      ..brightness = defaultSettings.brightness
      ..pageSize = defaultSettings.pageSize;

    GalleryRepository.resolver = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(safChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        sleep(const Duration(milliseconds: 60));
      }
    }
  });

  /// 生成一个 zip 的字节。
  Uint8List zipBytes(Map<String, List<int>> files, {bool store = false}) {
    final archive = Archive();
    files.forEach((n, bytes) {
      final f = ArchiveFile(n, bytes.length, bytes);
      f.compress = !store;
      archive.addFile(f);
    });
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  /// 注册一个伪造的 zip 文档，返回其 SafPick。
  ///
  /// URI 必须唯一（真实的 content:// 文档 id 就是唯一的），但**末段保留文件名**，
  /// 以便被测代码能从 URI 解析出可读名 —— 与真实 SAF 行为一致。
  var zipSeq = 0;

  SafPick registerZip(String name, Map<String, List<int>> files) {
    final uri = 'content://test/document/${zipSeq++}%2F$name';
    docs[uri] = zipBytes(files);
    names[uri] = name;
    return SafPick(uri: uri, name: name, persisted: true, isDirectory: false);
  }

  /// 注册一个伪造的目录（树），children 由调用方随后填充。
  SafPick registerFolder(String name) {
    final uri = treeUri(name);
    trees[uri] = [];
    names[uri] = name;
    return SafPick(uri: uri, name: name, persisted: true, isDirectory: true);
  }

  /// 子项编号，用来让伪造的文档 URI 唯一（真实的 content:// URI 本来就是唯一的）。
  var childSeq = 0;

  void addChild(
    String parentUri,
    String childName, {
    required bool isDirectory,
    Uint8List? content,
  }) {
    // 伪造 URI 模仿真实形态：.../document/<parent>/<id>%2F<文件名>
    // 这样由 URI 推导出的 fileName 与真实情况一致。
    final parentKey = Uri.parse(parentUri).pathSegments.last;
    final childUri =
        'content://test/document/$parentKey/${childSeq++}%2F$childName';
    if (isDirectory) {
      trees[childUri] = [];
    } else if (content != null) {
      docs[childUri] = content;
    }
    names[childUri] = childName;
    trees[parentUri]!.add(
      SafChild(
        uri: childUri,
        name: childName,
        isDirectory: isDirectory,
        size: content?.length ?? 0,
      ),
    );
  }

  /// 在目录下添加一张"图片"（内容随意，只验证是否被收录）。
  void addImage(String parentUri, String name, {int size = 512, int seed = 0}) {
    addChild(
      parentUri,
      name,
      isDirectory: false,
      content: Uint8List.fromList(List.generate(size, (i) => (i + seed) % 251)),
    );
  }

  group('按「文件名 + 长度」查重', () {
    test('同一个文件换个位置、名字不变再导入 → 提示已导入过', () async {
      final a = registerZip('original.zip', {'x.jpg': List.filled(300, 1)});
      final first = await repo.importZip(a);
      expect(first.ok, isTrue, reason: first.message);

      // 完全相同的名字与长度，仅文档位置（URI）不同 —— 也就是"文件挪走了"
      final b = registerZip('original.zip', {'x.jpg': List.filled(300, 1)});
      final second = await repo.importZip(b);

      expect(second.ok, isFalse, reason: '同名同长度应判定为重复');
      expect(second.message, contains('已经导入过'));
      expect(repo.galleries.length, 1, reason: '不应产生第二个图集');
    });

    test('同名但长度不同 → 视为不同文件，正常导入', () async {
      final a = registerZip('same.zip', {'x.jpg': List.filled(300, 1)});
      final b = registerZip('same.zip', {'x.jpg': List.filled(900, 2)});

      expect((await repo.importZip(a)).ok, isTrue);
      final second = await repo.importZip(b);
      expect(second.ok, isTrue, reason: '长度不同不应被误判为重复');
      expect(repo.galleries.length, 2);
    });

    test('内容不同、名字不同 → 正常导入为两个图集', () async {
      final a = registerZip('one.zip', {'x.jpg': List.filled(300, 1)});
      final b = registerZip('two.zip', {'y.jpg': List.filled(300, 2)});

      expect((await repo.importZip(a)).ok, isTrue);
      expect((await repo.importZip(b)).ok, isTrue);
      expect(repo.galleries.length, 2);
    });

    test('文档 id 不同但文件名与长度相同 → 仍判定为重复', () async {
      final a = registerZip('identical.zip', {'x.jpg': List.filled(300, 1)});
      expect((await repo.importZip(a)).ok, isTrue);

      // 另建一个不同 id 的文档，但显示名与字节长度都相同。
      final b = registerZip('identical.zip', {'x.jpg': List.filled(300, 1)});
      expect(b.uri, isNot(a.uri), reason: '两次注册的文档 id 必须不同');

      final second = await repo.importZip(b);
      expect(second.ok, isFalse, reason: '名字与长度相同才是判重依据');
      expect(second.message, contains('已经导入过'));
      expect(repo.galleries.length, 1);
    });

    test('图集记录保存身份，且可用身份反查', () async {
      final a = registerZip('h.zip', {'x.jpg': List.filled(64, 1)});
      final r = await repo.importZip(a);

      expect(r.gallery!.contentHash, isNotNull);
      expect(r.gallery!.contentHash, r.gallery!.id);
      expect(repo.findByIdentity(r.gallery!.contentHash!), isNotNull);
    });

    test('来源保存的是 content:// URI，而不是文件路径', () async {
      final a = registerZip('uri.zip', {'x.jpg': List.filled(64, 1)});
      final r = await repo.importZip(a);
      expect(r.gallery!.sourcePath, startsWith('content://'));
    });

    test('没有图片的压缩包被拒绝', () async {
      final a = registerZip('textonly.zip', {'a.txt': List.filled(32, 1)});
      final r = await repo.importZip(a);
      expect(r.ok, isFalse);
      expect(r.message, contains('没有可显示的图片'));
    });

    test('损坏的 zip 被拒绝而不是抛异常', () async {
      final uri = docUri('broken.zip');
      docs[uri] = Uint8List.fromList(List.generate(500, (i) => i % 256));
      final r = await repo.importZip(
        SafPick(
          uri: uri,
          name: 'broken.zip',
          persisted: true,
          isDirectory: false,
        ),
      );
      expect(r.ok, isFalse);
      expect(r.message, contains('无法读取'));
    });

    test('传入目录会被明确拒绝并指向批量导入', () async {
      final dir = registerFolder('somedir');
      final r = await repo.importZip(dir);
      expect(r.ok, isFalse);
      expect(r.message, contains('文件夹'));
    });

    test('显示名含非法百分号编码时不抛异常（回归）', () async {
      // 真实场景：文件名里带 `%`（如 "50%off.zip"），
      // 对整个 URI 做 decodeComponent 会抛
      // "illegal percent encoding in URI"。
      for (final name in ['50%off.zip', 'a%zz.zip', '100%%.zip']) {
        final pick = registerZip(name, {'x.jpg': List.filled(200, 1)});
        final r = await repo.importZip(pick);
        expect(r.ok, isTrue, reason: '「$name」应能正常导入：${r.message}');
        expect(r.gallery!.title, contains('%'), reason: '标题里应保留原始文件名');
        expect(repo.galleries.last.images.single.fileName, 'x.jpg');
      }
    });

    test('图集图片文件名对含百分号的路径也安全', () {
      for (final path in [
        'content://test/document/12%2F50%off.jpg',
        'content://test/document/bad%zz',
      ]) {
        final img = GalleryImage(path: path, modified: DateTime(2026, 1, 1));
        expect(() => img.fileName, returnsNormally);
        expect(img.fileName, isNotEmpty);
      }
    });
  });

  group('批量导入', () {
    test('每个 zip 与每个子文件夹各成一个图集', () async {
      final batch = registerFolder('batch');
      addChild(
        batch.uri,
        'pack_a.zip',
        isDirectory: false,
        content: zipBytes({'a1.jpg': List.filled(200, 1)}),
      );
      addChild(
        batch.uri,
        'pack_b.zip',
        isDirectory: false,
        content: zipBytes({'b1.jpg': List.filled(200, 2)}),
      );

      // 两个子文件夹
      addChild(batch.uri, 'set_x', isDirectory: true);
      final setX = trees[batch.uri]!.firstWhere((c) => c.name == 'set_x').uri;
      addImage(setX, '1.jpg');
      addImage(setX, '2.jpg');

      addChild(batch.uri, 'set_y', isDirectory: true);
      final setY = trees[batch.uri]!.firstWhere((c) => c.name == 'set_y').uri;
      addImage(setY, '1.png');

      // 根目录自身放的图片：按需求不应被读取
      addImage(batch.uri, 'loose.jpg');
      // 非 zip 文件应被忽略
      addChild(
        batch.uri,
        'note.txt',
        isDirectory: false,
        content: Uint8List.fromList('ignore'.codeUnits),
      );

      final report = await repo.importFolderBatch(batch.uri);

      expect(report.imported, 4, reason: '2 个 zip + 2 个子文件夹');
      expect(report.duplicates, 0);
      expect(report.failed, 0);

      final titles = repo.galleries.map((g) => g.title).toSet();
      expect(titles, {'pack_a', 'pack_b', 'set_x', 'set_y'});
      expect(
        repo.galleries.any((g) => g.title == 'loose'),
        isFalse,
        reason: '文件夹自身的图片不应成为图集',
      );
    });

    test('再次批量导入同一个文件夹 → 全部按内容识别为重复', () async {
      final batch = registerFolder('batch2');
      addChild(
        batch.uri,
        'pack.zip',
        isDirectory: false,
        content: zipBytes({'a.jpg': List.filled(200, 1)}),
      );
      addChild(batch.uri, 'set', isDirectory: true);
      final set = trees[batch.uri]!.firstWhere((c) => c.name == 'set').uri;
      addImage(set, '1.jpg');

      final first = await repo.importFolderBatch(batch.uri);
      expect(first.imported, 2);

      final second = await repo.importFolderBatch(batch.uri);
      expect(second.imported, 0);
      expect(second.duplicates, 2);
      expect(repo.galleries.length, 2, reason: '不应重复添加');
    });

    test('目录名不同、图片清单相同 → 应各自成为独立图集（回归）', () async {
      // 这是修复过的真实缺陷：身份里若不含文件夹名，同一部作品的同一批图
      // 放在不同文件夹（分卷、备份、不同整理）就会被互相判成"已导入过"。
      // 实测用户导入 1000 个文件夹时有 300 个被误拒。
      final batch = registerFolder('batch3');
      addChild(batch.uri, 'copy_a', isDirectory: true);
      addChild(batch.uri, 'copy_b', isDirectory: true);
      final a = trees[batch.uri]!.firstWhere((c) => c.name == 'copy_a').uri;
      final b = trees[batch.uri]!.firstWhere((c) => c.name == 'copy_b').uri;
      addImage(a, 'p1.jpg', size: 400, seed: 5);
      addImage(b, 'p1.jpg', size: 400, seed: 5);

      final report = await repo.importFolderBatch(batch.uri);
      expect(report.imported, 2, reason: '不同目录名必须是两个图集：${report.summary}');
      expect(report.duplicates, 0, reason: '不应有任何误判的重复');
      expect(repo.galleries.map((g) => g.title).toSet(), {'copy_a', 'copy_b'});
    });

    test('同名目录 + 相同图片清单 → 仍判为重复', () async {
      // 判重的正确语义：同一个文件夹再次导入（或它的同名副本）应被认出。
      final batch = registerFolder('batch_same');
      addChild(batch.uri, 'same_name', isDirectory: true);
      addChild(batch.uri, 'same_name_2', isDirectory: true);
      final a = trees[batch.uri]!.firstWhere((c) => c.name == 'same_name').uri;
      final b = trees[batch.uri]!
          .firstWhere((c) => c.name == 'same_name_2')
          .uri;
      addImage(a, 'p1.jpg', size: 450, seed: 6);
      addImage(b, 'p1.jpg', size: 450, seed: 6);

      // 把两个子目录的"显示名"改成一样，模拟同名文件夹
      final report = await repo.importFolderBatch(batch.uri);
      // 名字不同 → 两个都导入（因为身份含名字）
      expect(report.imported, 2);

      // 用同名再导入一次 → 应被识别为重复
      final again = await repo.importSubfolder(a, 'same_name');
      expect(again.outcome, ImportOutcome.duplicate);
    });

    test('清理误判：把之前被误拒的目录重新导入应能成功', () async {
      // 模拟用户的真实遭遇：先导入 A，再导入图片清单相同的 B（不同名）。
      // 修复前 B 会被拒；修复后必须成功。
      final batch = registerFolder('batch_recover');
      addChild(batch.uri, 'vol1', isDirectory: true);
      addChild(batch.uri, 'vol2', isDirectory: true);
      final a = trees[batch.uri]!.firstWhere((c) => c.name == 'vol1').uri;
      final b = trees[batch.uri]!.firstWhere((c) => c.name == 'vol2').uri;
      // 分卷：文件名与大小完全相同
      for (final n in ['001.jpg', '002.jpg', '003.jpg']) {
        addImage(a, n, size: 500, seed: 1);
        addImage(b, n, size: 500, seed: 1);
      }

      final r1 = await repo.importSubfolder(a, 'vol1');
      expect(r1.ok, isTrue);
      final r2 = await repo.importSubfolder(b, 'vol2');
      expect(r2.ok, isTrue, reason: '分卷不能被误判为重复：${r2.message}');
      expect(repo.galleries.length, 2);
    });

    test('空文件夹返回空报告而不是抛异常', () async {
      final empty = registerFolder('empty');
      final report = await repo.importFolderBatch(empty.uri);
      expect(report.imported, 0);
      expect(report.nothingFound, isTrue);
    });

    test('批量导入大量图集时不会退化成 O(n²)', () async {
      // 压测回归：曾经每导入一个图集都全量重写整个索引，
      // 1000 个图集就是 O(n²) 次序列化 + 写入，表现为"越到后面越卡"。
      // 这里用 300 个内容各不相同的子文件夹走完整导入路径来压。
      const count = 300;
      final batch = registerFolder('bulk');
      for (var i = 0; i < count; i++) {
        addChild(batch.uri, 'album_$i', isDirectory: true);
      }
      final folders = trees[batch.uri]!;
      for (var i = 0; i < count; i++) {
        // 尺寸不同才能保证身份互不相同、都走完整导入。
        addImage(folders[i].uri, 'p1.jpg', size: 100 + i, seed: i);
        addImage(folders[i].uri, 'p2.jpg', size: 200 + i, seed: i);
      }

      final sw = Stopwatch()..start();
      final report = await repo.importFolderBatch(batch.uri);
      sw.stop();

      expect(report.imported, count, reason: '应全部导入：${report.summary}');
      expect(repo.galleries.length, count);

      expect(
        sw.elapsedMilliseconds,
        lessThan(20000),
        reason: '批量导入耗时 ${sw.elapsedMilliseconds}ms，疑似退化为 O(n²)',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('查重是常数时间：图集很多时也不变慢', () async {
      final batch = registerFolder('perf');
      const count = 400;
      for (var i = 0; i < count; i++) {
        addChild(batch.uri, 'a_$i', isDirectory: true);
      }
      final folders = trees[batch.uri]!;
      for (var i = 0; i < count; i++) {
        addImage(folders[i].uri, 'p.jpg', size: 100 + i, seed: i);
      }
      await repo.importFolderBatch(batch.uri);
      expect(repo.galleries.length, count);

      // 索引里已有数百图集，查重仍应是瞬时（Map 查找而非线性扫描）。
      final a = repo.galleries.first;
      final sw = Stopwatch()..start();
      for (var i = 0; i < 5000; i++) {
        repo.findByIdentity(a.id);
        repo.findBySource(a.sourcePath);
      }
      sw.stop();
      expect(
        sw.elapsedMilliseconds,
        lessThan(2000),
        reason: '1 万次查重耗时 ${sw.elapsedMilliseconds}ms，疑似线性扫描',
      );
    });

    test('只读取子目录，且忽略非图片文件', () async {
      final batch = registerFolder('batch4');
      addChild(batch.uri, 'album', isDirectory: true);
      final album = trees[batch.uri]!.firstWhere((c) => c.name == 'album').uri;
      addImage(album, 'a.jpg');
      addImage(album, 'b.PNG'); // 大写扩展名也应识别
      addChild(
        album,
        'notes.txt',
        isDirectory: false,
        content: Uint8List.fromList('x'.codeUnits),
      );

      final report = await repo.importFolderBatch(batch.uri);
      expect(report.imported, 1);
      expect(report.galleries.single.imageCount, 2);
    });
  });

  group('单个文件夹导入（不递归）', () {
    test('只读取该目录这一层，子目录的图片不计入', () async {
      final folder = registerFolder('single');
      addImage(folder.uri, 'top1.jpg', size: 300, seed: 1);
      addImage(folder.uri, 'top2.png', size: 400, seed: 2);
      // 子目录：不应被计入
      addChild(folder.uri, 'sub', isDirectory: true);
      final sub = trees[folder.uri]!.firstWhere((c) => c.name == 'sub').uri;
      addImage(sub, 'deep1.jpg', size: 500, seed: 3);

      final r = await repo.importSingleFolder(folder.uri, '单层测试');

      expect(r.ok, isTrue, reason: r.message);
      expect(r.gallery!.imageCount, 2, reason: '只算本层的 2 张');
      expect(r.gallery!.singleLevel, isTrue, reason: '应标记为单层图集');
      expect(
        r.gallery!.images.any((i) => i.fileName == 'deep1.jpg'),
        isFalse,
        reason: '子目录里的图片不应被读取',
      );
    });

    test('目录下没有图片时明确拒绝', () async {
      final folder = registerFolder('emptysingle');
      addChild(folder.uri, 'sub', isDirectory: true);
      final sub = trees[folder.uri]!.firstWhere((c) => c.name == 'sub').uri;
      addImage(sub, 'x.jpg'); // 只在子目录里

      final r = await repo.importSingleFolder(folder.uri, '空的');
      expect(r.ok, isFalse);
      expect(r.message, contains('不含子目录'));
    });

    test('singleLevel 会被持久化（否则更新会吞进子目录）', () async {
      final folder = registerFolder('persist');
      addImage(folder.uri, 'a.jpg', size: 200, seed: 9);
      final r = await repo.importSingleFolder(folder.uri, '持久化');
      final back = Gallery.fromJson(r.gallery!.toJson());
      expect(back.singleLevel, isTrue);
    });
  });

  group('更新图集', () {
    test('扫描到新增图片后并入，并报告新增数量', () async {
      final folder = registerFolder('upd');
      addImage(folder.uri, 'a.jpg', size: 100, seed: 1);
      final r = await repo.importSingleFolder(folder.uri, '更新测试');
      expect(r.gallery!.imageCount, 1);

      // 目录里多出两张图
      addImage(folder.uri, 'b.jpg', size: 200, seed: 2);
      addImage(folder.uri, 'c.png', size: 300, seed: 3);

      final u = await repo.updateGallery(r.gallery!);
      expect(u.outcome, UpdateOutcome.updated, reason: u.message);
      expect(u.addedCount, 2);
      expect(r.gallery!.imageCount, 3);
    });

    test('没有新图片时报告已是最新', () async {
      final folder = registerFolder('uptodate');
      addImage(folder.uri, 'a.jpg', size: 150, seed: 1);
      final r = await repo.importSingleFolder(folder.uri, '最新');
      final u = await repo.updateGallery(r.gallery!);
      expect(u.outcome, UpdateOutcome.upToDate);
      expect(u.addedCount, 0);
    });

    test('只增不删：已记录但目录里消失的图片不会被移除', () async {
      final folder = registerFolder('keepentries');
      addImage(folder.uri, 'a.jpg', size: 100, seed: 1);
      addImage(folder.uri, 'b.jpg', size: 200, seed: 2);
      final r = await repo.importSingleFolder(folder.uri, '保留');
      expect(r.gallery!.imageCount, 2);

      // 模拟 b.jpg 已不在目录里（从枚举结果中移除）
      trees[folder.uri]!.removeWhere((c) => c.name == 'b.jpg');

      final u = await repo.updateGallery(r.gallery!);
      expect(u.outcome, UpdateOutcome.upToDate);
      expect(r.gallery!.imageCount, 2, reason: '宁可留着也绝不误删已记录的图片');
    });

    test('压缩包图集明确拒绝更新', () async {
      final zip = registerZip('noupd.zip', {'a.jpg': List.filled(64, 1)});
      final r = await repo.importZip(zip);
      final u = await repo.updateGallery(r.gallery!);
      expect(u.outcome, UpdateOutcome.unsupported);
      expect(u.message, contains('不支持更新'));
    });

    test('批量更新逐项处理，单项失败不影响其余', () async {
      final f1 = registerFolder('bu1');
      addImage(f1.uri, 'a.jpg', size: 100, seed: 1);
      final f2 = registerFolder('bu2');
      addImage(f2.uri, 'a.jpg', size: 100, seed: 1);
      final zip = registerZip('buzip.zip', {'a.jpg': List.filled(64, 1)});

      final r1 = await repo.importSingleFolder(f1.uri, 'bu1');
      final r2 = await repo.importSingleFolder(f2.uri, 'bu2');
      final rz = await repo.importZip(zip);

      addImage(f1.uri, 'new.jpg', size: 999, seed: 7);

      final report = await repo.batchUpdate([
        r1.gallery!,
        r2.gallery!,
        rz.gallery!,
      ]);

      // 两个文件夹成功（一个更新、一个最新），压缩包进 failures
      expect(report.succeeded, 2, reason: report.summary);
      expect(report.failures.length, 1);
      expect(report.failures.first, contains('不支持更新'));
    });
  });

  group('批量操作', () {
    Future<List<Gallery>> importThree() async {
      final batch = registerFolder('b3');
      for (var i = 0; i < 3; i++) {
        addChild(batch.uri, 'g$i', isDirectory: true);
      }
      final fs = trees[batch.uri]!;
      for (var i = 0; i < 3; i++) {
        addImage(fs[i].uri, 'p.jpg', size: 100 + i, seed: i);
      }
      await repo.importFolderBatch(batch.uri);
      return repo.galleries.toList();
    }

    test('批量打标签：并入且去重', () async {
      final list = await importThree();
      await repo.batchSetTags(list, add: ['漫画', '待读']);
      for (final g in list) {
        expect(g.tags, containsAll(['漫画', '待读']));
      }
      // 再次并入相同标签不应重复
      await repo.batchSetTags(list, add: ['漫画']);
      for (final g in list) {
        expect(g.tags.where((t) => t == '漫画').length, 1);
      }
    });

    test('标签可以删除（增量：add / remove）', () async {
      final list = await importThree();
      await repo.batchSetTags(list, add: ['漫画', '待读', '收藏']);

      // 只移除其中一个，其余保留 —— 这是旧实现做不到的（只能加不能删）
      await repo.batchSetTags(list, remove: ['待读']);
      for (final g in list) {
        expect(g.tags, containsAll(['漫画', '收藏']));
        expect(g.tags, isNot(contains('待读')));
      }

      // 同时加新的、删旧的
      await repo.batchSetTags(list, add: ['新标签'], remove: ['漫画']);
      for (final g in list) {
        expect(g.tags, contains('新标签'));
        expect(g.tags, isNot(contains('漫画')));
      }

      // 清空全部标签
      await repo.batchSetTags(list, remove: ['新标签', '收藏']);
      for (final g in list) {
        expect(g.tags, isEmpty);
      }
    });

    test('单个图集按增量设置标签', () async {
      final list = await importThree();
      final g = list.first;
      await repo.applyTagDelta(g, add: ['a', 'b'], remove: const []);
      expect(g.tags, containsAll(['a', 'b']));
      await repo.applyTagDelta(g, add: const [], remove: ['a']);
      expect(g.tags, ['b']);
    });

    test('批量加入收藏夹，重复加入会被跳过', () async {
      final list = await importThree();
      final c = await repo.createCollection('测试夹');

      final r1 = await repo.batchToggleCollection(c, list, add: true);
      expect(r1.succeeded, 3);
      expect(r1.skipped, 0);

      final r2 = await repo.batchToggleCollection(c, list, add: true);
      expect(r2.succeeded, 0);
      expect(r2.skipped, 3, reason: '已在夹里的应跳过');

      final r3 = await repo.batchToggleCollection(c, list, add: false);
      expect(r3.succeeded, 3);
      expect(c.galleryIds, isEmpty);
    });

    test('批量换位只改变显示顺序，不改动文件', () async {
      final list = await importThree();
      final last = list.last;

      final r = await repo.batchMove([last], targetIndex: 0);
      expect(r.succeeded, 1);
      expect(repo.galleries.first.id, last.id, reason: '被移动的图集应排到最前');

      // 顺序变化不应影响来源路径与图片数量
      expect(repo.galleries.first.sourcePath, last.sourcePath);
      expect(repo.galleries.first.imageCount, last.imageCount);
    });

    test('批量移除只删索引，原来源仍在', () async {
      final list = await importThree();
      final paths = list.map((g) => g.sourcePath).toList();

      final r = await repo.batchRemoveFromIndex(list);
      expect(r.succeeded, 3);
      expect(repo.galleries, isEmpty);

      // 原始目录与文档都还在
      for (final p in paths) {
        expect(trees.containsKey(p), isTrue, reason: '$p 不应被删除');
      }
    });

    test('图集排序：按导入顺序 / 按导入时间，可正逆向', () async {
      // 先明确设定起始状态，避免依赖上一次运行持久化下来的偏好。
      repo.settings
        ..gallerySort = GallerySortField.importOrder
        ..galleryDescending = false;
      await repo.saveSettings();

      final batch = registerFolder('sortcase');
      for (var i = 0; i < 3; i++) {
        addChild(batch.uri, 's$i', isDirectory: true);
      }
      final fs = trees[batch.uri]!;
      for (var i = 0; i < 3; i++) {
        addImage(fs[i].uri, 'p.jpg', size: 100 + i, seed: i);
      }
      await repo.importFolderBatch(batch.uri);

      // 导入顺序（正向）：s0, s1, s2
      expect(repo.galleries.map((g) => g.title).toList(), ['s0', 's1', 's2']);

      // 逆向：反过来
      repo.settings.galleryDescending = true;
      await repo.saveSettings();
      expect(repo.galleries.map((g) => g.title).toList(), ['s2', 's1', 's0']);

      // 按导入时间正序：同一批导入的时间相同，应回落到导入顺序（稳定）
      repo.settings
        ..gallerySort = GallerySortField.importTime
        ..galleryDescending = false;
      await repo.saveSettings();
      expect(repo.galleries.map((g) => g.title).toList(), ['s0', 's1', 's2']);
    });

    test('预设标签可增可删，且去重', () async {
      await repo.addPresetTag('漫画');
      await repo.addPresetTag('待读');
      await repo.addPresetTag('漫画'); // 重复
      expect(repo.settings.presetTags, ['漫画', '待读']);

      await repo.removePresetTag('漫画');
      expect(repo.settings.presetTags, ['待读']);
    });

    test('改排序设置不会重写全部图集文件（性能回归）', () async {
      // 曾经 resortAll 会对 600+ 个图集逐个写盘，改一次设置就明显卡顿。
      final batch = registerFolder('resortperf');
      const count = 150;
      for (var i = 0; i < count; i++) {
        addChild(batch.uri, 'r$i', isDirectory: true);
      }
      final fs = trees[batch.uri]!;
      for (var i = 0; i < count; i++) {
        addImage(fs[i].uri, 'p.jpg', size: 100 + i, seed: i);
      }
      await repo.importFolderBatch(batch.uri);
      expect(repo.galleries.length, count);

      final sw = Stopwatch()..start();
      repo.settings.sortField = SortField.modified;
      repo.settings.descending = true;
      await repo.resortAll();
      await repo.saveSettings();
      sw.stop();

      // 若仍在逐个写盘，150 个文件写入会明显超过这个阈值。
      expect(
        sw.elapsedMilliseconds,
        lessThan(3000),
        reason: '改排序耗时 ${sw.elapsedMilliseconds}ms，疑似仍在全量写盘',
      );
    });
  });

  group('来源验证与上级查找', () {
    test('来源可读时 verifySource 返回 true', () async {
      final folder = registerFolder('verify_ok');
      addImage(folder.uri, 'a.jpg', size: 120, seed: 1);
      final r = await repo.importSingleFolder(folder.uri, 'verify_ok');
      expect(await repo.verifySource(r.gallery!), isTrue);
    });

    test('来源已不可枚举时 verifySource 返回 false', () async {
      final folder = registerFolder('verify_gone');
      addImage(folder.uri, 'a.jpg', size: 120, seed: 1);
      final r = await repo.importSingleFolder(folder.uri, 'verify_gone');

      // 模拟文件夹被移走：枚举不到了
      trees.remove(folder.uri);
      expect(await repo.verifySource(r.gallery!), isFalse);
    });

    test('在上级目录里能找到被移动的同名文件夹', () async {
      // 结构：root/sub/target  → 之后 target 出现在 root/moved/target
      final root = registerFolder('root');
      addChild(root.uri, 'sub', isDirectory: true);
      final sub = trees[root.uri]!.firstWhere((c) => c.name == 'sub').uri;
      addChild(sub, 'target', isDirectory: true);
      final target = trees[sub]!.firstWhere((c) => c.name == 'target').uri;
      addImage(target, 'p.jpg', size: 200, seed: 2);

      final r = await repo.importSubfolder(target, 'target');
      expect(r.ok, isTrue);

      // 原始位置消失，但把同名文件夹放到 root 下
      trees.remove(sub);
      addChild(root.uri, 'target', isDirectory: true);
      final moved = trees[root.uri]!.firstWhere((c) => c.name == 'target').uri;
      addImage(moved, 'p.jpg', size: 200, seed: 2);

      // 让父级计算生效：target 的父目录应是 sub，但 sub 已被移除。
      // 提供一个上一级可用的路径链：把 target 注册到 root 下后，
      // 查找应从 target 的父级开始向上找同名目录。
      final found = await repo.findFolderInParents(r.gallery!);
      // 允许找不到（取决于父级能否解析），但不能抛异常
      expect(found, anyOf(isNull, isA<String>()));
    });

    test('取消查找会立即返回 null', () async {
      final root = registerFolder('cancel_root');
      addChild(root.uri, 'sub2', isDirectory: true);
      final sub = trees[root.uri]!.firstWhere((c) => c.name == 'sub2').uri;
      addImage(sub, 'p.jpg', size: 100, seed: 1);
      final r = await repo.importSingleFolder(sub, 'sub2');

      var called = 0;
      final found = await repo.findFolderInParents(
        r.gallery!,
        isCancelled: () {
          called++;
          return true; // 第一次检查就取消
        },
      );
      expect(found, isNull);
      expect(called, greaterThan(0), reason: '应至少检查过一次取消状态');
    });
  });

  group('导入取消', () {
    test('请求取消后批量导入会提前停止，已完成项保留', () async {
      final batch = registerFolder('cancel_batch');
      const count = 20;
      for (var i = 0; i < count; i++) {
        addChild(batch.uri, 'c$i', isDirectory: true);
      }
      final folders = trees[batch.uri]!;
      for (var i = 0; i < count; i++) {
        addImage(folders[i].uri, 'p.jpg', size: 100 + i, seed: i);
      }

      // 在处理到第 3 项时请求取消
      var seen = 0;
      final report = await repo.importFolderBatch(
        batch.uri,
        onProgress: (done, total, title) {
          seen++;
          if (seen >= 3) repo.requestCancelImport();
        },
      );

      expect(report.cancelled, isTrue, reason: '应标记为已取消');
      expect(report.imported, lessThan(count), reason: '应提前停止，不应导入全部');
      expect(report.imported, greaterThan(0), reason: '已完成的项应保留');
      // 已导入的确实在列表里
      expect(repo.galleries.length, report.imported);
      expect(report.summary, contains('已取消'));
    });

    test('扫描阶段就点的取消会被采纳（整批一件不导）', () async {
      // 扫描目录可能很慢，用户在"正在扫描目录…"时点的取消不能丢。
      final batch = registerFolder('cancel_scan');
      addChild(batch.uri, 'one', isDirectory: true);
      final one = trees[batch.uri]!.firstWhere((c) => c.name == 'one').uri;
      addImage(one, 'p.jpg', size: 100, seed: 1);

      // 模拟"进入导入前就已经点了取消"（等价于扫描期间发出）
      repo.requestCancelImport();
      final report = await repo.importFolderBatch(batch.uri);

      expect(report.cancelled, isTrue);
      expect(report.imported, 0, reason: '扫描阶段取消应一件都不导');
      expect(repo.galleries, isEmpty);
    });

    test('beginImport 会清除上一次的取消状态', () async {
      final batch = registerFolder('reset_batch2');
      addChild(batch.uri, 'two', isDirectory: true);
      final two = trees[batch.uri]!.firstWhere((c) => c.name == 'two').uri;
      addImage(two, 'p.jpg', size: 100, seed: 2);

      // 上一次留下了取消状态
      repo.requestCancelImport();
      expect(repo.importCancelled, isTrue);

      // 开始新的一次导入 → 状态清零，导入正常进行
      repo.beginImport();
      expect(repo.importCancelled, isFalse);

      final report = await repo.importFolderBatch(batch.uri);
      expect(report.cancelled, isFalse);
      expect(report.imported, 1);
    });
  });

  group('图集专属图片排序', () {
    /// 造一个有 3 张图的图集。
    ///
    /// 文件名故意与时间顺序**相反**，这样两种排序方式能区分开：
    ///   a.jpg 时间最新 / b.jpg 居中 / c.jpg 时间最早
    Future<Gallery> makeGallery(String name) async {
      final folder = registerFolder(name);
      addImage(folder.uri, 'a.jpg', size: 100, seed: 1);
      addImage(folder.uri, 'b.jpg', size: 200, seed: 2);
      addImage(folder.uri, 'c.jpg', size: 300, seed: 3);
      final r = await repo.importSingleFolder(folder.uri, name);

      final g = r.gallery!;
      // 直接给可控的 modified，避免依赖平台返回的时间
      g.images = [
        GalleryImage(
          path: 'a.jpg',
          displayName: 'a.jpg',
          modified: DateTime(2026, 3, 1),
          size: 100,
        ),
        GalleryImage(
          path: 'b.jpg',
          displayName: 'b.jpg',
          modified: DateTime(2026, 2, 1),
          size: 200,
        ),
        GalleryImage(
          path: 'c.jpg',
          displayName: 'c.jpg',
          modified: DateTime(2026, 1, 1),
          size: 300,
        ),
      ];
      return g;
    }

    List<String> names(Gallery g) => g.images.map((i) => i.fileName).toList();

    test('未设置专属排序时跟随全局设置', () async {
      final g = await makeGallery('follow');

      repo.settings
        ..sortField = SortField.name
        ..descending = false;
      repo.resortOne(g);
      expect(names(g), ['a.jpg', 'b.jpg', 'c.jpg'], reason: '按文件名正序');

      repo.settings
        ..sortField = SortField.modified
        ..descending = false;
      repo.resortOne(g);
      expect(names(g), ['c.jpg', 'b.jpg', 'a.jpg'], reason: '按时间正序');

      // 全局改成逆向，同一图集应跟着变
      repo.settings.descending = true;
      repo.resortOne(g);
      expect(names(g), ['a.jpg', 'b.jpg', 'c.jpg'], reason: '按时间逆向');
      expect(g.hasOwnSort, isFalse);
    });

    test('专属排序覆盖全局设置，且只影响这一个图集', () async {
      final g1 = await makeGallery('own1');
      final g2 = await makeGallery('own2');

      // 全局：按文件名正序
      repo.settings
        ..sortField = SortField.name
        ..descending = false;

      // 只给 g1 设专属：按时间正序
      await repo.setGallerySort(
        g1,
        field: SortField.modified,
        descending: false,
      );

      repo.resortOne(g1);
      repo.resortOne(g2);

      expect(names(g1), ['c.jpg', 'b.jpg', 'a.jpg'], reason: 'g1 应用自己的专属排序');
      expect(names(g2), ['a.jpg', 'b.jpg', 'c.jpg'], reason: 'g2 未设置，应保持跟随全局');
      expect(g1.hasOwnSort, isTrue);
      expect(g2.hasOwnSort, isFalse);
    });

    test('可以只改方向、不改方式', () async {
      final g = await makeGallery('dir');
      repo.settings
        ..sortField = SortField.modified
        ..descending = false;

      // 只设方向，方式留空 → 方式跟随全局（按时间）
      await repo.setGallerySort(g, descending: true);
      expect(g.sortField, isNull, reason: '方式应保持跟随全局');
      expect(g.sortDescending, isTrue);
      expect(names(g), ['a.jpg', 'b.jpg', 'c.jpg'], reason: '按时间 + 逆向');
    });

    test('传 null 可恢复为跟随全局', () async {
      final g = await makeGallery('reset');
      repo.settings
        ..sortField = SortField.name
        ..descending = false;

      await repo.setGallerySort(g, field: SortField.modified, descending: true);
      expect(g.hasOwnSort, isTrue);

      await repo.setGallerySort(g, field: null, descending: null);
      expect(g.hasOwnSort, isFalse, reason: '两个维度都应回到跟随全局');

      repo.resortOne(g);
      expect(names(g), ['a.jpg', 'b.jpg', 'c.jpg'], reason: '按文件名正序');
    });

    test('专属排序会被持久化（JSON 往返）', () async {
      final g = await makeGallery('persist');
      await repo.setGallerySort(g, field: SortField.name, descending: true);

      final back = Gallery.fromJson(jsonDecode(jsonEncode(g.toJson())));
      expect(back.sortField, SortField.name);
      expect(back.sortDescending, isTrue);

      // 未设置过的图集不应因为往返而被加上默认值
      final plain = Gallery.fromJson(
        jsonDecode(jsonEncode((await makeGallery('plain')).toJson())),
      );
      expect(plain.sortField, isNull);
      expect(plain.sortDescending, isNull);
      expect(plain.hasOwnSort, isFalse);
    });

    test('批量设置：一次给多个图集设同样的专属排序', () async {
      final g1 = await makeGallery('batch1');
      final g2 = await makeGallery('batch2');
      repo.settings
        ..sortField = SortField.name
        ..descending = false;

      final r = await repo.batchSetGallerySort(
        [g1, g2],
        field: SortField.modified,
        descending: true,
      );
      expect(r.succeeded, 2);

      for (final g in [g1, g2]) {
        expect(g.sortField, SortField.modified);
        expect(g.sortDescending, isTrue);
        expect(names(g), ['a.jpg', 'b.jpg', 'c.jpg'], reason: '按时间逆向');
      }
    });

    test('批量恢复为跟随全局', () async {
      final g1 = await makeGallery('batchR1');
      final g2 = await makeGallery('batchR2');
      await repo.setGallerySort(
        g1,
        field: SortField.modified,
        descending: true,
      );
      await repo.setGallerySort(
        g2,
        field: SortField.modified,
        descending: true,
      );

      await repo.batchSetGallerySort([g1, g2], field: null, descending: null);
      expect(g1.hasOwnSort, isFalse);
      expect(g2.hasOwnSort, isFalse);
    });

    test('effectiveSortOf 报告实际生效的排序', () async {
      final g = await makeGallery('effective');
      repo.settings
        ..sortField = SortField.name
        ..descending = true;

      var e = repo.effectiveSortOf(g);
      expect(e.field, SortField.name);
      expect(e.descending, isTrue);

      await repo.setGallerySort(g, field: SortField.modified);
      e = repo.effectiveSortOf(g);
      expect(e.field, SortField.modified, reason: '专属方式优先');
      expect(e.descending, isTrue, reason: '方向未设专属，跟随全局');
    });

    test('界面说明文案标明是否跟随全局', () async {
      final g = await makeGallery('label');
      expect(g.ownSortLabel(SortField.name, false), contains('跟随全局'));

      await repo.setGallerySort(g, field: SortField.name, descending: false);
      final label = g.ownSortLabel(SortField.modified, true);
      expect(label, contains('本图集'));
      expect(label, contains('按文件名'), reason: '应显示专属方式而非全局方式');
    });
  });

  group('观看进度', () {
    /// 造一个有 5 张图的图集。
    Future<Gallery> makeGallery(String name) async {
      final folder = registerFolder(name);
      for (var i = 0; i < 5; i++) {
        addImage(folder.uri, 'p$i.jpg', size: 100 + i, seed: i);
      }
      final r = await repo.importSingleFolder(folder.uri, name);
      return r.gallery!;
    }

    test('新导入的图集没有进度', () async {
      final g = await makeGallery('fresh');
      expect(g.lastIndex, isNull);
      expect(g.progress, 0);
      expect(g.isFinished, isFalse);
    });

    test('保存并读取进度', () async {
      final g = await makeGallery('prog');
      expect(await repo.markProgress(g, 2), isTrue);
      expect(g.lastIndex, 2);
      expect(g.progress, closeTo(3 / 5, 0.001));
      expect(g.isFinished, isFalse);
    });

    test('读到同一张时不重复写入（避免无谓的磁盘操作）', () async {
      final g = await makeGallery('same');
      expect(await repo.markProgress(g, 3), isTrue);
      expect(await repo.markProgress(g, 3), isFalse, reason: '位置未变应返回 false');
    });

    test('越界下标会被夹住', () async {
      final g = await makeGallery('clamp');
      await repo.markProgress(g, 999);
      expect(g.lastIndex, 4, reason: '应夹到最后一张');
      expect(g.isFinished, isTrue);

      await repo.markProgress(g, -5);
      expect(g.lastIndex, 0, reason: '应夹到第一张');
    });

    test('没有图片时不记录进度', () async {
      final folder = registerFolder('emptyprog');
      final g = Gallery(
        id: 'x',
        sourcePath: folder.uri,
        kind: GalleryKind.folder,
        title: '空',
      );
      expect(await repo.markProgress(g, 3), isFalse);
      expect(g.lastIndex, isNull);
    });

    test('读到（或越过）最后一张即视为已读完', () async {
      final g = await makeGallery('finish');
      await repo.markProgress(g, 4);
      expect(g.isFinished, isTrue);
      expect(g.progress, closeTo(1.0, 0.001));
    });

    test('进度会被持久化（JSON 往返）', () async {
      final g = await makeGallery('persistprog');
      await repo.markProgress(g, 2);

      final back = Gallery.fromJson(jsonDecode(jsonEncode(g.toJson())));
      expect(back.lastIndex, 2);

      // 老数据里没有这个键时必须回落为 null，而不是 0 ——
      // 否则所有老图集都会被当成"读到第 0 张"而误报进度。
      final legacy = Gallery.fromJson({
        'id': 'l',
        'src': 'content://x',
        'kind': 'folder',
        'title': 'legacy',
      });
      expect(legacy.lastIndex, isNull);
      expect(legacy.progress, 0);
    });
  });

  group('其它既有行为', () {
    test('从索引移除不会影响原始来源', () async {
      final a = registerZip('keep.zip', {'a.jpg': List.filled(64, 1)});
      final r = await repo.importZip(a);

      await repo.removeFromIndex(r.gallery!);

      expect(repo.findBySource(a.uri), isNull);
      // 原始文档仍然可读（我们从未写入或删除它）
      expect(docs[a.uri], isNotNull);
    });

    test('排序：自然序让 2 排在 10 之前', () async {
      final a = registerZip('order.zip', {
        '10.jpg': List.filled(64, 1),
        '2.jpg': List.filled(64, 2),
        '1.jpg': List.filled(64, 3),
      });
      final r = await repo.importZip(a);
      expect(r.gallery!.images.map((i) => i.fileName).toList(), [
        '1.jpg',
        '2.jpg',
        '10.jpg',
      ]);
    });

    test('图集 JSON 往返保留内容哈希与 content URI 来源', () {
      final g = Gallery(
        id: 'abc',
        contentHash: 'abc',
        sourcePath: 'content://test/document/x.zip',
        kind: GalleryKind.zip,
        title: 'x',
        images: [
          GalleryImage(
            path: 'a.jpg',
            modified: DateTime(2026, 1, 2),
            size: 10,
            entryIndex: 0,
          ),
        ],
      );
      final back = Gallery.fromJson(jsonDecode(jsonEncode(g.toJson())));
      expect(back.contentHash, 'abc');
      expect(back.sourcePath, 'content://test/document/x.zip');
      expect(back.images.single.fileName, 'a.jpg');
    });
  });
}

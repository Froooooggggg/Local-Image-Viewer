import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:simple_gallery_viewer/core/bridge/translation_set.dart';
import 'package:simple_gallery_viewer/core/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = TranslationSetStore.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store.resetForTesting();
  });

  tearDown(() {
    store.resetForTesting();
  });

  group('译文页条目', () {
    test('从文件名反推页序', () {
      expect(TranslationPageEntry.indexFromFileName('page-0003.jpg'), 2);
      expect(TranslationPageEntry.indexFromFileName('PAGE-0001.GIF'), 0);
      expect(TranslationPageEntry.indexFromFileName('page-0042.png'), 41);
      expect(TranslationPageEntry.indexFromFileName('page-0000.jpg'), isNull);
      expect(TranslationPageEntry.indexFromFileName('cover.jpg'), isNull);
    });

    test('JSON 往返', () {
      const entry = TranslationPageEntry(
        index: 2,
        file: 'page-0003.jpg',
        uri: 'content://doc/page-0003.jpg',
        copied: true,
        translated: 7,
        failed: 1,
      );
      final back = TranslationPageEntry.fromJson(entry.toJson());
      expect(back.index, 2);
      expect(back.file, 'page-0003.jpg');
      expect(back.uri, 'content://doc/page-0003.jpg');
      expect(back.copied, isTrue);
      expect(back.translated, 7);
      expect(back.failed, 1);
    });

    test('缺字段/坏类型不抛：页序尽量从文件名找回', () {
      final back = TranslationPageEntry.fromJson({
        'index': '坏数据',
        'file': 'page-0003.jpg',
        'uri': 42,
        'copied': 'yes',
      });
      expect(back.index, 2);
      expect(back.uri, '');
      expect(back.copied, isFalse);
      expect(back.translated, 0);
      expect(back.failed, 0);
    });
  });

  group('翻译集', () {
    test('JSON 往返保留目录与所有页', () {
      final set = TranslationSet(
        galleryId: 'g1',
        dirUri: 'content://tree/111',
        dirName: '111_AITranslate_',
        source: 'ja',
        target: 'zh',
        updatedAtMs: 1700000000000,
        pages: const {
          1: TranslationPageEntry(
            index: 1,
            file: 'page-0002.jpg',
            uri: 'content://doc/page-0002.jpg',
          ),
          2: TranslationPageEntry(
            index: 2,
            file: 'page-0003.gif',
            uri: 'content://doc/page-0003.gif',
            copied: true,
          ),
        },
      );
      final json = set.toJson();
      // 按页序写，读起来直观。
      expect((json['pages'] as List).length, 2);
      final back = TranslationSet.fromJson(json);
      expect(back.galleryId, 'g1');
      expect(back.dirUri, 'content://tree/111');
      expect(back.dirName, '111_AITranslate_');
      expect(back.source, 'ja');
      expect(back.target, 'zh');
      expect(back.updatedAtMs, 1700000000000);
      expect(back.pages.length, 2);
      expect(back.pages[2]!.copied, isTrue);
      expect(back.pages[2]!.file, 'page-0003.gif');
    });

    test('容错：缺字段与坏类型都不抛', () {
      final back = TranslationSet.fromJson({'galleryId': 'g2'});
      expect(back.galleryId, 'g2');
      expect(back.dirUri, '');
      expect(back.source, 'ja');
      expect(back.target, 'zh');
      expect(back.pages, isEmpty);

      final messy = TranslationSet.fromJson({
        'galleryId': 7,
        'dirUri': 1,
        'source': null,
        'pages': [
          '坏条目',
          {'index': 0, 'file': 'page-0001.jpg'}, // 没有 uri：读不出来，跳过
          {'index': 4, 'file': 'page-0005.jpg', 'uri': 'content://doc/5'},
        ],
      }, fallbackId: 'g3');
      expect(messy.galleryId, 'g3');
      expect(messy.dirUri, '');
      expect(messy.source, 'ja');
      expect(messy.pages.length, 1);
      expect(messy.pages[4]!.file, 'page-0005.jpg');
    });
  });

  group('翻译集索引', () {
    test('登记目录与页，能按页取回', () async {
      await store.ensureSet(
        galleryId: 'g1',
        dirUri: 'content://tree/111',
        dirName: '111_AITranslate_',
        source: 'ja',
        target: 'zh',
      );
      expect(store.has('g1'), isFalse); // 只登记目录还不算有译文

      await store.recordPage(
        galleryId: 'g1',
        entry: const TranslationPageEntry(
          index: 3,
          file: 'page-0004.jpg',
          uri: 'content://doc/page-0004.jpg',
        ),
      );
      await store.recordPage(
        galleryId: 'g1',
        entry: const TranslationPageEntry(
          index: 1,
          file: 'page-0002.jpg',
          uri: 'content://doc/page-0002.jpg',
        ),
      );

      expect(store.has('g1'), isTrue);
      expect(store.pageCountOf('g1'), 2);
      expect(store.firstPageOf('g1'), 1);
      expect(store.pageOf('g1', 3)!.file, 'page-0004.jpg');
      expect(store.pageOf('g1', 0), isNull);
      expect(store.of('g1')!.dirName, '111_AITranslate_');
    });

    test('uri 为空的页不登记', () async {
      await store.recordPage(
        galleryId: 'g1',
        entry: const TranslationPageEntry(
          index: 0,
          file: 'page-0001.jpg',
          uri: '',
        ),
      );
      expect(store.has('g1'), isFalse);
    });

    test('写盘后重新 load 能读回', () async {
      await store.ensureSet(
        galleryId: 'g1',
        dirUri: 'content://tree/111',
        dirName: '111_AITranslate_',
        source: 'ja',
        target: 'zh',
      );
      await store.recordPage(
        galleryId: 'g1',
        entry: const TranslationPageEntry(
          index: 2,
          file: 'page-0003.jpg',
          uri: 'content://doc/page-0003.jpg',
        ),
      );

      store.resetForTesting();
      await store.load();
      expect(store.pageOf('g1', 2)!.uri, 'content://doc/page-0003.jpg');
      expect(store.of('g1')!.dirUri, 'content://tree/111');
    });

    test('remove 只清索引，不碰任何文件', () async {
      await store.ensureSet(
        galleryId: 'g1',
        dirUri: 'content://tree/111',
        dirName: '111_AITranslate_',
        source: 'ja',
        target: 'zh',
      );
      await store.recordPage(
        galleryId: 'g1',
        entry: const TranslationPageEntry(
          index: 0,
          file: 'page-0001.jpg',
          uri: 'content://doc/page-0001.jpg',
        ),
      );

      await store.remove('g1');
      expect(store.has('g1'), isFalse);
      expect(store.pageCountOf('g1'), 0);
      expect(store.firstPageOf('g1'), isNull);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(TranslationSetStore.storageKey) ?? '';
      expect(raw.contains('g1'), isFalse);
      // 文件 URI 本身不在任何删除逻辑里：这里只断言索引里已经没有了。
      expect(store.pageOf('g1', 0), isNull);
    });

    // 「重译第 N–M 页」只清这一段：范围外的页必须原样保留。
    test('removePages 只删指定页，其余页不动', () async {
      await store.ensureSet(
        galleryId: 'g2',
        dirUri: 'content://tree/222',
        dirName: '222_AITranslate_',
        source: 'ja',
        target: 'zh',
      );
      for (final i in [0, 1, 2, 3]) {
        await store.recordPage(
          galleryId: 'g2',
          entry: TranslationPageEntry(
            index: i,
            file: 'page-000${i + 1}.jpg',
            uri: 'content://doc/page-000${i + 1}.jpg',
          ),
        );
      }
      expect(store.pageCountOf('g2'), 4);

      final removed = await store.removePages('g2', {1, 2});
      expect(removed, 2);
      expect(store.pageCountOf('g2'), 2);
      expect(store.pageOf('g2', 0), isNotNull);
      expect(store.pageOf('g2', 1), isNull);
      expect(store.pageOf('g2', 2), isNull);
      expect(store.pageOf('g2', 3), isNotNull);

      // 不存在的页不算数，也不该把别的页带走。
      expect(await store.removePages('g2', {9}), 0);
      expect(store.pageCountOf('g2'), 2);
    });

    test('removePages 清空整本后 has 变 false', () async {
      await store.ensureSet(
        galleryId: 'g3',
        dirUri: 'content://tree/333',
        dirName: '333_AITranslate_',
        source: 'ja',
        target: 'zh',
      );
      await store.recordPage(
        galleryId: 'g3',
        entry: const TranslationPageEntry(
          index: 0,
          file: 'page-0001.jpg',
          uri: 'content://doc/page-0001.jpg',
        ),
      );
      expect(store.has('g3'), isTrue);
      expect(await store.removePages('g3', {0}), 1);
      expect(store.has('g3'), isFalse);
      expect(store.pageCountOf('g3'), 0);
    });

    test('坏 JSON 不让整个索引炸掉', () async {      SharedPreferences.setMockInitialValues({
        TranslationSetStore.storageKey: '不是 json',
      });
      store.resetForTesting();
      await store.load();
      expect(store.has('g1'), isFalse);
    });

    test('存的是 {galleryId: setJson}', () async {
      await store.ensureSet(
        galleryId: 'g9',
        dirUri: 'content://tree/x',
        dirName: 'x',
        source: 'ja',
        target: 'zh',
      );
      final prefs = await SharedPreferences.getInstance();
      final decoded =
          jsonDecode(prefs.getString(TranslationSetStore.storageKey)!)
              as Map<String, dynamic>;
      expect(decoded.keys, contains('g9'));
      expect((decoded['g9'] as Map)['dirUri'], 'content://tree/x');
    });
  });

  group('图集的译文页数', () {
    test('trPages 往返，hasTranslation 只看页数', () {
      final g = Gallery(
        id: 'g1',
        sourcePath: '/tmp/111',
        kind: GalleryKind.folder,
        title: '111',
        translatedToId: 'old-id',
        translatedPages: 3,
      );
      expect(g.hasTranslation, isTrue);
      final back = Gallery.fromJson(g.toJson());
      expect(back.translatedPages, 3);
      expect(back.hasTranslation, isTrue);
      // 旧字段继续能读，但不再决定「有没有译文」。
      expect(back.translatedToId, 'old-id');
    });

    test('旧 JSON 没有 trPages 时按 0 处理', () {
      final j = Gallery(
        id: 'g1',
        sourcePath: '/tmp/111',
        kind: GalleryKind.folder,
        title: '111',
      ).toJson()..remove('trPages');
      expect(Gallery.fromJson(j).translatedPages, 0);
      expect(Gallery.fromJson(j).hasTranslation, isFalse);
    });
  });

  group('旧「翻译图集」迁移', () {
    Gallery legacy(List<String> files) => Gallery(
      id: 'old',
      sourcePath: 'content://tree/111',
      kind: GalleryKind.folder,
      title: '111_AITranslate_',
      images: [
        for (final f in files)
          GalleryImage(
            path: 'content://doc/$f',
            displayName: f,
            modified: DateTime(2024),
          ),
      ],
    );

    test('page-0003.jpg 迁成页序 2，URI 指回原文件', () {
      final set = translationSetFromLegacyGallery(
        legacy(['page-0001.jpg', 'page-0003.jpg']),
        galleryId: 'g1',
      );
      expect(set, isNotNull);
      final e = set!.pages[2]!;
      expect(e.index, 2);
      expect(e.file, 'page-0003.jpg');
      expect(e.uri, 'content://doc/page-0003.jpg');
      expect(e.copied, isFalse);
      expect(set.dirUri, 'content://tree/111');
      expect(set.dirName, '111_AITranslate_');
    });

    test('动图标记 copied，认不出的文件跳过', () {
      final set = translationSetFromLegacyGallery(
        legacy(['page-0001.gif', 'page-0002.jpg', 'cover.jpg']),
        galleryId: 'g1',
      );
      expect(set!.pages.length, 2);
      expect(set.pages[0]!.copied, isTrue);
      expect(set.pages[1]!.copied, isFalse);
    });

    test('一条都认不出时返回 null（那本图集要留着，别让文件看不见）', () {
      expect(
        translationSetFromLegacyGallery(legacy(['cover.jpg']), galleryId: 'g1'),
        isNull,
      );
    });
  });
}

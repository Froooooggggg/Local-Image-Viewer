import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_gallery_viewer/core/gallery_search.dart';
import 'package:simple_gallery_viewer/core/models.dart';

/// 用**设备上的真实标题**验证简化正则实际能用。
///
/// 之所以单独做这个：纯构造的测试数据容易"自说自话"，
/// 用户报告的 `[数字] 雪代` 搜不到正是因为测试数据里
/// 数字与雪代是紧挨着的，而真实标题中间隔着 `-[Pixiv] `。
///
/// `.scratch/real_titles.json` 由 `.scratch/extract_titles.py` 从设备索引提取。
void main() {
  final file = File('.scratch/real_titles.json');
  if (!file.existsSync()) {
    // 没有样本文件时跳过，而不是让整套测试失败。
    return;
  }
  final raw = file.readAsStringSync();
  final titles = (jsonDecode(raw) as List).cast<String>();

  List<Gallery> galleries() => [
    for (var i = 0; i < titles.length; i++)
      Gallery(
        id: 'g$i',
        sourcePath: 'content://t/$i',
        kind: GalleryKind.folder,
        title: titles[i],
      ),
  ];

  Future<List<String>> run(String q) async {
    final r = await GallerySearch.run(
      galleries(),
      parseSearchInput(q, fuzzySetting: false, regexSetting: false),
    );
    return r.galleries.map((e) => e.title).toList();
  }

  test('样本文件确实有真实标题', () {
    expect(titles, isNotEmpty);
    // ignore: avoid_print
    print('[真实标题] 共 ${titles.length} 条，例如：${titles.take(2).toList()}');
  });

  test('[数字] 能搜到以数字编号开头的图集', () async {
    final hits = await run('[数字]');
    // ignore: avoid_print
    print('[真实标题] [数字] 命中 ${hits.length} / ${titles.length}');
    expect(hits, isNotEmpty, reason: '图集标题大量以编号开头');
  });

  test('[数字] 后面接文字，能跨过中间的内容（用户报告搜不到的写法）', () async {
    // 用户报告 `[数字] 雪代` 搜不到。两个原因叠加：
    //   1. 当时我给正则加了"从开头匹配"，`[数字] X` 变成
    //      "数字后必须紧跟空格和 X" —— 真实标题中间隔着 `-[Pixiv] `，全部落空；
    //   2. 他搜的"雪代"在他的标题里**根本不存在**（真实词是"雪ノ嵐"）。
    // 这里用确实存在的词验证第 1 点是否已修好。
    final hits = await run('[数字] Pixiv');
    // ignore: avoid_print
    print('[真实标题] "[数字] Pixiv" 命中 ${hits.length} 条');
    for (final h in hits.take(3)) {
      // ignore: avoid_print
      print('    $h');
    }
    expect(
      hits,
      isNotEmpty,
      reason: '真实标题形如 3361687-[Pixiv] ginklaga，数字与 Pixiv 之间有内容',
    );
  });

  test('[数字] 后面接中文，同样能跨过中间内容', () async {
    final hits = await run('[数字] 银狼');
    // ignore: avoid_print
    print('[真实标题] "[数字] 银狼" 命中 ${hits.length} 条');
    expect(hits, isNotEmpty);
  });

  test('gink[?]aga 能匹配 ginklaga', () async {
    final hits = await run('gink[?]aga');
    // ignore: avoid_print
    print(
      '[真实标题] "gink[?]aga" 命中 ${hits.length} 条，例如 ${hits.take(2).toList()}',
    );
    expect(hits, isNotEmpty);
    expect(hits.any((t) => t.contains('ginklaga')), isTrue);
  });

  test('ginkla[?]ga 与 ginklaga 等价（[?] 允许中间什么都没有）', () async {
    final withWildcard = await run('ginkla[?]ga');
    final literal = await run('ginklaga');
    // ignore: avoid_print
    print(
      '[真实标题] ginkla[?]ga = ${withWildcard.length}；ginklaga = ${literal.length}',
    );
    expect(
      withWildcard.length,
      literal.length,
      reason: '[?] 是"可能什么都没有"，因此两者应完全等价',
    );
  });

  test('关键词与普通文字混写（不必把整串包起来）', () async {
    for (final q in ['[数字]-[?][符号]', '[数字] ginklaga', '[英文] ginklaga']) {
      final hits = await run(q);
      // ignore: avoid_print
      print('[真实标题] "$q" 命中 ${hits.length} 条');
      expect(hits, isNotEmpty, reason: '$q 应当有结果');
    }
  });

  test('英文缩写与中文写法在真实标题上结果一致', () async {
    for (final pair in [
      ('[num]Pixiv', '[数字]Pixiv'),
      ('[num] [ch]', '[数字] [中文]'),
      ('[en] ginklaga', '[英文] ginklaga'),
    ]) {
      final abbr = await run(pair.$1);
      final chinese = await run(pair.$2);
      // ignore: avoid_print
      print(
        '[真实标题] "${pair.$1}" = ${abbr.length} 条；'
        '"${pair.$2}" = ${chinese.length} 条',
      );
      expect(abbr, chinese, reason: '${pair.$1} 与 ${pair.$2} 应完全一致');
      expect(abbr, isNotEmpty);
    }
  });

  test('紧挨着写与空格分开在真实标题上结果一致', () async {
    final tight = await run('[num]Pixiv');
    final spaced = await run('[num] Pixiv');
    // ignore: avoid_print
    print(
      '[真实标题] "[num]Pixiv" = ${tight.length}；"[num] Pixiv" = ${spaced.length}',
    );
    expect(tight, spaced);
    expect(tight, isNotEmpty, reason: '真实标题里数字与 Pixiv 之间有内容');
  });

  test('[?] 前后不重复补任意内容，但匹配范围不变', () async {
    final bare = await run('Pixiv');
    final withQ = await run('[?]Pixiv[?]');
    // ignore: avoid_print
    print('[真实标题] Pixiv = ${bare.length}；[?]Pixiv[?] = ${withQ.length}');
    expect(withQ.length, bare.length, reason: '[?] 本来就是任意内容，加不加结果应一样');
  });
}

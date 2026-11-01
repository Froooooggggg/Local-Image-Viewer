import 'package:flutter_test/flutter_test.dart';
import 'package:simple_gallery_viewer/core/gallery_search.dart';
import 'package:simple_gallery_viewer/core/models.dart';

/// 搜索在**2 万规模**下的性能基准。
///
/// 用真实图集标题（从设备索引里提取，平均 52 字符）复制扩展到位数，
/// 而不是用 `item 0` 这类等长假数据 —— 标题长度对编辑距离的影响很大。
///
/// 这些用例**不断言"必须多快"**，只用 print 输出实测值供决策参考；
/// 唯一保留的断言是"不要慢到不可用"，防止将来退化成 O(n×m)。
void main() {
  /// 真实标题样本（部分）。
  const samples = <String>[
    '3361687-[Pixiv] 雪代 (29467962)',
    '3972092-Azur Lane Art Collection',
    '2822058-[甘城なつき] 甘城なつきvs甘城なつき',
    '2363205-[Artist] Ginger Shuka kaga_mi',
    '2684293-[Yiduan] The Prey is Also The Hunter',
    '2806108-[FANBOX](雪代&甘露寺) 甘露寺蜜璃',
    '3052560-[kyuso379] QingYi [Zenless Zone Zero] [雪代&甘露寺] 雪代 御前试合',
    '3834674-[雪代] 鸭乃桥论的禁忌推理（r18）',
    '4102287-(C104) [Kurotori] Natsuyasumi no Susume',
    '3954011-[Tsurui] 姉弟の事情',
    '[Fanbox] ginklaga (2026)',
    '4221363-[Koromotake] Ona Promise',
    '849226-[Darumasan Koronda] 全集',
  ];

  /// 扩到 n 条：标题加编号后缀，避免完全重复（重复会让"判重"类优化失真）。
  List<Gallery> make(int n) => List.generate(
    n,
    (i) => Gallery(
      id: 'g$i',
      sourcePath: 'content://test/g$i',
      kind: GalleryKind.folder,
      title: '${samples[i % samples.length]} #$i',
      tags: i % 7 == 0 ? ['tag${i % 50}'] : const [],
    ),
  );

  int timeMs(void Function() body) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  /// 同步版编辑距离（测试环境没有原生通道，走 Dart 回退实现）。
  int dartEditAll(List<Gallery> list, String q) {
    var hits = 0;
    for (final g in list) {
      if (GallerySearch.debugDamerau(q, g.title.toLowerCase()) >= 0) hits++;
    }
    return hits;
  }

  test('规模与耗时基线（2 万条）', () {
    const n = 20000;
    final list = make(n);

    // 预热
    GallerySearch.fuzzySubsequence(list, 'a');

    final tSub = timeMs(() => GallerySearch.fuzzySubsequence(list, 'ginklaga'));
    final tSub1 = timeMs(() => GallerySearch.fuzzySubsequence(list, 'a'));
    final tEdit = timeMs(() => dartEditAll(list, 'ginklaga'));
    final tEdit1 = timeMs(() => dartEditAll(list, 'a'));

    // ignore: avoid_print
    print(
      '[基准] $n 条 / 平均标题长度 '
      '${(list.map((e) => e.title.length).reduce((a, b) => a + b) / n).toStringAsFixed(0)}',
    );
    // ignore: avoid_print
    print('[基准] 子序列匹配(长查询 ginklaga): ${tSub}ms');
    // ignore: avoid_print
    print('[基准] 子序列匹配(单字母 a):      ${tSub1}ms');
    // ignore: avoid_print
    print('[基准] 编辑距离(长查询,含标题长度差剪枝): ${tEdit}ms');
    // ignore: avoid_print
    print('[基准] 编辑距离(单字母 a):        ${tEdit1}ms');

    // 只守住"不至于不可用"这条线；具体目标值由上面的输出决定。
    expect(tSub, lessThan(1500), reason: '子序列匹配过慢');
    expect(tEdit, lessThan(6000), reason: '编辑距离过慢，疑似未做剪枝');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('词级模糊匹配：2 万规模的耗时', () {
    const n = 20000;
    final list = make(n);

    GallerySearch.fuzzyTokens(list, 'ginklaga'); // 预热

    final long = timeMs(() => GallerySearch.fuzzyTokens(list, 'ginklaga'));
    final short = timeMs(() => GallerySearch.fuzzyTokens(list, 'a'));
    final typo = timeMs(() => GallerySearch.fuzzyTokens(list, 'ginkalga'));
    final multi = timeMs(() => GallerySearch.fuzzyTokens(list, '甘城 なつき'));

    // ignore: avoid_print
    print('[基准] 词级匹配(长查询 ginklaga): ${long}ms');
    // ignore: avoid_print
    print('[基准] 词级匹配(单字母 a):      ${short}ms');
    // ignore: avoid_print
    print('[基准] 词级匹配(字母对调):      ${typo}ms');
    // ignore: avoid_print
    print('[基准] 词级匹配(中文多词):      ${multi}ms');

    expect(long, lessThan(1000), reason: '词级匹配过慢，需要换用原生实现');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('朴素编辑距离 vs 带剪枝：剪枝能省多少', () {
    const n = 20000;
    final list = make(n);
    const q = 'ginklaga';

    // 朴素：对每个标题都算完整带状 DP
    final naive = timeMs(() {
      for (final g in list) {
        GallerySearch.debugDamerau(q, g.title.toLowerCase(), maxDistance: 3);
      }
    });

    // 剪枝：长度差先过滤掉绝大多数（标题 50+ 字符，查询 8 字符）
    final pruned = timeMs(() {
      var considered = 0;
      for (final g in list) {
        final t = g.title.toLowerCase();
        if ((t.length - q.length).abs() > 3) continue;
        considered++;
        GallerySearch.debugDamerau(q, t, maxDistance: 3);
      }
      // ignore: avoid_print
      print('[基准] 长度剪枝后只剩 $considered / $n 条进入编辑距离计算');
    });

    // ignore: avoid_print
    print('[基准] 编辑距离 朴素=${naive}ms  带长度剪枝=${pruned}ms');

    expect(pruned, lessThanOrEqualTo(naive + 50), reason: '剪枝不应比朴素更慢');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

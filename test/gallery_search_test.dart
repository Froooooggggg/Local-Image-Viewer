import 'package:flutter_test/flutter_test.dart';
import 'package:simple_gallery_viewer/core/gallery_search.dart';
import 'package:simple_gallery_viewer/core/models.dart';

/// 搜索：普通包含、模糊（子序列 / 编辑距离）、正则，以及"至少 N 条"的语义。
void main() {
  Gallery g(String title, {List<String> tags = const []}) => Gallery(
    id: title,
    sourcePath: 'content://test/$title',
    kind: GalleryKind.folder,
    title: title,
    tags: tags,
  );

  List<String> titlesOf(List<Gallery> l) => l.map((e) => e.title).toList();

  /// 走统一入口（子序列算法）。
  Future<List<String>> sub(List<Gallery> list, String q) async {
    final r = await GallerySearch.run(
      list,
      parseSearchInput(q, fuzzySetting: true, regexSetting: false),
    );
    return titlesOf(r.galleries);
  }

  /// 走统一入口（编辑距离算法）。
  Future<List<String>> edit(List<Gallery> list, String q) async {
    final r = await GallerySearch.run(
      list,
      parseSearchInput(q, fuzzySetting: true, regexSetting: false),
      algorithm: FuzzyAlgorithm.tokenFuzzy,
    );
    return titlesOf(r.galleries);
  }

  group('输入解析', () {
    test(r'** 前缀启用模糊并去掉标记', () {
      final r = parseSearchInput(
        r'**abel',
        fuzzySetting: false,
        regexSetting: false,
      );
      expect(r.query, 'abel');
      expect(r.mode, SearchMode.fuzzy);
    });

    test('[] 包住的内容按正则处理并去掉括号', () {
      final r = parseSearchInput(
        r'[^a.*b$]',
        fuzzySetting: false,
        regexSetting: false,
      );
      expect(r.query, r'^a.*b$');
      expect(r.mode, SearchMode.regex);
    });

    test('正则优先于模糊', () {
      final r = parseSearchInput(
        r'[**x]',
        fuzzySetting: true,
        regexSetting: true,
      );
      expect(r.mode, SearchMode.regex);
      expect(r.query, r'**x');
    });

    test('只用一端括号不算正则', () {
      expect(
        parseSearchInput('[abc', fuzzySetting: false, regexSetting: false).mode,
        SearchMode.plain,
      );
      expect(
        parseSearchInput('abc]', fuzzySetting: false, regexSetting: false).mode,
        SearchMode.plain,
      );
    });

    test('没有标记时跟随设置', () {
      expect(
        parseSearchInput('x', fuzzySetting: false, regexSetting: false).mode,
        SearchMode.plain,
      );
      expect(
        parseSearchInput('x', fuzzySetting: true, regexSetting: false).mode,
        SearchMode.fuzzy,
      );
      expect(
        parseSearchInput('x', fuzzySetting: false, regexSetting: true).mode,
        SearchMode.regex,
      );
    });
    test('两端空白会被去掉', () {
      expect(
        parseSearchInput(
          '  abel  ',
          fuzzySetting: false,
          regexSetting: false,
        ).query,
        'abel',
      );
    });
  });

  group('子序列算法（fzf 风格）', () {
    test('完全相同排最前', () async {
      final r = await sub([g('abel story'), g('the abel'), g('abel')], 'abel');
      expect(r.first, 'abel');
    });

    test('前缀优于词首，词首优于包含', () async {
      final r = await sub([
        g('xxxabel'),
        g('the abel story'),
        g('abel-01'),
      ], 'abel');
      expect(r, ['abel-01', 'the abel story', 'xxxabel']);
    });

    test('标题命中排在仅标签命中之前', () async {
      final r = await sub([
        g('无关标题', tags: ['abel']),
        g('abel 本子'),
      ], 'abel');
      expect(r.first, 'abel 本子');
      expect(r.length, 2);
    });

    test('字符顺序不一致则匹配不到（这是该算法的已知边界）', () async {
      // HelloWorld 与 HeoolWorld 是"两个字母对调"，子序列要求顺序一致，
      // 因此匹配不到 —— 需要编辑距离算法（见下一组）。
      final r = await sub([g('HelloWorld')], 'HeoolWorld');
      expect(r, isEmpty);
    });

    test('少打一个字母可以命中', () async {
      expect(await sub([g('ginklaga')], 'ginklga'), ['ginklaga']);
    });

    test('字符顺序不对则不匹配', () async {
      expect(await sub([g('abcdef')], 'fedcba'), isEmpty);
    });

    test('同分时保持原有顺序', () async {
      final list = [g('aaa x'), g('aaa y'), g('aaa z')];
      expect(await sub(list, 'aaa'), ['aaa x', 'aaa y', 'aaa z']);
    });

    test('大小写不敏感', () async {
      expect(await sub([g('Abel Story')], 'abel'), hasLength(1));
    });
  });

  group('词级模糊匹配（替代原先的整串编辑距离）', () {
    test('分词：字母数字成词、CJK 一字一词、标点是分隔符', () {
      expect(GallerySearch.tokenize('[Fanbox] ginklaga (2026)'), [
        'fanbox',
        'ginklaga',
        '2026',
      ]);
      // 中文无空格，按一字一词切；否则"比较单位"会退化成整串
      expect(GallerySearch.tokenize('甘城なつき'), ['甘', '城', 'な', 'つ', 'き']);
      expect(GallerySearch.tokenize('a-b_c.d'), ['a', 'b', 'c', 'd']);
      expect(GallerySearch.tokenize('   '), isEmpty);
    });

    test('字母对调能命中 —— 整串算法做不到的核心场景', () async {
      expect(await edit([g('HelloWorld')], 'HeoolWorld'), ['HelloWorld']);
    });

    test('长标题里的某个词打错也能命中（整串编辑距离在此完全失效）', () async {
      // 标题 33 字符、查询 8 字符：长度差远超任何容错上限，
      // 整串编辑距离会把这条在计算之前就剪掉。词级比较不受影响。
      final list = [g('[Fanbox] ginklaga (2026) 全集')];
      expect(await edit(list, 'ginkalga'), hasLength(1));
    });

    test('少打、多打、打错一个字母都能找到', () async {
      expect(await edit([g('HelloWorld')], 'HeloWorld'), ['HelloWorld']);
      expect(await edit([g('HelloWorld')], 'HellooWorld'), ['HelloWorld']);
      expect(await edit([g('HelloWorld')], 'HalloWorld'), ['HelloWorld']);
    });

    test('词序无关：倒过来写也能找到（模糊模式下）', () async {
      // 词序无关是**模糊匹配**的特性；普通包含匹配当然不认倒序，
      // 所以这里必须显式走模糊模式。
      Future<List<String>> fuzzy(String q) async {
        final r = await GallerySearch.run(
          [g('Hello World')],
          SearchInput(query: q, mode: SearchMode.fuzzy),
          algorithm: FuzzyAlgorithm.tokenFuzzy,
        );
        return titlesOf(r.galleries);
      }

      expect(await fuzzy('World Hello'), ['Hello World'], reason: '倒序');
      expect(await fuzzy('hello'), ['Hello World'], reason: '只命中一个词');
      expect(await fuzzy('world'), ['Hello World'], reason: '只命中另一个词');
    });

    test('已知边界：查询连写（worldhello）命中不了分开的两个词', () {
      // `worldhello` 切出来是**一个词**，而标题的词是 `hello` / `world`。
      // 要命中它需要"一个词等于相邻两词的拼接"这条规则，目前没有实现。
      // 这里把边界显式记下来，避免以后误以为"什么写法都能找到"。
      expect(
        GallerySearch.fuzzyTokens([g('Hello World')], 'worldhello'),
        isEmpty,
      );
      // 反过来，标题连写、查询分开则没有问题（因为查询的两个词都能命中它）
      expect(
        GallerySearch.fuzzyTokens([g('HelloWorld')], 'hello world'),
        hasLength(1),
      );
    });

    test('只命中标题里的一个词也算命中', () async {
      final r = await edit([g('naruto 全集 高清'), g('bleach 全集')], '高清');
      expect(r, ['naruto 全集 高清']);
    });

    test('多词查询：命中越多排越前', () async {
      final r = await edit([g('naruto 全集'), g('naruto 全集 高清 收藏')], 'naruto 高清');
      expect(r.first, 'naruto 全集 高清 收藏', reason: '命中 2/2 个查询词的应排在只命中 1/2 的之前');
    });

    test('中文查询能命中中文标题', () async {
      final r = await edit([g('甘城なつき 画集'), g('其他东西')], '甘城');
      expect(r, ['甘城なつき 画集']);
    });

    test('完全相等的排最前（整串相同要压过"首词相同"）', () async {
      final r = await edit([g('a-开头'), g('a')], 'a');
      expect(r.first, 'a');
    });

    test('差距过大则不匹配', () async {
      expect(await edit([g('HelloWorld')], 'zzzzzzzzzz'), isEmpty);
    });

    test('太短的词不做模糊，避免大面积误命中', () async {
      expect(await edit([g('xy')], 'ab'), isEmpty);
    });

    test('标签命中也能找到（补足已关闭，只应返回真正匹配的）', () async {
      final r = await edit([
        g('无关标题', tags: ['HelloWorld']),
        g('HelloWorld 本子'),
      ], 'HelloWorld');
      expect(r.toSet(), {'无关标题', 'HelloWorld 本子'});
    });

    test('完全相等的命中胜过差一个字母的命中', () async {
      // 匹配质量优先于字段位置。
      final r = await edit([
        g('HelloWorldX 本子'),
        g('无关标题', tags: ['HelloWorld']),
      ], 'HelloWorld');
      expect(r.first, '无关标题');
    });

    test('大小写不敏感', () async {
      expect(await edit([g('HelloWorld')], 'helloworld'), ['HelloWorld']);
    });

    test('空查询返回全部', () async {
      final r = await GallerySearch.run(
        [g('a'), g('b')],
        const SearchInput(query: '', mode: SearchMode.fuzzy),
        algorithm: FuzzyAlgorithm.tokenFuzzy,
      );
      expect(r.galleries, hasLength(2));
    });

    group('短查询必须能搜出东西（回归）', () {
      // 曾经的缺陷：单字母查询走编辑距离，而编辑距离要求"整串长度接近"，
      // 于是几十字的长标题全部超出容错 —— 搜 `a` 一条都出不来。
      final list = [g('abel story'), g('Bleach 全集'), g('naruto')];

      test('单字母查询能命中所有含该字母的标题', () async {
        final r = await edit(list, 'a');
        expect(r.toSet(), {
          'abel story',
          'Bleach 全集',
          'naruto',
        }, reason: '三个标题都含字母 a');
      });

      test('单字母查询不会命中不含该字母的标题', () async {
        final r = await edit([g('xyz'), g('abc')], 'a');
        expect(r, ['abc']);
      });

      test('两个字母同样能搜出来', () async {
        expect(await edit(list, 'ab'), contains('abel story'));
      });

      test('单字母查询下完全相等最前、前缀次之', () async {
        final r = await edit([g('b a'), g('a-开头'), g('a')], 'a');
        expect(r.first, 'a', reason: '完全相等优先');
        expect(r[1], 'a-开头', reason: '前缀其次');
      });

      test('短查询也看标签', () async {
        expect(
          await edit([
            g('无关标题', tags: ['a-tag']),
          ], 'a'),
          ['无关标题'],
        );
      });

      test('保持大小写不敏感', () async {
        expect(await edit([g('Abel')], 'a'), ['Abel']);
      });
    });
  });

  group('正则搜索', () {
    test('基本匹配', () async {
      final list = [g('abc123'), g('abc456'), g('xyz')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: r'^abc\d+$', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), [
        'abc123',
        'abc456',
      ], reason: 'xyz 不匹配模式，补足关闭时不应出现');
    });

    test('大小写不敏感', () async {
      final r = await GallerySearch.run([
        g('HelloWorld'),
      ], const SearchInput(query: 'helloworld', mode: SearchMode.regex));
      expect(r.galleries, hasLength(1));
    });

    test('标签也参与匹配', () async {
      final r = await GallerySearch.run([
        g('标题', tags: ['tag-2024']),
      ], const SearchInput(query: r'tag-\d+', mode: SearchMode.regex));
      expect(r.galleries, hasLength(1));
    });

    test('落单的中括号当字面量，不报语法错误', () {
      // 用户没打完括号时，报"正则语法错误"毫无帮助 ——
      // 当成普通字符去搜更合理。
      final r = GallerySearch.regex([g('a[b'), g('其他')], '[unclosed');
      expect(r.error, isNull);
      expect(r.result, isEmpty, reason: '没有标题以字面量 "[unclosed" 开头');

      final hit = GallerySearch.regex([g('[unclosed 本子')], '[unclosed');
      expect(hit.error, isNull);
      expect(hit.result, hasLength(1), reason: '应按字面量匹配到');
    });

    test('真正的正则语法错误仍然报错', () {
      final r = GallerySearch.regex([g('a')], '(unclosed');
      expect(r.result, isNull);
      expect(r.error, contains('正则'));
    });
  });

  group('简化正则（[中文] / [英文] / [数字] / [符号] / [?]）', () {
    test('关键词被替换成对应的字符类，长度不定', () {
      expect(translateSimplifiedRegex('[数字]'), '[0-9]+');
      expect(translateSimplifiedRegex('[英文]'), '[A-Za-z]+');
      // [?] 允许什么都没有，因此 ginkla[?]ga 等价于 ginklaga
      expect(translateSimplifiedRegex('[?]'), '.*');
      // 不含正则元字符的括号按字面文字处理
      expect(translateSimplifiedRegex('[C104]'), '(?:C104)');
      // 含元字符的仍是真正的字符类
      expect(translateSimplifiedRegex('[a-z]'), '[a-z]');
      // 段与段之间自动补"任意内容"
      expect(translateSimplifiedRegex('甘城[数字]'), '甘城.*[0-9]+');
      // 但 `[?]` 本身已是任意内容，旁边不重复补
      expect(translateSimplifiedRegex('[?]Pixiv'), '.*Pixiv');
      expect(translateSimplifiedRegex('Pixiv[?]'), 'Pixiv.*');
    });

    test('英文缩写与中文写法完全等价', () {
      const pairs = {
        '[num]': '[数字]',
        '[en]': '[英文]',
        '[ch]': '[中文]',
        '[mark]': '[符号]',
      };
      pairs.forEach((abbr, chinese) {
        expect(
          translateSimplifiedRegex(abbr),
          translateSimplifiedRegex(chinese),
          reason: '$abbr 应与 $chinese 等价',
        );
      });
    });

    test('缩写能实际搜到（与中文写法结果一致）', () async {
      final list = [g('3361687-[Pixiv] ginklaga'), g('甘城 画集'), g('无编号的东西')];
      for (final pair in [('[num]Pixiv', '[数字]Pixiv'), ('[ch]', '[中文]')]) {
        final a = await GallerySearch.run(
          list,
          parseSearchInput(pair.$1, fuzzySetting: false, regexSetting: false),
        );
        final b = await GallerySearch.run(
          list,
          parseSearchInput(pair.$2, fuzzySetting: false, regexSetting: false),
        );
        expect(
          titlesOf(a.galleries),
          titlesOf(b.galleries),
          reason: '${pair.$1} 与 ${pair.$2} 结果应一致',
        );
        expect(a.galleries, isNotEmpty, reason: '${pair.$1} 应有结果');
      }
    });

    test('紧挨着写与用空格分开完全等价', () async {
      final list = [g('3361687-[Pixiv] ginklaga'), g('别的')];
      final tight = await GallerySearch.run(
        list,
        parseSearchInput('[数字]Pixiv', fuzzySetting: false, regexSetting: false),
      );
      final spaced = await GallerySearch.run(
        list,
        parseSearchInput(
          '[数字] Pixiv',
          fuzzySetting: false,
          regexSetting: false,
        ),
      );
      expect(titlesOf(tight.galleries), ['3361687-[Pixiv] ginklaga']);
      expect(
        titlesOf(spaced.galleries),
        titlesOf(tight.galleries),
        reason: '中文用户不会特意加空格，两种写法必须等价',
      );
    });

    test('[数字] 匹配不定长度的数字', () async {
      final list = [g('3361687-标题'), g('42-标题'), g('没有数字')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: '[数字]', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), [
        '3361687-标题',
        '42-标题',
      ], reason: '一位与七位都应命中');
    });

    test('[中文] 匹配汉字', () async {
      final list = [g('中文标题'), g('English Only'), g('かな 标题')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: '[中文]', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), [
        '中文标题',
        'かな 标题',
      ], reason: '假名与汉字同样按"中文"处理（与分词规则一致）');
    });

    test('[英文] 匹配字母', () async {
      final list = [g('Azur Lane'), g('123')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: '[英文]', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), ['Azur Lane']);
    });

    test('[符号] 匹配标点', () async {
      final list = [g('-以符号开头'), g('以字开头')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: '[符号]', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), ['-以符号开头']);
    });

    test('[?] 就是"任意内容"，前后隐式补的 .* 已经覆盖了它', () async {
      final list = [
        g('3361687-[Pixiv] 雪代'),
        g('3361687-别的'),
        g('别的-3361687'),
        g('ginklaga'),
      ];

      // [数字] 单独用：含数字的都命中
      final digits = await GallerySearch.run(
        list,
        const SearchInput(query: '[数字]', mode: SearchMode.regex),
      );
      expect(titlesOf(digits.galleries), hasLength(3));

      // 加上 [?] 与不加，结果一致 —— 因为翻译后前后本来就有 .*，
      // [?] 的 ".+" 又能被那些 .* 让出字符，因此它不构成额外约束。
      final withQ = await GallerySearch.run(
        list,
        const SearchInput(query: '[数字][?]', mode: SearchMode.regex),
      );
      expect(
        titlesOf(withQ.galleries),
        hasLength(3),
        reason: '与 [数字] 等价：任意内容本来就是默认行为',
      );
    });

    test('[?] 允许中间什么都没有，因此等价于可省略', () async {
      // ginkla[?]ga 与 ginklaga 等价 —— 这正是 [?] 的语义。
      final list = [g('ginkla ga'), g('ginklaXga'), g('ginklaga')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: 'ginkla[?]ga', mode: SearchMode.regex),
      );
      expect(
        titlesOf(r.galleries),
        hasLength(3),
        reason: '空、一个字符、甚至空格都算"任意内容"',
      );
    });

    test('[?] 单独用于"这里有什么但我不记得"', () async {
      final list = [g('雪代 画集'), g('甘城 画集'), g('雪代')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: '雪代[?]', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), ['雪代 画集', '雪代'], reason: '雪代后面可以什么都没有');

      final reversed = await GallerySearch.run(
        list,
        const SearchInput(query: '[?]画集', mode: SearchMode.regex),
      );
      expect(titlesOf(reversed.galleries), ['雪代 画集', '甘城 画集']);
    });

    test('关键词之外的写法仍按正则处理', () async {
      final list = [g('abc'), g('123'), g('xyz')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: '[a-c]', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), ['abc'], reason: '[a-c] 仍是正则字符类');
    });

    test('大小写不敏感（关键词与正则一致）', () async {
      final list = [g('abc'), g('ABC'), g('123')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: '[a-c]', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), [
        'abc',
        'ABC',
      ], reason: '搜索整体是大小写不敏感的，字符类也不例外');
    });

    test('任意位置匹配，与常规搜索一致', () async {
      final list = [g('English 开头的标题'), g('中间 English 后面'), g('没有')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: '[英文]', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), [
        'English 开头的标题',
        '中间 English 后面',
      ], reason: '英文出现在哪都能命中 —— 这正是常规搜索的行为');
    });

    test('要限定开头可自己写 ^', () async {
      final list = [g('English 开头的标题'), g('中间 English 后面')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: '^English', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), [
        'English 开头的标题',
      ], reason: '^ 由正则引擎处理，因此只认开头的');
    });

    test('`^` 与关键词同用时仍限定开头（位置约束已实现）', () async {
      final list = [g('English 开头的标题'), g('中间 English 后面')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: '^[en]', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), [
        'English 开头的标题',
      ], reason: '^ 要求标题以该关键词那类字符开头');

      // 不加 ^ 就是"含有"
      final contains = await GallerySearch.run(
        list,
        const SearchInput(query: '[en]', mode: SearchMode.regex),
      );
      expect(titlesOf(contains.galleries), ['English 开头的标题', '中间 English 后面']);
    });

    test('关键词是"含有"的过滤器，与位置无关（这是支持中文的关键）', () async {
      // 用户报"还是不支持中文"就是因为关键词被当成位置约束：
      // `[ch]玖町` 曾译成 `[汉字]+玖町`，要求汉字紧挨着"玖町"，
      // 而真实标题是 `[Pixiv] 玖町`，于是永远搜不到。
      final list = [
        g('[Pixiv] 玖町 (29467962)'), // 中文不在"玖町"前面，但确实有中文
        g('玖町'), // 有中文
        g('Kudamachi'), // 没有中文
      ];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: '[ch]玖町', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), [
        '[Pixiv] 玖町 (29467962)',
        '玖町',
      ], reason: '只要求"有中文且有玖町"，不要求中文排在前面');
    });

    test('全角问号 [？] 与半角 [?] 等价', () {
      expect(kRegexKeywords.containsKey('？'), isTrue);
      expect(translateSimplifiedRegex('[？]'), translateSimplifiedRegex('[?]'));
    });

    test('[？] 能实际用于搜索', () async {
      final list = [g('ginkla ga'), g('ginklaga'), g('别的')];
      final r = await GallerySearch.run(
        list,
        const SearchInput(query: 'ginkla[？]ga', mode: SearchMode.regex),
      );
      expect(titlesOf(r.galleries), ['ginkla ga', 'ginklaga']);
    });

    test('usesSimplifiedRegex 能识别是否用了关键词', () {
      expect(usesSimplifiedRegex('[中文]'), isTrue);
      expect(usesSimplifiedRegex('[?]'), isTrue);
      expect(usesSimplifiedRegex('[a-z]'), isFalse);
      expect(usesSimplifiedRegex('普通文本'), isFalse);
    });

    group('与常规搜索配合：关键词可以和普通文字混写', () {
      test('混写直接可用，不必把整串包起来', () {
        expect(
          parseSearchInput(
            '甘城[数字]',
            fuzzySetting: false,
            regexSetting: false,
          ).mode,
          SearchMode.regex,
          reason: '出现关键词即走正则，位置随意',
        );
      });

      test('文字 + 数字混写：两者都是"含有"条件', () async {
        final list = [
          g('甘城2026 画集'),
          g('2026 甘城'), // 数字在前，但同样"有甘城且有数字"
          g('甘城 画集'), // 没有数字
          g('2026 画集'), // 没有甘城
        ];
        final r = await GallerySearch.run(
          list,
          parseSearchInput('甘城[数字]', fuzzySetting: false, regexSetting: false),
        );
        expect(titlesOf(r.galleries), [
          '甘城2026 画集',
          '2026 甘城',
        ], reason: '[数字] 是过滤器（标题里有数字），不限定位置');
      });

      test('已知取舍：多个关键词之间不表达位置关系', () async {
        // 关键词都是"含有"条件，因此 `甘城[?][数字]` 与 `甘城[数字]` 等价。
        // 要表达"数字排在甘城之后"得写纯正则：`甘城.*[0-9]`。
        final list = [g('甘城2026 画集'), g('2026 甘城')];
        final withQ = await GallerySearch.run(
          list,
          parseSearchInput(
            '甘城[?][数字]',
            fuzzySetting: false,
            regexSetting: false,
          ),
        );
        expect(titlesOf(withQ.galleries), ['甘城2026 画集', '2026 甘城']);

        final pureRegex = await GallerySearch.run(
          list,
          const SearchInput(query: r'甘城.*[0-9]', mode: SearchMode.regex),
        );
        expect(titlesOf(pureRegex.galleries), [
          '甘城2026 画集',
        ], reason: '纯正则可精确表达顺序');
      });

      test('多个关键词混用', () async {
        final list = [
          g('3361687-[Pixiv] 雪代'),
          g('3361687-雪代'), // 中括号那段没有 —— [?] 允许空，因此也命中
          g('abc-[Pixiv] 雪代'), // 开头不是数字
        ];
        final r = await GallerySearch.run(
          list,
          parseSearchInput(
            '[数字]-[?]雪代',
            fuzzySetting: false,
            regexSetting: false,
          ),
        );
        expect(titlesOf(r.galleries), [
          '3361687-[Pixiv] 雪代',
          '3361687-雪代',
        ], reason: '[?] 可以什么都没有；第三条没有数字所以不命中');
      });

      test('纯普通输入仍然走普通匹配（没被正则抢走）', () {
        expect(
          parseSearchInput('甘城', fuzzySetting: false, regexSetting: false).mode,
          SearchMode.plain,
        );
      });

      test('作品编号这类 [C104] 按里面的文字搜，不被当字符类吃掉', () {
        // 若当字符类，`[C104]` 会变成"匹配 C/1/0/4 中的一个字符"。
        // 现在剥掉括号按内容 `C104` 做普通搜索 —— 带不带括号的标题都能找到。
        final input = parseSearchInput(
          '[C104]',
          fuzzySetting: false,
          regexSetting: false,
        );
        expect(input.mode, SearchMode.plain);
        expect(input.query, 'C104');

        // 确实在写正则的（含元字符或字符类语法）仍按正则处理
        expect(translateSimplifiedRegex('[a-z]'), '[a-z]');
        expect(translateSimplifiedRegex('[^abc]'), '[^abc]');
      });

      test('[C104] 能按字面量搜到（含无括号的）', () async {
        final list = [g('[C104] 合订本'), g('C104 无括号'), g('无关')];
        final r = await GallerySearch.run(
          list,
          parseSearchInput('[C104]', fuzzySetting: false, regexSetting: false),
        );
        expect(titlesOf(r.galleries), [
          '[C104] 合订本',
          'C104 无括号',
        ], reason: '搜的是文字 C104，出现在哪都算');
      });

      test('想只搜带括号的原文，用反斜杠转义', () async {
        final list = [g('[C104] 合订本'), g('C104 无括号')];
        final r = await GallerySearch.run(
          list,
          const SearchInput(query: r'\[C104\]', mode: SearchMode.regex),
        );
        expect(titlesOf(r.galleries), ['[C104] 合订本']);
      });

      test('设置里开了正则时，直接写关键词即可（不用再加括号）', () {
        final input = parseSearchInput(
          '[数字]',
          fuzzySetting: false,
          regexSetting: true,
        );
        expect(input.mode, SearchMode.regex);
        expect(input.query, '[数字]', reason: '关键词写法原样保留，由翻译层处理');

        final plainText = parseSearchInput(
          '甘城',
          fuzzySetting: false,
          regexSetting: true,
        );
        expect(plainText.mode, SearchMode.regex, reason: '开关打开后，普通文字也按正则处理');
      });

      test('`**` 模糊前缀仍然可用（关键词优先，但前缀没被破坏）', () {
        final input = parseSearchInput(
          '**ginklaga',
          fuzzySetting: false,
          regexSetting: false,
        );
        expect(input.mode, SearchMode.fuzzy);
        expect(input.query, 'ginklaga');
      });

      test('正则与模糊互不干扰：同一批数据按需切换', () async {
        final list = [g('ginklaga 全集'), g('ginkalga 全集')];
        // 模糊（词级）能找到拼错的
        final fuzzy = await GallerySearch.run(
          list,
          parseSearchInput(
            '**ginkalga',
            fuzzySetting: false,
            regexSetting: false,
          ),
          algorithm: FuzzyAlgorithm.tokenFuzzy,
        );
        expect(fuzzy.galleries, hasLength(2));

        // 正则只认字面
        final regex = await GallerySearch.run(
          list,
          parseSearchInput('[英文] 全集', fuzzySetting: false, regexSetting: false),
        );
        expect(regex.galleries, hasLength(2), reason: '两条都以英文开头');
      });
    });
  });

  group('不做事后补足：只返回真正匹配的', () {
    List<Gallery> many(int n) => List.generate(n, (i) => g('item $i'));

    test('只有 1 条匹配时就只返回 1 条', () async {
      final list = [g('only-one-match'), ...many(30)];
      final r = await GallerySearch.run(
        list,
        parseSearchInput(
          'only-one-match',
          fuzzySetting: false,
          regexSetting: false,
        ),
      );
      expect(r.galleries, hasLength(1), reason: '不补足 —— 结果里每一项都必须是真实匹配');
      expect(r.galleries.single.id, 'only-one-match');
      expect(r.matched, 1);
    });

    test('完全没有匹配时返回空，而不是塞满一屏无关内容', () async {
      final r = await GallerySearch.run(
        many(20),
        parseSearchInput('zzzzzz', fuzzySetting: false, regexSetting: false),
      );
      expect(r.galleries, isEmpty);
      expect(r.matched, 0);
    });

    test('模糊匹配的弱结果会全部返回并按分数排到最后', () async {
      // 不做补足，但"分数低的也一起排进去" —— 它们自然沉到后面。
      final list = [
        g('abel'), // 完全命中，最高分
        ...many(20),
      ];
      final r = await GallerySearch.run(
        list,
        parseSearchInput('abel', fuzzySetting: true, regexSetting: false),
      );
      expect(r.galleries.first.id, 'abel');
      // item N 里不含 a/b/e/l 的组合，模糊匹配不应把它们算作匹配
      for (final gal in r.galleries) {
        expect(gal.id.contains('item'), isFalse, reason: '毫不相关的不应出现在结果里');
      }
    });

    test('限制条数时按下限与上限的正常区间截断', () async {
      final r = await GallerySearch.run(
        many(100),
        parseSearchInput('item', fuzzySetting: true, regexSetting: false),
        limit: 25,
      );
      expect(r.galleries, hasLength(25));
    });

    test('低于下限时抬到下限', () async {
      final r = await GallerySearch.run(
        many(100),
        parseSearchInput('item', fuzzySetting: true, regexSetting: false),
        limit: 4,
      );
      expect(r.galleries, hasLength(kMinSearchLimit));
    });

    test('0 表示不限：匹配多少返回多少', () async {
      final r = await GallerySearch.run(
        many(120),
        parseSearchInput('item', fuzzySetting: true, regexSetting: false),
        limit: 0,
      );
      expect(r.galleries, hasLength(120));
    });
  });

  group('性能（2000 个图集）', () {
    List<Gallery> realistic(int n) => List.generate(
      n,
      (i) => g(
        '[$i] (C${i % 100}) [Circle ${i % 500}] '
        'Some Doujinshi Title Number $i (Japanese)',
      ),
    );

    test('子序列算法：连续输入仍在预算内', () async {
      final list = realistic(2000);
      await sub(list, 'circle');
      final sw = Stopwatch()..start();
      for (final q in ['c', 'ci', 'cir', 'circ', 'circl', 'circle']) {
        await sub(list, q);
      }
      sw.stop();
      final per = sw.elapsedMilliseconds / 6;
      expect(
        per,
        lessThan(150),
        reason: '平均每次 ${per.toStringAsFixed(1)}ms，输入会卡',
      );
    });

    test('编辑距离算法：2000 个候选的批量计算仍可接受', () async {
      final list = realistic(2000);
      final sw = Stopwatch()..start();
      await edit(list, 'circle');
      sw.stop();
      // 测试环境走 Dart 回退实现（没有原生通道），真机由 Kotlin 执行会更快，
      // 因此这个上限取得比较宽松，主要用于防止复杂度退化成 O(n×m)。
      expect(
        sw.elapsedMilliseconds,
        lessThan(3000),
        reason: '耗时 ${sw.elapsedMilliseconds}ms，疑似未做带状优化',
      );
    });
  });
}

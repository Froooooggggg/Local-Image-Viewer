import 'dart:math' as math;

import 'models.dart';

/// 搜索输入解析结果。
class SearchInput {
  const SearchInput({required this.query, required this.mode, this.regexError});

  /// 去掉标记之后的实际查询词。
  final String query;

  /// 本次应采用的搜索方式。
  final SearchMode mode;

  /// 正则表达式非法时的错误信息（此时应提示用户而不是返回空结果）。
  final String? regexError;

  bool get isEmpty => query.isEmpty;
}

/// 强制启用模糊搜索的前缀标记。
///
/// 搜索串以这两个字符开头时，本次搜索**一律走模糊匹配**，并把标记本身去掉。
/// 用 `**` 而不是 `$*`：后者要切换到符号键盘才能输入，不方便。
const String kFuzzyTrigger = '**';

/// 强制启用**正则搜索**的标记：用一对中括号包住表达式。
///
/// 形如 `[^\[.*\.jpg$]` 会被识别为正则，外层的 `[]` 去掉。
const String kRegexOpen = '[';
const String kRegexClose = ']';

/// 简化正则的**关键词表**（中文与英文缩写等价）。
///
/// 记不清某一段具体是什么时，用中括号写一个关键词代替：
///
/// | 写法 | 等价写法 | 含义 |
/// |---|---|---|
/// | `[中文]` | `[ch]` | 一个或多个汉字（含日文假名、韩文）|
/// | `[英文]` | `[en]` | 一个或多个英文字母 |
/// | `[数字]` | `[num]` | 一个或多个数字 |
/// | `[符号]` | `[mark]` | 一个或多个标点/符号 |
/// | `[?]` | | 任意内容，**可以什么都没有** |
///
/// 长度不定：`[数字]` 既能匹配 `1` 也能匹配 `2026`。
///
/// `[?]` 是 `.*` 而不是 `.+`：它是"这一段我记不清、也可能根本不存在"，
/// 因此 `ginkla[?]ga` 与 `ginklaga` 等价。
///
/// 关键词之外的 `[...]` 分两种情况：
///   * 含正则元字符（`[a-z]`、`[^abc]`）→ 按真正的字符类处理
///   * 不含（`[C104]`）→ 当成用户要找的**字面文字**
const Map<String, String> kRegexKeywords = {
  // 中文关键字
  '中文': r'[\u4e00-\u9fff\u3400-\u4dbf\u3040-\u30ff\uac00-\ud7af\uff66-\uff9d]+',
  '英文': r'[A-Za-z]+',
  '数字': r'[0-9]+',
  '符号': r'[^A-Za-z0-9\u4e00-\u9fff\u3400-\u4dbf\u3040-\u30ff\uac00-\ud7af\uff66-\uff9d]+',
  // 英文缩写（与上面完全等价，方便少打字/切换输入法）
  'ch': r'[\u4e00-\u9fff\u3400-\u4dbf\u3040-\u30ff\uac00-\ud7af\uff66-\uff9d]+',
  'en': r'[A-Za-z]+',
  'num': r'[0-9]+',
  'mark': r'[^A-Za-z0-9\u4e00-\u9fff\u3400-\u4dbf\u3040-\u30ff\uac00-\ud7af\uff66-\uff9d]+',
  // 任意内容。`？` 是全角问号 —— 中文输入法下很容易打出来，一并支持。
  '?': r'.*',
  '？': r'.*',
};

/// 把"简化正则"翻译成真正的正则。
///
/// 处理两件事：
///   1. `[关键词]` → 对应的字符类（长度不定）
///   2. 关键词之外的 `[...]` 原样保留（仍是正则字符类）
///
/// **前后隐式补上 `.*`**：写出来的片段只要**按顺序出现**就算命中，
/// 不必管它位于标题的哪里、中间隔着什么。
///
/// 这一条解决了两个反复出现的问题：
///   * `gink[?]aga` 不必要求标题以 `gink` 开头；
///   * `[数字] 雪代` 不必要求数字后面紧跟空格和雪代
///     （真实标题是 `3361687-[Pixiv] 雪代`，中间隔着东西）。
///
/// 已经自己写了 `^` / `$` 的话就不再补那一侧 —— 否则锚点会被 `.*` 抵消，
/// 变成"写了也没用"。
RegExp compileSimplifiedRegex(String pattern) {
  final body = translateSimplifiedRegex(pattern);

  // 翻译结果自己已经以 `.*` 开头/结尾时（例如 `[?]Pixiv` → `.*Pixiv`），
  // 就不要再补，否则会出现 `.*.*`。
  final startsAny = body.startsWith(r'.*');
  final endsAny = body.endsWith(r'.*') && !body.endsWith(r'\.*');

  // 自己写了锚点的那一侧也不补 —— 否则锚点会被 `.*` 抵消，写了没用。
  final startsAnchored = _startsWithUnescaped(body, '^');
  final endsAnchored = _endsWithUnescaped(body, r'$');

  final buf = StringBuffer();
  if (!startsAny && !startsAnchored) buf.write('.*');
  buf.write(body);
  if (!endsAny && !endsAnchored) buf.write('.*');
  return RegExp(buf.toString(), caseSensitive: false);
}

/// 判断字符串是否以某个**未被转义**的字符开头。
bool _startsWithUnescaped(String s, String ch) {
  if (s.isEmpty || s[0] != ch) return false;
  return true;
}

/// 判断字符串是否以某个**未被转义**的字符结尾。
///
/// 需要数前面连续反斜杠的个数：`\$` 是字面量美元，`\\$` 才是转义符 + 锚点。
bool _endsWithUnescaped(String s, String ch) {
  if (s.isEmpty || !s.endsWith(ch)) return false;
  var backslashes = 0;
  for (var i = s.length - 2; i >= 0 && s[i] == r'\'; i--) {
    backslashes++;
  }
  return backslashes.isEven;
}

/// 从输入里取出所有**关键词**（`[ch]`/`[num]`/`[?]` 等）。
///
/// 关键词是**对标题的要求**，不是位置约束，因此单独提取出来。
List<String> keywordsOf(String pattern) {
  // 整串是一段完整正则 → 里面没有"关键词"这回事。
  if (_looksLikeRawRegex(pattern)) return const [];
  final out = <String>[];
  for (final piece in _splitPieces(pattern)) {
    if (_isKeyword(piece)) {
      out.add(piece.substring(1, piece.length - 1));
    }
  }
  return out;
}

/// 整串是否被一对中括号包住，且里面是**完整的正则**。
bool _isWrappedInBrackets(String s) => _looksLikeRawRegex(s);

/// 去掉关键词后剩下的部分，就是要**查找的文字**（段间补"任意内容"）。
///
/// 关键词两侧的 `^` / `$` 会被去掉：它们约束的是**位置**，
/// 由 [startsWithKeyword] / [endsWithKeyword] 单独判断，
/// 混在字面正则里只会互相干扰（`^` 后面跟 `.*` 就等于没有 `^`）。
String literalOf(String pattern) {
  // 整串是一段完整正则（`[a-c]`、`[^x.*]`）时**连同括号一起交给引擎**。
  // 剥掉括号会把 `[a-c]` 变成字面量 `a-c`，字符类语义直接丢失。
  if (_looksLikeRawRegex(pattern)) return pattern;

  final pieces = _splitPieces(pattern);
  final buf = StringBuffer();
  // 上一段是关键词？—— 决定当前段前面要不要补"任意内容"。
  // 关键词与它紧邻的文字之间**必须**补：`[ch]玖町` 若成了 `[汉字]+玖町`，
  // 就要求汉字紧挨着"玖町"，而真实标题是 `[Pixiv] 玖町`，永远搜不到。
  var prevWasKeyword = false;

  for (final piece in pieces) {
    if (_isKeyword(piece)) {
      // `[?]` 本身就是任意内容，直接写出来；其余关键词只做标记。
      final name = piece.substring(1, piece.length - 1);
      if (kRegexKeywords[name] == _kAnyContent) {
        if (buf.isNotEmpty && !_endsWithAny(buf)) buf.write(_kAnyContent);
        if (buf.isEmpty) buf.write(_kAnyContent);
      }
      prevWasKeyword = true;
      continue;
    }

    // 关键词紧邻的锚点丢掉（位置约束由 startsWithKeyword 等单独处理）。
    var text = piece;
    if (prevWasKeyword && text.startsWith(r'$')) text = text.substring(1);
    if (text.endsWith('^') && _nextIsKeyword(pieces, piece)) {
      text = text.substring(0, text.length - 1);
    }
    if (text.isEmpty) continue;

    if (buf.isNotEmpty && !prevWasKeyword && !_endsWithAny(buf)) {
      buf.write(_kAnyContent);
    }
    buf.write(text);
    prevWasKeyword = false;
  }
  return buf.toString();
}

/// 已写出的内容是否以"任意内容"结尾（避免写出 `.*.*`）。
bool _endsWithAny(StringBuffer buf) => buf.toString().endsWith(_kAnyContent);

/// 某一段之后是否紧跟关键词（用于判断 `^` 是不是"关键词的开头锚点"）。
bool _nextIsKeyword(List<String> pieces, String piece) {
  final i = pieces.indexOf(piece);
  return i >= 0 && i + 1 < pieces.length && _isKeyword(pieces[i + 1]);
}

/// 输入是否形如 `^[关键词]…`（要求标题**以该类字符开头**）。
bool startsWithKeyword(String pattern) {
  if (_isWrappedInBrackets(pattern)) return false;
  final pieces = _splitPieces(pattern);
  return pieces.length >= 2 && pieces[0].endsWith('^') && _isKeyword(pieces[1]);
}

/// 输入是否形如 `…[关键词]$`（要求标题**以该类字符结尾**）。
bool endsWithKeyword(String pattern) {
  if (_isWrappedInBrackets(pattern)) return false;
  final pieces = _splitPieces(pattern);
  final n = pieces.length;
  return n >= 2 && pieces[n - 1].startsWith(r'$') && _isKeyword(pieces[n - 2]);
}

/// 取形如 `^[关键词]…` 里那个关键词的判据；取不到返回 null。
KeywordTest? _firstKeywordTest(String pattern) {
  final pieces = _splitPieces(pattern);
  if (pieces.length < 2) return null;
  return _testForPiece(pieces[1]);
}

/// 取形如 `…[关键词]$` 里那个关键词的判据；取不到返回 null。
KeywordTest? _lastKeywordTest(String pattern) {
  final pieces = _splitPieces(pattern);
  final n = pieces.length;
  if (n < 2) return null;
  return _testForPiece(pieces[n - 2]);
}

KeywordTest? _testForPiece(String piece) {
  if (!_isKeyword(piece)) return null;
  return kKeywordTests[piece.substring(1, piece.length - 1)];
}

/// 输入里是否**含**简化关键词（`[ch]`/`[num]`/`[?]` 等）。
///
/// 与 [keywordsOf] 的区别：本函数不过"整串括号"那道早退，
/// 因此 `[数字]-[?][符号]` 这种含标点的混写也能被识别出来。
bool hasAnyKeyword(String pattern) {
  for (final piece in _splitPieces(pattern)) {
    if (_isKeyword(piece)) return true;
  }
  return false;
}

/// 这一段是不是关键词（`[ch]`/`[num]`/`[?]` 等）。
bool _isKeyword(String piece) {
  if (!piece.startsWith(kRegexOpen) || !piece.endsWith(kRegexClose)) {
    return false;
  }
  return kRegexKeywords.containsKey(piece.substring(1, piece.length - 1));
}

/// 输入里是否用了**简化关键词**（`[ch]`/`[num]`/`[?]` 等）。
///
/// 注意与"该不该走正则"是两件事：
///   * 本函数只判断有没有关键词，供界面提示与解析分流使用；
///   * 是否走正则见 [parseSearchInput]（关键词或正则元字符都算）。
bool usesSimplifiedRegex(String pattern) => keywordsOf(pattern).isNotEmpty;

/// 判断一段文字是否含有某类字符。
typedef KeywordTest = bool Function(String text);

/// 各关键词的判据。
/// 各关键词的判据。`[?]` 不产生约束（任意内容本来就有），因此不在此表中。
final Map<String, KeywordTest> kKeywordTests = {
  '中文': _hasCjk,
  'ch': _hasCjk,
  '英文': _hasAsciiLetter,
  'en': _hasAsciiLetter,
  '数字': _hasDigit,
  'num': _hasDigit,
  '符号': _hasMark,
  'mark': _hasMark,
};

bool _hasCjk(String s) => s.runes.any(_isCjkRune);

bool _hasAsciiLetter(String s) =>
    s.runes.any((r) => (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A));

bool _hasDigit(String s) => s.runes.any((r) => r >= 0x30 && r <= 0x39);

bool _hasMark(String s) => s.runes.any(
  (r) => !_isCjkRune(r) && !_isAsciiLetterRune(r) && !_isDigitRune(r),
);

/// CJK 统一表意文字、日文假名、韩文音节。
bool _isCjkRune(int r) =>
    (r >= 0x4E00 && r <= 0x9FFF) ||
    (r >= 0x3400 && r <= 0x4DBF) ||
    (r >= 0x3040 && r <= 0x30FF) ||
    (r >= 0xAC00 && r <= 0xD7AF) ||
    (r >= 0xFF66 && r <= 0xFF9D);

bool _isAsciiLetterRune(int r) =>
    (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A);

bool _isDigitRune(int r) => r >= 0x30 && r <= 0x39;

/// 只做关键词替换与字面量转义，不加锚点（便于单独测试与复用）。
///
/// **每一段之间都补上"任意内容"**：写出来的片段只要**按顺序出现**就算命中。
///
/// "段"的边界是：方括号段落（`[数字]`、`[?]`、`[C104]`）、以及被空白分开的
/// 普通文字。因此下面这些写法**完全等价**：
///
///     [数字]Pixiv      紧挨着写
///     [数字] Pixiv     用空格分开
///     都是 .*[0-9]+.*Pixiv.*
///
/// 这一点很关键：只把空格当分隔符是不够的 —— 中文用户不会特意加空格，
/// 而"紧挨着写"如果要求两段相邻，`[数字]Pixiv` 就永远匹配不到
/// `3361687-[Pixiv] ...` 这种真实标题（中间隔着 `-[`）。
///
/// 注意：关键词的**位置**其实不参与匹配（见 [keywordsOf]）——
/// 真正生效的是"这一侧要不要补任意内容"，用于保证字面文字的查找不受位置影响。
String translateSimplifiedRegex(String pattern) {
  final pieces = _splitPieces(pattern);
  return _translateLiteral(pieces.map(_translatePiece).join(_kAnyContent));
}

/// 把字面片段拼起来，段间补"任意内容"。
String _translateLiteral(String joined) {
  // `[?]` 本身已是任意内容，旁边再补属于重复。
  final deduped = joined.replaceAll(_kAnyContent * 2, _kAnyContent);
  return deduped;
}

/// `[?]` 翻译后的形态（也是拼接时用的"任意内容"）。
const String _kAnyContent = r'.*';

/// 把输入拆成"段"。
///
/// 规则：
///   * `[` 到匹配的 `]` 是一段（关键词或正则字符类）
///   * **其余文字连成一段**，其中的空白当分隔符（因此普通文字里的空格是
///     "任意内容"而不是必须匹配的字面空格）；需要字面空格时写 `\ `
///
/// 为什么普通文字要连成一段：若按空白逐词切开，`^[A-Za-z]` 会变成
/// `^` + `[A-Za-z]` 两段，拼接时中间被塞进 `.*`，锚点就废了。
List<String> _splitPieces(String pattern) {
  final pieces = <String>[];
  final buf = StringBuffer();

  /// 把累积的普通文字按空白切分后加入（空白视为"任意内容"）。
  void flushText() {
    if (buf.isEmpty) return;
    for (final part in buf.toString().split(RegExp(r'\s+'))) {
      if (part.isNotEmpty) pieces.add(part);
    }
    buf.clear();
  }

  var i = 0;
  while (i < pattern.length) {
    final ch = pattern[i];
    if (ch == r'\' && i + 1 < pattern.length) {
      // 转义的下一个字符原样保留（`\ ` 是字面空格，`\[` 是字面中括号）。
      buf.write(ch);
      buf.write(pattern[i + 1]);
      i += 2;
      continue;
    }
    if (ch == kRegexOpen) {
      final close = pattern.indexOf(kRegexClose, i + 1);
      if (close > i) {
        flushText();
        pieces.add(pattern.substring(i, close + 1));
        i = close + 1;
        continue;
      }
      buf.write(RegExp.escape(ch));
      i++;
      continue;
    }
    if (ch == kRegexClose) {
      buf.write(RegExp.escape(ch));
      i++;
      continue;
    }
    buf.write(ch);
    i++;
  }
  flushText();
  return pieces;
}

/// 翻译单个"段"：可能是方括号段落，也可能是普通文字。
String _translatePiece(String piece) {
  if (!piece.startsWith(kRegexOpen) || !piece.endsWith(kRegexClose)) {
    return piece; // 普通文字：原样交给正则引擎
  }
  final inner = piece.substring(1, piece.length - 1);
  final keyword = kRegexKeywords[inner];
  if (keyword != null) return keyword;
  // 含正则元字符、或含字符类的 `-`/`^` → 是真正的字符类，原样保留。
  // 漏了这一步会把 `[a-c]` 转义成字面量 `a-c`，正则类直接失效。
  if (_hasRegexMeta(inner) || _hasClassRangeOrNegation(inner)) return piece;
  // 剩下的（如作品编号 `[C104]`）是用户想找的**字面文字**。
  // 若当字符类，`[C104]` 会变成"匹配 C/1/0/4 中的一个字符"，那不是用户的意思。
  return '(?:${RegExp.escape(inner)})';
}

/// 文本里是否含正则元字符（用于判断"用户是不是在写正则"）。
///
/// **不含 `-` 和 `]`**：
///   * `-` 只在字符类内部才是元字符，普通文字里是破折号（`well-known`）；
///   * 落单的 `]`（如 `abc]`）纯粹是普通字符。
/// 把它们算进来会让"搜带破折号或括号的文字"被误当成正则，从而搜不到。
bool _hasRegexMeta(String s) {
  const meta = r'^$.*+?(){}|\';
  for (var i = 0; i < s.length; i++) {
    if (meta.contains(s[i])) return true;
  }
  return false;
}

/// 字符类内部是否含"范围/取反"这类信号（`-`、`^`）。
///
/// 单独判断是因为 `-` 只在 `[...]` 里才有正则含义：
/// `[a-z]` 是范围，而 `abc-def` 只是普通文字。
bool _hasClassRangeOrNegation(String inner) =>
    inner.contains('-') || inner.startsWith('^');

/// 输入是否"整串是一段完整正则"（`[^a.*b$]`、`[a-z]`、`[**x]` 这类）。
///
/// 判断依据：被一对中括号包住 + 内容含正则元字符 + **本身不是关键词**
/// （否则 `[?]` 会被剥成 `?`、`[数字]` 被剥成 `数字`，关键词功能直接失效）。
bool _looksLikeRawRegex(String s) {
  if (s.length < 2 || !s.startsWith(kRegexOpen) || !s.endsWith(kRegexClose)) {
    return false;
  }
  final inner = s.substring(1, s.length - 1);
  if (kRegexKeywords.containsKey(inner)) return false;
  // **这一对中括号必须是唯一的一对**，否则里面装的就是关键词/字面段落，
  // 剥掉外层会把它们毁掉。曾经的判据只看"首尾是括号 + 内含元字符"，
  // 于是 `[数字][?]` 被剥成 `数字][?`、`[?]Pixiv[?]` 被剥成 `?]Pixiv[?`，
  // 关键词与通配符全部失效。
  if (inner.contains(kRegexOpen) || inner.contains(kRegexClose)) return false;
  // 括号内的 `-`/`^` 是字符类语法（`[a-z]`、`[^abc]`），也要算作正则。
  return _hasRegexMeta(inner) || _hasClassRangeOrNegation(inner);
}

/// 解析用户在搜索栏里的输入。
///
/// 识别顺序（先到先得）：
///   1. `**` 开头 → 模糊模式（并把标记去掉）。
///   2. 用了**简化关键词**（`[ch]`/`[num]`/`[?]`…），或含**正则元字符**
///      （`^ $ . * + ? ( ) { } | \`）→ 正则模式。
///      关键词不要求括号在首尾，因此可以混写：`甘城[num]`、`[ch][num]-[en]`。
///   3. 整串被一对中括号包住 → 正则模式（去掉外层括号）。
///   4. 设置里开了正则 → 正则模式。
///   5. 设置里开了模糊 → 模糊模式。
///   6. 否则 → 普通包含匹配。
///
/// 注意第 2 条里"含正则元字符"这一项：用户直接写 `^[A-Za-z]` 或
/// `甘城.*[0-9]` 时显然是在写正则，不该被当成普通文字搜。
SearchInput parseSearchInput(
  String raw, {
  required bool fuzzySetting,
  required bool regexSetting,
  FuzzyAlgorithm algorithm = FuzzyAlgorithm.subsequence,
}) {
  final text = raw.trim();

  // 1) 整串被一对中括号包住，且里面确实是正则（含元字符）→ 剥掉外层括号。
  //
  // 必须排在最前：`[**x]` 里的 `**` 是正则内容而不是模糊标记。
  //
  // 但**只在内容含正则元字符时才剥**：`[数字]` 里的括号是关键词标记，
  // 剥掉就变成普通文字"数字"了；`[a-z]` 本身就是合法的正则字符类，
  // 也不该被剥（剥了变成 `a-z`，含义完全不同）。
  if (_isWrappedInBrackets(text) &&
      _hasRegexMeta(text.substring(1, text.length - 1))) {
    return SearchInput(
      query: text.substring(1, text.length - 1),
      mode: SearchMode.regex,
    );
  }

  // 2) `**` 前缀模糊。
  if (text.startsWith(kFuzzyTrigger)) {
    return SearchInput(
      query: text.substring(kFuzzyTrigger.length).trim(),
      mode: SearchMode.fuzzy,
    );
  }

  // 3) 关键词或正则元字符 → 正则。
  //
  // 关键词用 hasAnyKeyword 判断（它不经过"整串括号"早退，因此
  // `[数字]-[?][符号]` 这类含标点的写法也能被正确识别）。
  if (hasAnyKeyword(text) || _hasRegexMeta(text) || _looksLikeRawRegex(text)) {
    return SearchInput(query: text, mode: SearchMode.regex);
  }

  // 4) 形如 `[C104]`：里面既不是关键词也不是正则，就是用户要找的**文字**。
  //    剥掉括号按内容搜，这样带不带括号的标题都能找到 —— 比要求用户
  //    写 `\[C104\]` 才搜得到更符合直觉。
  if (text.length >= 2 &&
      text.startsWith(kRegexOpen) &&
      text.endsWith(kRegexClose)) {
    return SearchInput(
      query: text.substring(1, text.length - 1),
      mode: SearchMode.plain,
    );
  }

  // 4) 跟随设置。
  if (regexSetting) return SearchInput(query: text, mode: SearchMode.regex);
  if (fuzzySetting) return SearchInput(query: text, mode: SearchMode.fuzzy);
  return SearchInput(query: text, mode: SearchMode.plain);
}

/// 搜索结果。
///
/// 结果里**每一项都是真实匹配**（不做事后补足），按匹配质量从高到低排列；
/// 分数低、勉强沾边的会排到后面，自然沉到靠后的位置。
class SearchOutcome {
  const SearchOutcome({required this.galleries, required this.matched});

  final List<Gallery> galleries;

  /// 结果条数（等于 [galleries] 的长度；保留该字段便于调用方语义清晰）。
  final int matched;
}

/// 图集搜索：普通包含、模糊匹配（两种算法）、正则匹配。
///
/// ## 模糊匹配的算法选择
///
/// 详细说明见 [FuzzyAlgorithm]。要点：
///   * [FuzzyAlgorithm.subsequence]：字符顺序必须一致，覆盖"多打/少打字母"；
///   * [FuzzyAlgorithm.editDistance]：编辑距离，额外覆盖**相邻字符对调**
///     （`HeoolWorld` 找 `HelloWorld`），实现在 Kotlin 侧。
class GallerySearch {
  const GallerySearch._();

  // ------------------------------------------------------------ 普通包含

  static List<Gallery> plain(List<Gallery> galleries, String query) {
    final q = query.toLowerCase();
    return galleries
        .where(
          (g) =>
              g.title.toLowerCase().contains(q) ||
              g.tags.any((t) => t.toLowerCase().contains(q)),
        )
        .toList();
  }

  // ------------------------------------------------------------ 正则

  /// 正则匹配。语法非法时返回错误信息而不是空结果。
  ///
  /// 语义分两部分：
  ///   * **关键词**（`[ch]`/`[num]`…）是**过滤器** —— 判断标题是否"含有"
  ///     某类字符，与位置无关。因此 `[ch]玖町` 表示"有中文 **且** 有玖町"，
  ///     而不是"中文必须排在玖町前面"。
  ///   * **其余部分**是要**查找的文字**（支持完整正则语法）。
  ///
  /// 为什么关键词必须当过滤器：若当成位置约束，`[ch]玖町` 会译成
  /// `[汉字]+玖町`，要求汉字紧挨着"玖町"；而真实标题是 `[Pixiv] 玖町`，
  /// 紧挨着的是空格和 `]`，于是永远搜不到 —— 这正是用户报的
  /// "还是不支持中文"。
  static ({List<Gallery>? result, String? error}) regex(
    List<Gallery> galleries,
    String pattern,
  ) {
    final keywords = keywordsOf(pattern);
    final literal = literalOf(pattern);

    RegExp? re;
    if (literal.isNotEmpty) {
      try {
        re = RegExp(literal, caseSensitive: false);
      } on FormatException catch (e) {
        return (result: null, error: '正则表达式有误：${e.message}');
      }
    }

    // 关键词判据（跳过 `[?]`：它不构成任何约束）。
    final tests = <KeywordTest>[
      for (final k in keywords)
        if (kKeywordTests[k] != null) kKeywordTests[k]!,
    ];

    // 位置约束：`^[ch]` 要求以该类字符开头、`[num]$` 要求以数字结尾。
    //
    // 关键词是"含有"过滤器，本身不含位置信息；用户写了 `^`/`$` 就得照做，
    // 否则 `^[en]` 与 `[en]` 毫无区别、锚点等于白写。
    final needStart = startsWithKeyword(pattern);
    final needEnd = endsWithKeyword(pattern);
    final startTest = needStart ? _firstKeywordTest(pattern) : null;
    final endTest = needEnd ? _lastKeywordTest(pattern) : null;

    /// 标题是否以某类字符开头（跳过前导的空白）。
    bool startsWithType(String text, KeywordTest test) {
      final t = text.trimLeft();
      if (t.isEmpty) return false;
      return test(t[0]);
    }

    /// 标题是否以某类字符结尾（跳过尾部空白）。
    bool endsWithType(String text, KeywordTest test) {
      final t = text.trimRight();
      if (t.isEmpty) return false;
      return test(t[t.length - 1]);
    }

    bool matches(String text) {
      for (final t in tests) {
        if (!t(text)) return false;
      }
      if (startTest != null && !startsWithType(text, startTest)) return false;
      if (endTest != null && !endsWithType(text, endTest)) return false;
      if (re != null && !re.hasMatch(text)) return false;
      // 只剩关键词、没有要查找的文字时，关键词本身就是匹配条件。
      return tests.isNotEmpty || re != null;
    }

    return (
      result: galleries
          .where((g) => matches(g.title) || g.tags.any((t) => matches(t)))
          .toList(),
      error: null,
    );
  }

  // ------------------------------------------------------------ 模糊

  /// 模糊匹配（子序列算法，参照 fzf）。
  ///
  /// 打分规则与位置奖励见 [_fzfMatch]。
  static List<Gallery> fuzzySubsequence(List<Gallery> galleries, String query) {
    final q = query.toLowerCase();
    final scored = <({Gallery g, int score, int order})>[];
    for (var i = 0; i < galleries.length; i++) {
      final s = _scoreSubsequence(galleries[i], q);
      if (s > 0) scored.add((g: galleries[i], score: s, order: i));
    }
    return _sorted(scored);
  }

  // ------------------------------------------------------------ 词级模糊

  /// 词级模糊匹配：**以词为单位**比较，而不是整串。
  ///
  /// 为什么需要它：整串比较的算法对几十字符的长标题都失效 ——
  ///   * 子序列要求字符顺序一致，**字母对调就废**；
  ///   * 编辑距离要求两个字符串长度接近，查询 8 字符、标题 41 字符时
  ///     长度差远超容错上限，实测 2 万条里**一条都进不了计算**。
  ///
  /// 改成以词为单位之后：
  ///   * 词序无关：标题 `World Hello` 也能被查询 `helloworld` 找到；
  ///   * 只命中标题里的某一个词也算命中（长标题不再是障碍）；
  ///   * 词内允许拼错（相邻字母对调、多打少打）—— 词通常很短，
  ///     而编辑距离在短文本上才真正有效。
  ///
  /// 打分 = 覆盖率（命中几个查询词）+ 词匹配质量 + 位置奖励。
  static List<Gallery> fuzzyTokens(List<Gallery> galleries, String query) {
    final qTokens = tokenize(query);
    if (qTokens.isEmpty) return galleries;

    final scored = <({Gallery g, int score, int order})>[];
    for (var i = 0; i < galleries.length; i++) {
      final s = _tokenScore(galleries[i], qTokens);
      if (s > 0) scored.add((g: galleries[i], score: s, order: i));
    }
    return _sorted(scored);
  }

  static int _tokenScore(Gallery g, List<String> qTokens) {
    var best = _scoreTokens(g.title, qTokens);
    for (final t in g.tags) {
      final s = _scoreTokens(t, qTokens);
      if (s > best) best = s;
    }
    return best;
  }

  /// 对一段文本按词级规则打分；0 表示不匹配。
  static int _scoreTokens(String text, List<String> qTokens) {
    final tTokens = tokenize(text);
    if (tTokens.isEmpty) return 0;

    var matched = 0;
    var quality = 0;
    var firstHit = -1;

    // 每个查询词找标题里最合适的那个词。
    // 不做"一对一占用"：同一个标题词可以服务多个查询词，
    // 否则会因为"被占用了"而漏掉部分命中分。
    for (final q in qTokens) {
      var bestScore = 0;
      var bestIndex = -1;
      for (var i = 0; i < tTokens.length; i++) {
        final s = _tokenPairScore(q, tTokens[i]);
        if (s > bestScore) {
          bestScore = s;
          bestIndex = i;
        }
      }
      if (bestScore > 0) {
        matched++;
        quality += bestScore;
        if (bestIndex >= 0 && (firstHit < 0 || bestIndex < firstHit)) {
          firstHit = bestIndex;
        }
      }
    }
    if (matched == 0) return 0;

    // 全部查询词都命中：这是最理想的情况，额外给分。
    if (matched == qTokens.length) quality += 300;

    // **整串完全相等**要单独给足分量。
    // 只比较词的话，`a` 与 `a-开头` 的首个词都是"完全相等"（同分），
    // 结果靠位置决胜 —— 真正完全一样的那个反而不在最前面。
    if (tTokens.length == qTokens.length) {
      var same = true;
      for (var i = 0; i < qTokens.length; i++) {
        if (tTokens[i] != qTokens[i]) {
          same = false;
          break;
        }
      }
      if (same) quality += 600;
    }

    // 覆盖率权重最高：命中越多查询词越相关。
    final coverage = (matched * 700) ~/ qTokens.length;

    // 位置奖励：命中得越靠前越好（标题开头的词通常更关键）。
    var position = 0;
    if (firstHit > 0) position = firstHit > 6 ? -60 : -firstHit * 10;

    final score = coverage + quality + position;
    return score <= 0 ? 0 : score;
  }

  /// 单个查询词与单个标题词的匹配分数；0 表示不匹配。
  ///
  /// 完全相等 > 前缀 > 子串 > 模糊（编辑距离）。
  /// 词通常很短，所以编辑距离在这里**真正有效** ——
  /// 这正是它在长标题上失效的反面。
  static int _tokenPairScore(String q, String t) {
    if (q.isEmpty || t.isEmpty) return 0;
    if (q == t) return 400;
    if (t.startsWith(q)) return 320 - (t.length - q.length).clamp(0, 40);
    if (t.contains(q)) return 240 - (t.length - q.length).clamp(0, 60);

    // 模糊：只在两者长度接近时才有意义。
    if (q.length < 3) return 0; // 太短的词不做模糊，否则大面积误命中
    final allowed = q.length <= 4 ? 1 : (q.length <= 8 ? 2 : 3);
    if ((q.length - t.length).abs() > allowed) return 0;
    final d = _damerauDart(q, t, allowed);
    if (d < 0) return 0;
    final s = 200 - d * 70;
    return s < 0 ? 0 : s;
  }

  /// 把一段文本切成词。
  ///
  /// 规则刻意简单，够用即可：
  ///   * 连续的字母/数字算一个词（`ginklaga`、`2026`）
  ///   * **每个 CJK 字各自成一个词** —— 中文标题没有空格，整串当一个词
  ///     会让"比较单位"退化成整串，回到原来的问题
  ///   * 其余字符当分隔符丢掉
  ///
  /// 全部转小写，因此比较天然大小写不敏感。
  static List<String> tokenize(String text) {
    final out = <String>[];
    final buf = StringBuffer();

    void flush() {
      if (buf.length > 0) {
        out.add(buf.toString());
        buf.clear();
      }
    }

    for (final rune in text.toLowerCase().runes) {
      if (_isCjk(rune)) {
        flush();
        out.add(String.fromCharCode(rune));
      } else if (_isWordChar(rune)) {
        buf.writeCharCode(rune);
      } else {
        flush();
      }
    }
    flush();
    return out;
  }

  static bool _isWordChar(int rune) =>
      (rune >= 0x30 && rune <= 0x39) || // 0-9
      (rune >= 0x61 && rune <= 0x7A) || // a-z（已转小写）
      (rune >= 0x41 && rune <= 0x5A); // A-Z（保险）

  /// CJK 统一表意文字、日文假名、韩文音节。
  ///
  /// 这些文字不用空格分词，因此按"一字一词"处理。
  static bool _isCjk(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK 统一表意
      (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
      (rune >= 0x3040 && rune <= 0x30FF) || // 平假名 / 片假名
      (rune >= 0xAC00 && rune <= 0xD7AF) || // 韩文音节
      (rune >= 0xFF66 && rune <= 0xFF9D); // 半角片假名

  // ------------------------------------------------- 短查询的包含匹配

  /// 纯 Dart 的 Damerau-Levenshtein（原生不可用时的回退）。
  ///
  /// 公开给基准测试使用：测试环境没有原生通道，只能走这条路径，
  /// 而它同时也是"剪枝策略到底省了多少"的对照实现。
  static int debugDamerau(String a, String b, {int maxDistance = 3}) =>
      _damerauDart(a, b, maxDistance);

  /// 纯 Dart 的 Damerau-Levenshtein（原生不可用时的回退）。
  ///
  /// 与 Kotlin 侧同样的带状优化，行为保持一致。
  static int _damerauDart(String a, String b, int maxDistance) {
    if (a == b) return 0;
    final n = a.length;
    final m = b.length;
    if ((n - m).abs() > maxDistance) return -1;
    if (n == 0) return m <= maxDistance ? m : -1;
    if (m == 0) return n <= maxDistance ? n : -1;

    final inf = maxDistance + 1;
    var prev2 = List<int>.filled(m + 1, inf);
    var prev = List<int>.filled(m + 1, inf);
    var cur = List<int>.filled(m + 1, inf);
    for (var j = 0; j <= m; j++) {
      prev[j] = j <= maxDistance ? j : inf;
    }

    for (var i = 1; i <= n; i++) {
      cur[0] = i <= maxDistance ? i : inf;
      final from = math.max(1, i - maxDistance);
      final to = math.min(m, i + maxDistance);
      if (from > 1) cur[from - 1] = inf;
      for (var j = from; j <= to; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        var best = math.min(
          math.min(prev[j] + 1, cur[j - 1] + 1),
          prev[j - 1] + cost,
        );
        // 相邻字符对调 —— 这是"编辑距离"相对"子序列"的关键增益。
        if (i > 1 &&
            j > 1 &&
            a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) &&
            a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
          final swap = prev2[j - 2] + 1;
          if (swap < best) best = swap;
        }
        cur[j] = best > inf ? inf : best;
      }
      if (to < m) cur[to + 1] = inf;
      final t = prev2;
      prev2 = prev;
      prev = cur;
      cur = t;
    }
    final d = prev[m];
    return d <= maxDistance ? d : -1;
  }

  // ------------------------------------------------------------ 统一入口

  /// 执行搜索：按匹配质量排序，**只返回真正匹配的结果**。
  ///
  /// 不做事后补足 —— 分数低的匹配本来就排在后面（甚至排到最后一页），
  /// 效果等同于"至少有东西可看"，但每一项都是真实匹配，
  /// 不会把毫不相关的内容混进结果里冒充搜索结果。
  ///
  /// [limit] 为 0 表示不限；小于 [minLimit] 时抬到 [minLimit]。
  static Future<SearchOutcome> run(
    List<Gallery> galleries,
    SearchInput input, {
    int limit = 0,
    int minLimit = kMinSearchLimit,
    FuzzyAlgorithm algorithm = FuzzyAlgorithm.subsequence,
  }) async {
    if (input.isEmpty || input.regexError != null) {
      return SearchOutcome(
        galleries: input.isEmpty ? galleries : const [],
        matched: input.isEmpty ? galleries.length : 0,
      );
    }

    List<Gallery> matched;
    switch (input.mode) {
      case SearchMode.plain:
        matched = plain(galleries, input.query);
      case SearchMode.regex:
        final r = regex(galleries, input.query);
        matched = r.result ?? const [];
      case SearchMode.fuzzy:
        matched = switch (algorithm) {
          FuzzyAlgorithm.tokenFuzzy => fuzzyTokens(galleries, input.query),
          FuzzyAlgorithm.subsequence => fuzzySubsequence(
            galleries,
            input.query,
          ),
        };
    }

    final effective = limit <= 0
        ? matched.length
        : (limit < minLimit ? minLimit : limit);
    final out = matched.take(effective).toList();
    return SearchOutcome(galleries: out, matched: out.length);
  }

  // ------------------------------------------------------------ 子序列打分

  static List<Gallery> _sorted(
    List<({Gallery g, int score, int order})> scored,
  ) {
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.order.compareTo(b.order);
    });
    return scored.map((e) => e.g).toList();
  }

  static int _scoreSubsequence(Gallery g, String query) {
    var best = 0;
    for (final tag in g.tags) {
      final s = _fzfMatch(tag.toLowerCase(), query);
      if (s > best) best = s;
    }
    final t = _fzfMatch(g.title.toLowerCase(), query);
    if (t > 0) {
      final boosted = t + _titleBonus;
      if (boosted > best) best = boosted;
    }
    return best;
  }

  static const int _titleBonus = 4000;

  static const int _scoreMatch = 16;
  static const int _scoreGapStart = -3;
  static const int _scoreGapExtension = -1;
  static const int _bonusBoundary = _scoreMatch ~/ 2;
  static const int _bonusNonWord = _scoreMatch ~/ 2;
  static const int _bonusCamel123 = _bonusBoundary + _scoreGapExtension;
  static const int _bonusConsecutive = -(_scoreGapStart + _scoreGapExtension);
  static const int _bonusFirstCharMultiplier = 2;
  static const int _bonusBoundaryWhite = _bonusBoundary + 2;
  static const int _bonusBoundaryDelimiter = _bonusBoundary + 1;
  static const int _maxDpSpan = 1024;

  static const int _classWhite = 0;
  static const int _classNonWord = 1;
  static const int _classDelimiter = 2;
  static const int _classLower = 3;
  static const int _classUpper = 4;
  static const int _classLetter = 5;
  static const int _classNumber = 6;

  static const String _delimiters = '/,:;|、，。；：｜';
  static const String _whiteChars = ' \t\n\v\f\r';

  static final List<int> _asciiClass = _buildAsciiTable();

  static List<int> _buildAsciiTable() {
    final t = List<int>.filled(128, _classNonWord);
    for (var i = 0; i < 128; i++) {
      final cu = i;
      if (cu >= 0x30 && cu <= 0x39) {
        t[i] = _classNumber;
      } else if (cu >= 0x61 && cu <= 0x7A) {
        t[i] = _classLower;
      } else if (cu >= 0x41 && cu <= 0x5A) {
        t[i] = _classUpper;
      } else if (_whiteChars.contains(String.fromCharCode(cu))) {
        t[i] = _classWhite;
      } else if (_delimiters.contains(String.fromCharCode(cu))) {
        t[i] = _classDelimiter;
      }
    }
    return t;
  }

  static int _classOf(int rune) {
    if (rune < 128) return _asciiClass[rune];
    final c = String.fromCharCode(rune);
    if (c.toUpperCase() != c.toLowerCase()) {
      return c == c.toLowerCase() ? _classLower : _classUpper;
    }
    if (RegExp(r'^\d$').hasMatch(c)) return _classNumber;
    if (RegExp(r'^\s$').hasMatch(c)) return _classWhite;
    if (_delimiters.contains(c)) return _classDelimiter;
    return _classLetter;
  }

  static int _bonusFor(int prevClass, int cls) {
    if (cls >= _classNonWord) {
      switch (prevClass) {
        case _classWhite:
          return _bonusBoundaryWhite;
        case _classDelimiter:
          return _bonusBoundaryDelimiter;
        case _classNonWord:
          return _bonusBoundary;
      }
    }
    if ((prevClass == _classLower && cls == _classUpper) ||
        (prevClass != _classNumber && cls == _classNumber)) {
      return _bonusCamel123;
    }
    switch (cls) {
      case _classNonWord:
      case _classDelimiter:
        return _bonusNonWord;
      case _classWhite:
        return _bonusBoundaryWhite;
    }
    return 0;
  }

  /// fzf 风格的模糊匹配打分；0 表示不匹配。
  static int _fzfMatch(String text, String query) {
    if (query.isEmpty || text.isEmpty) return 0;
    if (query.length > text.length) return 0;

    final direct = text.indexOf(query);
    if (direct >= 0) {
      final raw = _scoreRange(text, query, direct, direct + query.length);
      return _withLengthTiebreak(raw, text.length, query.length);
    }

    final n = text.length;
    final m = query.length;
    var firstIdx = 0;
    var idx = 0;
    var lastIdx = 0;
    var lastChar = 0;
    for (var p = 0; p < m; p++) {
      lastChar = query.codeUnitAt(p);
      final found = text.indexOf(String.fromCharCode(lastChar), idx);
      if (found < 0) return 0;
      if (p == 0 && found > 0) firstIdx = found - 1;
      lastIdx = found;
      idx = found + 1;
    }

    var end = lastIdx + 1;
    if (lastIdx + 1 < n) {
      final tail = text.indexOf(String.fromCharCode(lastChar), lastIdx + 1);
      if (tail >= 0) end = tail + 1;
    }
    if (end <= firstIdx) return 0;

    final span = end - firstIdx;
    if (span > _maxDpSpan) {
      return _withLengthTiebreak(_scoreMatch * m, text.length, m);
    }
    final raw = _scoreRange(text, query, firstIdx, end);
    return _withLengthTiebreak(raw, text.length, m);
  }

  static int _withLengthTiebreak(int raw, int textLen, int queryLen) {
    final extra = textLen - queryLen;
    if (extra <= 0) return raw;
    final penalty = extra > 200 ? 200 : extra;
    final v = raw - penalty;
    return v < 0 ? 0 : v;
  }

  static int _scoreRange(String text, String query, int sidx, int eidx) {
    var pidx = 0;
    var score = 0;
    var inGap = false;
    var consecutive = 0;
    var firstBonus = 0;

    var prevClass = sidx == 0
        ? _classWhite
        : _classOf(text.codeUnitAt(sidx - 1));

    for (var idx = sidx; idx < eidx; idx++) {
      final rune = text.codeUnitAt(idx);
      final cls = _classOf(rune);
      final bonus = _bonusFor(prevClass, cls);
      prevClass = cls;

      if (pidx < query.length && rune == query.codeUnitAt(pidx)) {
        score += _scoreMatch;
        var b = bonus;
        if (consecutive == 0) {
          firstBonus = bonus;
        } else {
          if (bonus >= _bonusBoundary && bonus > firstBonus) {
            firstBonus = bonus;
          }
          var inside = bonus;
          if (inside < firstBonus) inside = firstBonus;
          if (inside < _bonusConsecutive) inside = _bonusConsecutive;
          b = inside;
        }
        score += pidx == 0 ? b * _bonusFirstCharMultiplier : b;
        inGap = false;
        consecutive++;
        pidx++;
      } else {
        score += inGap ? _scoreGapExtension : _scoreGapStart;
        inGap = true;
        consecutive = 0;
        firstBonus = 0;
      }
    }
    return score < 0 ? 0 : score;
  }
}

/// 搜索"最多显示"的下限（需求：最低 10 条）。
const int kMinSearchLimit = 10;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 连不上翻译端：进程没起来、端口不对、局域网不通，或者请求超时。
///
/// 与 [BridgeException] 的区别很重要：这个类别说明「根本没拿到应答」，
/// 提示文案应该让用户去检查同传互译是否在跑；而 [BridgeException] 是
/// 服务端明确拒绝了请求，文案要指出配置或状态问题。
class BridgeUnreachable implements Exception {
  BridgeUnreachable(this.cause, {required this.hint});

  /// 底层异常（SocketException / TimeoutException / HttpException 等）。
  final Object cause;

  /// 面向用户的一句话建议。
  final String hint;

  @override
  String toString() => 'BridgeUnreachable($hint): $cause';
}

/// 服务端返回的语义错误（HTTP 状态码不是 200）。
class BridgeException implements Exception {
  BridgeException({
    required this.status,
    required this.code,
    required this.message,
    this.retryAfterSeconds,
  });

  final int status;

  /// 服务端错误码，例如 `busy` / `render_gone` / `unauthorized`。
  final String code;

  /// 服务端给的中文说明，可直接展示给用户。
  final String message;

  /// `Retry-After` 头（秒）；服务端忙时会给。
  final int? retryAfterSeconds;

  /// 配对码不对：只能让用户重新配对，重试没有意义。
  bool get isUnauthorized => status == 401;

  /// 上一页还没处理完；等一会儿再试是正确做法。
  bool get isBusy => status == 409;

  /// 出图结果过期或被淘汰：重发同一页即可。
  ///
  /// 0.8.0 起服务端对「渲染缓存里没有这张」既可能回 `410 render_gone`，
  /// 也可能回 `404`（缓存被淘汰后路径也失效），两者都算过期。
  bool get isRenderGone => status == 410 || status == 404;

  /// 图片过大或体积超限：重试也不会变，必须降分辨率。
  bool get isTooLarge => status == 413;

  /// 服务端读不到自己的设置（503 `settings_timeout`）。
  ///
  /// 这是「服务端一时卡住」而不是「我们发错了」，隔一会儿再试一次即可；
  /// 但不要连着轰，否则只是把它的线程池占满。
  bool get isSettingsTimeout => status == 503;

  /// 推理超时（504 `inference_timeout`）：OCR 60 秒 / 翻译 90 秒没跑完。
  ///
  /// 模型自己卡住时重试同一页往往还是超时，所以调用方应该暂停整批、
  /// 让用户决定是继续还是先看看翻译 App。
  bool get isInferenceTimeout => status == 504;

  /// 图片格式不被支持（415 `unsupported_media`）：必须转成 JPEG 再送。
  bool get isUnsupportedMedia => status == 415;

  /// 值得重试的类别（忙 / 超时 / 服务端内部错误）。
  bool get isRetryable => isBusy || status == 408 || status >= 500;

  @override
  String toString() => 'BridgeException($status $code): $message';
}

/// `GET /v1/health` 的结果。
///
/// 这个接口**不需要配对码**，因此是"服务在不在"的第一判断入口。
class BridgeHealth {
  const BridgeHealth({
    required this.api,
    required this.ok,
    required this.app,
    required this.version,
    required this.backend,
    required this.model,
    required this.visionReady,
    required this.translateReady,
    required this.bridgeEnabled,
    required this.port,
  });

  final int api;
  final bool ok;
  final String app;
  final String version;
  final String backend;
  final String model;

  /// 识图模型已就绪（决定能不能做图片翻译）。
  final bool visionReady;

  /// 翻译后端已就绪（没选模型时为 false）。
  final bool translateReady;

  /// 用户是否打开了「图集互联」开关。
  final bool bridgeEnabled;

  /// 服务实际监听的端口。**必须用这个值**，因为端口被占时服务会改端口。
  final int port;

  factory BridgeHealth.fromJson(Map<String, dynamic> j) => BridgeHealth(
    api: _int(j['api']),
    ok: j['ok'] == true,
    app: _str(j['app']),
    version: _str(j['version']),
    backend: _str(j['backend']),
    model: _str(j['model']),
    visionReady: j['visionReady'] == true,
    translateReady: j['translateReady'] == true,
    bridgeEnabled: j['bridgeEnabled'] == true,
    port: _int(j['port']),
  );
}

/// 一行识别+翻译结果。
class BridgeLine {
  const BridgeLine({
    required this.i,
    required this.source,
    required this.target,
    required this.box,
    required this.conf,
    required this.ok,
    required this.error,
  });

  /// 行序号，从 0 开始，按阅读顺序（先上后下、同一行从左到右）。
  final int i;

  /// 原文（OCR 结果）。
  final String source;

  /// 译文。翻译失败时为空字符串。
  final String target;

  /// `[左, 上, 宽, 高]`，单位是**返回图片的像素**（已按 maxSide 缩放）。
  final List<int> box;

  /// OCR 置信度，0~1。
  final double conf;

  /// 这一行是否翻译成功。
  final bool ok;

  /// 失败原因（服务端给的原文，可能为 null）。
  final String? error;

  factory BridgeLine.fromJson(Map<String, dynamic> j) => BridgeLine(
    i: _int(j['i']),
    source: _str(j['source']),
    target: _str(j['target']),
    box: (j['box'] as List<dynamic>? ?? const [])
        .map((e) => _int(e))
        .toList(growable: false),
    conf: (j['conf'] as num?)?.toDouble() ?? 0,
    ok: j['ok'] == true,
    error: j['error'] as String?,
  );
}

/// 服务端统计。全部是"这一页发生了多少事"的计数，不参与逻辑判断。
class BridgeStats {
  const BridgeStats({
    required this.blocks,
    required this.translated,
    required this.failed,
    required this.dropped,
    required this.ocrMs,
    required this.translateMs,
    required this.renderMs,
    required this.elapsedMs,
  });

  final int blocks;
  final int translated;
  final int failed;

  /// 被过滤或合并掉的行数。**不是错误数**，不要把 dropped 当失败汇报。
  final int dropped;
  final int ocrMs;
  final int translateMs;
  final int renderMs;
  final int elapsedMs;

  factory BridgeStats.fromJson(Map<String, dynamic> j) => BridgeStats(
    blocks: _int(j['blocks']),
    translated: _int(j['translated']),
    failed: _int(j['failed']),
    dropped: _int(j['dropped']),
    ocrMs: _int(j['ocrMs']),
    translateMs: _int(j['translateMs']),
    renderMs: _int(j['renderMs']),
    elapsedMs: _int(j['elapsedMs']),
  );

  static const empty = BridgeStats(
    blocks: 0,
    translated: 0,
    failed: 0,
    dropped: 0,
    ocrMs: 0,
    translateMs: 0,
    renderMs: 0,
    elapsedMs: 0,
  );
}

/// 出图结果的引用。只有 `render=1` 且渲染成功时才会出现。
class BridgeRenderRef {
  const BridgeRenderRef({
    required this.id,
    required this.format,
    required this.path,
  });

  final String id;

  /// 目前固定是 `jpeg`。
  final String format;

  /// 下载路径，例如 `/v1/render/<id>`。
  final String path;

  factory BridgeRenderRef.fromJson(Map<String, dynamic> j) => BridgeRenderRef(
    id: _str(j['id']),
    format: _str(j['format']),
    path: _str(j['path']),
  );
}

/// `POST /v1/translate/image` 的结果。
class BridgeImageResult {
  const BridgeImageResult({
    required this.width,
    required this.height,
    required this.lines,
    required this.stats,
    required this.render,
  });

  /// 返回图片的尺寸。**注意**：这是已经按 maxSide 缩放、并且做过 EXIF
  /// 旋转后的尺寸，box 用的就是这个坐标系——百分比是安全的映射方式。
  final int width;
  final int height;

  final List<BridgeLine> lines;
  final BridgeStats stats;

  /// 渲染成品图的引用；`render=1` 但渲染失败时为 null（外层仍 ok=true）。
  final BridgeRenderRef? render;

  int get translatedCount => lines.where((l) => l.ok).length;

  factory BridgeImageResult.fromJson(Map<String, dynamic> j) {
    final image = (j['image'] as Map<String, dynamic>? ?? const {});
    return BridgeImageResult(
      width: _int(image['width']),
      height: _int(image['height']),
      lines: (j['lines'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(BridgeLine.fromJson)
          .toList(growable: false),
      stats: BridgeStats.fromJson(
        (j['stats'] as Map<String, dynamic>? ?? const {}),
      ),
      render: j['render'] == null
          ? null
          : BridgeRenderRef.fromJson(j['render'] as Map<String, dynamic>),
    );
  }
}

/// `POST /v1/translate/text` 的结果。
class BridgeTextResult {
  const BridgeTextResult({
    required this.text,
    required this.sourceLang,
    required this.targetLang,
    required this.elapsedMs,
    required this.backend,
  });

  final String text;
  final String sourceLang;
  final String targetLang;
  final int elapsedMs;
  final String backend;

  factory BridgeTextResult.fromJson(Map<String, dynamic> j) => BridgeTextResult(
    text: _str(j['text']),
    sourceLang: _str(j['sourceLang']),
    targetLang: _str(j['targetLang']),
    elapsedMs: _int(j['elapsedMs']),
    backend: _str(j['backend']),
  );
}

/// 本机翻译服务的 HTTP 客户端。
///
/// 契约来自 `docs/图集接入本机翻译服务-客户端开发文档.md`，服务端实现在
/// `Android-ScreenAndAudio-Translate/app/src/main/java/com/screenast/app/bridge/`。
/// 几条容易踩的规则集中写在这里，改代码前先读一遍：
///
///  1. 端口**用 health 返回的 `port`**，不要相信用户填的值——服务被占用时
///     会改用 8099/8100。
///  2. `/v1/health` 不需要配对码；其余接口都要 `X-Bridge-Token`。
///  3. text 请求的 `Content-Type` 必须**精确**是 `application/json`，
///     带上 `; charset=utf-8` 会被服务端按 415 拒掉（它只去掉参数做比较）。
///  4. image 请求体是**原始图片字节**，不是 JSON、不做 base64、不做分块编码。
///  5. 服务端全局串行：一次只处理一页，其余请求立刻 409。客户端必须串行发。
///  6. 出图结果只缓存几份、几分钟，**拿到 image 响应就要马上下载渲染图**，
///     等整批跑完再回来下载会拿到 410。
class BridgeClient {
  BridgeClient({required this.port, this.host = '127.0.0.1', this.token});

  final String host;

  /// 初始端口。health 成功后会被 [detectedPort] 覆盖。
  final int port;

  /// 配对码；health 之外的请求都要带。
  final String? token;

  /// 服务端实际端口（health 探测后填充）。
  int? detectedPort;

  int get effectivePort => detectedPort ?? port;

  /// 单次响应体上限，与文档给的 32 MiB 请求上限对应。
  static const int maxResponseBytes = 48 * 1024 * 1024;

  final HttpClient _http = HttpClient()
    // 连接阶段就该快速失败：服务没起来时用户不该等 30 秒。
    ..connectionTimeout = const Duration(seconds: 3);

  bool _closed = false;

  /// 默认超时：按文档给出的实测值留足余量（图片翻译含 OCR + 翻译 + 渲染）。
  static const Duration healthTimeout = Duration(seconds: 3);
  static const Duration textTimeout = Duration(seconds: 30);

  /// 远程 PC 服务是 CPU llama.cpp，大页/复杂气泡的 OCR + 翻译 + 出图
  /// 可能远超 120 秒，所以放到 240 秒。外层 `TranslationService.translatePage`
  /// 的总超时（5 分钟）必须比它更宽，否则内层还没超时就被外层掐断。
  static const Duration imageTimeout = Duration(seconds: 240);
  static const Duration renderTimeout = Duration(seconds: 30);

  Uri _uri(String path, [Map<String, String>? query]) => Uri(
    scheme: 'http',
    host: host,
    port: effectivePort,
    path: path,
    queryParameters: (query == null || query.isEmpty) ? null : query,
  );

  /// 探测服务，并记住真实端口。
  Future<BridgeHealth> health({Duration timeout = healthTimeout}) async {
    final resp = await _send(
      'GET',
      _uri('/v1/health'),
      timeout: timeout,
      withToken: false,
    );
    final health = BridgeHealth.fromJson(resp);
    // 端口以服务端自报为准：被占用时它会换端口，写死的 8098 会连错地方。
    if (health.port > 0) detectedPort = health.port;
    return health;
  }

  /// 纯文本翻译。
  Future<BridgeTextResult> translateText(
    String text, {
    String source = 'auto',
    String target = 'zh',
    Duration timeout = textTimeout,
  }) async {
    final resp = await _send(
      'POST',
      _uri('/v1/translate/text'),
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode({'text': text, 'source': source, 'target': target}),
        ),
      ),
      // 服务端要求去掉参数后精确等于 application/json。
      contentType: 'application/json',
      timeout: timeout,
    );
    return BridgeTextResult.fromJson(resp);
  }

  /// 图片翻译（OCR + 翻译 + 可选渲染）。
  ///
  /// [bytes] 是原始图片字节；[source] 对日漫应显式传 `ja`——`auto` 会把
  /// 纯汉字台词猜成中文而整页跳过翻译。
  Future<BridgeImageResult> translateImage(
    Uint8List bytes, {
    required String source,
    String target = 'zh',
    bool render = true,
    int maxSide = 4096,
    int minChars = 0,
    Duration timeout = imageTimeout,
  }) async {
    final resp = await _send(
      'POST',
      _uri('/v1/translate/image', {
        'source': source,
        'target': target,
        'ocr': '1',
        'translate': '1',
        'render': render ? '1' : '0',
        'maxSide': '$maxSide',
        'minChars': '$minChars',
      }),
      body: bytes,
      contentType: sniffImageContentType(bytes),
      timeout: timeout,
    );
    return BridgeImageResult.fromJson(resp);
  }

  /// 按文件头猜图片的 MIME，供 `POST /v1/translate/image` 使用。
  ///
  /// 0.8.0 起服务端按 `Content-Type` 分流（只认 `image/jpeg` / `image/png`），
  /// 一律发 `application/octet-stream` 会被回 415 `unsupported_media`。
  /// 这里按魔数给出真实类型；猜不出才退回 JPEG——图集里绝大多数就是 JPEG。
  static String sniffImageContentType(Uint8List bytes) {
    bool at(int i, List<int> sig) {
      if (bytes.length < i + sig.length) return false;
      for (var k = 0; k < sig.length; k++) {
        if (bytes[i + k] != sig[k]) return false;
      }
      return true;
    }

    if (at(0, const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return 'image/png';
    }
    if (at(0, const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
    if (at(0, const [0x42, 0x4D])) return 'image/bmp';
    if (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
        at(8, const [0x57, 0x45, 0x42, 0x50])) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  /// 下载渲染成品图。
  ///
  /// [pathOrId] 可以传 `/v1/render/<id>`，也可以只传 id。
  Future<Uint8List> fetchRender(
    String pathOrId, {
    Duration timeout = renderTimeout,
  }) async {
    final path = pathOrId.startsWith('/') ? pathOrId : '/v1/render/$pathOrId';
    await _send('GET', _uri(path), timeout: timeout, raw: true);
    final bytes = _lastRawBytes;
    if (bytes == null || bytes.isEmpty) {
      throw BridgeException(
        status: 500,
        code: 'bridge_error',
        message: '渲染图返回为空',
      );
    }
    return bytes;
  }

  Uint8List? _lastRawBytes;

  void close() {
    if (_closed) return;
    _closed = true;
    _http.close(force: true);
  }

  /// 发一个请求，返回解析后的 JSON（或原始字节）。
  ///
  /// `raw: true` 时返回值无意义，真实数据在 [_lastRawBytes] —— 这样做是为了
  /// 让所有错误处理集中在一处，不必为二进制响应再写一套。
  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri, {
    Uint8List? body,
    String? contentType,
    required Duration timeout,
    bool withToken = true,
    bool raw = false,
  }) async {
    _lastRawBytes = null;
    final HttpClientRequest req;
    try {
      req = await _http.openUrl(method, uri).timeout(timeout);
    } on TimeoutException catch (e) {
      throw BridgeUnreachable(e, hint: '连接超时，确认翻译服务正在运行、地址可达');
    } on SocketException catch (e) {
      throw BridgeUnreachable(
        e,
        hint: '连不上翻译服务（没运行，或手机与电脑不在同一局域网？）',
      ); 
    } on HttpException catch (e) {
      throw BridgeUnreachable(e, hint: '连接被重置，翻译服务可能刚重启');
    }

    try {
      req.headers.set(HttpHeaders.acceptHeader, 'application/json, image/*');
      if (withToken) {
        final t = token;
        if (t == null || t.isEmpty) {
          throw BridgeUnreachable(
            StateError('缺少配对码'),
            hint: '还没有配对，先到设置里粘贴配对信息',
          );
        }
        req.headers.set('X-Bridge-Token', t);
      }
      if (contentType != null) {
        req.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }

      final resp = await req.close().timeout(timeout);
      final status = resp.statusCode;
      final bytes = await _collect(resp);

      if (status != 200) {
        throw _errorFrom(status, bytes, resp.headers);
      }

      if (raw) {
        _lastRawBytes = bytes;
        return const {};
      }

      if (bytes.isEmpty) {
        throw BridgeUnreachable(
          const FormatException('响应为空'),
          hint: '服务返回了空响应，稍后重试',
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is! Map<String, dynamic>) {
        throw BridgeUnreachable(
          FormatException('响应不是 JSON 对象: ${decoded.runtimeType}'),
          hint: '服务返回了非预期内容',
        );
      }
      if (decoded['ok'] != true) {
        throw BridgeException(
          status: status,
          code: _str(decoded['code'], fallback: 'unknown'),
          message: _str(decoded['message'], fallback: '翻译服务返回失败'),
        );
      }
      return decoded;
    } on TimeoutException catch (e) {
      throw BridgeUnreachable(e, hint: '等太久没有响应，试着重试当前这一页');
    } on SocketException catch (e) {
      throw BridgeUnreachable(e, hint: '连接中断，翻译服务可能被系统回收了');
    } finally {
      // 不主动 close(req)：keep-alive 复用连接，减少每次请求的握手开销。
    }
  }

  /// 把非 200 响应翻译成 [BridgeException]。
  ///
  /// 服务端的错误体是 `{api, ok:false, code, message}`；但 405/415 这类
  /// 由路由层直接返回的可能没有 body，所以每条都要能退化成状态码说明。
  BridgeException _errorFrom(int status, Uint8List bytes, HttpHeaders headers) {
    String code = 'http_$status';
    String message = _statusHint(status);
    if (bytes.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
        if (decoded is Map<String, dynamic>) {
          code = _str(decoded['code'], fallback: code);
          message = _str(decoded['message'], fallback: message);
        }
      } catch (_) {
        // 不是 JSON：保留状态码文案即可。
      }
    }
    final retry = int.tryParse(
      headers.value(HttpHeaders.retryAfterHeader) ?? '',
    );
    return BridgeException(
      status: status,
      code: code,
      message: message,
      retryAfterSeconds: retry,
    );
  }

  static String _statusHint(int status) => switch (status) {
    400 => '请求格式不对',
    401 => '配对码不对，请重新配对',
    404 => '接口不存在（版本不匹配？）',
    408 => '服务端处理超时',
    409 => '正在处理另一页，稍后自动重试',
    410 => '出图结果已过期',
    413 => '图片太大，先把图片缩小再试',
    415 => '服务端不认识这个格式（需要转成 JPEG）',
    500 => '翻译服务内部错误',
    502 => '翻译失败（模型没返回结果）',
    503 => '服务端读不到设置，稍后重试',
    504 => '模型推理超时',
    _ => '请求失败（HTTP $status）',
  };

  /// 读完整个响应体，并强制上限，避免异常响应把内存吃光。
  Future<Uint8List> _collect(HttpClientResponse resp) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
      if (builder.length > maxResponseBytes) {
        throw BridgeUnreachable(
          StateError('响应超过 $maxResponseBytes 字节'),
          hint: '服务返回了过大的数据',
        );
      }
    }
    return builder.takeBytes();
  }
}

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

String _str(Object? v, {String fallback = ''}) {
  if (v == null) return fallback;
  final s = v is String ? v : '$v';
  return s.isEmpty ? fallback : s;
}

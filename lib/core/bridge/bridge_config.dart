import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 配对信息。
///
/// 同传互译的配对页会把这四样东西以 JSON 形式**自动复制到剪贴板**：
/// `{"api":1,"port":8098,"token":"…","hosts":["192.168.1.5"]}`。
/// 图集端只要"从剪贴板粘贴"，不需要也不应该去拉起对方的 Activity
/// （`PairActivity` 明确不导出，外部拉起会被系统按 SecurityException 拒绝）。
class BridgePairing {
  const BridgePairing({
    required this.api,
    required this.port,
    required this.token,
    required this.hosts,
  });

  final int api;
  final int port;
  final String token;

  /// 对方枚举出的本机地址（不含端口）。同机调试用 `127.0.0.1` 即可，
  /// 这些只在跨设备联调时有意义。
  final List<String> hosts;

  /// 解析剪贴板里的配对文本。
  ///
  /// 容错策略：先当 JSON 解析；不是 JSON 就当成"只粘贴了 token"，
  /// 因为用户很可能手动复制了那一串十六进制。返回 null 表示完全无法识别。
  static BridgePairing? tryParse(String raw, {int fallbackPort = 8098}) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        final token = (decoded['token'] as String?)?.trim() ?? '';
        if (token.isEmpty) return null;
        final port = (decoded['port'] as num?)?.toInt() ?? fallbackPort;
        final hosts = <String>[
          for (final h in (decoded['hosts'] as List<dynamic>? ?? const []))
            if (h is String && h.trim().isNotEmpty) h.trim(),
        ];
        return BridgePairing(
          api: (decoded['api'] as num?)?.toInt() ?? 1,
          port: port <= 0 || port > 65535 ? fallbackPort : port,
          token: token,
          hosts: hosts,
        );
      }
    } on FormatException {
      // 落到下面的 "纯 token" 分支。
    }

    // 纯 token：只接受 token 字符集，避免把任意剪贴板内容当成配对码。
    if (RegExp(r'^[A-Za-z0-9._~+/=-]{16,256}$').hasMatch(text)) {
      return BridgePairing(
        api: 1,
        port: fallbackPort,
        token: text,
        hosts: const [],
      );
    }
    return null;
  }
}

/// 源语言：auto 放第一位。
///
/// 日漫建议显式选 `ja`：大量汉字台词用 `auto` 会被判成中文母语，
/// 服务端就"不需要翻译"直接跳过。
const Map<String, String> kSourceLangs = {
  'auto': '自动检测',
  'ja': '日语',
  'en': '英语',
  'ko': '韩语',
  'zh': '中文',
};

const Map<String, String> kTargetLangs = {
  'zh': '简体中文',
  'en': '英语',
  'ja': '日语',
  'ko': '韩语',
};

/// 图集端保存的翻译服务配置。
///
/// token 会落到 SharedPreferences（应用私有目录），**不进日志、不显示完整值**。
class BridgeConfig {
  const BridgeConfig({
    this.host = '127.0.0.1',
    this.port = 8098,
    this.token = '',
    this.source = 'ja',
    this.target = 'zh',
    this.maxSide = 4096,
    this.minChars = 0,
    this.outputTreeUri,
    this.outputTreeName,
  });

  /// 服务地址。默认回环——同机方案下不需要经过网络。
  final String host;

  /// 期望端口。实际端口以 health 返回为准（可能被占用后改成 8099/8100）。
  final int port;

  /// 配对码。
  final String token;

  /// OCR 源语言。默认 `ja`：日漫里大量汉字台词用 `auto` 会被猜成中文，
  /// 直接被"识别成母语"跳过翻译。
  final String source;

  final String target;

  /// 发给 OCR 的最长边。过大只会变慢，4096 已超过绝大多数手机屏幕。
  final int maxSide;

  /// 少于这么多字的文本块不翻译（0 表示不过滤）。
  final int minChars;

  /// 上次选定的输出目录（SAF 树 URI）与它的显示名。
  final String? outputTreeUri;
  final String? outputTreeName;

  bool get hasToken => token.trim().isNotEmpty;

  BridgeConfig copyWith({
    String? host,
    int? port,
    String? token,
    String? source,
    String? target,
    int? maxSide,
    int? minChars,
    String? outputTreeUri,
    String? outputTreeName,
  }) => BridgeConfig(
    host: host ?? this.host,
    port: port ?? this.port,
    token: token ?? this.token,
    source: source ?? this.source,
    target: target ?? this.target,
    maxSide: maxSide ?? this.maxSide,
    minChars: minChars ?? this.minChars,
    outputTreeUri: outputTreeUri ?? this.outputTreeUri,
    outputTreeName: outputTreeName ?? this.outputTreeName,
  );

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'token': token,
    'source': source,
    'target': target,
    'maxSide': maxSide,
    'minChars': minChars,
    'outTree': outputTreeUri,
    'outName': outputTreeName,
  };

  /// 容错读取：配置是用户目录里的明文 JSON，可能被手改或旧版本写坏。
  /// 任何字段类型不对都退回默认值，绝不让"读配置"抛异常。
  static BridgeConfig fromJson(Map<String, dynamic> j) {
    final host = j['host'];
    return BridgeConfig(
      host: host is String && host.trim().isNotEmpty
          ? host.trim()
          : '127.0.0.1',
      port: _asInt(j['port']) ?? 8098,
      token: j['token'] is String ? j['token'] as String : '',
      source: _asString(j['source']) ?? 'ja',
      target: _asString(j['target']) ?? 'zh',
      maxSide: _asInt(j['maxSide']) ?? 4096,
      minChars: _asInt(j['minChars']) ?? 0,
      outputTreeUri: _asString(j['outTree']),
      outputTreeName: _asString(j['outName']),
    );
  }

  static int? _asInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static String? _asString(Object? v) => v is String ? v : null;

  /// 把配对信息并进现有配置：只更新 host/port/token，不动语言与目录偏好。
  ///
  /// 显式配对**总是**采用配对信息里的 host：以前「只有当前是 127.0.0.1 才换」
  /// 会让用户粘了新地址的配对 JSON 却仍在连旧地址（远程 PC 尤其明显——
  /// 换一台电脑、或者电脑换了 IP，配置就再也切不过去）。
  BridgeConfig mergedWith(BridgePairing pairing) => copyWith(
    host: pairing.hosts.isNotEmpty ? pairing.hosts.first : host,
    port: pairing.port,
    token: pairing.token,
  );
}

/// 配置的读写。
///
/// 用单键 JSON 而不是多个键：以后加字段不会散落成一堆 key，
/// 读取时也不会出现"部分字段是新值、部分还是旧值"。
class BridgeConfigStore {
  BridgeConfigStore._();

  static const _key = 'bridge.config.v1';

  static Future<BridgeConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const BridgeConfig();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return BridgeConfig.fromJson(decoded);
      }
    } catch (_) {
      // 配置损坏就当没配过，让用户重新配对，比抛异常友好。
    }
    return const BridgeConfig();
  }

  static Future<void> save(BridgeConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(config.toJson()));
  }

  /// 测试用：清掉保存的配置。
  static Future<void> clearForTesting() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

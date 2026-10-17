/// 网络出口：代理解析 + HttpClient 构造。
///
/// 为什么需要专门一层：Flutter 的 `dart:io` HttpClient **不使用系统代理**，
/// 必须自己读 Windows 的 WinINET 设置 / 环境变量，再把代理塞给 `findProxy`。
/// Android 上通常靠 TUN/VPN 全局模式，直连即可；手动代理也走这里。
library;

import 'dart:convert';
import 'dart:io';

enum ProxyType { http, socks5 }

class ProxyConfig {
  const ProxyConfig({
    this.mode = ProxyMode.system,
    this.type = ProxyType.http,
    this.host = '',
    this.port = 0,
    this.username,
    this.password,
  });

  final ProxyMode mode;
  final ProxyType type;
  final String host;
  final int port;
  final String? username;
  final String? password;

  bool get hasManual => mount.isNotEmpty;
  bool get isDirect => mode == ProxyMode.direct;

  /// 供 UI 展示的 `host:port`
  String get mount => (host.isEmpty || port == 0) ? '' : '$host:$port';

  ProxyConfig copyWith({
    ProxyMode? mode,
    ProxyType? type,
    String? host,
    int? port,
    String? username,
    String? password,
  }) =>
      ProxyConfig(
        mode: mode ?? this.mode,
        type: type ?? this.type,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
      );

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'type': type.name,
        'host': host,
        'port': port,
        if (username != null) 'username': username,
        if (password != null) 'password': password,
      };

  factory ProxyConfig.fromJson(Map<String, Object?> j) => ProxyConfig(
        mode: ProxyMode.values.firstWhere((m) => m.name == j['mode'],
            orElse: () => ProxyMode.system),
        type: ProxyType.values.firstWhere((t) => t.name == j['type'],
            orElse: () => ProxyType.http),
        host: j['host'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 0,
        username: j['username'] as String?,
        password: j['password'] as String?,
      );
}

enum ProxyMode {
  /// 跟随系统（Windows 读 WinINET / 环境变量；Android 通常直连）
  system,

  /// 手动指定
  manual,

  /// 直连，忽略一切代理
  direct,
}

/// 解析当前生效的代理地址：返回 null 表示直连。
Future<({ProxyType type, String host, int port, String? user, String? pass})?>
    resolveProxy(ProxyConfig config) async {
  if (config.mode == ProxyMode.direct) return null;
  if (config.mode == ProxyMode.manual) {
    if (!config.hasManual) return null;
    return (
      type: config.type,
      host: config.host,
      port: config.port,
      user: config.username,
      pass: config.password,
    );
  }
  return resolveSystemProxy();
}

/// 系统代理：
/// 1. 环境变量 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`
/// 2. Windows：WinINET 注册表 `ProxyEnable` + `ProxyServer`
Future<({ProxyType type, String host, int port, String? user, String? pass})?>
    resolveSystemProxy() async {
  for (final key in ['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy']) {
    final raw = Platform.environment[key];
    if (raw == null || raw.trim().isEmpty) continue;
    final parsed = _parseProxyUrl(raw.trim());
    if (parsed != null) return parsed;
  }

  if (Platform.isWindows) {
    try {
      final r = await Process.run('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        '/v',
        'ProxyServer',
      ]);
      if (r.exitCode == 0) {
        final out = r.stdout.toString();
        final m = RegExp(r'ProxyServer\s+REG_SZ\s+(\S+)').firstMatch(out);
        if (m != null) {
          final parsed = _parseWinInetServer(m.group(1)!);
          if (parsed != null) return parsed;
        }
      }
    } catch (_) {
      // 读不到就算了，按直连处理
    }
  }
  return null;
}

/// `http://user:pass@host:port` 或 `host:port`
({ProxyType type, String host, int port, String? user, String? pass})?
    _parseProxyUrl(String raw) {
  var type = ProxyType.http;
  var rest = raw;
  if (rest.startsWith('socks5://') || rest.startsWith('socks5h://')) {
    type = ProxyType.socks5;
    rest = rest.substring(rest.indexOf('://') + 3);
  } else if (rest.startsWith('http://') || rest.startsWith('https://')) {
    rest = rest.substring(rest.indexOf('://') + 3);
  }
  // 去掉路径
  rest = rest.split('/').first;

  String? user;
  String? pass;
  final at = rest.lastIndexOf('@');
  if (at > 0) {
    final cred = rest.substring(0, at);
    rest = rest.substring(at + 1);
    final c = cred.split(':');
    user = c[0];
    if (c.length > 1) pass = c.sublist(1).join(':');
  }

  final colon = rest.lastIndexOf(':');
  if (colon <= 0) return null;
  final host = rest.substring(0, colon);
  final port = int.tryParse(rest.substring(colon + 1));
  if (port == null || port <= 0) return null;
  return (type: type, host: host, port: port, user: user, pass: pass);
}

/// WinINET 的 `ProxyServer` 可能是 `host:port`、`http=host:port;https=host:port`。
({ProxyType type, String host, int port, String? user, String? pass})?
    _parseWinInetServer(String value) {
  if (value.contains('=')) {
    for (final part in value.split(';')) {
      final kv = part.split('=');
      if (kv.length == 2 && (kv[0] == 'https' || kv[0] == 'http')) {
        final parsed = _parseProxyUrl(kv[1]);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }
  return _parseProxyUrl(value);
}

/// 构造走代理的 HttpClient。
///
/// 注意：`findProxy` 只支持 HTTP 代理（Dart 不支持 SOCKS5）。
/// SOCKS5 在 M7 用本地桥接实现；在此之前若配置成 SOCKS5 会退回直连并给出提示。
class ProxyResolution {
  ProxyResolution(this.client, this.usedProxy, this.warning);
  final HttpClient client;
  final String? usedProxy;
  final String? warning;
}

Future<ProxyResolution> buildHttpClient(ProxyConfig config) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 30);

  final proxy = await resolveProxy(config);
  if (proxy == null) {
    return ProxyResolution(client, null, null);
  }
  if (proxy.type == ProxyType.socks5) {
    return ProxyResolution(
      client,
      null,
      'SOCKS5 代理暂未支持，已改为直连（请改用 HTTP 代理或 TUN 模式）',
    );
  }
  final addr = '${proxy.host}:${proxy.port}';
  // 带认证的 HTTP 代理：Dart 的 findProxy 不支持认证，需在请求头里加 Proxy-Authorization。
  client.findProxy = (uri) => 'PROXY $addr';
  if (proxy.user != null && proxy.user!.isNotEmpty) {
    final auth = base64Encode(utf8.encode('${proxy.user}:${proxy.pass ?? ''}'));
    // 通过每次请求注入请求头更稳，这里暴露给调用方处理。
    ProxyAuthHolder.instance.header = 'Basic $auth';
  } else {
    ProxyAuthHolder.instance.header = null;
  }
  return ProxyResolution(client, addr, null);
}

/// 简单承载「给每个请求加 Proxy-Authorization」的状态（Dart 的 HttpClient 不直接支持）。
class ProxyAuthHolder {
  ProxyAuthHolder._();
  static final instance = ProxyAuthHolder._();
  String? header;
}

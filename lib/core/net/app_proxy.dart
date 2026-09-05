import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 代理来源(设置页展示;文案由 UI 按语言映射)。
enum ProxySource { forcedDirect, manual, envVar, systemProxy, directNoProxy }

/// 测试连接结果类型。
enum ProxyTestKind { ok, abnormal, failed }

/// 代理协议。`dart:io` 的 HttpClient 只会说 HTTP(明文转发 + CONNECT 隧道);
/// SOCKS 要自己做握手,它不支持——所以这里认得出来,只为**明确拒绝**而不是
/// 悄悄当成 HTTP 代理连过去(那样只会得到一堆莫名其妙的握手失败)。
enum ProxyScheme { http, https, socks }

/// 代理地址解析失败的原因。核心层不碰 [BuildContext],UI 按当前语言映射文案。
enum ProxyParseError {
  /// 空字符串。
  empty,

  /// 压根不是个地址(缺主机、协议不认识…)。
  malformed,

  /// 端口不在 1–65535。
  badPort,

  /// SOCKS 代理:能解析,但 HttpClient 不支持。
  socksUnsupported,
}

/// 一个解析好的代理端点。
class ProxyEndpoint {
  const ProxyEndpoint({
    required this.scheme,
    required this.host,
    required this.port,
    this.username,
    this.password,
  });

  final ProxyScheme scheme;
  final String host;
  final int port;
  final String? username;
  final String? password;

  bool get hasCredentials => (username ?? '').isNotEmpty;

  /// `host:port`——展示、日志、传给 mpv 用。**不带账密**。
  String get hostPort => '$host:$port';

  /// [HttpClient.findProxy] 要的那一条指令。
  ///
  /// 带认证时写成 `PROXY user:pass@host:port`:`dart:io` 会据此**抢先**发
  /// `Proxy-Authorization: Basic`,并且明文转发和 https 的 CONNECT 隧道两条路都发。
  /// (`addProxyCredentials` 那条路只在明文转发时生效,https 的 CONNECT 隧道压根
  /// 不查它——而这个 App 几乎全是 https,所以走 userinfo 这条。)
  String get directive => hasCredentials
      ? 'PROXY $username:${password ?? ''}@$hostPort'
      : 'PROXY $hostPort';

  @override
  String toString() => hostPort;

  @override
  bool operator ==(Object other) =>
      other is ProxyEndpoint &&
      other.scheme == scheme &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.password == password;

  @override
  int get hashCode => Object.hash(scheme, host, port, username, password);
}

/// [AppProxy.parse] 的结果:成功给端点,失败给错误码。
class ProxyParseResult {
  const ProxyParseResult.ok(ProxyEndpoint this.endpoint) : error = null;
  const ProxyParseResult.failed(ProxyParseError this.error) : endpoint = null;

  final ProxyEndpoint? endpoint;
  final ProxyParseError? error;

  bool get ok => endpoint != null;
}

/// 结构化的测试连接结果(UI 按当前语言拼展示文案)。
class ProxyTestResult {
  const ProxyTestResult({
    required this.kind,
    required this.status,
    required this.ms,
    this.via, // null=直连
    this.error,
  });

  final ProxyTestKind kind;
  final int status; // HTTP 状态码(失败=0)
  final int ms;
  final String? via; // 经由的代理 host:port,null=直连
  final String? error;

  bool get ok => kind == ProxyTestKind.ok;
}

/// 全局 HTTP 代理解析 + 注入。
///
/// **背景**:dio / dart:io 默认只认 `HTTP_PROXY`/`HTTPS_PROXY` 环境变量;从没有这些变量的
/// 终端(或双击)启动时就直连,被墙的源会握手失败。
/// FlClash 之类的工具通常设的是 **Windows 系统代理**(注册表),dart 不会自动读。
/// 这里在启动时解析出应使用的代理并用 [HttpOverrides.global] 注入,让 dio + 图片加载
/// 全部走代理,像浏览器一样"开了系统代理就能用"。
///
/// 解析优先级:手动覆盖 > 环境变量 > 系统代理(Windows 读注册表)。
class AppProxy {
  AppProxy._();

  static const _prefKey = 'net.proxyOverride'; // null=自动 · 'DIRECT'=强制直连 · 'host:port'=手动
  static const _noProxyKey = 'net.proxyNoProxy'; // 逗号分隔的直连名单

  static String? _override;
  static String _noProxy = '';
  static ProxyEndpoint? _resolved; // 当前生效的端点(null=直连)
  static List<String> _bypass = const [];
  static ProxySource _sourceCode = ProxySource.directNoProxy; // 来源码(UI 映射 l10n)
  static int _generation = 0;

  /// 代理配置的版本号,每次 [refresh] 递增。
  ///
  /// [HttpOverrides.global] 只在 `HttpClient()` **构造那一刻**被查询,之后换全局
  /// 覆盖不会追溯到已经建好的 client。持有长命 client 的地方(图片缓存)据此判断
  /// 「自己手里这个是旧代理下建的」并重建。
  static int get generation => _generation;

  /// 当前生效代理("host:port",null=直连)。**不含账密**,可直接进日志/UI。
  static String? get current => _resolved?.hostPort;

  /// 当前生效的完整端点(含账密),注入 HttpClient 用。
  static ProxyEndpoint? get endpoint => _resolved;

  /// 当前代理来源码(设置页据此按当前语言展示)。
  static ProxySource get sourceCode => _sourceCode;

  /// 来源码的中文标签(**仅日志/诊断用**;UI 走 [sourceCode] 映射 l10n)。
  static String get sourceLabel => switch (_sourceCode) {
        ProxySource.forcedDirect => '强制直连',
        ProxySource.manual => '手动设置',
        ProxySource.envVar => '环境变量',
        ProxySource.systemProxy => '系统代理',
        ProxySource.directNoProxy => '直连(未检测到代理)',
      };

  /// 不走代理的主机名单(用户填的原文,逗号分隔)。
  static String get noProxy => _noProxy;

  /// 覆盖模式:null=自动 · 'DIRECT'=强制直连 · 'host:port'=手动。
  static String? get override => _override;

  /// 启动时调用:读回持久化的覆盖设置 → 解析 → 注入。
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _override = prefs.getString(_prefKey);
    _noProxy = prefs.getString(_noProxyKey) ?? '';
    await refresh();
  }

  /// 设置覆盖并立即生效(持久化)。[v]:null=自动 / 'DIRECT'=直连 / 'host:port'=手动。
  /// [noProxy] 给出时一并保存直连名单。
  static Future<void> setOverride(String? v, {String? noProxy}) async {
    final prefs = await SharedPreferences.getInstance();
    if (v == null) {
      await prefs.remove(_prefKey);
    } else {
      await prefs.setString(_prefKey, v);
    }
    if (noProxy != null) {
      _noProxy = noProxy.trim();
      if (_noProxy.isEmpty) {
        await prefs.remove(_noProxyKey);
      } else {
        await prefs.setString(_noProxyKey, _noProxy);
      }
    }
    _override = v;
    await refresh();
  }

  /// 重新解析并注入 [HttpOverrides.global]。
  static Future<void> refresh() async {
    _resolved = await _resolve();
    _bypass = [
      ..._bypassList(_noProxy, includeEnvironment: _override == null),
      // 系统代理自带的排除名单(Android 的 ProxyInfo / http.nonProxyHosts)。
      if (_sourceCode == ProxySource.systemProxy) ..._detectedBypass,
    ];
    HttpOverrides.global = _AppHttpOverrides(_resolved, _bypass);
    _generation++;
  }

  static Future<ProxyEndpoint?> _resolve() async {
    final ov = _override;
    if (ov == 'DIRECT') {
      _sourceCode = ProxySource.forcedDirect;
      return null;
    }
    if (ov != null && ov.isNotEmpty) {
      _sourceCode = ProxySource.manual;
      // 存下来的值可能是旧版本写的、或用户手改过 prefs——解析不了就当直连,
      // 别把 `PROXY 一坨乱码` 塞进 findProxy(dart 会直接抛 HttpException)。
      return parse(ov).endpoint;
    }
    final (proxy, src) = await detectAuto();
    _sourceCode = src;
    return proxy;
  }

  /// 把用户/环境给的一串地址解析成端点。
  ///
  /// 接受 `host:port`、`http://host:port`、`https://user:pass@host:port`;
  /// `socks5://…` 解析得出来但明确拒绝(见 [ProxyScheme])。
  /// 之前这里只是"删掉 scheme 前缀"了事:`user:pass@host:port` 会被整串当主机名,
  /// socks 会被当 HTTP 代理去连,两种都只能得到看不懂的失败。
  static ProxyParseResult parse(String raw) {
    final text = raw.trim().replaceAll(RegExp(r'/+$'), '');
    if (text.isEmpty) return const ProxyParseResult.failed(ProxyParseError.empty);
    final hasScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*://').hasMatch(text);
    final uri = Uri.tryParse(hasScheme ? text : 'http://$text');
    if (uri == null || uri.host.isEmpty) {
      return const ProxyParseResult.failed(ProxyParseError.malformed);
    }
    final scheme = switch (uri.scheme.toLowerCase()) {
      'http' => ProxyScheme.http,
      'https' => ProxyScheme.https,
      'socks' || 'socks4' || 'socks4a' || 'socks5' || 'socks5h' =>
        ProxyScheme.socks,
      _ => null,
    };
    if (scheme == null) {
      return const ProxyParseResult.failed(ProxyParseError.malformed);
    }
    if (scheme == ProxyScheme.socks) {
      return const ProxyParseResult.failed(ProxyParseError.socksUnsupported);
    }
    // 没写端口就按 URL 的常规默认(http 80 / https 443)。
    final port = uri.hasPort
        ? uri.port
        : (scheme == ProxyScheme.https ? 443 : 80);
    if (port <= 0 || port > 65535) {
      return const ProxyParseResult.failed(ProxyParseError.badPort);
    }
    String? user;
    String? pass;
    final info = uri.userInfo;
    if (info.isNotEmpty) {
      final colon = info.indexOf(':');
      user = Uri.decodeComponent(colon < 0 ? info : info.substring(0, colon));
      pass = colon < 0 ? '' : Uri.decodeComponent(info.substring(colon + 1));
      if (user.isEmpty) {
        return const ProxyParseResult.failed(ProxyParseError.malformed);
      }
    }
    return ProxyParseResult.ok(ProxyEndpoint(
      scheme: scheme,
      host: uri.host,
      port: port,
      username: user,
      password: pass,
    ));
  }

  /// 自动检测:环境变量 → 系统代理(Windows 读注册表 / Android 走原生桥)。
  /// 返回 (端点 或 null, 来源码)。供"使用系统代理"选项 + 测试连接复用。
  static Future<(ProxyEndpoint?, ProxySource)> detectAuto() async {
    _detectedBypass = const [];
    final env = Platform.environment;
    final e = env['HTTPS_PROXY'] ??
        env['https_proxy'] ??
        env['HTTP_PROXY'] ??
        env['http_proxy'] ??
        env['ALL_PROXY'] ??
        env['all_proxy'];
    if (e != null && e.isNotEmpty) {
      final parsed = parse(e).endpoint;
      if (parsed != null) return (parsed, ProxySource.envVar);
    }
    if (Platform.isWindows) {
      final sys = await _windowsSystemProxy();
      if (sys != null) {
        final parsed = parse(sys).endpoint;
        if (parsed != null) return (parsed, ProxySource.systemProxy);
      }
    }
    if (Platform.isAndroid) {
      // Android 进程里没有 HTTP_PROXY 之类的环境变量,系统代理只能问原生要;
      // 之前这段被 `Platform.isWindows` 包着,于是设置页照样给「使用系统代理」
      // 这个选项,选了却永远直连。
      final (sys, exclusions) = await readAndroidSystemProxy();
      final parsed = sys == null ? null : parse(sys).endpoint;
      if (parsed != null) {
        _detectedBypass = exclusions;
        return (parsed, ProxySource.systemProxy);
      }
    }
    return (null, ProxySource.directNoProxy);
  }

  static const _androidProxyChannel =
      MethodChannel('dream_manga_reader/system_proxy');

  /// 系统自带的直连名单(Android `ProxyInfo.exclusionList` / `http.nonProxyHosts`)。
  static List<String> _detectedBypass = const [];

  /// 系统代理自带的直连名单(自动模式下并进用户名单)。
  static List<String> get detectedBypass => _detectedBypass;

  /// 问原生要 Android 系统代理,返回 (`host:port` 或 null, 排除名单)。
  /// 测试可直接调它(桩掉 MethodChannel)。
  static Future<(String?, List<String>)> readAndroidSystemProxy() async {
    try {
      final raw = await _androidProxyChannel
          .invokeMapMethod<String, Object?>('getSystemProxy');
      return androidSystemProxyFrom(raw);
    } catch (_) {
      // 老版本 APK / 桥没注册(MissingPluginException)→ 当作没有系统代理。
      return (null, const <String>[]);
    }
  }

  /// 把原生回来的 `{host, port, exclusions}` 规整成 (`host:port`, 排除名单)。
  static (String?, List<String>) androidSystemProxyFrom(
    Map<String, Object?>? raw,
  ) {
    if (raw == null) return (null, const <String>[]);
    final host = (raw['host'] as String?)?.trim() ?? '';
    final port = raw['port'];
    if (host.isEmpty || port is! int || port <= 0 || port > 65535) {
      return (null, const <String>[]);
    }
    final exclusions = <String>[
      for (final e in (raw['exclusions'] as List?) ?? const [])
        if ('$e'.trim().isNotEmpty) '$e'.trim(),
    ];
    return ('$host:$port', exclusions);
  }

  /// 该主机是否绕过代理(no_proxy 名单 + 本机地址)。
  ///
  /// [patterns] 里:`*` = 全部直连;`.corp.com` / `corp.com` = 该域及其子域;
  /// 其余按主机名精确匹配。大小写不敏感。
  static bool shouldBypass(String host, [List<String>? patterns]) {
    final h = host.toLowerCase();
    // 本机地址永远直连(代理自身、localhost 服务),避免环回。
    if (h == 'localhost' ||
        h == '127.0.0.1' ||
        h == '::1' ||
        h == '[::1]' ||
        h.endsWith('.local')) {
      return true;
    }
    for (final raw in patterns ?? _bypass) {
      final p = raw.toLowerCase();
      if (p.isEmpty) continue;
      if (p == '*') return true;
      final bare = p.startsWith('.') ? p.substring(1) : p;
      if (h == bare || h.endsWith('.$bare')) return true;
    }
    return false;
  }

  /// 把逗号/分号/空白分隔的名单切成列表;自动模式下并上 `NO_PROXY` 环境变量。
  static List<String> _bypassList(
    String raw, {
    required bool includeEnvironment,
  }) {
    final env = includeEnvironment
        ? (Platform.environment['NO_PROXY'] ??
            Platform.environment['no_proxy'] ??
            '')
        : '';
    return [
      for (final part in '$raw,$env'.split(RegExp(r'[,;\s]+')))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }

  /// 解析直连名单文本(设置页校验/预演用)。
  static List<String> parseNoProxy(String raw) =>
      _bypassList(raw, includeEnvironment: false);

  /// 测试连接:用指定代理([proxy] 为 null=直连)访问一个在墙内会被拦的站点,返回结构化结果
  /// (UI 按当前语言拼文案)。用 Google 的 generate_204 做通用连通性探针;独立 HttpClient +
  /// 显式 findProxy,**不受当前全局设置影响**,可在保存前预演。[ProxyTestResult.via] null=直连。
  static Future<ProxyTestResult> test(
    ProxyEndpoint? proxy, {
    List<String> bypass = const [],
  }) async {
    const url = 'https://www.google.com/generate_204';
    final sw = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    final via = proxy?.hostPort;
    client.findProxy = (uri) => proxy == null || shouldBypass(uri.host, bypass)
        ? 'DIRECT'
        : proxy.directive;
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      await resp.drain<void>();
      sw.stop();
      final ok = resp.statusCode == 204 || resp.statusCode == 200;
      return ProxyTestResult(
        kind: ok ? ProxyTestKind.ok : ProxyTestKind.abnormal,
        status: resp.statusCode,
        ms: sw.elapsedMilliseconds,
        via: via,
      );
    } catch (e) {
      sw.stop();
      return ProxyTestResult(
        kind: ProxyTestKind.failed,
        status: 0,
        ms: sw.elapsedMilliseconds,
        via: via,
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 读 Windows 系统代理(注册表 Internet Settings)。
  static Future<String?> _windowsSystemProxy() async {
    try {
      const key =
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      final en = await Process.run('reg', ['query', key, '/v', 'ProxyEnable']);
      // ProxyEnable REG_DWORD 0x0/0x1
      if (!RegExp(r'ProxyEnable\s+REG_DWORD\s+0x0*1\b')
          .hasMatch(en.stdout.toString())) {
        return null;
      }
      final sv = await Process.run('reg', ['query', key, '/v', 'ProxyServer']);
      final m = RegExp(r'ProxyServer\s+REG_SZ\s+(\S+)')
          .firstMatch(sv.stdout.toString());
      if (m == null) return null;
      var v = m.group(1)!.trim();
      // 可能是 "host:port" 或 "http=host:port;https=host:port;..."
      if (v.contains('=')) {
        final https = RegExp(r'https=([^;]+)').firstMatch(v);
        final http = RegExp(r'http=([^;]+)').firstMatch(v);
        v = (https ?? http)?.group(1)?.trim() ?? '';
      }
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }
}

class _AppHttpOverrides extends HttpOverrides {
  _AppHttpOverrides(this.proxy, this.bypass);

  final ProxyEndpoint? proxy;
  final List<String> bypass;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    final p = proxy;
    if (p != null) {
      client.findProxy = (uri) =>
          AppProxy.shouldBypass(uri.host, bypass) ? 'DIRECT' : p.directive;
    }
    return client;
  }
}

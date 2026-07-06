import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

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

  static String? _override;
  static String? _resolved; // 当前生效的 host:port(null=直连)
  static String _source = '未初始化'; // 来源说明(设置页展示)

  /// 当前生效代理("host:port",null=直连)。
  static String? get current => _resolved;

  /// 当前代理来源的人话说明。
  static String get sourceLabel => _source;

  /// 覆盖模式:null=自动 · 'DIRECT'=强制直连 · 'host:port'=手动。
  static String? get override => _override;

  /// 启动时调用:读回持久化的覆盖设置 → 解析 → 注入。
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _override = prefs.getString(_prefKey);
    await refresh();
  }

  /// 设置覆盖并立即生效(持久化)。[v]:null=自动 / 'DIRECT'=直连 / 'host:port'=手动。
  static Future<void> setOverride(String? v) async {
    final prefs = await SharedPreferences.getInstance();
    if (v == null) {
      await prefs.remove(_prefKey);
    } else {
      await prefs.setString(_prefKey, v);
    }
    _override = v;
    await refresh();
  }

  /// 重新解析并注入 [HttpOverrides.global]。
  static Future<void> refresh() async {
    _resolved = await _resolve();
    HttpOverrides.global = _AppHttpOverrides(_resolved);
  }

  static Future<String?> _resolve() async {
    final ov = _override;
    if (ov == 'DIRECT') {
      _source = '强制直连';
      return null;
    }
    if (ov != null && ov.isNotEmpty) {
      _source = '手动设置';
      return _strip(ov);
    }
    final (proxy, src) = await detectAuto();
    _source = src;
    return proxy;
  }

  /// 自动检测:环境变量 → Windows 系统代理。返回 (host:port 或 null, 来源说明)。
  /// 供"使用系统代理"选项 + 测试连接复用。
  static Future<(String?, String)> detectAuto() async {
    final env = Platform.environment;
    final e = env['HTTPS_PROXY'] ??
        env['https_proxy'] ??
        env['HTTP_PROXY'] ??
        env['http_proxy'] ??
        env['ALL_PROXY'] ??
        env['all_proxy'];
    if (e != null && e.isNotEmpty) return (_strip(e), '环境变量');
    if (Platform.isWindows) {
      final sys = await _windowsSystemProxy();
      if (sys != null) return (sys, 'Windows 系统代理');
    }
    return (null, '直连(未检测到代理)');
  }

  /// 测试连接:用指定代理([proxy] 为 null=直连)访问一个在墙内会被拦的站点,返回 (成功?, 说明)。
  /// 用 Google 的 generate_204(墙内直连握手失败、走代理返回 204)做通用连通性探针。
  /// 独立构建 HttpClient 并显式设 findProxy,**不受当前全局设置影响**,可在保存前预演。
  static Future<(bool, String)> test(String? proxy) async {
    const url = 'https://www.google.com/generate_204';
    final sw = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    final p = proxy;
    client.findProxy = (uri) {
      final h = uri.host;
      if (h == 'localhost' || h == '127.0.0.1' || h == '::1') return 'DIRECT';
      return (p != null && p.isNotEmpty) ? 'PROXY $p' : 'DIRECT';
    };
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      await resp.drain<void>();
      sw.stop();
      final via = (p == null || p.isEmpty) ? '直连' : p;
      final ok = resp.statusCode == 204 || resp.statusCode == 200;
      return (
        ok,
        '${ok ? '✓ 连通' : '⚠ 有响应但异常'} · HTTP ${resp.statusCode}'
            ' · ${sw.elapsedMilliseconds}ms · 经 $via'
      );
    } catch (e) {
      sw.stop();
      final via = (p == null || p.isEmpty) ? '直连' : p;
      return (
        false,
        '✗ 失败 · ${sw.elapsedMilliseconds}ms · 经 $via\n$e'
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 去掉 scheme 与尾部斜杠:`http://127.0.0.1:7890/` → `127.0.0.1:7890`。
  static String _strip(String s) =>
      s.replaceFirst(RegExp(r'^\w+://'), '').replaceAll(RegExp(r'/+$'), '').trim();

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
  _AppHttpOverrides(this.proxy);

  final String? proxy;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    final p = proxy;
    if (p != null && p.isNotEmpty) {
      client.findProxy = (uri) {
        final h = uri.host;
        // 本机地址直连(代理本身、以及 localhost 服务),避免环回
        if (h == 'localhost' ||
            h == '127.0.0.1' ||
            h == '::1' ||
            h.endsWith('.local')) {
          return 'DIRECT';
        }
        return 'PROXY $p';
      };
    }
    return client;
  }
}

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';

import '../../app/app_info.dart';
import '../../app/theme/app_colors.dart';
import '../../core/net/dio_http_service.dart';
import '../../core/net/webview_fetch.dart';
import '../../core/script/js_engine.dart';
import '../../core/script/script_source.dart';
import '../../core/source/hello_source.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../spike/cloudflare_spike_page.dart';

/// 调试工具:环境信息 + 各环节自检 + 抓取探针。产品页面不含这些,统一收在这里。
class DebugPage extends StatefulWidget {
  const DebugPage({super.key});

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage> {
  late final MangaSource _hello = HelloSource(DefaultHostApi(DioHttpService()));
  String _srcTest = '未运行';
  String _jsTest = '未运行';
  String _scriptTest = '未运行';
  String _liveTest = '未运行';
  String _probeResult = '未运行';
  String _pagesResult = '未运行';
  final TextEditingController _pMangaCtrl = TextEditingController();
  final TextEditingController _pChapterCtrl =
      TextEditingController();
  final TextEditingController _probeCtrl =
      TextEditingController(text: 'https://example.com/update/');
  final TextEditingController _probeKwCtrl = TextEditingController();
  final TextEditingController _probeJsCtrl = TextEditingController(
    text:
        r"var r=await fetch(location.href,{credentials:'include'});var h=await r.text();var m=h.match(/window\[[\x22\x27]\\x65\\x76\\x61\\x6c[\x22\x27]\]([\s\S]+?)<\/script>/);if(!m)return 'NO packed; htmlLen='+h.length;var p=m[1];return JSON.stringify({packedLen:p.length,head:p.slice(0,260),tail:p.slice(-260)});",
  );

  /// 若填了关键词,返回其在 html 中周围的片段(用于找章节链接/packed 脚本等)。
  String _kwContext(String html) {
    final raw = _probeKwCtrl.text.trim();
    if (raw.isEmpty) return '';
    final kws = raw
        .split(RegExp(r'[,，\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    final b = StringBuffer();
    for (final kw in kws) {
      final idx = html.indexOf(kw);
      if (idx < 0) {
        b.writeln('\n--- "$kw" 未找到 ---');
        continue;
      }
      final start = (idx - 200).clamp(0, html.length);
      final end = (idx + 700).clamp(0, html.length);
      b
        ..writeln('\n--- "$kw" @ $idx ---')
        ..writeln(html.substring(start, end));
    }
    return b.toString();
  }

  Future<void> _runHello() async {
    final d = await _hello.getDiscovery(1);
    final ch = await _hello.getChapters('m0');
    final pg = await _hello.getPages('m0', 'c1');
    setState(() => _srcTest = '✓ 源「${_hello.name}」contract OK\n'
        '发现 ${d.items.length} 部 · 章节 ${ch.items.length} 话 · 首话 ${pg.length} 页\n'
        '示例:${d.items.take(3).map((m) => m.title).join('、')} …');
  }

  void _runJs() {
    try {
      final js = JsEngine();
      final v1 = js.evalSync('1 + 2');
      final v2 = js.evalSync(
        '(function(){const d={t:"墨染之约",c:[1,2,3]};'
        'return JSON.stringify({n:d.c.length,len:d.t.length});})()',
      );
      js.dispose();
      setState(() => _jsTest = '✓ QuickJS OK\n1 + 2 = $v1\nJSON/Unicode = $v2');
    } catch (e) {
      setState(() => _jsTest = '✗ $e');
    }
  }

  Future<void> _runScript() async {
    try {
      final engine = JsEngine();
      final src = ScriptSource(
        engine: engine,
        http: _FakeHtmlHttp(),
        scriptCode: _demoHtmlSource,
      );
      final page = await src.getDiscovery(1);
      engine.dispose();
      setState(() => _scriptTest =
          '✓ 脚本源(JS prepare/handle + host.html)OK\n'
          '解析出 ${page.items.length} 部:'
          '${page.items.map((m) => m.title).join('、')}');
    } catch (e) {
      setState(() => _scriptTest = '✗ $e');
    }
  }

  Future<void> _runLive(SourceMeta meta) async {
    setState(() => _liveTest = '运行中…(联网)');
    try {
      final src = buildSource(meta);
      final page = await src.getDiscovery(1);
      setState(() => _liveTest = '✓ ${meta.name}.getDiscovery → ${page.items.length} 部\n'
          '${page.items.take(6).map((m) => m.title).join('、')}');
    } catch (e) {
      setState(() => _liveTest = '✗ ${meta.name}:$e');
    }
  }

  Future<void> _runProbe() async {
    setState(() => _probeResult = '抓取中…(联网)');
    try {
      final resp = await DioHttpService().fetch(HostRequest(
        _probeCtrl.text.trim(),
        headers: const {
          'Referer': 'https://example.com/',
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
        },
      ));
      final doc = html_parser.parse(resp.body);
      final links = doc.querySelectorAll('a[href*="/comic/"]');
      final sb = StringBuffer()
        ..writeln('HTTP ${resp.status} · ${resp.body.length} 字节')
        ..writeln('a[href*="/comic/"]: ${links.length} 个');
      for (final a in links.take(12)) {
        sb.writeln(a.outerHtml.replaceAll(RegExp(r'\s+'), ' ').trim());
      }
      if (links.isEmpty) {
        final b = resp.body;
        sb
          ..writeln('--- 未找到 /comic/ 链接,页面前 1500 字节 ---')
          ..writeln(b.length <= 1500 ? b : b.substring(0, 1500));
      }
      sb.write(_kwContext(resp.body));
      setState(() => _probeResult = sb.toString());
    } catch (e) {
      setState(() => _probeResult = '✗ $e');
    }
  }

  Future<void> _runProbeWebView() async {
    setState(() => _probeResult = 'WebView 抓取中…(联网)');
    try {
      final html = await WebViewFetcher.fetchHtml(
        _probeCtrl.text.trim(),
        userAgent:
            'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
      );
      final doc = html_parser.parse(html);
      final links = doc.querySelectorAll('a[href*="/comic/"]');
      final sb = StringBuffer()
        ..writeln('[WebView] ${html.length} 字节 · a[href*="/comic/"]: ${links.length} 个');
      for (final a in links.take(12)) {
        sb.writeln(a.outerHtml.replaceAll(RegExp(r'\s+'), ' ').trim());
      }
      if (links.isEmpty) {
        sb
          ..writeln('--- 无 /comic/ 链接,前 1500 字节 ---')
          ..writeln(html.length <= 1500 ? html : html.substring(0, 1500));
      }
      sb.write(_kwContext(html));
      setState(() => _probeResult = sb.toString());
    } catch (e) {
      setState(() => _probeResult = '✗ WebView: $e');
    }
  }

  Future<void> _runProbeEval() async {
    setState(() => _probeResult = 'WebView 执行 JS 中…(联网)');
    try {
      final r = await WebViewFetcher.evalInPage(
        _probeCtrl.text.trim(),
        _probeJsCtrl.text,
        userAgent:
            'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
      );
      setState(() => _probeResult = '[eval 结果]\n$r');
    } catch (e) {
      setState(() => _probeResult = '✗ eval: $e');
    }
  }

  /// 执行 JS 并把**完整**返回写到文件,供离线直接读全文(不截断)。
  Future<void> _runProbeEvalSave() async {
    setState(() => _probeResult = '执行并保存中…(联网)');
    try {
      final r = await WebViewFetcher.evalInPage(
        _probeCtrl.text.trim(),
        _probeJsCtrl.text,
        userAgent:
            'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
      );
      final dir = await getApplicationSupportDirectory();
      final f =
          File('${dir.path}${Platform.pathSeparator}probe_result.txt');
      await f.writeAsString('$r');
      setState(() => _probeResult = '✓ 已保存 ${('$r').length} 字节:\n${f.path}');
    } catch (e) {
      setState(() => _probeResult = '✗ $e');
    }
  }

  Future<void> _runPages() async {
    if (registeredSources.isEmpty) {
      setState(() => _pagesResult = '✗ 未配置任何源(去「设置 › 源管理」加载源仓库)');
      return;
    }
    setState(() => _pagesResult = '运行中…(联网 + 解码)');
    try {
      final src = buildSource(registeredSources.first);
      final pages = await src.getPages(
          _pMangaCtrl.text.trim(), _pChapterCtrl.text.trim());
      final sb = StringBuffer()..writeln('✓ 解出 ${pages.length} 页');
      for (final pg in pages.take(3)) {
        sb.writeln('${pg.index}: ${pg.url}');
      }
      setState(() => _pagesResult = sb.toString());
    } catch (e) {
      setState(() => _pagesResult = '✗ $e');
    }
  }

  /// 把真实详情页(章节表)+ 章节页(图片解码)HTML 存到文件,供离线集成测试。
  Future<void> _saveFixture() async {
    setState(() => _pagesResult = '抓取并保存中…(联网)');
    try {
      final id = _pMangaCtrl.text.trim();
      final cid = _pChapterCtrl.text.trim();
      const ua =
          'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';
      final dir = await getApplicationSupportDirectory();
      final sep = Platform.pathSeparator;

      // 详情页:JS 渲染后的 DOM(章节表在这里)
      final detailHtml = await WebViewFetcher.fetchHtml(
          'https://example.com/comic/$id/',
          userAgent: ua);
      final df = File('${dir.path}${sep}probe_detail.html');
      await df.writeAsString(detailHtml);

      // 章节页:原始 HTML(packer 在这里)
      final chapterHtml = await WebViewFetcher.fetchHtml(
          'https://example.com/comic/$id/$cid.html',
          userAgent: ua,
          raw: true);
      final cf = File('${dir.path}${sep}probe_chapter.html');
      await cf.writeAsString(chapterHtml);

      setState(() => _pagesResult = '✓ 详情 ${detailHtml.length}B → ${df.path}\n'
          '✓ 章节 ${chapterHtml.length}B → ${cf.path}');
    } catch (e) {
      setState(() => _pagesResult = '✗ $e');
    }
  }

  @override
  void dispose() {
    _probeCtrl.dispose();
    _probeKwCtrl.dispose();
    _probeJsCtrl.dispose();
    _pMangaCtrl.dispose();
    _pChapterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(title: const Text('调试工具')),
      body: AppScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          _sectionLabel(p, '环境'),
          _envCard(p),
          const SizedBox(height: 20),
          _sectionLabel(p, '平台自检'),
          _card(p, '① 源契约', '本地演示源验证 MangaSource 契约。', _runHello, _srcTest,
              '运行 Hello 源'),
          const SizedBox(height: 14),
          _card(p, '② JS 引擎(QuickJS)', 'flutter_js 跑 JS,验证引擎可用。',
              _runJs, _jsTest, '运行 JS 引擎'),
          const SizedBox(height: 14),
          _card(
              p,
              '③ 脚本源(JS + host.html)',
              'JS 源经宿主拉取 + host.html 解析,端到端跑通脚本源管线。',
              _runScript,
              _scriptTest,
              '运行脚本源'),
          const SizedBox(height: 14),
          _card2(
            p,
            '④ Cloudflare 过盾',
            'WebView 过挑战 → 取 cf_clearance → dio 复验。',
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CloudflareSpikePage()),
            ),
            '打开过盾验证 →',
          ),
          const SizedBox(height: 20),
          _sectionLabel(p, '源 · 探针'),
          _shell(
            p,
            '⑤ 真源联网测试',
            '联网运行任一注册源的 getDiscovery,看结果 / 报错。'
                '各源的快速可用性状态见「设置 → 源管理」的状态点。',
            [
              for (final s in registeredSources)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FilledButton(
                    onPressed: () => _runLive(s),
                    child: Text('运行 ${s.name}'),
                  ),
                ),
              _resultBox(p, _liveTest),
            ],
          ),
          const SizedBox(height: 14),
          _shell(
            p,
            '⑥ 源探针(抓 HTML 看结构)',
            '抓取一个 URL(带 mhgm 头),列出含 /comic/ 的 <a> 标签原文——复制发我,'
                '我照真实 class/结构把选择器改对。',
            [
              TextField(
                controller: _probeCtrl,
                style: TextStyle(color: p.textPrimary, fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: p.elevated,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _probeKwCtrl,
                style: TextStyle(color: p.textPrimary, fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '关键词(可选,显示其周围片段,如 SMH. / eval)',
                  filled: true,
                  fillColor: p.elevated,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: _runProbe, child: const Text('dio 抓取(诊断)')),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _runProbeWebView,
                child: const Text('WebView 抓取并分析(推荐)'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _probeJsCtrl,
                maxLines: 2,
                style: TextStyle(color: p.textPrimary, fontSize: 11),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '在页面执行的 JS(读整章图片列表用)',
                  filled: true,
                  fillColor: p.elevated,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _runProbeEval,
                      child: const Text('在页面执行 JS'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _runProbeEvalSave,
                      child: const Text('执行并保存全文'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _resultBox(p, _probeResult),
            ],
          ),
          const SizedBox(height: 14),
          _shell(
            p,
            '⑦ 章节解码(getPages)',
            'WebView 取原始 HTML → 沙箱 eval 解包 SMH.reader → 整章图片 URL(带签名)。'
                '默认 60392/894381(葬流者 第1卷)。',
            [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pMangaCtrl,
                      style: TextStyle(color: p.textPrimary, fontSize: 12),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '漫画 id',
                        filled: true,
                        fillColor: p.elevated,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _pChapterCtrl,
                      style: TextStyle(color: p.textPrimary, fontSize: 12),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '章节 id',
                        filled: true,
                        fillColor: p.elevated,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton(
                  onPressed: _runPages, child: const Text('运行 getPages')),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _saveFixture,
                child: const Text('保存详情+章节 HTML(供离线调试)'),
              ),
              const SizedBox(height: 8),
              _resultBox(p, _pagesResult),
            ],
          ),
        ],
      ),
    );
  }

  Widget _card(AppPalette p, String title, String subtitle,
          VoidCallback onRun, String result, String btn) =>
      _shell(p, title, subtitle, [
        FilledButton(onPressed: onRun, child: Text(btn)),
        const SizedBox(height: 12),
        _resultBox(p, result),
      ]);

  Widget _card2(AppPalette p, String title, String subtitle,
          VoidCallback onTap, String btn) =>
      _shell(p, title, subtitle, [
        FilledButton(onPressed: onTap, child: Text(btn)),
      ]);

  Widget _sectionLabel(AppPalette p, String text) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 12, left: 4),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
              color: p.accent,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 2),
        ),
      );

  Widget _kv(AppPalette p, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 76,
                child: Text(k,
                    style: TextStyle(color: p.textMuted, fontSize: 12.5))),
            Expanded(
                child: Text(v,
                    style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 12.5,
                        height: 1.4))),
          ],
        ),
      );

  Widget _envCard(AppPalette p) => _shell(p, '环境信息', '当前运行环境概览。', [
        _kv(p, '应用', '${AppInfo.name} v${AppInfo.version}'),
        _kv(p, '平台', defaultTargetPlatform.name),
        _kv(p, '编译模式',
            kDebugMode ? 'debug' : (kProfileMode ? 'profile' : 'release')),
        _kv(p, '已注册源',
            '${registeredSources.length} 个 · ${registeredSources.map((s) => s.name).join('、')}'),
      ]);

  Widget _shell(
          AppPalette p, String title, String subtitle, List<Widget> body) =>
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(subtitle,
                style:
                    TextStyle(color: p.textMuted, fontSize: 12.5, height: 1.5)),
            const SizedBox(height: 14),
            ...body,
          ],
        ),
      );

  Widget _resultBox(AppPalette p, String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 12, 6, 6),
        decoration: BoxDecoration(
          color: p.elevated,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(
              text,
              style: TextStyle(
                color: p.textPrimary,
                fontSize: 12.5,
                height: 1.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                tooltip: '复制',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  showAppNotify(context, '已复制', kind: AppNotifyKind.success);
                },
                icon: Icon(Icons.copy_rounded, color: p.textMuted),
              ),
            ),
          ],
        ),
      );
}

class _FakeHtmlHttp implements HttpService {
  @override
  Future<HostResponse> fetch(HostRequest request) async => const HostResponse(
        status: 200,
        headers: {},
        body: '<ul class="list">'
            '<li><a href="/c/1">墨染之约</a></li>'
            '<li><a href="/c/2">银河剑客</a></li>'
            '<li><a href="/c/3">雾之国</a></li>'
            '</ul>',
      );
}

const String _demoHtmlSource = r'''
var __source = {
  meta: { id:'dbg', name:'Debug HTML 源', lang:'zh-Hans', baseUrl:'https://demo.test', version:1, nsfw:false },
  prepareDiscovery: function(page){ return { url: this.meta.baseUrl + '/list?p=' + page }; },
  handleDiscovery: function(text){
    var doc = host.html.parse(text);
    return host.html.select(doc, 'ul.list li a').map(function(a){
      return { id: host.html.attr(a,'href'), title: host.html.text(a) };
    });
  }
};
''';

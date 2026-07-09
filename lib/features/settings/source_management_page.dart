import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/auth_store.dart';
import '../../core/net/github_oauth.dart';
import '../../app/library_store.dart';
import '../../app/source_controller.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/source_health.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/source_repository.dart';
import '../../ui/ui.dart';
import 'source_login_page.dart';

/// 源管理:启用/禁用漫画源(至少保留一个)+ 每个源的**可用性状态点**。
/// 打开即联网自检各源(getDiscovery);点圆点看检测日志。禁用的源不在书架源切换器里出现。
class SourceManagementPage extends StatefulWidget {
  const SourceManagementPage({super.key});

  @override
  State<SourceManagementPage> createState() => _SourceManagementPageState();
}

class _SourceManagementPageState extends State<SourceManagementPage> {
  final Map<String, SourceHealthResult> _health = {};
  bool _checkingAll = false;

  final _repo = SourceRepository.instance;
  late final TextEditingController _urlCtrl =
      TextEditingController(text: _repo.repoUrl ?? '');
  late final TextEditingController _tokenCtrl =
      TextEditingController(text: _repo.token ?? '');
  bool _reloading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAll());
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  /// 应用一次源仓库变更(设 URL / 选目录),然后修正当前选中源并重新自检。
  Future<void> _applyRepo(
      Future<void> Function() apply, SourceController sc) async {
    setState(() => _reloading = true);
    await apply();
    _revalidate(sc);
    if (!mounted) return;
    setState(() => _reloading = false);
    showAppNotify(context, _repo.status, kind: AppNotifyKind.info);
    _checkAll();
  }

  /// 源列表变了:把当前选中源修正到仍存在的源(此前为空、或选中项被移除时)。
  void _revalidate(SourceController sc) {
    if (registeredSources.isEmpty) return; // 保持空,UI 走空态
    final cur = sc.current;
    if (cur == null || !registeredSources.any((s) => s.id == cur.id)) {
      sc.current = registeredSources.first;
    }
  }

  Future<void> _pickLocalDir(SourceController sc) async {
    final dir = await FilePicker.getDirectoryPath(
        dialogTitle: '选择包含 index.json 的源目录');
    if (dir == null) return;
    await _applyRepo(() => _repo.setLocalDir(dir), sc);
  }

  /// 导入本地源:单个 `.js` 脚本,或一整套打包的 `.zip`(index.json + 多脚本)。
  Future<void> _addLocalSource(SourceController sc) async {
    final res = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['js', 'zip'],
        dialogTitle: '选择源脚本(.js)或源包(.zip)');
    final path = res?.files.single.path;
    if (path == null) return;
    setState(() => _reloading = true);
    try {
      final String msg;
      if (path.toLowerCase().endsWith('.zip')) {
        final n = await _repo.addLocalSourceZip(path);
        msg = '已从 zip 导入 $n 个源';
      } else {
        msg = '已添加本地源:${await _repo.addLocalSource(path)}';
      }
      _revalidate(sc);
      if (!mounted) return;
      setState(() => _reloading = false);
      showAppNotify(context, msg, kind: AppNotifyKind.success);
      _checkAll();
    } catch (e) {
      if (!mounted) return;
      setState(() => _reloading = false);
      showAppNotify(context, '导入失败:$e', kind: AppNotifyKind.error);
    }
  }

  /// 用 GitHub 设备码流登录换取访问令牌,自动填入令牌框并用当前仓库地址重载。
  Future<void> _githubLogin(SourceController sc) async {
    if (!GithubOAuth.configured) {
      showAppNotify(context,
          'GitHub 登录需先配置 OAuth Client ID(见 github_oauth.dart 注释),或继续用手动令牌',
          kind: AppNotifyKind.warn, duration: const Duration(seconds: 5));
      return;
    }
    setState(() => _reloading = true);
    GithubDeviceCode dc;
    try {
      dc = await GithubOAuth.startDeviceFlow();
    } catch (e) {
      if (!mounted) return;
      setState(() => _reloading = false);
      showAppNotify(context, 'GitHub 登录发起失败:$e', kind: AppNotifyKind.error);
      return;
    }
    if (!mounted) return;
    setState(() => _reloading = false);
    // 弹框:展示 user_code + 打开授权页,后台轮询;成功 pop 出 token。
    final token = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _GithubDeviceDialog(dc),
    );
    if (token != null && token.isNotEmpty && mounted) {
      _tokenCtrl.text = token;
      await _applyRepo(() async {
        await _repo.setToken(token);
        await _repo.setRepoUrl(_urlCtrl.text);
      }, sc);
    }
  }

  /// 删除源(带二次确认)。本地源=真删文件;仓库源=隐藏(可在源仓库卡片恢复)。
  Future<void> _deleteSource(SourceMeta s, SourceController sc) async {
    final isLocal = _repo.localIds.contains(s.id);
    final ok = await showAppConfirm(
      context,
      title: '删除源',
      message: isLocal
          ? '确定删除本地源「${s.name}」?会删掉本地脚本文件,不可撤销。'
          : '确定删除源「${s.name}」?会从列表隐藏(重载仓库也不再出现),之后可在源仓库卡片「恢复已删除的源」找回。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _reloading = true);
    await _repo.deleteSource(s.id);
    _revalidate(sc);
    if (!mounted) return;
    setState(() => _reloading = false);
    showAppNotify(context, '已删除源:${s.name}', kind: AppNotifyKind.success);
  }

  Future<void> _restoreRemoved(SourceController sc) async {
    setState(() => _reloading = true);
    await _repo.restoreRemoved();
    _revalidate(sc);
    if (!mounted) return;
    setState(() => _reloading = false);
    showAppNotify(context, '已恢复删除的源', kind: AppNotifyKind.success);
    _checkAll();
  }

  Future<void> _checkAll() async {
    if (_checkingAll) return;
    setState(() {
      _checkingAll = true;
      for (final s in registeredSources) {
        _health[s.id] = SourceHealthResult.checking;
      }
    });
    await Future.wait(registeredSources.map(_checkOne));
    if (mounted) setState(() => _checkingAll = false);
  }

  Future<void> _checkOne(SourceMeta s) async {
    if (mounted) setState(() => _health[s.id] = SourceHealthResult.checking);
    final r = await checkSourceHealth(s);
    if (mounted) setState(() => _health[s.id] = r);
  }

  Color _colorOf(SourceHealthStatus st, AppPalette p) {
    switch (st) {
      case SourceHealthStatus.ok:
        return p.statusOk;
      case SourceHealthStatus.empty:
        return p.statusWarn;
      case SourceHealthStatus.fail:
        return p.statusFail;
      case SourceHealthStatus.checking:
        return p.accent;
      case SourceHealthStatus.unknown:
        return p.textMuted;
    }
  }

  String _labelOf(SourceHealthResult r) {
    switch (r.status) {
      case SourceHealthStatus.ok:
        return '正常 · ${r.count} 部 · ${r.elapsedMs}ms';
      case SourceHealthStatus.empty:
        return '返回 0 部(疑似限流/失效) · ${r.elapsedMs}ms';
      case SourceHealthStatus.fail:
        return '不可用 · 点圆点看详情';
      case SourceHealthStatus.checking:
        return '检测中…（联网）';
      case SourceHealthStatus.unknown:
        return '未检测';
    }
  }

  Widget _dot(SourceMeta s, AppPalette p) {
    final r = _health[s.id] ?? SourceHealthResult.unknown;
    final Widget inner;
    if (r.status == SourceHealthStatus.checking) {
      inner = SizedBox(
        width: 15,
        height: 15,
        child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
      );
    } else {
      inner = AppStatusDot(color: _colorOf(r.status, p), size: 13, glow: true);
    }
    if (!LibraryStore.animationsEnabled) return inner;
    // 结果点从转圈里带 easeOutBack 回弹弹入,读起来「有定论」。
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      transitionBuilder: (child, anim) => ScaleTransition(
        scale: CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
        child: FadeTransition(opacity: anim, child: child),
      ),
      child: KeyedSubtree(key: ValueKey(r.status), child: inner),
    );
  }

  void _showLog(SourceMeta s) {
    final p = context.palette;
    final r = _health[s.id] ?? SourceHealthResult.unknown;
    showAppDialog<void>(
      context,
      title: '${s.name} · 检测日志',
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: SelectableText(
            r.log,
            style: TextStyle(
              color: p.textPrimary,
              fontSize: 12.5,
              height: 1.55,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: r.log));
            showAppNotify(context, '日志已复制', kind: AppNotifyKind.success);
          },
          child: const Text('复制'),
        ),
        Builder(
          builder: (ctx) => TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _checkOne(s);
            },
            child: const Text('重新检测'),
          ),
        ),
        Builder(
          builder: (ctx) => TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final store = LibraryScope.of(context);
    final sc = SourceScope.of(context);
    final auth = AuthScope.of(context); // 依赖:登录/登出后行内登录按钮自动刷新
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('源管理',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: [
          IconButton(
            tooltip: '重新检测全部',
            onPressed: _checkingAll ? null : _checkAll,
            icon: _checkingAll
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: AppScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _repoCard(p, sc),
          const SizedBox(height: 16),
          if (registeredSources.isEmpty)
            const EmptyState(
              title: '还没有加载到任何源',
              message: '填入上面的源仓库地址,或选择一个包含 index.json 的本地目录。',
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Text(
                '圆点=可用性:绿=正常 · 黄=可达但返回空(限流/失效) · 红=不可用 · 灰=未测。点圆点看日志。',
                style: TextStyle(color: p.textMuted, fontSize: 12, height: 1.5),
              ),
            ),
            // 漫画源、番剧源分开成两组,别缠在一起。
            ..._group('漫画源', registeredSources.where((s) => !s.isAnime).toList(),
                p, store, sc, auth),
            ..._group('番剧源', registeredSources.where((s) => s.isAnime).toList(),
                p, store, sc, auth),
          ],
        ],
      ),
    );
  }

  /// 一组同类源(漫画 / 番剧):标题 + 若干行;组为空则整组不渲染。
  List<Widget> _group(String title, List<SourceMeta> list, AppPalette p,
      LibraryStore store, SourceController sc, AuthStore auth) {
    if (list.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 2, 12),
        child: AppSectionHeading(title, fontSize: 18),
      ),
      for (final s in list)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _row(s, p, store, sc, auth),
        ),
    ];
  }

  // 源仓库配置:引擎不内置源,从这里填 URL / 选本地目录加载源脚本。
  Widget _repoCard(AppPalette p, SourceController sc) => AppCard(
        radius: 14,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_sync_rounded, size: 18, color: p.accent),
                const SizedBox(width: 8),
                Text('源仓库',
                    style: TextStyle(
                        color: p.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 15)),
                const SizedBox(width: 12),
                // 状态文本可能很长(URL/错误/路径)→ Expanded + 省略号,别撑溢出。
                Expanded(
                  child: Text('${registeredSources.length} 个源 · ${_repo.status}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(color: p.textMuted, fontSize: 11.5)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            AppTextField(
              controller: _urlCtrl,
              enabled: !_reloading,
              hint: '源仓库地址(index.json 所在的 raw 根 URL)',
            ),
            const SizedBox(height: 8),
            // 访问令牌:填了才能拉**私有**源仓库(留空 = 公开地址直接拉)。
            AppTextField(
              controller: _tokenCtrl,
              enabled: !_reloading,
              obscure: true,
              hint: '访问令牌(拉私有仓库用,可留空)',
            ),
            const SizedBox(height: 4),
            // 用 GitHub 登录换取令牌(设备码流),免手动粘贴 PAT。
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _reloading ? null : () => _githubLogin(sc),
                icon: const Icon(Icons.login_rounded, size: 16),
                label: const Text('用 GitHub 登录(拉私有仓库,免粘贴令牌)',
                    style: TextStyle(fontSize: 12.5)),
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 32)),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _reloading
                        ? null
                        : () => _applyRepo(() async {
                              await _repo.setToken(_tokenCtrl.text); // 先落盘 token
                              await _repo.setRepoUrl(_urlCtrl.text); // 再存 URL 并重载
                            }, sc),
                    icon: _reloading
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.download_rounded, size: 18),
                    label: const Text('加载 / 刷新'),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _reloading ? null : () => _pickLocalDir(sc),
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('本地目录'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 加单个本地源脚本(不需要整套仓库/清单),与仓库源合并共存。
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _reloading ? null : () => _addLocalSource(sc),
                icon: const Icon(Icons.note_add_rounded, size: 18),
                label: const Text('导入本地源(.js / .zip)'),
              ),
            ),
            // 有删掉的仓库源时,给个一键恢复入口。
            if (_repo.removedIds.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _reloading ? null : () => _restoreRemoved(sc),
                  icon: const Icon(Icons.restore_rounded, size: 16),
                  label: Text('恢复已删除的源(${_repo.removedIds.length})',
                      style: const TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 32)),
                ),
              ),
          ],
        ),
      );

  Widget _row(SourceMeta s, AppPalette p, LibraryStore store,
      SourceController sc, AuthStore auth) {
    final r = _health[s.id] ?? SourceHealthResult.unknown;
    final enabled = store.isSourceEnabled(s.id);
    return AppCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      child: Row(
        children: [
          // 状态点(可点 → 日志),留足点击热区
          InkWell(
            onTap: () => _showLog(s),
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _dot(s, p),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.name,
                    style: TextStyle(
                        color: p.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14)),
                const SizedBox(height: 2),
                Text(
                  '${_repo.localIds.contains(s.id) ? '本地 · ' : ''}${s.experimental ? '实验性 · ' : ''}${_labelOf(r)}',
                  style: TextStyle(
                    color: r.status == SourceHealthStatus.fail
                        ? p.statusFail
                        : (r.status == SourceHealthStatus.empty
                            ? p.statusWarn
                            : p.textMuted),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          // 删除源(本地=真删文件;仓库=隐藏,可恢复)。带二次确认。
          IconButton(
            tooltip: '删除源',
            visualDensity: VisualDensity.compact,
            onPressed: _reloading ? null : () => _deleteSource(s, sc),
            icon: Icon(Icons.delete_outline_rounded,
                color: p.textMuted, size: 20),
          ),
          // 需要账号的源:行内直接放登录入口(已登录=实心账号图标+主题色)。
          if (s.needsLogin)
            IconButton(
              tooltip: auth.isLoggedIn(s.id)
                  ? '已登录:${auth.nicknameOf(s.id) ?? auth.usernameOf(s.id) ?? ''}'
                  : '登录 ${s.name}',
              visualDensity: VisualDensity.compact,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SourceLoginPage(meta: s))),
              icon: Icon(
                auth.isLoggedIn(s.id)
                    ? Icons.account_circle_rounded
                    : Icons.login_rounded,
                color: auth.isLoggedIn(s.id) ? p.accent : p.textMuted,
                size: 20,
              ),
            ),
          Switch(
            value: enabled,
            onChanged: (v) {
              store.setSourceEnabled(s.id, v, registeredSources.length);
              if (!store.isSourceEnabled(s.id) && sc.current?.id == s.id) {
                for (final x in registeredSources) {
                  if (store.isSourceEnabled(x.id)) {
                    sc.current = x;
                    break;
                  }
                }
              }
              setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

/// GitHub 设备码授权弹框:展示验证码 + 打开授权页,后台轮询;授权成功自动 pop 出 access_token。
class _GithubDeviceDialog extends StatefulWidget {
  const _GithubDeviceDialog(this.dc);
  final GithubDeviceCode dc;

  @override
  State<_GithubDeviceDialog> createState() => _GithubDeviceDialogState();
}

class _GithubDeviceDialogState extends State<_GithubDeviceDialog> {
  bool _cancelled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _poll();
  }

  Future<void> _poll() async {
    try {
      final token =
          await GithubOAuth.pollForToken(widget.dc, cancelled: () => _cancelled);
      if (mounted) Navigator.of(context).pop(token);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text('用 GitHub 登录',
          style: TextStyle(
              color: p.textPrimary, fontSize: 17, fontWeight: FontWeight.w800)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('1. 复制下面的验证码:',
              style: TextStyle(color: p.textMuted, fontSize: 13)),
          const SizedBox(height: 8),
          Center(
            child: SelectableText(widget.dc.userCode,
                style: TextStyle(
                    color: p.accent,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
          const SizedBox(height: 12),
          Text('2. 打开授权页,粘贴验证码并授权:',
              style: TextStyle(color: p.textMuted, fontSize: 13)),
          const SizedBox(height: 8),
          Center(
            child: FilledButton.icon(
              onPressed: () => launchUrl(Uri.parse(widget.dc.verificationUri),
                  mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('打开 GitHub 授权页'),
            ),
          ),
          const SizedBox(height: 14),
          if (_error != null)
            Text(_error!,
                style: TextStyle(color: p.statusFail, fontSize: 12.5))
          else
            Row(children: [
              SizedBox(
                  width: 14,
                  height: 14,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: p.accent)),
              const SizedBox(width: 8),
              Text('等待授权…', style: TextStyle(color: p.textMuted, fontSize: 12.5)),
            ]),
        ],
      ),
      actions: [
        if (_error != null)
          TextButton(
              onPressed: () {
                setState(() => _error = null);
                _poll();
              },
              child: const Text('重试')),
        TextButton(
          onPressed: () {
            _cancelled = true;
            Navigator.of(context).pop();
          },
          child: const Text('取消'),
        ),
      ],
    );
  }
}

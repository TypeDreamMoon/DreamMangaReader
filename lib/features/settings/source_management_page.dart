import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/library_store.dart';
import '../../app/source_controller.dart';
import '../../app/theme/app_colors.dart';
import '../../core/source/source_health.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/source_repository.dart';

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
  bool _reloading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAll());
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
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
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_repo.status), duration: const Duration(seconds: 2)));
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

  static const _green = Color(0xFF3FB950);
  static const _amber = Color(0xFFD9A441);
  static const _red = Color(0xFFE5534B);

  Color _colorOf(SourceHealthStatus st, AppPalette p) {
    switch (st) {
      case SourceHealthStatus.ok:
        return _green;
      case SourceHealthStatus.empty:
        return _amber;
      case SourceHealthStatus.fail:
        return _red;
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
      final c = _colorOf(r.status, p);
      inner = Container(
        width: 13,
        height: 13,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
                color: c.withValues(alpha: 0.55), blurRadius: 6, spreadRadius: 1),
          ],
        ),
      );
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
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            _dot(s, p),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${s.name} · 检测日志',
                  style: TextStyle(
                      color: p.textPrimary, fontSize: 16, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
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
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('日志已复制'), duration: Duration(seconds: 1)));
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _checkOne(s);
            },
            child: const Text('重新检测'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final store = LibraryScope.of(context);
    final sc = SourceScope.of(context);
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _repoCard(p, sc),
          const SizedBox(height: 16),
          if (registeredSources.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
              child: Text(
                '还没有加载到任何源。填入上面的源仓库地址,或选择一个包含 index.json 的本地目录。',
                style: TextStyle(color: p.textMuted, fontSize: 12.5, height: 1.5),
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Text(
                '圆点=可用性:绿=正常 · 黄=可达但返回空(限流/失效) · 红=不可用 · 灰=未测。点圆点看日志。',
                style: TextStyle(color: p.textMuted, fontSize: 12, height: 1.5),
              ),
            ),
            for (final s in registeredSources)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _row(s, p, store, sc),
              ),
          ],
        ],
      ),
    );
  }

  // 源仓库配置:引擎不内置源,从这里填 URL / 选本地目录加载源脚本。
  Widget _repoCard(AppPalette p, SourceController sc) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.line),
        ),
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
            TextField(
              controller: _urlCtrl,
              enabled: !_reloading,
              style: TextStyle(color: p.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: '源仓库地址(index.json 所在的 raw 根 URL)',
                hintStyle: TextStyle(color: p.textMuted, fontSize: 12.5),
                filled: true,
                fillColor: p.background,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: p.line)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: p.accent)),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _reloading
                        ? null
                        : () => _applyRepo(
                            () => _repo.setRepoUrl(_urlCtrl.text), sc),
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
          ],
        ),
      );

  Widget _row(SourceMeta s, AppPalette p, LibraryStore store, SourceController sc) {
    final r = _health[s.id] ?? SourceHealthResult.unknown;
    final enabled = store.isSourceEnabled(s.id);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.line),
      ),
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
                  '${s.experimental ? '实验性 · ' : ''}${_labelOf(r)}',
                  style: TextStyle(
                    color: r.status == SourceHealthStatus.fail
                        ? _red
                        : (r.status == SourceHealthStatus.empty ? _amber : p.textMuted),
                    fontSize: 12,
                  ),
                ),
              ],
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

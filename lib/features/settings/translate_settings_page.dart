import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/translate/translator.dart';
import '../../ui/ui.dart';

/// 搜索翻译设置:选服务商(谷歌 / 微软 免费,或大模型 API)+ 大模型参数 + 测试。
/// 实际翻译动作集成在发现页搜索栏。
class TranslateSettingsPage extends StatefulWidget {
  const TranslateSettingsPage({super.key});

  @override
  State<TranslateSettingsPage> createState() => _TranslateSettingsPageState();
}

class _TranslateSettingsPageState extends State<TranslateSettingsPage> {
  late final TextEditingController _base;
  late final TextEditingController _key;
  late final TextEditingController _model;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  TranslateLang _targetSource = TranslateLang.zhHans; // 正在编辑目标顺序的源语言

  // 服务商名(枚举 label 是中文,按当前语言映射)。语言名(TranslateLang.label)是各语言
  // 自身写法(简体中文/日本語…),不翻译、保持原样。
  String _provName(BuildContext context, TranslateProvider v) => switch (v) {
        TranslateProvider.google => context.l10n.trans_provGoogle,
        TranslateProvider.microsoft => context.l10n.trans_provMicrosoft,
        TranslateProvider.llm => context.l10n.trans_provLlm,
      };

  String _desc(BuildContext context, TranslateProvider v) => switch (v) {
        TranslateProvider.google => context.l10n.trans_descGoogle,
        TranslateProvider.microsoft => context.l10n.trans_descMicrosoft,
        TranslateProvider.llm => context.l10n.trans_descLlm,
      };

  @override
  void initState() {
    super.initState();
    final lib = LibraryScope.read(context);
    _base = TextEditingController(text: lib.translateLlmBase);
    _key = TextEditingController(text: lib.translateLlmKey);
    _model = TextEditingController(text: lib.translateLlmModel);
  }

  @override
  void dispose() {
    _base.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _test(LibraryStore lib) async {
    setState(() {
      _testing = true;
      _testResult = context.l10n.trans_testing;
    });
    try {
      // 按优先级链式翻译:验证「按当前排序实际会用到的」服务商可用。
      final tr =
          Translator.chain(lib.translateProviderOrder, llm: lib.translateLlm);
      // 用一句固定文本试翻成英文,能出结果即视为可用。
      final out = await tr.translate('你好,世界', TranslateLang.en);
      if (!mounted) return;
      setState(() {
        _testOk = true;
        _testResult = context.l10n.trans_testResult(out);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = '$e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  // 优先级列表里的一行:序号徽标 + 服务商名(第一位标「主用」)+ 简介 + 拖拽把手。
  Widget _providerRow(AppPalette p, TranslateProvider v, int index) {
    final primary = index == 0;
    return Padding(
      key: ValueKey(v),
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: primary ? p.accent.withValues(alpha: 0.16) : p.elevated,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: primary ? p.accent.withValues(alpha: 0.5) : p.line),
            ),
            child: Text('${index + 1}',
                style: TextStyle(
                    color: primary ? p.accent : p.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(_provName(context, v),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: p.textPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700)),
                    ),
                    if (primary) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                            color: p.accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(5)),
                        child: Text(context.l10n.trans_badgePrimary,
                            style: TextStyle(
                                color: p.accent,
                                fontSize: 10,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(_desc(context, v),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.textMuted, fontSize: 11.5)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child:
                  Icon(Icons.drag_handle_rounded, size: 20, color: p.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  // 源语言选择芯片。
  Widget _srcChip(AppPalette p, TranslateLang s) {
    final sel = _targetSource == s;
    return GestureDetector(
      onTap: () => setState(() => _targetSource = s),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: sel ? p.accent.withValues(alpha: 0.16) : p.surface,
          borderRadius: BorderRadius.circular(context.radius),
          border: Border.all(color: sel ? p.accent : p.line, width: sel ? 1.5 : 1),
        ),
        child: Text(context.l10n.trans_srcChip(s.label),
            style: TextStyle(
                color: sel ? p.accent : p.textMuted,
                fontSize: 12.5,
                fontWeight: FontWeight.w700)),
      ),
    );
  }

  // 目标语言优先级列表里的一行:序号 + 语言名(第一位标「首选」)+ 拖拽把手。
  Widget _targetRow(AppPalette p, TranslateLang t, int index) {
    final primary = index == 0;
    return Padding(
      key: ValueKey(t),
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: primary ? p.accent.withValues(alpha: 0.16) : p.elevated,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: primary ? p.accent.withValues(alpha: 0.5) : p.line),
            ),
            child: Text('${index + 1}',
                style: TextStyle(
                    color: primary ? p.accent : p.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(t.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700)),
                ),
                if (primary) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                        color: p.accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(5)),
                    child: Text(context.l10n.trans_badgePreferred,
                        style: TextStyle(
                            color: p.accent,
                            fontSize: 10,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child:
                  Icon(Icons.drag_handle_rounded, size: 20, color: p.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final lib = LibraryScope.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(context.l10n.trans_title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: AppScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AppCard(
            color: p.elevated,
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.translate_rounded, size: 18, color: p.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    context.l10n.trans_intro,
                    style: TextStyle(color: p.textPrimary, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          AppSectionHeading(context.l10n.trans_providerPriority),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(context.l10n.trans_providerPriorityHint,
                style: TextStyle(color: p.textMuted, fontSize: 12, height: 1.5)),
          ),
          const SizedBox(height: 10),
          AppCard(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (oldIndex, newIndex) {
                // onReorderItem 已按「移除 oldIndex 后」调整好 newIndex,直接用。
                final order = List.of(lib.translateProviderOrder);
                order.insert(newIndex, order.removeAt(oldIndex));
                lib.translateProviderOrder = order;
                setState(() => _testResult = null);
              },
              children: [
                for (var i = 0; i < lib.translateProviderOrder.length; i++)
                  _providerRow(p, lib.translateProviderOrder[i], i),
              ],
            ),
          ),
          const SizedBox(height: 18),
          AppSectionHeading(context.l10n.trans_llmParams),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(context.l10n.trans_llmParamsHint,
                style: TextStyle(color: p.textMuted, fontSize: 12, height: 1.5)),
          ),
          const SizedBox(height: 10),
          ...[
            AppTextField(
              controller: _base,
              label: context.l10n.trans_apiBase,
              hint: context.l10n.trans_apiBaseHint,
              prefixIcon: Icon(Icons.link_rounded, size: 18, color: p.textMuted),
              keyboardType: TextInputType.url,
              onChanged: (v) => lib.translateLlmBase = v.trim(),
            ),
            const SizedBox(height: 10),
            AppTextField(
              controller: _key,
              label: context.l10n.trans_apiKey,
              hint: context.l10n.trans_apiKeyHint,
              obscure: true,
              prefixIcon: Icon(Icons.key_rounded, size: 18, color: p.textMuted),
              onChanged: (v) => lib.translateLlmKey = v.trim(),
            ),
            const SizedBox(height: 10),
            AppTextField(
              controller: _model,
              label: context.l10n.trans_model,
              hint: context.l10n.trans_modelHint,
              prefixIcon:
                  Icon(Icons.smart_toy_rounded, size: 18, color: p.textMuted),
              onChanged: (v) => lib.translateLlmModel = v.trim(),
            ),
          ],
          const SizedBox(height: 18),
          AppSectionHeading(context.l10n.trans_autoTargetLang),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
                context.l10n.trans_autoTargetLangHint,
                style: TextStyle(color: p.textMuted, fontSize: 12, height: 1.5)),
          ),
          const SizedBox(height: 10),
          // 源语言选择:选哪个源语言就编辑它的目标顺序。
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final s in TranslateLang.values) _srcChip(p, s)],
          ),
          const SizedBox(height: 10),
          AppCard(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (oldIndex, newIndex) {
                final list = List.of(lib.translateTargets[_targetSource]!);
                list.insert(newIndex, list.removeAt(oldIndex));
                lib.setTranslateTargets(_targetSource, list);
              },
              children: [
                for (var i = 0;
                    i < lib.translateTargets[_targetSource]!.length;
                    i++)
                  _targetRow(p, lib.translateTargets[_targetSource]![i], i),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _testing ? null : () => _test(lib),
                icon: _testing
                    ? SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: p.accent))
                    : const Icon(Icons.wifi_tethering_rounded, size: 18),
                label: Text(context.l10n.trans_testTranslate),
              ),
            ],
          ),
          if (_testResult != null) ...[
            const SizedBox(height: 12),
            AppCard(
              color: p.elevated,
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                      _testOk
                          ? Icons.check_circle_rounded
                          : Icons.error_outline_rounded,
                      size: 18,
                      color: _testOk ? p.accent : p.statusFail),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SelectableText(_testResult!,
                        style: TextStyle(color: p.textPrimary, fontSize: 12.5)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

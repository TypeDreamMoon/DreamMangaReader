import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
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

  static String _desc(TranslateProvider v) => switch (v) {
        TranslateProvider.google => '免费端点,开箱即用(可能需代理)',
        TranslateProvider.microsoft => '免费端点,自动取临时令牌',
        TranslateProvider.llm => '你自己的大模型 · 需在下方配置',
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
      _testResult = '测试中…(联网)';
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
        _testResult = '「你好,世界」→ $out';
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
                      child: Text(v.label,
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
                        child: Text('主用',
                            style: TextStyle(
                                color: p.accent,
                                fontSize: 10,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(_desc(v),
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

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final lib = LibraryScope.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('翻译',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: ListView(
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
                    '把搜索词翻成 简 / 繁 / 英 / 日 / 韩 再搜(换语种源、搜不到时自动回退)。'
                    '可拖动下方服务商调整优先级 —— 从上到下依次尝试,失败自动降级。',
                    style: TextStyle(color: p.textPrimary, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          AppSectionHeading('服务商优先级'),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text('从上到下依次尝试,前一个失败(未配置 / 报错)就自动降级到下一个。拖右侧 ☰ 排序。',
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
          AppSectionHeading('大模型参数'),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text('排到「大模型」时才会用。OpenAI 兼容 /chat/completions;密钥仅存本机、不随云同步。',
                style: TextStyle(color: p.textMuted, fontSize: 12, height: 1.5)),
          ),
          const SizedBox(height: 10),
          ...[
            AppTextField(
              controller: _base,
              label: 'API 地址',
              hint: '如 https://api.openai.com/v1',
              prefixIcon: Icon(Icons.link_rounded, size: 18, color: p.textMuted),
              keyboardType: TextInputType.url,
              onChanged: (v) => lib.translateLlmBase = v.trim(),
            ),
            const SizedBox(height: 10),
            AppTextField(
              controller: _key,
              label: 'API 密钥',
              hint: 'sk-…(仅存本机)',
              obscure: true,
              prefixIcon: Icon(Icons.key_rounded, size: 18, color: p.textMuted),
              onChanged: (v) => lib.translateLlmKey = v.trim(),
            ),
            const SizedBox(height: 10),
            AppTextField(
              controller: _model,
              label: '模型',
              hint: '如 gpt-4o-mini / deepseek-chat',
              prefixIcon:
                  Icon(Icons.smart_toy_rounded, size: 18, color: p.textMuted),
              onChanged: (v) => lib.translateLlmModel = v.trim(),
            ),
          ],
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
                label: const Text('测试翻译'),
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

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

  static const _short = {
    TranslateProvider.google: '谷歌',
    TranslateProvider.microsoft: '微软',
    TranslateProvider.llm: '大模型',
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
      final tr = Translator.create(lib.translateProvider, llm: lib.translateLlm);
      // 用一句固定文本试翻成英文,能出结果即视为该服务商可用。
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

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final lib = LibraryScope.of(context);
    final isLlm = lib.translateProvider == TranslateProvider.llm;
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
                    '在发现页搜索栏点「译」按钮,可把搜索词翻成简体 / 繁体 / 英文再搜 '
                    '—— 换语种源(如日漫、MangaDex)时很有用。',
                    style: TextStyle(color: p.textPrimary, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          AppSectionHeading('服务商'),
          const SizedBox(height: 10),
          AppCard(
            width: double.infinity,
            child: AppSegmentedRow<TranslateProvider>(
              icon: Icons.cloud_rounded,
              title: '翻译引擎',
              segments: [
                for (final v in TranslateProvider.values)
                  ButtonSegment(value: v, label: Text(_short[v]!)),
              ],
              selected: {lib.translateProvider},
              onSelectionChanged: (s) {
                lib.translateProvider = s.first;
                setState(() => _testResult = null);
              },
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              switch (lib.translateProvider) {
                TranslateProvider.google => '谷歌翻译免费端点,无需配置,开箱即用(可能需要代理)。',
                TranslateProvider.microsoft => '微软翻译免费端点,自动获取临时令牌,无需配置。',
                TranslateProvider.llm =>
                  '用你自己的大模型(OpenAI 兼容 /chat/completions)翻译。密钥仅存本机、不随云同步。',
              },
              style: TextStyle(color: p.textMuted, fontSize: 12),
            ),
          ),
          if (isLlm) ...[
            const SizedBox(height: 18),
            AppSectionHeading('大模型参数'),
            const SizedBox(height: 10),
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

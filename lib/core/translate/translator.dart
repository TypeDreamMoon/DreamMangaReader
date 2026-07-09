import 'dart:convert';

import 'package:dio/dio.dart';

/// 搜索词翻译:简体 / 繁体 / 英 / 日 / 韩 互译。服务商可选谷歌(免费)/ 微软(免费)/ 大模型 API。
///
/// - 谷歌、微软走各自的**免费**网页端点(无需 key,微软自取临时令牌)。
/// - 大模型走 OpenAI 兼容的 chat/completions(用户在设置里填 地址 / 密钥 / 模型)。
/// - 请求走全局 Dio,代理由 [HttpOverrides.global](AppProxy)统一注入,和图片/源同一条网络。
/// - 失败一律抛带人话信息的异常,交由调用方 toast。

/// 目标语言。[short] 用于搜索栏按钮上的极简标签。
enum TranslateLang {
  zhHans('简体中文', '简'),
  zhHant('繁體中文', '繁'),
  en('English', 'EN'),
  ja('日本語', '日'),
  ko('한국어', '韩');

  const TranslateLang(this.label, this.short);
  final String label;
  final String short;
}

/// 翻译服务商。
enum TranslateProvider {
  google('谷歌翻译 · 免费'),
  microsoft('微软翻译 · 免费'),
  llm('大模型 API');

  const TranslateProvider(this.label);
  final String label;
}

/// 大模型翻译配置(OpenAI 兼容)。
class LlmConfig {
  const LlmConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isReady =>
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      model.trim().isNotEmpty;
}

final Dio _dio = Dio(BaseOptions(
  headers: {'User-Agent': 'Mozilla/5.0 (compatible; DreamMangaReader)'},
  connectTimeout: const Duration(seconds: 12),
  sendTimeout: const Duration(seconds: 12),
  receiveTimeout: const Duration(seconds: 20),
  validateStatus: (_) => true,
));

/// 把 Dio 的网络异常翻成人话(连不上 / 超时 / 其它),避免把 DioException 原样弹给用户。
Exception _friendlyDio(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionError:
    case DioExceptionType.connectionTimeout:
      return Exception('连不上翻译服务(检查网络 / 代理)');
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.sendTimeout:
      return Exception('翻译服务响应超时');
    default:
      // unknown 且带底层传输错误(握手/Socket 失败,如该服务在本网络不可达)→ 归为连不上。
      if (e.type == DioExceptionType.unknown && e.error != null) {
        return Exception('连不上翻译服务(检查网络 / 代理)');
      }
      return Exception('翻译请求出错(${e.type.name})');
  }
}

/// 把 [text] 翻成 [target]。用 [Translator.create] 按服务商拿实例。
abstract class Translator {
  Future<String> translate(String text, TranslateLang target);

  factory Translator.create(TranslateProvider provider, {LlmConfig? llm}) {
    switch (provider) {
      case TranslateProvider.google:
        return _GoogleTranslator();
      case TranslateProvider.microsoft:
        return _MicrosoftTranslator();
      case TranslateProvider.llm:
        if (llm == null || !llm.isReady) {
          throw Exception('大模型翻译未配置(到设置 · 翻译里填 API 地址 / 密钥 / 模型)');
        }
        return _LlmTranslator(llm);
    }
  }

  /// 按**优先级** [order] 依次尝试:前一个失败(抛错/无结果)就降级到下一个;
  /// 全失败才抛最后一个错。未配置好的服务商(如大模型缺参数)自动跳过。
  /// [order] 为空时退回谷歌。
  factory Translator.chain(List<TranslateProvider> order, {LlmConfig? llm}) =>
      _ChainTranslator(
          order.isEmpty ? const [TranslateProvider.google] : order, llm);
}

/// 优先级链式翻译:见 [Translator.chain]。
class _ChainTranslator implements Translator {
  _ChainTranslator(this._order, this._llm);
  final List<TranslateProvider> _order;
  final LlmConfig? _llm;

  @override
  Future<String> translate(String text, TranslateLang target) async {
    Exception? lastErr;
    var tried = 0;
    for (final p in _order) {
      final Translator tr;
      try {
        tr = Translator.create(p, llm: _llm);
      } catch (_) {
        continue; // 该服务商没配好 → 跳过,试下一个
      }
      tried++;
      try {
        return await tr.translate(text, target);
      } on Exception catch (e) {
        lastErr = e; // 记下,降级到下一个服务商
      }
    }
    if (tried == 0) throw Exception('没有可用的翻译服务商(到设置 · 翻译里配置)');
    throw lastErr ?? Exception('翻译失败');
  }
}

/// 谷歌免费端点(translate_a/single),无需 key。
class _GoogleTranslator implements Translator {
  static const _codes = {
    TranslateLang.zhHans: 'zh-CN',
    TranslateLang.zhHant: 'zh-TW',
    TranslateLang.en: 'en',
    TranslateLang.ja: 'ja',
    TranslateLang.ko: 'ko',
  };

  @override
  Future<String> translate(String text, TranslateLang target) async {
    try {
      final r = await _dio.get(
        'https://translate.googleapis.com/translate_a/single',
        queryParameters: {
          'client': 'gtx',
          'sl': 'auto',
          'tl': _codes[target],
          'dt': 't',
          'q': text,
        },
      );
      if (r.statusCode != 200) {
        throw Exception('谷歌翻译请求失败(${r.statusCode})');
      }
      // data = [ [ ["译文","原文",...], ... ], ... ]
      final data = r.data is String ? jsonDecode(r.data as String) : r.data;
      final segs = (data is List && data.isNotEmpty && data[0] is List)
          ? data[0] as List
          : const [];
      final buf = StringBuffer();
      for (final s in segs) {
        if (s is List && s.isNotEmpty && s[0] is String) buf.write(s[0]);
      }
      final out = buf.toString().trim();
      if (out.isEmpty) throw Exception('谷歌翻译无结果');
      return out;
    } on DioException catch (e) {
      throw _friendlyDio(e);
    } on FormatException {
      // HTTP 200 但响应体不是 JSON(如被门户/代理劫持返回 HTML)→ 别把 FormatException 原样弹出。
      throw Exception('翻译服务返回异常(检查网络 / 代理)');
    }
  }
}

/// 微软免费端点:先取临时令牌(edge/translate/auth,JWT ~10min),再调翻译。
class _MicrosoftTranslator implements Translator {
  static const _codes = {
    TranslateLang.zhHans: 'zh-Hans',
    TranslateLang.zhHant: 'zh-Hant',
    TranslateLang.en: 'en',
    TranslateLang.ja: 'ja',
    TranslateLang.ko: 'ko',
  };

  // 令牌进程内缓存(所有实例共享),提前 2 分钟视为过期。
  static String? _token;
  static int _tokenExpMs = 0;

  Future<String> _auth() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _token;
    if (cached != null && now < _tokenExpMs) return cached;
    final r = await _dio.get(
      'https://edge.microsoft.com/translate/auth',
      options: Options(responseType: ResponseType.plain),
    );
    final body = r.data;
    if (r.statusCode != 200 || body is! String || body.trim().isEmpty) {
      throw Exception('微软翻译取令牌失败(${r.statusCode})');
    }
    _token = body.trim();
    _tokenExpMs = now + 8 * 60 * 1000;
    return _token!;
  }

  @override
  Future<String> translate(String text, TranslateLang target) async {
    try {
      final token = await _auth();
      final r = await _dio.post(
        'https://api.cognitive.microsofttranslator.com/translate',
        queryParameters: {'api-version': '3.0', 'to': _codes[target]},
        data: [
          {'Text': text}
        ],
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        }),
      );
      if (r.statusCode == 401) _token = null; // 令牌失效:清缓存,下次重取
      if (r.statusCode != 200) {
        throw Exception('微软翻译请求失败(${r.statusCode})');
      }
      // data = [ { "translations": [ {"text":"...","to":"xx"} ] } ]
      final data = r.data is String ? jsonDecode(r.data as String) : r.data;
      if (data is List && data.isNotEmpty && data[0] is Map) {
        final tr = (data[0] as Map)['translations'];
        if (tr is List && tr.isNotEmpty && tr[0] is Map) {
          final t = (tr[0] as Map)['text'];
          if (t is String && t.trim().isNotEmpty) return t.trim();
        }
      }
      throw Exception('微软翻译无结果');
    } on DioException catch (e) {
      throw _friendlyDio(e);
    } on FormatException {
      // HTTP 200 但响应体不是 JSON(如被门户/代理劫持返回 HTML)→ 别把 FormatException 原样弹出。
      throw Exception('翻译服务返回异常(检查网络 / 代理)');
    }
  }
}

/// 大模型(OpenAI 兼容 chat/completions)。
class _LlmTranslator implements Translator {
  _LlmTranslator(this.cfg);
  final LlmConfig cfg;

  static const _names = {
    TranslateLang.zhHans: 'Simplified Chinese',
    TranslateLang.zhHant: 'Traditional Chinese',
    TranslateLang.en: 'English',
    TranslateLang.ja: 'Japanese',
    TranslateLang.ko: 'Korean',
  };

  @override
  Future<String> translate(String text, TranslateLang target) async {
    try {
      // 兼容用户填「.../v1」或直接填完整端点。
      final base = cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final url =
          base.endsWith('/chat/completions') ? base : '$base/chat/completions';
      final r = await _dio.post(
        url,
        data: {
          'model': cfg.model.trim(),
          'messages': [
            {
              'role': 'system',
              'content':
                  'You are a translation engine. Translate the user text to ${_names[target]}. '
                      'Output ONLY the translation itself — no quotes, no notes, no romanization. '
                      'Keep well-known proper nouns / work titles natural.'
            },
            {'role': 'user', 'content': text},
          ],
          'temperature': 0.2,
          'stream': false,
        },
        options: Options(headers: {
          'Authorization': 'Bearer ${cfg.apiKey.trim()}',
          'Content-Type': 'application/json',
        }),
      );
      if (r.statusCode != 200) {
        throw Exception('大模型翻译失败(${r.statusCode})');
      }
      final data = r.data is String ? jsonDecode(r.data as String) : r.data;
      final choices = (data is Map) ? data['choices'] : null;
      if (choices is List && choices.isNotEmpty && choices[0] is Map) {
        final msg = (choices[0] as Map)['message'];
        final content = (msg is Map) ? msg['content'] : null;
        if (content is String && content.trim().isNotEmpty) {
          return content.trim();
        }
      }
      throw Exception('大模型翻译无结果');
    } on DioException catch (e) {
      throw _friendlyDio(e);
    } on FormatException {
      // HTTP 200 但响应体不是 JSON(如被门户/代理劫持返回 HTML)→ 别把 FormatException 原样弹出。
      throw Exception('翻译服务返回异常(检查网络 / 代理)');
    }
  }
}

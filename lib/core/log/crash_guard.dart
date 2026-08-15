import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../l10n/app_strings.dart';
import 'app_log.dart';

/// 未捕获错误的全局兜底。在 [main] 最开头调用一次(要早于其余初始化,
/// 这样启动阶段自己出的错也能被记下来)。
///
/// 装三处:
/// - [FlutterError.onError] —— 框架同步错误(build/layout/paint、手势回调…)。
/// - [PlatformDispatcher.onError] —— 根 zone 的未捕获异步错误(漏了 await 的
///   Future、Stream 的 onError…)。这是 Flutter 现行做法;**不要**改用
///   `runZonedGuarded` 包 [runApp] —— 那会让 binding 与 runApp 落在不同 zone。
/// - [ErrorWidget.builder] —— 构建期抛错时顶替上去的那个 widget。
///
/// 三处都只「记录 + 保留原有行为」,不吞错、不改变控制流:控制台该打印的照打印,
/// debug 下该红屏的照红屏。区别只是错误同时进了 [AppLog],用户能在
/// 「设置 › 运行日志」里复制给你,而不是无声消失。
void installCrashGuard() {
  // 默认值是 FlutterError.presentError(控制台 dump)。先记录再交还给它,
  // 顺序无所谓但这样日志时间戳更接近错误发生时刻。
  final presentToConsole = FlutterError.onError;
  FlutterError.onError = (details) {
    // silent 的多是框架自己吞掉的预期内错误(如 overflow 之后的连锁),不刷屏。
    if (!details.silent) {
      _record(
        details.exception,
        details.stack,
        // context 形如 'building MyWidget' / 'during layout',定位用。
        where: details.context?.toDescription(),
        library: details.library,
      );
    }
    presentToConsole?.call(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    _record(error, stack, where: 'uncaught async');
    // 直接走 presentError 打控制台,不走 FlutterError.onError —— 否则会被上面
    // 那个 handler 再记一遍,同一条错误在日志里出现两次。
    FlutterError.presentError(FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'DreamMangaReader',
    ));
    return true; // 已处理:不再上抛给平台默认处理器
  };

  // debug 下保留框架自带的红底详情屏 —— 开发时那个信息量是有用的。
  // 只有 release/profile 才换成给用户看的兜底卡片。
  if (!kDebugMode) {
    ErrorWidget.builder = (details) => _RenderFallback(details: details);
  }
}

/// 堆栈可能上千行;日志是 800 条的内存环形缓冲,整条塞进去几次就把别的挤没了。
/// 保留最上面 [_stackLines] 行(出错点就在那儿),其余折成一行计数。
const _stackLines = 24;

String? _trimStack(StackTrace? stack) {
  if (stack == null) return null;
  final lines = stack.toString().trimRight().split('\n');
  if (lines.length <= _stackLines) return lines.join('\n');
  final rest = lines.length - _stackLines;
  return '${lines.take(_stackLines).join('\n')}\n… 另有 $rest 行';
}

void _record(
  Object error,
  StackTrace? stack, {
  String? where,
  String? library,
}) {
  // 记录本身绝不能再抛 —— 那会变成错误处理里出错的循环。
  try {
    final at = [
      if (where != null && where.isNotEmpty) where,
      if (library != null && library.isNotEmpty) library,
    ].join(' · ');
    final head = error.toString().split('\n').first;
    AppLog.i.err(
      LogCat.crash,
      at.isEmpty ? head : '$head($at)',
      detail: [error.toString(), _trimStack(stack)]
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .join('\n'),
    );
  } catch (_) {
    // 连记日志都失败就放弃,控制台那份还在。
  }
}

/// release 下顶替构建失败处的兜底卡片。
///
/// 它渲染在「已经出错」的位置,祖先树可能残缺:`context.palette` 里有个 `!`、
/// `context.l10n` 要求有 Localizations 祖先,两者都可能再抛一次 —— 那就成了
/// 错误循环。所以这里每个查找都单独 try,失败各自退到常量。
class _RenderFallback extends StatelessWidget {
  const _RenderFallback({required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    AppPalette? p;
    try {
      p = context.palette;
    } catch (_) {
      /* 主题不可用:用下面的中性色 */
    }

    String title;
    try {
      title = context.l10n.err_renderFailed;
    } catch (_) {
      title = 'This part failed to render.';
    }

    String hint;
    try {
      hint = context.l10n.err_renderFailedHint;
    } catch (_) {
      hint = '';
    }

    final fail = p?.statusFail ?? const Color(0xFFE5534B);
    final text = p?.textPrimary ?? const Color(0xFF9AA5A1);
    final muted = p?.textMuted ?? const Color(0xFF8F9C98);

    // Directionality / 默认字体在残缺树里未必有,用 Directionality + DefaultTextStyle
    // 自带一份,保证这个 widget 自身不会再抛。
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(
        style: TextStyle(fontSize: 13, color: text, decoration: TextDecoration.none),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: fail.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: fail.withValues(alpha: 0.35)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded, size: 18, color: fail),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: text,
                            decoration: TextDecoration.none)),
                  ),
                ],
              ),
              if (hint.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(hint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        color: muted,
                        decoration: TextDecoration.none)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

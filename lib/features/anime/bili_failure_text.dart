import 'package:flutter/widgets.dart';

import '../../core/bili/bili_errors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/net/app_proxy.dart';

/// 把源抛出来的错翻成一句人话。
///
/// `core/` 只归类不出文案([BiliFailure]),翻译在这儿做 —— 这样 core 保持无 l10n
/// 依赖,而用户不再看到「取播放源失败:-10403」这种东西。
///
/// 不认识的错原样返回,别把有用的排查信息吃掉。
String describeSourceError(BuildContext context, Object error) {
  if (error is! BiliException) return '$error';
  final l10n = context.l10n;
  return switch (error.failure) {
    // 锁区光说「看不了」没用,得告诉人下一步干嘛 —— 顺带把当前代理状态摆出来,
    // 不然用户根本不知道自己是直连还是已经挂着代理了。
    BiliFailure.geoBlocked => '${l10n.bili_geoBlocked}\n'
        '${l10n.bili_geoBlockedHint(AppProxy.current ?? l10n.bili_proxyDirect)}',
    BiliFailure.needsLogin => l10n.bili_needsLogin,
    BiliFailure.vipOnly => l10n.bili_vipOnly,
    BiliFailure.rateLimited => l10n.bili_rateLimited,
    BiliFailure.notFound => l10n.bili_notFound,
    BiliFailure.unknown => error.detail?.isNotEmpty == true
        ? error.detail!
        : '$error',
  };
}

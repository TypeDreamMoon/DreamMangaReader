import '../core/log/app_log.dart';

/// 跑一项启动加载,**永不抛错**。
///
/// 启动加载全是「拿到就更好、拿不到也能开」的东西:读坏的偏好文件、被占用的安全
/// 存储、离线时的远程源清单。它们却都排在 `Future.wait` 里 —— 那是「有一个抛就整体
/// 抛」的语义:`runApp` 之前那批里挂一个,首帧根本走不到,用户拿到一块没有任何提示
/// 的黑窗;首帧之后那批里挂一个,自动上传的监听、启动同步、追更检查会一起被跳过,
/// 而且错误没人接。
///
/// 失败只记日志,对应模块停在自己的默认值上。
///
/// [what] 只进运行日志,不上界面,故不走 l10n。
Future<void> guardedStartupLoad(
  String what,
  Future<void> Function() load,
) async {
  try {
    await load();
  } catch (e, s) {
    AppLog.i.err(LogCat.app, '启动加载失败 · $what', detail: '$e\n$s');
  }
}

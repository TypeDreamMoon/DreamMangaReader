import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app.dart';
import 'app/app_info.dart';
import 'core/log/app_log.dart';
import 'core/source/chinese_fold.dart';
import 'core/net/app_proxy.dart';
import 'core/platform/system_fonts.dart';
import 'core/source/source_repository.dart';
import 'core/sync/sync_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 运行日志随每次启动清空(内存缓冲本就为空,这里显式重置并记一条启动)。
  AppLog.i.clear();
  AppLog.i.success(LogCat.app, '应用启动 · v${AppInfo.version}');
  // 番剧播放器后端(libmpv)初始化;必须在 runApp 前。
  MediaKit.ensureInitialized();
  // 漫画整页解码后很大(单页常 6~14MB);默认 100MB 图片缓存装不下「预载几页 + 在建几页」。
  // 桌面内存宽裕给 256MB;手机内存有限,256MB 会造成内存压力 / GC 卡顿 / 甚至 OOM,
  // 降到 128MB(仍够容纳预载几页 + 封面)。
  final mobile = defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      (mobile ? 128 : 256) * 1024 * 1024;
  // 繁→简折叠字表(OpenCC 资源)读进内存,供发现页多源同名去重折繁简变体。
  await ChineseFold.load();
  // 解析并注入系统/环境代理(否则从无代理环境变量的终端启动会直连、被墙的源握手失败)。
  await AppProxy.init();
  // 引擎不内置源:启动时从外部清单加载源脚本(仓库 URL / 本地目录 / 缓存;未配置则为空)。
  await SourceRepository.instance.load();
  // 云同步配置(WebDAV 地址/账密/自动开关)读回;自动同步在书架读档后触发(见 App.initState)。
  await SyncController.instance.load();
  // 桌面:预热系统字体列表(GDI 枚举,~几十毫秒;非 Windows 立即返回)。
  await SystemFonts.ensureLoaded();
  runApp(const App());
}

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app.dart';
import 'app/app_info.dart';
import 'core/bili/bili_auth.dart';
import 'core/library/update_tracker.dart';
import 'core/log/app_log.dart';
import 'core/log/crash_guard.dart';
import 'core/source/chinese_fold.dart';
import 'core/net/app_proxy.dart';
import 'core/platform/system_fonts.dart';
import 'core/source/source_repository.dart';
import 'core/sync/sync_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 未捕获错误的兜底(框架错误 / 根 zone 异步错误 / 构建失败的占位 widget)。
  // 尽量早装:这之后启动阶段自己出的错也进得了运行日志。
  installCrashGuard();
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

  // 以下几项互不依赖,且都是真异步 I/O(资源读 / SharedPreferences / 安全存储 /
  // 可能的网络),串行 await 只是让它们排队等对方。并发跑,首帧提前到最慢的那个
  // 完成时,而不是所有耗时之和。**唯一的真依赖是代理 → 源清单**:源仓可能配的是
  // 远程 URL,不先注入代理,被墙的源会直接握手失败。
  final sourcesReady = AppProxy.init()
      // 引擎不内置源:启动时从外部清单加载源脚本(仓库 URL / 本地目录 / 缓存;
      // 未配置则为空)。
      .then((_) => SourceRepository.instance.load());
  await Future.wait([
    sourcesReady,
    // 繁→简折叠字表(OpenCC 资源)读进内存,供发现页多源同名去重折繁简变体。
    ChineseFold.load(),
    // B站账号态(扫码登录后的 Cookie,安全存储)读回;不进云同步。
    BiliAuth.instance.load(),
    // 云同步配置(WebDAV 地址/账密/自动开关)读回。首帧后 App.initState 里的
    // 自动同步会用到它,所以必须在 runApp 前就位 —— 只是不必单独排队。
    SyncController.instance.load(),
    // 追更账本读回(书架封面上的「N 话新」角标)。首帧书架就要用,不能推到帧后。
    LibraryUpdateTracker.instance.load(),
  ]);

  runApp(const App());

  // 桌面系统字体枚举。`ensureLoaded` 虽是 async,内部 GDI 枚举却是同步 FFI ——
  // 放进上面的 Future.wait 一样会卡住 isolate(几十毫秒),等于没并行。挪到首帧
  // 之后:代价照付,但付在用户已经看到界面之后。唯一的消费方是设置页的字体选择器,
  // 它在列表为空时有回退字体栈,拿不到也不会坏。非 Windows 上直接返回空。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    SystemFonts.ensureLoaded();
  });
}

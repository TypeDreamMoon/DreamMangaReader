import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Release 的一个可下载附件(名 + 直链)。
class UpdateAsset {
  const UpdateAsset(this.name, this.url);
  final String name;
  final String url;
}

/// 应用内更新:下载新版并唤起安装。
///
/// - **Android**:下通用 APK,用系统安装器打开(首次需在系统里授予「安装未知应用」)。
///   能否**覆盖安装**取决于新旧包**签名一致**——签名不一致会「应用未安装」。
/// - **Windows**:下 setup.exe,写个临时脚本:等本进程退出 → 静默运行安装器覆盖 → 重启 App。
///   安装版(装目录里有 unins000.exe)才静默;便携版起普通安装器让用户自己选目录。
class UpdateInstaller {
  UpdateInstaller._();

  /// 当前平台是否支持应用内自更新(否则退回浏览器下载页)。
  static bool get supported => Platform.isAndroid || Platform.isWindows;

  static final Dio _dio = Dio(BaseOptions(
    headers: {'User-Agent': 'DreamMangaReader-Updater'},
    connectTimeout: const Duration(seconds: 20),
    // 分片空闲超时:连接中途卡死(收不到新数据)60s 即报错,不至于无限挂着。
    // 不是整体超时,持续下载的大文件不会误杀。
    receiveTimeout: const Duration(seconds: 60),
    followRedirects: true, // GitHub 附件直链会 302 到 CDN
    maxRedirects: 6,
    validateStatus: (_) => true,
  ));

  /// 从 release 附件里挑当前平台要下的那个(Android=通用 APK · Windows=setup.exe)。
  ///
  /// Android 必须下 universal:CI 把它的 versionCode 抬到 5000+n 档,高于一切
  /// --split-per-abi 分包档(1000~4000+n),从任何安装来源升级都不会撞
  /// 「无法降级安装」。**别改成挑分档 APK**——装过 5000 档 universal 的设备
  /// 再装分包就是降级,一键更新会永久失败。
  static UpdateAsset? pickAsset(List<UpdateAsset> assets) {
    if (Platform.isAndroid) {
      return _firstWhere(
              assets, (a) => a.name.toLowerCase().endsWith('-universal.apk')) ??
          _firstWhere(assets, (a) => a.name.toLowerCase().endsWith('.apk'));
    }
    if (Platform.isWindows) {
      return _firstWhere(
          assets, (a) => a.name.toLowerCase().endsWith('setup.exe'));
    }
    return null;
  }

  static UpdateAsset? _firstWhere(
      List<UpdateAsset> xs, bool Function(UpdateAsset) f) {
    for (final x in xs) {
      if (f(x)) return x;
    }
    return null;
  }

  /// 下载 [asset] 并唤起安装。[onProgress] 回传 0~1(总大小未知时回传 -1)。
  /// [cancelToken] 供调用方取消下载;[onBeforeExit] 在 Windows 静默安装 exit(0) 前调用
  /// (落盘未保存状态)。Android:装完由系统安装器接手;Windows:见 [_installWindows]。
  static Future<void> downloadAndInstall(
    UpdateAsset asset, {
    required void Function(double progress) onProgress,
    CancelToken? cancelToken,
    Future<void> Function()? onBeforeExit,
  }) async {
    final dir = await getTemporaryDirectory();
    final safeName = asset.name.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final path = '${dir.path}${Platform.pathSeparator}$safeName';
    // 删掉可能的半包残留,免得被当成完整包。
    final f = File(path);
    if (await f.exists()) {
      try {
        await f.delete();
      } catch (_) {}
    }

    final resp = await _dio.download(
      asset.url,
      path,
      cancelToken: cancelToken,
      onReceiveProgress: (recv, total) =>
          onProgress(total > 0 ? recv / total : -1),
    );
    if (resp.statusCode != 200) {
      throw Exception('下载失败(${resp.statusCode})');
    }

    if (Platform.isAndroid) {
      final res = await OpenFilex.open(
        path,
        type: 'application/vnd.android.package-archive',
      );
      if (res.type != ResultType.done) {
        throw Exception('打开安装器失败:${res.message}');
      }
      return;
    }
    if (Platform.isWindows) {
      await _installWindows(path, onBeforeExit);
      return;
    }
    throw Exception('该平台不支持应用内更新');
  }

  static Future<void> _installWindows(
      String setupPath, Future<void> Function()? onBeforeExit) async {
    final exe = Platform.resolvedExecutable;
    final appDir = File(exe).parent.path;
    final installed = File('$appDir\\unins000.exe').existsSync();
    final writable = _canWrite(appDir);

    // 走「静默覆盖 + 自杀重启」的前提:是安装版**且**装目录免提权可写(= per-user 安装)。
    // 便携版(装器会另装)/ 系统级安装(装 Program Files 需 UAC 提权,静默会弹 UAC 或失败,
    // 而此时 App 已 exit 无法收场)→ 都不自杀:直接起安装器,交给 Inno 自己处理
    // (系统装时它会 UAC 提权 + 用重启管理器关掉/重开 App),App 继续运行。
    if (!installed || !writable) {
      await Process.start(
        setupPath,
        installed ? ['/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS'] : const [],
        mode: ProcessStartMode.detached,
      );
      return;
    }

    // per-user 安装:临时脚本 —— 等 2s(本进程退出、文件解锁)→ 静默覆盖 → 重启 App → 自删。
    final tmp = await getTemporaryDirectory();
    final bat = File('${tmp.path}\\dmr_update.bat');
    await bat.writeAsString(
      '@echo off\r\n'
      'timeout /t 2 /nobreak >NUL\r\n'
      '"$setupPath" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART\r\n'
      'start "" "$exe"\r\n'
      'del "%~f0"\r\n',
    );
    await Process.start(
      'cmd',
      ['/c', bat.path],
      mode: ProcessStartMode.detached,
    );
    await onBeforeExit?.call(); // 退出前落盘,别丢最近的进度/设置
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0); // 退出让安装器替换文件
  }

  /// 目录是否免提权可写(区分 per-user 安装 vs 需 UAC 的系统级安装)。
  static bool _canWrite(String dir) {
    try {
      final probe = File('$dir\\.dmr_write_probe');
      probe.writeAsStringSync('x');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }
}

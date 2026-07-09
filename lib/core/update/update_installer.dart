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
    followRedirects: true, // GitHub 附件直链会 302 到 CDN
    maxRedirects: 6,
    validateStatus: (_) => true,
  ));

  /// 从 release 附件里挑当前平台要下的那个(Android=通用 APK · Windows=setup.exe)。
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
  /// Android:装完由系统安装器接手;Windows:静默装好后自动重启,本进程随即退出。
  static Future<void> downloadAndInstall(
    UpdateAsset asset, {
    required void Function(double progress) onProgress,
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
      await _installWindows(path);
      return;
    }
    throw Exception('该平台不支持应用内更新');
  }

  static Future<void> _installWindows(String setupPath) async {
    final exe = Platform.resolvedExecutable;
    final appDir = File(exe).parent.path;
    final installed = File('$appDir\\unins000.exe').existsSync();
    final tmp = await getTemporaryDirectory();
    final bat = File('${tmp.path}\\dmr_update.bat');
    final runInstaller = installed
        ? '"$setupPath" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        : '"$setupPath"'; // 便携版:正常安装器,用户自己选目录
    // 脚本:等 2s(本进程退出、文件解锁)→ 运行安装器 → 重启 App → 自删。
    await bat.writeAsString(
      '@echo off\r\n'
      'timeout /t 2 /nobreak >NUL\r\n'
      '$runInstaller\r\n'
      'start "" "$exe"\r\n'
      'del "%~f0"\r\n',
    );
    await Process.start(
      'cmd',
      ['/c', bat.path],
      mode: ProcessStartMode.detached,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    exit(0); // 退出让安装器替换文件
  }
}

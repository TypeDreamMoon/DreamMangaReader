import 'dart:async';
import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// 应用内更新:唤起已经完成完整性校验的安装包。
///
/// - **Android**:打开已按设备 ABI 选择的 APK(首次需在系统里授予「安装未知应用」)。
///   能否**覆盖安装**取决于新旧包**签名一致**——签名不一致会「应用未安装」。
/// - **Windows**:下 setup.exe,写个临时脚本:等本进程退出 → 静默运行安装器覆盖 → 重启 App。
///   安装版(装目录里有 unins000.exe)才静默;便携版起普通安装器让用户自己选目录。
class UpdateInstaller {
  UpdateInstaller._();

  /// 当前平台是否支持应用内自更新(否则退回浏览器下载页)。
  static bool get supported => Platform.isAndroid || Platform.isWindows;

  /// 唤起 [package] 安装。[onBeforeExit] 在 Windows 静默安装 exit(0) 前调用。
  static Future<void> install(
    File package, {
    Future<void> Function()? onBeforeExit,
  }) async {
    if (Platform.isAndroid) {
      final res = await OpenFilex.open(
        package.path,
        type: 'application/vnd.android.package-archive',
      );
      if (res.type != ResultType.done) {
        throw Exception('打开安装器失败:${res.message}');
      }
      return;
    }
    if (Platform.isWindows) {
      await _installWindows(package.path, onBeforeExit);
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

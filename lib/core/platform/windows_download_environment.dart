import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../downloads/download_environment_provider.dart';

/// Windows 侧的下载环境探测。
///
/// 网络:wininet 的 `InternetGetConnectedState` —— 只有拨号/移动调制解调器才算
/// 计费,局域网、Wi-Fi、以及探不出来的情况一律按「不计费」处理(桌面上没有
/// 「仅 Wi-Fi」这个概念,把有线判成计费只会让下载无缘无故停住)。Windows 没有
/// 现成的连接变化回调可用,靠 [DownloadEnvironmentProvider] 的兜底轮询。
///
/// 空间:kernel32 的 `GetDiskFreeSpaceEx`,取当前用户可用的字节数。
///
/// 非 Windows 或 FFI 抛异常时一律返回 unknown(不限制)。
class WindowsDownloadEnvironment {
  const WindowsDownloadEnvironment._();

  // InternetGetConnectedState 的 lpdwFlags 位。
  static const _connectionModem = 0x01;
  static const _connectionOffline = 0x20;

  static Future<DownloadNetworkStatus> readNetwork() async => networkStatus();

  static Future<DownloadStorageStatus> readStorage(String path) async =>
      storageStatus(path);

  static DownloadNetworkStatus networkStatus() {
    if (!Platform.isWindows) return DownloadNetworkStatus.unknown;
    try {
      final flags = calloc<Uint32>();
      try {
        final connected = _internetGetConnectedState(flags, 0) != 0;
        final value = flags.value;
        if (!connected || (value & _connectionOffline) != 0) {
          return DownloadNetworkStatus.offline;
        }
        return DownloadNetworkStatus(
          connected: true,
          unmetered: (value & _connectionModem) == 0,
          roaming: false,
        );
      } finally {
        calloc.free(flags);
      }
    } on Object {
      return DownloadNetworkStatus.unknown;
    }
  }

  static DownloadStorageStatus storageStatus(String path) {
    if (!Platform.isWindows) return DownloadStorageStatus.unknown;
    try {
      final directory = path.toNativeUtf16();
      final free = calloc<Uint64>();
      try {
        final ok = GetDiskFreeSpaceEx(directory, free, nullptr, nullptr);
        if (ok == 0) {
          // 目录不存在 / 盘符掉了:磁盘不可用,而不是「空间为 0」。
          return const DownloadStorageStatus(
            available: false,
            freeBytes: 0,
          );
        }
        return DownloadStorageStatus(available: true, freeBytes: free.value);
      } finally {
        calloc.free(free);
        calloc.free(directory);
      }
    } on Object {
      return DownloadStorageStatus.unknown;
    }
  }
}

// win32 包没有 wininet,直接自己开一份句柄(惰性加载,只有真调用时才打开 DLL)。
final DynamicLibrary _wininet = DynamicLibrary.open('wininet.dll');

final int Function(Pointer<Uint32> lpdwFlags, int dwReserved)
    _internetGetConnectedState = _wininet.lookupFunction<
        Int32 Function(Pointer<Uint32> lpdwFlags, Uint32 dwReserved),
        int Function(
          Pointer<Uint32> lpdwFlags,
          int dwReserved,
        )>('InternetGetConnectedState');

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// 枚举 Windows 系统已安装的字体族(GDI `EnumFontFamiliesEx`)。
///
/// 用 GDI 而非读注册表/跑 PowerShell:拿到的就是 DirectWrite/Skia 解析用的
/// 干净字体族名(可直接当 `fontFamily`),且无子进程、无控制台闪窗。
/// 仅 Windows 生效(其他平台返回空,交给回退栈);win32 的 DLL 句柄惰性加载,
/// 只有真正调用时才打开 gdi32/user32,Android 不受影响。结果缓存,启动预热一次。
class SystemFonts {
  SystemFonts._();

  static List<String>? _cache;

  /// 已加载的字体族列表(未加载或非 Windows 时为空)。
  static List<String> get cached => _cache ?? const [];

  /// 枚举一次并缓存。启动时 `await` 预热,之后同步读 [cached]。
  static Future<List<String>> ensureLoaded() async {
    final c = _cache;
    if (c != null) return c;
    if (!Platform.isWindows) return _cache = const [];
    try {
      return _cache = _enumerate();
    } catch (_) {
      return _cache = const []; // FFI 异常不致命:退回系统默认回退栈
    }
  }

  static List<String> _enumerate() {
    final names = <String>{};
    final hdc = GetDC(NULL);
    if (hdc == 0) return const [];
    // 拿到 hdc 后立刻进 try:calloc / NativeCallable 万一抛异常也保证 ReleaseDC。
    Pointer<LOGFONT>? lf;
    NativeCallable<FONTENUMPROC>? cb;
    try {
      lf = calloc<LOGFONT>();
      lf.ref.lfCharSet = DEFAULT_CHARSET; // 枚举所有字符集下的字体族
      cb = NativeCallable<FONTENUMPROC>.isolateLocal(
        (Pointer<LOGFONT> lpelfe, Pointer<TEXTMETRIC> lpntme, int fontType,
            int lParam) {
          final name = lpelfe.ref.lfFaceName;
          // '@' 前缀是 CJK 竖排变体,跳过。
          if (name.isNotEmpty && !name.startsWith('@')) names.add(name);
          return 1; // TRUE:继续枚举
        },
        exceptionalReturn: 0,
      );
      EnumFontFamiliesEx(hdc, lf, cb.nativeFunction, 0, 0);
    } finally {
      cb?.close();
      if (lf != null) calloc.free(lf);
      ReleaseDC(NULL, hdc);
    }
    final list = names.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }
}

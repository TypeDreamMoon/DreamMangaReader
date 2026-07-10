import 'package:flutter/services.dart' show rootBundle;

import 'title_match.dart' show normalizeTitle;

/// 繁体 → 简体逐字折叠。单字表来自 **OpenCC**(Apache-2.0)的 TSCharacters,打包成资源
/// `assets/data/t2s.txt`(第 1 行繁、第 2 行简,逐字对齐);启动时 [load] 一次读进内存。
/// **不硬编码在源码里** —— 字表由数据文件维护,完整覆盖繁简单字,更新只换资源。
///
/// 用途:多源同名去重把繁简变体折成同一 key(绝世武神 / 絕世武神)。只折繁体字、
/// 简体原样透传 → 不会把两本不同的简体书误并。未 [load] 前 [fold] 退化为原样。
class ChineseFold {
  ChineseFold._();

  static Map<int, int> _map = const {}; // 繁体码点 → 简体码点

  static bool get loaded => _map.isNotEmpty;

  /// 启动时调用一次(main 里,runApp 前)。失败静默(退化为不折,不拖累启动)。
  static Future<void> load() async {
    if (_map.isNotEmpty) return;
    try {
      final raw = await rootBundle.loadString('assets/data/t2s.txt');
      final lines = raw
          .split('\n')
          .map((l) => l.replaceAll('\r', ''))
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();
      if (lines.length < 2) return;
      final trad = lines[0].runes.toList();
      final simp = lines[1].runes.toList();
      final n = trad.length < simp.length ? trad.length : simp.length;
      final m = <int, int>{};
      for (var i = 0; i < n; i++) {
        m[trad[i]] = simp[i];
      }
      _map = m;
    } catch (_) {/* 资源缺失/损坏 → 不折,静默 */}
  }

  /// 繁体逐字折成简体(表内没有的字原样保留)。
  static String fold(String s) {
    if (_map.isEmpty || s.isEmpty) return s;
    final b = StringBuffer();
    for (final r in s.runes) {
      b.writeCharCode(_map[r] ?? r);
    }
    return b.toString();
  }

  /// 多源同名去重键:先折繁→简再归一 → 繁简变体得到同一 key。
  static String dedupKey(String title) => normalizeTitle(fold(title));
}

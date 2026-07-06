import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../net/image_cache.dart';

/// 从封面主色派生的一小组主题色,用来给详情页头部/按钮/角标染色。
///
/// 不可变、可比较——放进 `setState` 或做缓存 key 都安全。
@immutable
class CoverPalette {
  const CoverPalette({
    required this.primary,
    required this.secondary,
    required this.onPrimary,
  });

  /// 最显眼的「鲜艳」聚类(已排除近白/近黑/低饱和)。用作强调色。
  final Color primary;

  /// 次要聚类(与 primary 拉开距离、兼顾占比)。用作渐变的另一端。
  final Color secondary;

  /// primary 之上可读的文字色(按亮度对比,白或近黑)。
  final Color onPrimary;

  @override
  bool operator ==(Object other) =>
      other is CoverPalette &&
      other.primary == primary &&
      other.secondary == secondary &&
      other.onPrimary == onPrimary;

  @override
  int get hashCode => Object.hash(primary, secondary, onPrimary);
}

/// 从封面图算主色 → [CoverPalette]。
///
/// 流程:磁盘缓存取字节(带 Referer 头,复用全 App 的 [appImageCache])→ 主线程用
/// `dart:ui` 解码成 RGBA(引擎图像解码必须在平台线程)→ 把裸字节丢进 `compute()`
/// 的隔离区跑 k-means(纯 CPU、无 UI 依赖,`Uint8List` 可在隔离间传递)。
///
/// 失败(网络/解码/空图)返回 `null`,由调用方回退到 `p.accent` / id 哈希渐变。
Future<CoverPalette?> extractCoverPalette(
  String url,
  Map<String, String> headers,
) async {
  if (url.isEmpty) return null;
  try {
    // 1) 取字节。getSingleFile 已被 reader/download 复用,命中缓存则不走网络。
    final file = await appImageCache.getSingleFile(url, headers: headers);
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;

    // 2) 主线程解码。dart:ui 的解码走引擎,不能进普通 Dart 隔离区。
    final codec = await ui.instantiateImageCodec(
      bytes,
      // 缩到小图再取像素:降内存 + 天然降采样(封面细节对主色无意义)。
      targetWidth: 96,
      targetHeight: 128,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final byteData =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = image.width;
    final h = image.height;
    image.dispose();
    codec.dispose();
    if (byteData == null) return null;
    final rgba = byteData.buffer.asUint8List();

    // 3) k-means 丢到后台隔离区。传入是可转移的 Uint8List + 尺寸。
    final raw = await compute(
      _kmeansEntry,
      _KMeansInput(rgba, w, h),
    );

    return CoverPalette(
      primary: Color(raw.primary),
      secondary: Color(raw.secondary),
      onPrimary: Color(raw.onPrimary),
    );
  } catch (_) {
    return null; // 任一步失败都回退,详情页照常用 accent。
  }
}

// ---------------------------------------------------------------------------
// 以下为隔离区里跑的纯计算部分:必须是顶层函数 + 只用可转移/可复制的数据。
// ---------------------------------------------------------------------------

@immutable
class _KMeansInput {
  const _KMeansInput(this.rgba, this.width, this.height);
  final Uint8List rgba;
  final int width;
  final int height;
}

@immutable
class _RawResult {
  const _RawResult(this.primary, this.secondary, this.onPrimary);
  final int primary; // ARGB
  final int secondary; // ARGB
  final int onPrimary; // ARGB
}

/// 顶层入口,供 [compute] 调用。RGB 空间的简易 k-means(k=5, 8 轮),
/// 挑「占比 × 饱和度」最高、且非近白/近黑的聚类做 primary。
_RawResult _kmeansEntry(_KMeansInput input) {
  final rgba = input.rgba;
  final w = input.width;
  final h = input.height;
  final total = w * h;
  // 兜底色:中性深灰,和暗色主题不冲突。
  const fallback = _RawResult(0xFF3A3F45, 0xFF23282D, 0xFFFFFFFF);
  if (total == 0 || rgba.length < total * 4) return fallback;

  // 采样到约 1600 点:即便解码没缩到小图,这里也再降采样一层。
  const target = 1600;
  final step = math.max(1, math.sqrt(total / target).floor());

  final rs = <double>[];
  final gs = <double>[];
  final bs = <double>[];
  for (var y = 0; y < h; y += step) {
    final rowBase = y * w;
    for (var x = 0; x < w; x += step) {
      final i = (rowBase + x) * 4;
      if (rgba[i + 3] < 125) continue; // 跳过透明像素
      rs.add(rgba[i].toDouble());
      gs.add(rgba[i + 1].toDouble());
      bs.add(rgba[i + 2].toDouble());
    }
  }

  final n = rs.length;
  if (n == 0) return fallback;

  const k = 5;
  final centR = List<double>.filled(k, 0);
  final centG = List<double>.filled(k, 0);
  final centB = List<double>.filled(k, 0);
  // 固定种子:同一张封面每次结果一致(避免主题色闪烁)。
  final rng = math.Random(0x9E3779B9);
  for (var c = 0; c < k; c++) {
    final idx = rng.nextInt(n);
    centR[c] = rs[idx];
    centG[c] = gs[idx];
    centB[c] = bs[idx];
  }

  final assign = Uint16List(n);
  const iterations = 8;
  for (var it = 0; it < iterations; it++) {
    // 分配
    for (var p = 0; p < n; p++) {
      final r = rs[p], g = gs[p], b = bs[p];
      var best = 0;
      var bestD = double.infinity;
      for (var c = 0; c < k; c++) {
        final dr = r - centR[c];
        final dg = g - centG[c];
        final db = b - centB[c];
        final d = dr * dr + dg * dg + db * db;
        if (d < bestD) {
          bestD = d;
          best = c;
        }
      }
      assign[p] = best;
    }
    // 更新质心
    final sumR = List<double>.filled(k, 0);
    final sumG = List<double>.filled(k, 0);
    final sumB = List<double>.filled(k, 0);
    final cnt = List<int>.filled(k, 0);
    for (var p = 0; p < n; p++) {
      final c = assign[p];
      sumR[c] += rs[p];
      sumG[c] += gs[p];
      sumB[c] += bs[p];
      cnt[c]++;
    }
    for (var c = 0; c < k; c++) {
      if (cnt[c] == 0) {
        // 空簇:重新随机播种,防止后续除零 / 死簇。
        final idx = rng.nextInt(n);
        centR[c] = rs[idx];
        centG[c] = gs[idx];
        centB[c] = bs[idx];
      } else {
        centR[c] = sumR[c] / cnt[c];
        centG[c] = sumG[c] / cnt[c];
        centB[c] = sumB[c] / cnt[c];
      }
    }
  }

  final counts = List<int>.filled(k, 0);
  for (var p = 0; p < n; p++) {
    counts[assign[p]]++;
  }

  double sat(double r, double g, double b) {
    final mx = math.max(r, math.max(g, b));
    final mn = math.min(r, math.min(g, b));
    if (mx <= 0) return 0;
    return (mx - mn) / mx;
  }

  double lum(double r, double g, double b) =>
      (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;

  // 按占比降序,便于「同分取更主流」的挑选。
  final order = List<int>.generate(k, (i) => i)
    ..sort((a, b) => counts[b].compareTo(counts[a]));

  // primary:综合「饱和度 × (0.55 + 0.45×占比)」,排除近白/近黑。
  int? bestVivid;
  var bestScore = -1.0;
  for (final c in order) {
    if (counts[c] == 0) continue;
    final r = centR[c], g = centG[c], b = centB[c];
    final l = lum(r, g, b);
    if (l > 0.93 || l < 0.07) continue; // 近白/近黑不当强调色
    final weight = counts[c] / n;
    final score = sat(r, g, b) * (0.55 + 0.45 * weight);
    if (score > bestScore) {
      bestScore = score;
      bestVivid = c;
    }
  }
  // 全是黑白/近白近黑时:退回最大的非空簇,保证有色可用。
  bestVivid ??= order.firstWhere((c) => counts[c] > 0, orElse: () => 0);

  // secondary:兼顾占比与「和 primary 拉开距离」,做渐变另一端。
  int? secondary;
  var secBest = -1.0;
  for (final c in order) {
    if (c == bestVivid || counts[c] == 0) continue;
    final dr = centR[c] - centR[bestVivid];
    final dg = centG[c] - centG[bestVivid];
    final db = centB[c] - centB[bestVivid];
    final dist = math.sqrt(dr * dr + dg * dg + db * db) / 441.67; // 归一化
    final weight = counts[c] / n;
    final score = weight * 0.6 + dist * 0.4;
    if (score > secBest) {
      secBest = score;
      secondary = c;
    }
  }
  secondary ??= bestVivid;

  int pack(int c) {
    final r = centR[c].round().clamp(0, 255);
    final g = centG[c].round().clamp(0, 255);
    final b = centB[c].round().clamp(0, 255);
    return 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  final pl = lum(centR[bestVivid], centG[bestVivid], centB[bestVivid]);
  final onPrimary = pl < 0.55 ? 0xFFFFFFFF : 0xFF0A0A0A;

  return _RawResult(pack(bestVivid), pack(secondary), onPrimary);
}

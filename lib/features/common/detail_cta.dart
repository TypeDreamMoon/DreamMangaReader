import 'package:flutter/material.dart';

import '../../core/l10n/app_strings.dart';

/// 详情页主操作行:一个铺满的主按钮(开始/继续)+ 右侧一排方形图标键。
///
/// 三个详情页原本各写一份,内边距、按钮高度、10px 间距、「继续 · X / 从头开始」
/// 的图标与文案全一样。真正不同的只是主按钮点了干什么、以及右侧挂哪几个键。
class DetailCta extends StatelessWidget {
  const DetailCta({
    super.key,
    required this.accent,
    required this.onAccent,
    required this.resumed,
    required this.resumeLabel,
    required this.onPrimary,
    required this.actions,
    this.primaryKey,
  });

  final Color accent;

  /// 主按钮上的前景色(封面取色给的 onPrimary,退回主题 onAccent)。
  final Color onAccent;

  /// 读/看过 → 主按钮显示「继续 · [resumeLabel]」,否则「从头开始」。
  final bool resumed;

  /// 续读点的名字(章节名 / 集名);[resumed] 为 false 时忽略。
  final String resumeLabel;

  /// null = 主按钮禁用(还没拿到章节/分集)。
  final VoidCallback? onPrimary;

  /// 右侧图标键(收藏 / 下载 / 浏览器打开…),之间自动留 10px。
  final List<Widget> actions;

  final Key? primaryKey;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: FilledButton(
                key: primaryKey,
                onPressed: onPrimary,
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: onAccent,
                  minimumSize: const Size.fromHeight(46),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                        resumed
                            ? Icons.play_circle_fill_rounded
                            : Icons.play_arrow_rounded,
                        size: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        resumed
                            ? context.l10n.detail_continueChapter(resumeLabel)
                            : context.l10n.detail_startFromBeginning,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            for (final action in actions) ...[
              const SizedBox(width: 10),
              action,
            ],
          ],
        ),
      );
}

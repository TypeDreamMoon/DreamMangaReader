import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/transitions.dart';
import '../common/cover_hero.dart';
import '../detail/detail_page.dart';
import '../library/manga_cover.dart';
import 'recommend_controller.dart';

/// 「为你推荐」横条:据书架(收藏 + 在读)的口味算、混合源解析成可读漫画。
///
/// 住在**发现页** —— 书架只管「我的收藏与历史」,推荐属于「找新内容」那一侧。
/// 无结果且无可重试提示时整条不占位。
class RecommendStrip extends StatefulWidget {
  const RecommendStrip({super.key, required this.controller});

  final RecommendController controller;

  @override
  State<RecommendStrip> createState() => _RecommendStripState();
}

class _RecommendStripState extends State<RecommendStrip> {
  final ScrollController _scroll = ScrollController();
  String _lastSig = ''; // 上次触发刷新时的书架签名(变了才重算)

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // 推荐空态语义码 → 当前语言文案(控制器无 context,映射放这里)。
  String _noteText(RecNote code) {
    final l = context.l10n;
    return switch (code) {
      RecNote.noRecsYet => l.rec_noRecsYet,
      RecNote.shelfTooEmpty => l.rec_shelfTooEmpty,
      RecNote.notEnoughBangumi => l.rec_notEnoughBangumi,
      RecNote.noSources => l.rec_noSources,
      RecNote.generateFailed => l.rec_generateFailed,
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final store = LibraryScope.of(context); // 依赖:书架变了自动重建
    // 书架内容变了(签名变)才后台重算;post-frame 触发,避免 build 期改 controller。
    final sig = RecommendController.signatureOf(store);
    if (sig != _lastSig) {
      _lastSig = sig;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.ensure(store);
      });
    }
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (_, __) {
        final recs = widget.controller.recs;
        final noteCode = widget.controller.noteCode;
        final loading = widget.controller.loading;
        // 空态里只有「可重试」的提示(失败 / 暂时性)才占位显示 —— 「书架太少」这类
        // 需用户去收藏、重试无用的,直接不占位。
        final showNote = recs.isEmpty &&
            !loading &&
            noteCode != null &&
            widget.controller.canRetry;
        if (recs.isEmpty && !loading && !showNote) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 10),
              child: Row(
                children: [
                  // Row 给子级无界宽度,带尾线(内部 Expanded)会炸布局 → 关掉尾线。
                  AppSectionHeading(context.l10n.shelf_forYou,
                      fontSize: 16, trailingRule: false),
                  const SizedBox(width: 10),
                  if (loading)
                    SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: p.accent)),
                  const Spacer(),
                  if (!loading)
                    Pressable(
                      onTap: () => widget.controller.ensure(store, force: true),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.refresh_rounded,
                            size: 18, color: p.textMuted),
                      ),
                    ),
                ],
              ),
            ),
            if (recs.isEmpty && loading)
              SizedBox(
                height: 56,
                child: Center(
                  child: Text(context.l10n.shelf_generatingRecs,
                      style: TextStyle(color: p.textMuted, fontSize: 12)),
                ),
              ),
            if (showNote)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(_noteText(noteCode),
                    style: TextStyle(color: p.textMuted, fontSize: 12.5)),
              ),
            if (recs.isNotEmpty)
              SizedBox(
                height: 172,
                // 桌面滚轮/鼠标拖拽可横滑(AppHStrip 统一处理)。
                child: AppHStrip.separated(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: recs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, i) => _card(p, recs[i]),
                ),
              ),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }

  Widget _card(AppPalette p, RecItem rec) {
    final m = rec.manga;
    final tag = coverHeroTag(CoverHeroScope.recommend,
        sourceId: rec.meta.id, itemId: m.id);
    return SizedBox(
      width: 92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: MangaCover(
              manga: m,
              headers: imageHeadersOf(rec.meta),
              heroTag: tag,
              onTap: () => pushPage(context, DetailPage(manga: m, meta: rec.meta, heroTag: tag)),
            ),
          ),
          const SizedBox(height: 6),
          Text(m.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
          if (rec.bgm.score > 0)
            Text('★ ${rec.bgm.score.toStringAsFixed(1)} · ${rec.meta.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.textMuted, fontSize: 10.5)),
        ],
      ),
    );
  }
}

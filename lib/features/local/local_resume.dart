import 'package:flutter/material.dart';

import '../../app/anime_library_store.dart';
import '../../app/local_media_store.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/local/local_models.dart';
import '../common/transitions.dart';
import 'local_library_detail_page.dart';

/// 从书架的历史卡片 / 历史页 / 收藏打开一条**本地播放**记录。
///
/// 本地播放的进度写在番剧库里(`sourceId = LocalSource.id`、`animeId = 库 id`,
/// 见 `local_player_page.dart`),所以在书架与历史里它以「番剧」形态出现。
/// 它**不能**走番剧那条「按 sourceId 找源」的路 —— 没有 id 为 `local` 的脚本源,
/// 那条路只会把用户送去一句「番剧源不可用」。
///
/// 落点与番剧保持一致:本地库详情页(那页自己会把「继续观看 · 第 N 集」摆在最上面,
/// 想挑另一集也不用退出去)。库已经被移除时给一句提示 —— 条目位置只活在这台设备上,
/// 没有「换个源再找回来」这回事。
Future<void> openLocalLibrary(BuildContext context, String libraryId) async {
  final library = LocalMediaScope.maybeRead(context)?.library(libraryId);
  if (library == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.local_libraryGone)),
    );
    return;
  }
  await pushPage(context, LocalLibraryDetailPage(libraryId: library.id));
}

/// 历史记录里的那条本地播放 → 打开它所在的本地库。
Future<void> openLocalHistory(BuildContext context, AnimeHistoryEntry entry) =>
    openLocalLibrary(context, entry.animeId);

/// 这条番剧历史是不是本地库播放留下的(`sourceId` 是保留 id)。
bool isLocalHistorySource(String sourceId) => sourceId == LocalSource.id;

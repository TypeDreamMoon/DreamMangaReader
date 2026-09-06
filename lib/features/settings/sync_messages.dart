import '../../core/l10n/app_strings.dart';
import '../../core/sync/sync_messages.dart';

/// 同步层的结果码 → 当前语言文案。
///
/// 核心层只回 [SyncNotice](见 `core/sync/sync_messages.dart`),翻译在这一层做,
/// 英文/日文界面才不会突然冒出中文。
String syncNoticeText(AppLocalizations l10n, SyncNotice notice) {
  final status = notice.httpStatus ?? 0;
  final detail = notice.detail ?? '';
  return switch (notice.message) {
    SyncMessage.syncing => l10n.sync_stSyncing,
    SyncMessage.uploading => l10n.sync_stUploading,
    SyncMessage.downloading => l10n.sync_stDownloading,
    SyncMessage.synced =>
      l10n.sync_stSynced(notice.favorites, notice.history),
    SyncMessage.uploaded => l10n.sync_stUploaded(notice.count),
    SyncMessage.downloaded => l10n.sync_stDownloaded(notice.count),
    SyncMessage.serverEmpty => l10n.sync_stServerEmpty,
    SyncMessage.testWebDavReady => l10n.sync_stTestWebdavReady,
    SyncMessage.testAccountReady => l10n.sync_stTestAccountReady,
    SyncMessage.notConfiguredAccount => l10n.sync_errNotConfiguredAccount,
    SyncMessage.notConfiguredWebDav => l10n.sync_errNotConfiguredWebdav,
    SyncMessage.noCategoriesChosen => l10n.sync_errNoCategories,
    SyncMessage.noDownloadChosen => l10n.sync_errNoDownload,
    SyncMessage.alreadySyncing => l10n.sync_errAlreadySyncing,
    SyncMessage.uploadConflictRetries => l10n.sync_errConflictRetries,
    SyncMessage.notLoggedIn => l10n.sync_errNotLoggedIn,
    SyncMessage.sessionExpired => l10n.sync_errSessionExpired,
    SyncMessage.serviceOnlineNotLoggedIn =>
      l10n.sync_errServiceOnlineNotLoggedIn,
    SyncMessage.serviceDown => l10n.sync_errServiceDown(status),
    SyncMessage.authFailed => l10n.sync_errAuthFailed(status),
    SyncMessage.forbidden => l10n.sync_errForbidden(status),
    SyncMessage.pullFailed => l10n.sync_errPullFailed(status),
    SyncMessage.pushFailed => l10n.sync_errPushFailed(status),
    SyncMessage.unexpectedStatus => l10n.sync_errUnexpectedStatus(status),
    SyncMessage.unreachable => l10n.sync_errUnreachable(detail),
    SyncMessage.autoSyncFailed => l10n.sync_errAutoSyncFailed(detail),
    SyncMessage.autoUploadFailed => l10n.sync_errAutoUploadFailed(detail),
  };
}

/// 同步动作抛出来的异常 → 当前语言文案。
/// 不认识的异常(dio / IO 之类)按「连不上」处理,底层原因照旧附在后面。
String syncErrorText(AppLocalizations l10n, Object error) =>
    error is SyncException
        ? syncNoticeText(l10n, error.notice)
        : l10n.sync_errUnreachable('$error');

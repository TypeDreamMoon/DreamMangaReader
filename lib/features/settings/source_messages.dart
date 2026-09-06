import '../../core/l10n/app_strings.dart';
import '../../core/source/source_health.dart';
import '../../core/source/source_repository.dart';

/// 源仓库加载状态 → 当前语言文案。
///
/// `SourceRepoStatus.debugText` 是**中文常量**、只给运行日志用;
/// 设置页/提示条这些给用户看的地方都走这里。
String sourceRepoStatusText(AppLocalizations l10n, SourceRepoStatus s) {
  final head = switch (s.origin) {
    SourceRepoOrigin.notLoaded => l10n.srcmgmt_repoStNotLoaded,
    SourceRepoOrigin.notConfigured => l10n.srcmgmt_repoStNotConfigured,
    SourceRepoOrigin.remote => l10n.srcmgmt_repoStRemote(s.repoCount),
    SourceRepoOrigin.localDir => l10n.srcmgmt_repoStLocalDir(s.repoCount),
    SourceRepoOrigin.cache => l10n.srcmgmt_repoStCache(s.repoCount),
    SourceRepoOrigin.devDir => l10n.srcmgmt_repoStDevDir(s.repoCount),
    SourceRepoOrigin.cacheAfterFailure =>
      l10n.srcmgmt_repoStCacheAfterFailure(s.repoCount),
    SourceRepoOrigin.failed => l10n.srcmgmt_repoStFailed(s.error ?? ''),
  };
  final local = s.localCount == 0
      ? ''
      : l10n.srcmgmt_repoStLocalExtra(s.localCount);
  final hidden =
      s.hiddenCount == 0 ? '' : l10n.srcmgmt_repoStHidden(s.hiddenCount);
  return '$head$local$hidden';
}

/// 一次可用性检测 → 弹窗里那份检测日志(当前语言)。
///
/// 报告本身([SourceHealthReport])只有事实,没有成句文案——以前是核心层直接
/// 拼中文,英/日界面照样弹一整屏中文。
String sourceHealthLogText(AppLocalizations l10n, SourceHealthResult result) {
  final report = result.report;
  if (report == null) return l10n.srcmgmt_logNotChecked;
  final transport = report.transport == SourceTransport.webView
      ? l10n.srcmgmt_logTransportWebView
      : l10n.srcmgmt_logTransportDio;
  final b = StringBuffer()
    ..writeln(l10n.srcmgmt_logSource(report.sourceName, report.sourceId))
    ..writeln(l10n.srcmgmt_logTransport(report.experimental
        ? '$transport · ${l10n.srcmgmt_logExperimental}'
        : transport));
  final fn = report.discoveryFn;
  if (fn != null) {
    b.writeln(l10n.srcmgmt_logTest(fn, report.timeoutSeconds));
  }
  b
    ..writeln('──────────')
    ..writeln(l10n.srcmgmt_logElapsed(report.elapsedMs));
  switch (result.status) {
    case SourceHealthStatus.ok:
      b
        ..writeln(l10n.srcmgmt_logResultOk(
            report.count ?? 0, report.withCover))
        ..writeln(l10n.srcmgmt_logSamples(report.samples.join('、')));
    case SourceHealthStatus.empty:
      b
        ..writeln(l10n.srcmgmt_logResultEmpty)
        ..writeln(l10n.srcmgmt_logEmptyHint);
    case SourceHealthStatus.fail:
      b.writeln(l10n.srcmgmt_logResultFail);
      if (result.failure == SourceHealthFailure.scriptStuck) {
        b.writeln(l10n.srcmgmt_logStuckHint);
      }
      final detail = report.errorDetail;
      if (detail != null && detail.isNotEmpty) b.writeln(detail);
    case SourceHealthStatus.unknown:
    case SourceHealthStatus.checking:
      break;
  }
  return b.toString().trimRight();
}

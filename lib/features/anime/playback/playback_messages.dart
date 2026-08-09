/// 播放过程中会呈现给用户的文案。
///
/// `playback/` 这层是纯逻辑(用 fake_async 跑单测),刻意不碰 `BuildContext`,
/// 所以文案不在这儿取:由播放页在 `didChangeDependencies` 里用 l10n 填好注入。
/// 语言切换时 `didChangeDependencies` 会再跑一遍,顺带把这份也换掉。
class PlaybackMessages {
  const PlaybackMessages({
    required this.noRoute,
    required this.bufferTimeout,
    required this.recovering,
    required this.recoverFailed,
  });

  /// 一集解析不出任何可播放地址。
  final String noRoute;

  /// 缓冲迟迟不结束,判为卡死。
  final String bufferTimeout;

  /// 正在做第 [attempt] 次(共 [total] 次)自动恢复。
  final String Function(int attempt, int total) recovering;

  /// 几轮恢复都没救回来。[detail] 是**已脱敏**的底层原因,可以直接进 UI。
  final String Function(String detail) recoverFailed;
}

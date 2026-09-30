import '../../core/source/models.dart';
import '../anime/playback/playback_session_controller.dart';

/// 本地播放的轨道提供者。
///
/// 存在的唯一理由是喂饱 `PlaybackSessionController._recover` 的恢复阶梯
/// (rebuildDecoder → refresh/matchRefreshed → lowerQuality/alternateLine):
///
/// - [refresh] **必须返回当前 track**,不能返回空列表。本地只有一个不可变的
///   文件,如果 refresh 也空,一次偶发打不开就会在 1s/2s/4s 三次退避后直接
///   落到 `PlaybackPhase.failed`;返回当前文件可以把前两轮变成「重开同一个文件」,
///   只有文件真被删/权限被撤时才真正失败。
/// - 本地没有清晰度、也没有线路,另外两条一律 `null`(退化为返回上一级)。
class LocalTrackProvider implements PlaybackTrackProvider {
  LocalTrackProvider(this.track);

  /// 当前那条 track。重扫/重算字幕后可以换掉它,下一条发给播放内核的就是它。
  VideoTrack track;

  @override
  Future<List<VideoTrack>> refresh() async => [track];

  @override
  VideoTrack? matchRefreshed(VideoTrack current, List<VideoTrack> refreshed) =>
      refreshed.isEmpty ? null : refreshed.first;

  @override
  VideoTrack? lowerQuality(VideoTrack current, List<VideoTrack> available) =>
      null;

  @override
  VideoTrack? alternateLine(VideoTrack current, List<VideoTrack> available) =>
      null;
}

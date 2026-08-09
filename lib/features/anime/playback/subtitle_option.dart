import '../../../core/source/models.dart';

/// 一条可选字幕。两种来源在 UI 上是一个列表,对播放器却是两条路:
///
/// * [url] 非空 —— 源另给的**外挂**文件(SRT / WebVTT / ASS),让 mpv 单独去加载;
/// * [url] 为空 —— 流里**自带**的轨道,[id] 就是 mpv 报上来的轨道号。
class SubtitleOption {
  const SubtitleOption({
    required this.id,
    this.label = '',
    this.url,
    this.language,
  });

  /// 从源给的外挂字幕建一条。id 直接用 url —— 同一集里够唯一了。
  SubtitleOption.asset(SubtitleAsset asset)
      : id = asset.url,
        label = asset.label,
        url = asset.url,
        language = asset.language;

  final String id;

  /// 展示名。空则由 UI 用「字幕 N」兜底(那是要翻译的文案,不该落到这层)。
  final String label;

  final String? url;
  final String? language;

  /// 关闭字幕。mpv 用 `no` 表示不显示。
  static const off = SubtitleOption(id: 'no');

  bool get isOff => id == off.id;

  bool get isExternal => url != null && url!.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is SubtitleOption && other.id == id && other.url == url;

  @override
  int get hashCode => Object.hash(id, url);
}

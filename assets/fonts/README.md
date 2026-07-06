# 字体:思源黑体 / Source Han Sans

本项目 UI 字体选用 **思源黑体(Source Han Sans SC = Noto Sans CJK SC)**,授权 **SIL OFL 1.1**(可自由嵌入、商用)。

## 如何启用

1. 下载思源黑体(简中子集),放到本目录,建议只保留会用到的字重:

   ```
   assets/fonts/SourceHanSansSC-Regular.otf
   assets/fonts/SourceHanSansSC-Medium.otf
   assets/fonts/SourceHanSansSC-Bold.otf
   assets/fonts/SourceHanSansSC-Heavy.otf
   ```

   下载:<https://github.com/adobe-fonts/source-han-sans/releases>(或 Google 的 Noto Sans CJK)。

2. 在根 `pubspec.yaml` 的 `flutter:` 段加入(取消注释/新增):

   ```yaml
   flutter:
     fonts:
       - family: SourceHanSansSC
         fonts:
           - asset: assets/fonts/SourceHanSansSC-Regular.otf
             weight: 400
           - asset: assets/fonts/SourceHanSansSC-Medium.otf
             weight: 500
           - asset: assets/fonts/SourceHanSansSC-Bold.otf
             weight: 700
           - asset: assets/fonts/SourceHanSansSC-Heavy.otf
             weight: 900
   ```

3. `flutter pub get` 后即生效——`app_theme.dart` 里 `kFontFamily = 'SourceHanSansSC'` 会自动套用。

> 未放字体文件时,代码引用未声明的 family 会**静默回退**到系统字体,不会报错;因此可以先跑起来,之后再补字体。

## 体积提示

思源黑体全量很大(每字重数 MB)。发布前建议按实际用到的字符做**子集裁剪**(如 `fonttools subset` / `pyftsubset`),或改用 **MiSans / HarmonyOS Sans**(均免费商用,体积更友好)。

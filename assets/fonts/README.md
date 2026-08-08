# 小说阅读器内置字体

本目录只收录从官方上游取得、允许随应用分发的 SIL Open Font License 1.1 字体。字体和许可证均未从掌阅或其他 APK 中提取。

## LXGW WenKai

- 上游仓库: <https://github.com/lxgw/LxgwWenKai>
- 官方发布: `v1.522`
- 上游 commit: `e8b5b48b79f19f29aa68b0a178eab3472ea9f7e8`
- 下载地址: <https://github.com/lxgw/LxgwWenKai/releases/download/v1.522/LXGWWenKai-Regular.ttf>
- 原始文件名: `LXGWWenKai-Regular.ttf`
- 打包文件名: `LXGWWenKai-Regular.ttf`
- SHA-256: `39AD71264B588165B469E35E6AFB162A378DACD1F95348160240BA9038AC3009`
- 许可证原始路径: `OFL.txt`（仓库标签 `v1.522`）
- 本地许可证: `OFL-LXGW.txt`

## Noto Serif CJK SC

- 上游仓库: <https://github.com/notofonts/noto-cjk>
- 官方修订: `Serif2.003`
- 上游 commit: `9b0f1436e455d902de067a2501422e5dc71ad16b`
- 原始地址: <https://github.com/notofonts/noto-cjk/blob/Serif2.003/Serif/OTF/SimplifiedChinese/NotoSerifCJKsc-Regular.otf>
- 原始文件名: `NotoSerifCJKsc-Regular.otf`
- 打包文件名: `NotoSerifSC-Regular.otf`
- SHA-256: `2A2EAE2628DF83556C54018C41E20FA532C1B862C5256AE8B3F23FEB918D12CA`
- 许可证原始路径: `Serif/LICENSE`（仓库标签 `Serif2.003`）
- 本地许可证: `OFL-Noto.txt`

## 运行时约定

- 偏好设置只保存 `builtin:noto-serif-sc`、`builtin:lxgw-wenkai` 或 `imported:<sha256>` 形式的稳定 ID。
- 内置字体和用户导入字体会复制到应用支持目录后再通过 WebView `@font-face` 加载。
- 本目录字体不得用 APK 反编译产物替换；升级时必须重新记录上游版本、文件名与 SHA-256。

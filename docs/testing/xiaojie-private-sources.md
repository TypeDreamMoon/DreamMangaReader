# 晓桀私有源验证记录

日期：2026-08-05

## 范围

- APP 分支：`codex/xiaojie-github-sources`
- 源分支：`codex/xiaojie-github-source`
- 内容仓库：`kirito0000001/Xiaojie-Reader-Content`（Private）
- 三个源：`xiaojie_novel`、`xiaojie_manga`、`xiaojie_anime`

## 已验证

- 三个源共享 `authKey: xiaojie_github`，Token 迁移到设备安全存储，不进入同步或备份。
- 私有 GitHub Contents API 的目录、详情、章节、漫画页和 HLS 请求均携带 Bearer Header。
- 小说按 EPUB spine 导出 24 个公开章节，排除制作信息页；正文图片只允许 PNG、JPEG、GIF、WebP Base64。
- 漫画固定为 6 页，索引为 0 至 5，资源文件为 `001.png` 至 `006.png`。
- 动漫生成 480p 和 360p HLS，媒体清单含 `#EXT-X-ENDLIST`，连续发布 70/70 文件 SHA-256 一致。
- 私有仓库认证读取成功，匿名读取返回 404。

## 命令结果

```text
node --test tests/*.test.mjs: 50 passed, 4 skipped, 0 failed
flutter test: 305 passed, 0 failed
flutter analyze: No issues found
Windows integration: 1 passed, 0 failed
Validate-Content.ps1: passed
```

Windows 集成测试使用真实 QuickJS 脚本和本地内容，通过假 HTTP 映射验证 APP 数据契约，不使用真实 Token。首次 Windows 构建需要 NuGet；本次使用 Microsoft 签名的项目 build 缓存，不修改系统 PATH。

## 未验证边界

- 未连接 Android 设备，因此尚未在 Android 真机执行登录、阅读、翻页和 HLS 播放。
- 未用真实 Fine-grained Token 在 APP UI 中登录；Token 仍需由使用者在设备上手工填写。
- APP 与源功能分支尚未推送，也未创建作者 PR；没有制作 Windows 或 Android 发布包。

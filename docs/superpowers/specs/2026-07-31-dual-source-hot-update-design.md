# DreamMangaReader 双源热更新与发布设计

## 1. 背景与目标

DreamMangaReader 当前版本为 `v1.3.0`。现有客户端只读取
`TypeDreamMoon/DreamMangaReader` 的 GitHub Releases，但已经具备 Windows 和
Android 的应用内下载安装能力。当前发布流程仅包含 GitHub Actions，没有 Gitee
更新检查、本地发布脚本、双源回退、下载后 SHA-256 校验或 Gitee 附件限制处理。

本次工作的目标是：

1. 制作一个由作者在原 GitHub 发布的桥接版 `v1.3.1`，让现有用户进入双源更新链路。
2. 从桥接版开始默认使用 Gitee 更新，Gitee 不可用时自动回退 GitHub。
3. Windows 和 Android 都在软件内完成检查、下载、校验和安装引导，网页链接仅作为备用。
4. 提供本地 Windows PowerShell 脚本，让维护者可以构建并发布 Gitee 版本。
5. 严格分离权限：本地脚本只写 Gitee Release，不写作者 GitHub；作者继续负责 GitHub 发布。

目标 Gitee 仓库为：

`https://gitee.com/TypeDreamMoon/DreamMangaReader`

## 2. 非目标与权限边界

本次不修改虚幻引擎项目或其他项目内容，也不把 FantasyTools 的业务代码复制进本项目。
FantasyTools 只作为双源更新、断点下载、哈希校验和安全发布流程的参考。

本地发布脚本必须遵守以下边界：

- 不登录、不推送、不创建作者 GitHub 的 Tag 或 Release。
- 不向 Gitee 源代码分支提交或强推代码。
- 不删除或覆盖已有 Gitee Tag、Release 或附件。
- 同版本重复运行时只补传缺失附件。
- 发布前显示仓库、版本、目标分支和附件清单，并要求明确确认。
- 提供 `-DryRun`，完整执行检查但不产生远程写入。
- Gitee Token 只从环境变量读取，不写入仓库、配置文件、日志或安装包。

建议的环境变量名为 `DREAMMANGAREADER_GITEE_TOKEN`，兼容备用名
`GITEE_TOKEN`。Token 仅在创建或更新 Gitee Release、上传附件时使用；客户端读取
公开 Release 不需要 Token。

## 3. 方案选择

采用“共用产物、分离发布权限”的混合方案。

- 本地脚本负责构建、校验并发布 Gitee。
- GitHub Actions 继续构建 GitHub Release，供作者使用。
- 两端遵循相同的版本、文件命名和更新清单协议。
- 维护者可以把本地验证过的同版本产物交给作者，也可以让作者使用 Actions 重建。
- 客户端默认 Gitee，但保留 GitHub 作为自动备用源和手动选择项。

不采用完全本地双源发布，因为这需要维护者持有作者 GitHub 写权限；也不采用完全依赖
GitHub Actions 的方案，因为维护者需要能够独立构建和发布 Gitee。

## 4. 桥接版本

桥接版计划版本为 `v1.3.1`。最终实施前仍需从 `upstream/main` 同步并确认作者没有占用该
版本；若已占用，则顺延到下一个未使用的补丁版本。

桥接版必须由作者在原 GitHub 仓库发布。原因是 `v1.3.0` 只读取作者 GitHub Releases，
无法发现 fork 或 Gitee 上的新版本。

桥接版 GitHub Release 必须至少包含：

- `DreamMangaReader-windows-x64-setup.exe`
- `DreamMangaReader-windows-x64.zip`
- `DreamMangaReader-android-universal.apk`
- Android 分架构 APK
- `dream-manga-reader-update.json`

旧客户端会忽略 JSON 清单并按现有文件名选择 Windows 安装器或通用 APK；桥接版客户端
开始使用新清单和双源逻辑。

## 5. 更新清单协议

每个 Release 附带 `dream-manga-reader-update.json`。清单只保存稳定元数据和附件文件名，
下载 URL 由客户端把清单附件与当前 Release 的附件列表匹配后获得，避免发布前无法预知
Gitee 附件 URL。

清单结构如下：

```json
{
  "schemaVersion": 1,
  "appId": "DreamMangaReader",
  "version": "1.3.1",
  "channel": "stable",
  "publishedAt": "2026-07-31T00:00:00Z",
  "releaseNotes": "更新说明",
  "requiresRestart": true,
  "assets": [
    {
      "platform": "windows",
      "arch": "x64",
      "kind": "installer",
      "fileName": "DreamMangaReader-windows-x64-setup.exe",
      "sha256": "...",
      "sizeBytes": 0
    },
    {
      "platform": "android",
      "arch": "arm64-v8a",
      "kind": "apk",
      "fileName": "DreamMangaReader-android-arm64-v8a.apk",
      "sha256": "...",
      "sizeBytes": 0
    }
  ]
}
```

客户端必须验证 `schemaVersion`、`appId`、版本、附件文件名、大小和 SHA-256。文件名需要先
取 basename，拒绝包含路径穿越语义的值。无法识别的更高版本清单不得自动安装，应显示
明确错误并保留手动下载入口。

为兼容历史 Release，新客户端在缺少 JSON 清单时继续使用现有 GitHub Release 解析方式，
但此时只提供旧有的附件选择和安装行为。新 Release 必须带清单，才能启用完整哈希校验。

## 6. 双源检查与版本选择

更新源包含：

- Gitee：默认源。
- GitHub：自动备用源，也可在设置中手动选择。

设置中的选择表示“首选源”，不是关闭另一来源。选择 Gitee 时先查 Gitee、再查 GitHub；
选择 GitHub 时顺序相反。这样用户可以主动切换首选源，同时始终保留故障回退能力。恢复
默认设置后首选源必须回到 Gitee。

启动自动检查和设置页手动检查共用同一个更新服务。默认流程为：

1. 请求 Gitee Releases API。
2. 筛选当前通道允许的、严格高于本地版本的 Release。
3. 读取 Release 的 `attach_files`，下载并解析更新清单。
4. 检查当前平台是否存在完整、可用的安装附件。
5. Gitee 连接失败、超时、响应无效、没有可用新版本、清单无效或附件缺失时，再检查 GitHub。
6. 两个源都得到可用候选时，选择语义化版本更高的候选；版本相同时优先 Gitee。
7. 对话框显示最终使用的来源、版本、更新说明和安装附件。

“没有可用新版本”也会触发 GitHub 检查，以防 Gitee 镜像发布落后于作者 GitHub。单个来源
失败不会阻止另一个来源。两个来源都失败时显示可理解的汇总错误，不把网络失败伪装成
“已经是最新版”。

稳定版默认忽略 prerelease；启用测试版或当前版本本身为 prerelease 时，按现有语义化版本
规则参与比较。

## 7. 应用内下载与安装

网页 Release 链接只作为自动更新不可用时的备用入口。

通用流程为：

1. 在软件内下载选择出的附件，显示来源、文件名、进度和可取消状态。
2. 使用 `.download` 临时文件保存未完成下载。
3. 服务端支持 Range 时继续断点下载；不支持时清理临时文件并从头下载。
4. 下载完成后校验文件大小和 SHA-256。
5. 校验失败时删除错误文件，拒绝启动安装器，并允许重新下载。
6. 只保留有限数量的历史更新包，避免缓存无限增长。

### 7.1 Windows

Windows 自动选择 `DreamMangaReader-windows-x64-setup.exe`。ZIP 只用于便携分发和手动恢复，
不作为自动覆盖安装附件。

保留当前 Inno Setup 的 `AppId`、安装目录和覆盖安装行为。已安装版本下载完成后启动安装器；
可无提权覆盖的安装执行退出、静默安装和重启，需要管理员权限时允许系统显示 UAC。便携版
继续启动普通安装器，由用户确认安装目录。

### 7.2 Android

Android 根据设备 `supportedAbis` 按顺序选择 `arm64-v8a`、`armeabi-v7a` 或 `x86_64`
附件。桥接版保留通用 APK，供旧客户端和无法识别 ABI 的新版客户端兜底。

下载校验完成后打开 Android 系统安装器。受系统安全限制，用户仍需确认安装，并可能需要
首次授予“安装未知应用”权限。应用不能绕过系统确认静默安装。

固定发布签名必须继续使用当前 `android/app/dmr-release.jks`，否则不能覆盖安装历史版本。

## 8. Android 附件大小与版本码

当前 `v1.3.0` 通用 APK 约为 106.56 MiB，超过 Gitee Release 单附件 100 MiB 限制；各分架构
APK 均低于限制。因此：

- GitHub 桥接版继续发布通用 APK。
- Gitee 日常版本以分架构 APK 为主要自动更新附件。
- 发布脚本在上传前拒绝任何超过 Gitee 限制的附件，并列出实际大小。

现有通用 APK 使用 `5000 + pubspec build number` 档位，而旧分架构 APK 使用 Flutter 默认
ABI 档位。桥接版开始使用新的高位基准：

- 桥接版通用 APK 的 `versionCode` 进入 `10000 + build number` 档位。
- 后续分架构构建使用至少 `10000 + build number` 的基础值，再由 Flutter 添加 ABI 档位。
- 因而后续最低的分架构 `versionCode` 也严格高于桥接版通用 APK。

实施时必须用 Android 构建产物的实际 `versionCode` 做自动化断言，不能只依赖注释或公式。
每次发布的 `pubspec.yaml` build number 必须递增。

## 9. 本地脚本设计

新增以下入口：

- `Scripts/检查发布环境.ps1`
- `Scripts/打包新版本.ps1`
- `Scripts/发布到Gitee.ps1`
- `Scripts/打包并发布Gitee.ps1`

### 9.1 检查发布环境

只读检查 Flutter、Dart、Visual Studio C++、Android SDK/JDK、NuGet、Inno Setup、Git、
工作区状态、Gitee Token 是否存在以及目标 Gitee 仓库是否可访问。检查不得输出 Token 值。

缺少 NuGet 或 Inno Setup 时给出具体安装位置和影响，不自动修改全局环境。允许只构建 Android
或只构建 Windows，但完整发布必须通过两个平台的环境门禁。

### 9.2 打包新版本

参数至少包括版本、通道和输出目录。流程为：

1. 确认工作区与当前分支。
2. 校验 `AppInfo.version`、`pubspec.yaml`、build number 和目标版本一致。
3. 运行格式化检查、静态分析和测试。
4. 构建 Windows Release、补齐 VC++ 运行时并生成 ZIP 与 Inno Setup 安装器。
5. 构建 Android 通用包和分架构 APK，并核对签名、包名与实际 `versionCode`。
6. 计算所有附件的大小与 SHA-256。
7. 生成更新清单和人类可读的 SHA-256 文件。
8. 重新读取产物并验证文件存在、大小、哈希、命名和 Gitee 大小限制。

打包脚本只写独立输出目录，不修改或删除用户其他构建产物。

### 9.3 发布到 Gitee

发布脚本只读取已经验证的输出目录。流程为：

1. 读取 Token 环境变量并验证目标仓库权限，不打印 Token。
2. 展示目标仓库、版本、通道、目标分支、Release 标题和全部附件。
3. `-DryRun` 到此完成，不写远程。
4. 经确认后创建 Gitee Release；同版本已存在时读取现状。
5. 只上传缺失附件，不覆盖同名附件。
6. 上传后重新读取 Release 和附件列表，核对文件名与大小。
7. 下载清单并抽查解析；报告 Release URL 和最终状态。

任一步失败均以非零退出码结束，并保留已成功上传的附件供下次补传。脚本不得为了“重试”
自动删除远程 Release。若远程已经存在同名但大小或哈希不一致的附件，脚本必须停止并报告
冲突，要求维护者与作者核对后手动处理，不得静默视为成功。

### 9.4 打包并发布 Gitee

该入口依次调用环境检查、打包和 Gitee 发布。任一阶段失败立即停止。它是日常维护的主要
入口，但仍保留分步脚本，便于只打包、交给作者或针对上传失败进行补传。

## 10. GitHub Actions 与作者发布

现有 `.github/workflows/release.yml` 继续由作者仓库使用，并升级为与本地脚本相同的版本、
命名、清单和 Android `versionCode` 规则。

作者发布流程仍为推送 `vX.Y.Z` 或预发布 Tag，由 Actions 构建并创建 GitHub Release。
本地 Gitee 脚本不调用该流程。维护者向作者提交 PR 时提供：

- 建议 Tag。
- 版本与 build number。
- 已通过的测试和构建结果。
- Gitee Release URL。
- 应存在的 GitHub 附件清单。

作者不需要向维护者提供 GitHub Token。Gitee Token 也不提交给作者仓库，除非作者以后主动
选择在 Actions Secrets 中配置自动镜像；这不属于本次必需范围。

## 11. 错误处理与可观测性

更新检查需区分并记录：

- 网络连接失败或超时。
- API 限流或非 200 响应。
- Release 列表为空。
- 清单缺失、格式错误或 schema 不支持。
- 当前平台附件缺失。
- 下载中断。
- 大小或 SHA-256 不一致。
- Android 安装器无法打开。
- Windows 安装器启动失败或覆盖失败。

面向用户的提示保持简洁，日志保留来源、URL 主机、状态码、版本和附件名，但不记录 Token、
带凭据 URL 或本地敏感配置。更新对话框必须显示当前使用 Gitee 还是 GitHub 备用源。

## 12. 测试与验收

### 12.1 自动化测试

- 语义化版本和 prerelease 比较。
- GitHub 与 Gitee Release 响应解析。
- 更新清单解析、字段校验和路径安全。
- Gitee 优先、GitHub 回退和两个来源取更高版本。
- Windows 安装器选择。
- Android ABI 附件选择和通用包兜底。
- 缺失附件、大小错误和 SHA-256 错误时拒绝安装。
- 发布脚本的版本一致性、`-DryRun` 和补传判断。

### 12.2 构建验收

- `flutter analyze` 通过。
- `flutter test` 通过。
- Windows Release、ZIP 和 Inno Setup 安装器构建成功。
- Android 通用包和三个分架构 APK 构建成功。
- APK 包名、签名和 `versionCode` 符合升级要求。
- 所有 Gitee 附件小于平台限制。

### 12.3 行为验收

- `v1.3.0` 能从作者 GitHub 发现并安装桥接版。
- 桥接版能默认从 Gitee 发现、下载并安装后续版本。
- Gitee 不可用或附件不完整时自动使用 GitHub。
- Windows 安装版能覆盖更新并重启；便携版能启动普通安装器。
- Android 能选择当前设备 ABI 的 APK，并由系统确认覆盖安装。
- 哈希不一致的文件不会被安装。
- Gitee 发布脚本 `-DryRun` 不产生远程改动，重复发布只补缺失附件。

## 13. 实施顺序

1. 抽离并测试 Release、清单和来源模型。
2. 实现 Gitee API、双源选择和设置默认值迁移。
3. 实现带断点、大小和 SHA-256 校验的下载层。
4. 完善 Windows 与 Android 平台附件选择和安装流程。
5. 调整 Android `versionCode` 与分架构构建。
6. 编写环境检查、打包和 Gitee 发布脚本。
7. 对齐 GitHub Actions。
8. 完成自动化测试、本地构建和桥接升级演练。
9. 提交 PR，由作者审核并发布桥接版。

## 14. 安全发布结论

本设计不会赋予维护者作者 GitHub 写权限，也不会让本地脚本修改作者 GitHub。维护者只在
明确授权的 Gitee Release 范围内发布二进制附件。作者仍控制源码合并和 GitHub Release。

第一次迁移必须由作者发布桥接版；完成这一步后，维护者即可独立制作、打包并发布 Gitee
版本，软件会默认在应用内从 Gitee 下载更新，并在必要时自动回退作者 GitHub。

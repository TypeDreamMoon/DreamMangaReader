# Android 后台更新下载设计

## 目标

Android 用户确认更新后，由系统前台服务持续下载 APK。关闭更新弹窗、切到后台或 Activity 重建都不能中断任务；下载期间显示系统通知，完成后按 APP 前后台状态进入安装流程。

Windows 继续使用现有 Dart `UpdateDownloader`，不改变其下载和安装行为。

## 当前问题

当前 Android 与 Windows 共用 Dart `Dio` 下载器。下载 Future 由更新弹窗发起，进度和取消状态也保存在弹窗 State 中。Android 切后台、Activity 重建或进程界面被系统回收时，这条链路缺少独立生命周期和系统前台优先级，可能出现 `Connection closed while receiving data`。

现有 `.download` 文件可以在用户手动重试时续传，但下载过程没有系统通知、自动重试、持久任务状态或后台完成后的安装入口。错误文本还可能包含 Gitee 临时下载 URL 的 `token`、`ts` 等查询参数。

## 用户确认的行为

- 检测到新版本时只展示更新弹窗，不自动下载。
- 用户点击“立即更新”后才启动后台任务。
- 下载期间可关闭弹窗或切换到其他 APP，任务继续运行。
- APP 在前台完成下载时，自动打开系统 APK 安装器。
- APP 在后台完成下载时，只显示“更新已下载，点击安装”通知。
- 用户点击完成通知后打开 APP，并立即进入系统安装器。
- 用户主动取消时删除任务和未完成文件；网络中断时保留临时文件用于续传。

## 方案比较

### 采用：原生 Android 前台服务

新增 Android `dataSync` 前台服务，复用零境启动器已经验证的通知、WakeLock、状态持久化、Range 续传和自动重试模式。Flutter 仅负责准备可信下载计划、展示状态和触发安装。

该方案能完整保留 DreamMangaReader 现有的 Gitee/GitHub 双源、ABI 选择、分片附件、大小和 SHA-256 校验协议。

### 不采用：Android DownloadManager

DownloadManager 能提供系统下载通知，但不适合现有的分片逐片校验、最终合并、来源切换和统一错误模型。Gitee 临时地址过期后的重新解析也难与现有更新解析器衔接。

### 不采用：Flutter 后台插件或 WorkManager

后台插件仍需处理 Android 前台服务限制，并引入额外生命周期与版本兼容风险。当前需求只有 Android 需要原生后台能力，跨平台抽象不能抵消复杂度。

## 架构

### Android `UpdateDownloadService`

职责：

- 接收并持久化下载计划。
- 建立低打扰通知通道并进入 `FOREGROUND_SERVICE_TYPE_DATA_SYNC`。
- 持有有时限的 Partial WakeLock，避免下载和校验阶段休眠中断。
- 下载普通 APK 或按顺序下载分片。
- 执行 Range 续传、自动重试、大小与 SHA-256 校验。
- 合并分片并校验最终 APK。
- 校验 APK 包名与当前应用一致。
- 持久化状态，向 Flutter 广播状态变化并更新通知。
- 处理取消、服务重投递和清理。

服务不负责访问 Gitee/GitHub API，也不保存访问令牌。它只消费 Flutter 已解析、已绑定附件的下载计划。

### Android `UpdateDownloadBridge`

职责：

- 注册 Flutter MethodChannel 与 EventChannel。
- 暴露 `startUpdateDownload`、`cancelUpdateDownload`、`getUpdateDownloadState` 和 `installReadyUpdate`。
- Android 13 以上请求通知权限；权限未授予时拒绝启动并返回可读错误。
- 监听服务状态广播并转发给 Dart。
- 判断 Activity 前后台状态。
- 前台进入 `ready` 时通知 Dart 自动安装。
- 处理完成通知带来的启动 Intent；APP 初始化后触发安装。

现有 `MainActivity` 只负责把 Flutter Engine、生命周期和 Intent 交给桥接对象，不承载下载算法。

### Dart `AndroidUpdateBridge`

职责：

- 把 `ResolvedUpdateAsset` 转成平台无关的 JSON 下载计划。
- 支持普通资产与 `parts` 分片资产。
- 将原生状态映射为 Dart 状态模型。
- 提供状态 Stream 和一次性状态读取。
- 把平台错误转成不含敏感 URL 的用户提示。

### 更新弹窗

`UpdateDialogDependencies` 保留可注入边界。生产环境根据平台选择：

- Windows：现有 `UpdateDownloader` 与 `UpdateInstaller`。
- Android：`AndroidUpdateBridge` 启动服务、监听状态并安装已就绪 APK。

弹窗打开时先读取持久状态。若状态属于同一版本和同一 SHA-256，则恢复进度；若状态属于旧版本，则清理旧任务后准备新资产。

下载阶段提供“后台下载”和“取消下载”。“后台下载”仅关闭弹窗；“取消下载”调用服务取消并删除未完成文件。再次打开更新弹窗时显示当前下载、校验、失败或等待安装状态，不重复启动任务。

## 下载计划

下载计划至少包含：

- `schemaVersion`
- `versionName`
- `fileName`
- `sizeBytes`
- `sha256`
- `url`（普通资产）
- `parts[]`（分片资产，每项含 `fileName`、`url`、`sizeBytes`、`sha256`）

服务严格拒绝缺字段、非 HTTPS 地址、非正数大小、非法 SHA-256、文件名路径穿越和总分片大小不匹配。文件名只用于显示和应用私有目录内的安全叶子名称。

## 状态模型

持久状态使用以下有限集合：

- `idle`：没有任务。
- `downloading`：下载普通资产或某个分片。
- `retrying`：连接中断，等待下一次自动重试。
- `verifying`：校验分片或最终 APK。
- `assembling`：合并分片。
- `ready`：APK 已完成并通过校验，等待安装。
- `error`：任务停止，保留可续传文件和脱敏错误。

每个非 `idle` 状态包含任务标识、版本、已下载字节、总字节、百分比和短消息。`ready` 额外包含应用私有 APK 路径。状态写入 SharedPreferences，并通过仅限本应用的广播发送。

## 续传、重试与恢复

- 下载写入 `.download` 临时文件，完成后原子改名。
- 已有临时文件时发送 `Range: bytes=<length>-`。
- `206` 必须包含起点一致的 `Content-Range`。
- 服务器退回 `200` 时从头覆盖临时文件，不能把完整响应追加到旧数据。
- 单个网络步骤最多尝试 3 次，短暂退避后从当前文件长度续传。
- 连接关闭、超时和 5xx 可以自动重试；格式错误、校验错误和大多数 4xx 直接失败。
- Gitee 临时 URL 返回 `401/403` 时标记“下载地址已过期”。用户点击重试后，Dart 重新执行更新检查并取得新 URL，再提交同一 SHA-256 的计划；服务复用已有临时文件。
- 服务被系统终止后使用已保存计划和 `START_REDELIVER_INTENT` 恢复。
- 手机重启后不静默自动下载。用户下次打开 APP 时读取中断状态，并恢复前台服务。

## 完整性与安全

- 每个分片先校验大小和 SHA-256，再参与合并。
- 合并后的 APK再次校验总大小和 SHA-256。
- Android PackageManager 校验归档包名等于当前应用包名。
- 最终安装仍走现有系统未知来源授权和 APK 安装器。
- 原生状态、通知、Dart 错误和日志都不得包含完整下载查询参数。
- 用户可见错误只保留来源、HTTP 状态和简短原因，例如“Gitee 下载地址已过期，请重试”。
- 下载文件保存在应用私有目录；不申请公共存储权限。

## 通知与安装

- 通知通道名称为“应用更新”，重要性为低。
- 下载、重试、校验和合并阶段使用常驻通知，并显示版本和进度。
- 下载通知包含“取消”操作；点击通知打开 APP 的更新状态。
- 失败通知显示脱敏短消息，点击后打开更新弹窗。
- 完成通知显示“版本 x 已下载，点击安装”，点击后打开 APP 并调用 `installReadyUpdate`。
- Flutter Activity 在前台收到 `ready` 事件时直接调用安装。
- 后台服务不能直接拉起安装器，避免违反 Android 后台启动限制。

## 权限与 Manifest

新增或确认以下权限：

- `POST_NOTIFICATIONS`
- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_DATA_SYNC`
- `WAKE_LOCK`

注册非导出的 `UpdateDownloadService`，声明 `foregroundServiceType="dataSync"` 和 `stopWithTask="false"`。不申请电池优化白名单权限，不增加开机广播接收器。

## 测试

### Dart 单元与组件测试

- 普通 APK 和分片 APK 下载计划序列化。
- 非法 URL、SHA-256、大小和文件名在进入原生层前被拒绝。
- 原生状态映射与同任务恢复。
- 弹窗“后台下载”关闭但不取消任务。
- 用户取消会调用原生取消并回到空闲状态。
- 前台 `ready` 自动安装，后台 `ready` 不在 Dart 侧抢先安装。
- Gitee `401/403` 错误触发重新检查版本并使用新 URL。
- 错误提示和日志不包含 URL 查询参数。

### Android 契约与算法测试

- Manifest 权限、前台服务类型和非导出声明。
- MethodChannel/EventChannel 方法和状态字段。
- `206` 续传与 `Content-Range` 校验。
- 退回 `200` 时覆盖旧临时文件。
- 三次重试与已下载字节保留。
- 分片逐片校验、顺序合并和最终校验。
- 用户取消删除计划和临时文件。
- APK 包名不匹配时拒绝进入 `ready`。

### 验证边界

本地运行 Flutter 完整测试、静态分析、格式和差异检查。按照现有协作约定，不恢复已删除的大型 Android 构建缓存，也不在本地打 Windows/Android 安装包。

作者侧必须完成 Android 原生编译和真机验证，包括：前后台切换、锁屏、系统回收服务、通知权限拒绝、断网恢复、完成通知安装以及同签名覆盖安装。

## 非目标

- 不让检测更新自动触发下载。
- 不改变 Windows 更新实现。
- 不新增独立更新下载页面。
- 不在重启后无用户交互地恢复下载。
- 不把漫画、小说或番剧离线下载迁移到该服务。
- 不修改 Gitee/GitHub 发布脚本和清单格式。

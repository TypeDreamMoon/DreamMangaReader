# 打开 App 就自动双向合并(默认开)

> 目标:每次打开 App(冷启动**和**从后台切回)都把云端与本机并集合并一次,本机变更推上去、
> 云端别处的变更拉下来;**本机为空 / 本机这一段没读出来时,绝不清空云端**。

## 1. 起因

用户报「一些收藏漫画丢了」,并且说自己明明开过自动同步。复盘下来有三个各自独立的问题:

1. **默认是关的**。`sync.auto` 只在 SharedPreferences 里存过 `true` 时才开
   (`p.getBool(_kAuto) ?? false`)。而这个键**在应用数据里** —— 重装 / 清除数据 / 换机之后
   它连同 WebDAV 账密一起没了,默认值又把它按回「关」。丢数据的人最需要的恰恰是
   「装回来就有」,却要先知道设置页有这么一个开关。
2. **只管冷启动**。手机上「打开 App」绝大多数是切回前台,进程根本没重启过,启动那一次
   早就跑完了。用户感知到的「我开了啊」和实际发生的「这次打开什么都没做」是两件事。
3. **自动上传是整份覆盖**。`uploadNow` 用 `SyncData.overlay(remote, local)`:本地这一类
   是什么就盖掉云端这一类是什么。本机这一段**读档失败**时(存档 JSON 坏了,
   `LibraryStore` 会按段记 `favoritesLoadFailed`),内存里就是一张空表 —— 覆盖上传
   会把云端收藏清掉;`_snapshot` 的墓碑差分也会把「这次一个都没有」记成「用户全删了」,
   墓碑再把对端一起删。这是在用户没盯着看的时候发生的,也没有任何提示。

## 2. 改动

| # | 位置 | 改动 |
|---|------|------|
| 1 | `sync_controller.dart` `auto` 字段 / `load()` | 默认值 `false → true`;**写过就完全听用户的**(`false` 是一个值,不会被默认值盖回来) |
| 2 | `app.dart` `_AppState` | 挂 `WidgetsBindingObserver`;真的离开过(paused/hidden)再回到前台时,调 `autoSyncOnResume` |
| 3 | `sync_controller.dart` `autoSyncOnResume` / `_autoSync` | 与启动同步同一套逻辑(拉 → 并集合并 → 应用 → 推回),按 `autoSyncMinGap`(2 分钟)节流 |
| 4 | `sync_controller.dart` `uploadNow({mergeInsteadOfCover})` | 自动上传(`_autoUploadCheck`)改走**并集**而非整份覆盖;手动「上传」保持覆盖语义 |
| 5 | `sync_controller.dart` `_unreadableCategories` / `_snapshot` | 「本机这一段根本没读出来」的类别:不参与墓碑差分、也不推;**数据照常合并**,并集结果写回本地反而把这一段修回来 |

### 2.1 为什么自动上传要改成并集

整份覆盖对「用户明确要求:用本机这份盖掉云端」是对的(设置页的「上传」按钮)。
但对**自动**路径是错的:它在用户没看的时候跑,依据是「本机这类现在是什么」——
而本机这份可能只是没加载出来。并集只会让云端变多,不会变少;本机真删掉的条目
仍然靠墓碑传播(`SyncTombstoneGroup`),删除照样删得掉,不存在「删不掉」的倒退。

### 2.2 为什么「没读出来」不能当成「删光了」

`LibraryStore` 读档是**按段**容错的(收藏 / 历史 / 作品进度各一段),坏一段会把原文
备份到 `<key>.corrupt.<ts>` 并把该段标成失败,而内存里留下的是一张空表。
同步层只看得到那张空表,所以必须显式问一句「这一段这次读出来了吗」:

- 墓碑差分跳过该类别 → 不会把云端记录成删除;
- 覆盖上传跳过该类别 → 用户点「上传」也不会清掉云端(状态栏给
  `SyncMessage.localUnreadable`,四种语言都有文案);
- 合并本身照常进行 → 并集结果 = 云端那份,`apply` 写回本地时 `importData` 会清掉
  失败标记,这一段从此又能存了。**数据是修回来的,不是绕过去的。**

### 2.3 触发时机

```
冷启动 → 书架读档完成 → attachAutoUpload → autoSyncOnStart(不节流)
切后台又回来 → AppLifecycleState.resumed → autoSyncOnResume(2 分钟节流)
```

只在**真的离开过**之后才算「打开」:桌面上点回窗口会发 `resumed`,但那不是打开 App。
控制器的 2 分钟最小间隔是第二道闸门(连续切几次只同步一次)。
`configured == false`(WebDAV 地址为空 / 账号未登录)时不会有任何网络行为,
所以「默认开」不会打扰还没配同步的用户。

## 3. 验证

### 3.1 整链测试 `test/sync_auto_merge_test.dart`(13 例)

用内存后端(`debugBackendFactory`)把 `pull → 合并 → 应用 → push` 整条链跑完,
断言**推上去的那份**里云端数据还在 —— 只测纯函数测不到这里。

| 用例 | 断言的不变量 |
|------|--------------|
| 没写过键时默认开 | 丢过数据的人「装回来就有」 |
| 用户明确关掉过 | 关掉是一个值,不被默认值盖回来 |
| 本机为空 + 云端有收藏 | 云端 3 本原样;`favoritesDeleted` 墓碑为空;本机也拿回 3 本 |
| 收藏段读档失败 | 同上,且 `favoritesLoadFailed` 在合并后变回 false(修回来了) |
| 切回前台 | 合并一次;连切三次仍然只拉一次(节流) |
| 关掉 / 没配好 | 0 次网络请求 |
| 自动上传走并集 | 本机为空时云端 3 本原样、无墓碑 |
| 自动上传 + 读档失败 | 该类不推,`pushes == 0`,云端原样 |
| 手动「上传」 | 仍然是覆盖语义(没被顺手改掉) |
| 手动「上传」+ 读档失败 | 拒绝推空的,状态为 `localUnreadable` |
| **装上真 App 外壳,发平台生命周期消息** `hidden → resumed` | 启动那次之后**再合并一次**(证明接线真的接到了控制器) |
| 同上,但只发 `inactive → resumed` | 仍然只有启动那一次(桌面上点回窗口不算「打开 App」) |

最后两例是一组 A/B:同样的外壳、同样的等待,只有生命周期序列不同、结果不同 ——
所以「切回前台会合并」不是碰巧被别的定时器触发的。

### 3.2 设备上的端到端(Android,真 HTTP)

`test/sync_auto_merge_test.dart` 用的是内存后端 —— 证明不了「真 WebDAV 后端 +
真 JSON 序列化 + 真 ETag + 真 SharedPreferences」这一层。所以另有一条跑在模拟器上的:

```
node Scripts/e2e_webdav.mjs 8099          # 宿主机上的极简 WebDAV(只做 MKCOL/GET/PUT + 强 ETag)
flutter test integration_test/sync_auto_merge_test.dart -d emulator-5554
```

一条测试讲完整个用户故事,四步都断言:

| 步骤 | 断言 |
|------|------|
| ① 设备 A 把 3 本收藏同步上云端(真 client、真 HTTP) | 假云端上有 3 本 |
| ② 清掉应用数据(等价重装),只把地址填回来,`SyncController.load()` | `sync.auto == true`(**真 SharedPreferences** 上验证默认开) |
| ③ 打开真 App 外壳:启动链自己合并 | 本机 store 拿到 3 本;**云端仍然 3 本、没有 `favoritesDeleted` 墓碑** |
| ④ 另一台设备再加 1 本 → 发 `hidden → resumed` | 本机变 4 本,云端也还是 4 本 |

实测(UE_pixel_6_API_36 / API 36,`Scripts/e2e_webdav.mjs`,连跑三次都通过):
单次干净运行 `{"mkcol":3,"gets":8,"puts":4,"rejected":0}`,云端最终 `favorites=4` 且无墓碑。

⚠️ 别在**自己的手机上**跑这条:`flutter test integration_test/... -d <设备>` 装的是 debug 签名,
和正式包同一个 `applicationId` —— 签名不匹配会先卸载再装,跑完还会把包卸掉,
手机上的应用数据(书架、同步配置)会一起没。用模拟器。

### 3.3 回归

- `flutter analyze --no-pub` → No issues found
- `flutter test --no-pub` → **1470 passed**(含本次新增 13 例)
- `SyncMessage` 完整性由 `test/sync_messages_l10n_test.dart` 把守:新增的
  `localUnreadable` 在 zh / zh_Hant / en / ja 四种语言下都有文案,且英文界面不出现汉字。
- CI 只跑 `flutter analyze` + `flutter test`(见 `.github/workflows/ci.yml`),
  `integration_test/` 不会被它跑,所以这条真机 E2E 不会把 CI 拖成需要模拟器。

## 4. 明确不做

- **本地库(local media)不参与同步**:它存的是本机路径 / SAF 授权,换台机器没有意义。
  重装后本地库条目要重新导入,这是设计如此,不是这次没做。
- **不自动下载二进制**:同步载荷仍然只有元数据(背景图只带指纹)。
- **不改手动「上传 / 下载」的覆盖语义**:那是用户明确按下去的动作。
- **自动合并失败仍然只在设置页显示**:目前没有全局 toast 通道(没有 `scaffoldMessengerKey`),
  给自动路径加弹窗要动应用根。真要做的话是下一步的事 —— 现在失败会在同步设置页留一条状态。

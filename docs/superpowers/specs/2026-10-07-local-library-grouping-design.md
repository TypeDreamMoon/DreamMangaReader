# 本地库分组建库与重命名（M1.1）

更新时间：2026-10-07
分支：`codex/local-playback`
关系：在 `2026-09-30-local-playback-design.md`（M1）之上的一次行为修正，不改数据模型。

## 问题（实测）

Android 上把一部剧的两集分别加进本地库，得到的是**两张卡、每张 1 个条目**：

```
本地库                                    2 个条目
┌ Loki.S02E06.2160p.mov     1 个条目            ┐
└ Loki.S02E05.2160p.mov     1 个条目 · 02:29    ┘
```

三个原因叠在一起：

1. 每点一次「添加文件」就 `addLibrary` 建一个新库；文件型库的 `path`/`treeUri` 都是空，
   `dedupeKey` 为空 → 不去重（`LocalMediaStore.addLibrary`）。
2. 文件型库的名字在 Android 上取**第一个文件名**（旧 `_nameForPickedFiles`），所以卡片
   标题就是文件名。
3. ⋮ 菜单里只有「重新扫描」「移除库」，**没有重命名、没有合并** —— 加错了只能删了重来。

> 多选本来就是支持的（`EXTRA_ALLOW_MULTIPLE` + clipData，一次多选 = 一个库），
> 但「一次一集地加」这条路会把库越加越多。

## 规则

### 1. 一批条目怎么分库（`groupLocalItemsForLibraries`）

| 条目形态 | 归堆键 | 库名 |
| --- | --- | --- |
| 带季号或集号（剧集） | `series:<归一化剧名>` | 剧名（组内出现最多的那个写法） |
| 没有季集号（散装电影/录音） | `dir:<所在目录>` | 目录名 |

- 归一化 = 小写 + 抹掉空白与常见分隔/包装符号（`Loki` / `loki` / `LOKI-` / `《Loki》` 同键）。
- 组序 = 每组第一条在入参里的先后（Dart Map 的插入序），结果稳定。
- 一次挑两部剧 → 两个库；同一个目录里挑一堆电影 → 一个库（重复从同一目录挑也并进去）。
- 目录名在 SAF 上要**先解码 docId**：`…/document/primary%3AMovies%2Fx.mkv` 里整段
  `primary%3AMovies%2Fx.mkv` 只是**一个**路径段，直接取字符串父目录会得到 `…/document`，
  所有文件都会算成同一个目录（`localParentKey` / `localParentDisplayName` 就是干这个的）。

### 2. 什么时候并入已有库

`addFiles` 逐组处理：先按上面的键在**已有的文件型库**里找同组（键由库里现有条目现算，
所以这次改动之前建的库照样能被认出来），找到就 `applyScanResult` 追进去，找不到才新建。

- 只并**文件型**库：目录型库的内容由「那个目录扫出来什么」定义（§8.4 重新扫描），把目录外的
  文件塞进去会让这份语义变糊。散装散集因此会另开一张卡，由用户自己重命名/移除。
- 并入失败（库刚好被删）不吞掉用户的挑选：提示一句后改成新建。

### 3. 重命名

- 库名：`LocalMediaStore.renameLibrary(id, name)`，只有空白抛 `invalidName`，同名不写盘。
- 条目名：`renameItem(itemId, title)`，存**新增的可选字段** `customTitle`，
  界面统一读 `displayTitle`（用户改过优先，否则用解析出来的 `title`）。
  - 留空、或填回解析出来的原名 → 清掉 `customTitle`（恢复默认）。
  - `applyScanResult` 命中已有条目时**保留** `customTitle` —— 重扫刷新 `title` 不该冲掉
    用户改的名字，这也是当初不直接改 `title` 的原因。
- 展示面：条目列表、播放页标题、选集列表、写进番剧历史的 `episodeName` 全部走
  `displayTitle`；库名进历史的 `title`（改库名只影响之后的记录）。

### 4. 向后兼容

`customTitle` 是可选字段：老索引没这一项时读回 `null`（`displayTitle` 落回 `title`），
索引版本号不变，落盘只在非空时写这一项。

## 不做的（留给 M2/M3）

- 「把条目移动到其它库」「合并两个库」——本次只保证**新加的**不再散开；已有散卡靠
  重命名 + 移除 + 重新添加收拾。
- 剧名之外的启发式：`Show.2019` 与 `Show` 会被当成两部（年份留在标题里是解析器的既定行为），
  跨季合并（`Loki` S01 与 S02 同一个库）属于预期。
- 封面抽帧、时长探测、`ShelfKind.local`、Windows 拖拽导入。

## 测试

- `test/local_series_test.dart`（新增）：归一化键、分组、组名、组序、SAF 目录键与展示名。
- `test/local_library_actions_test.dart`：同剧并卡、一次两部剧两张卡、散装按目录归堆、
  不并进目录型库、改名走 store 并提示。
- `test/local_media_store_test.dart`：改名落盘读回、空白库名拒绝、`customTitle` 的重扫保留
  与清空、老索引兼容。
- `test/local_library_page_test.dart` / `local_library_detail_page_test.dart`：⋮ 菜单改名、
  空库名禁用保存、条目改名后列表跟着变。

# 书签功能设计（Bookmarks）

> 本文是「在喜欢之外增加完整书签闭环」的设计记录与实施基线。
> 所有决策都来自逐轮确认；标 `⚠` 的是风险或刻意取舍，标 `待定` 的是实现阶段仍需验证的事实。

## 1. 目标

X 账号里的**喜欢**与**书签**是两个独立的私有集合（喜欢公开、书签私密）。本 App 目前只覆盖喜欢。
本设计把书签做成与喜欢**同构**的完整闭环：回填、增量、巡边核对、加入/移除、列表浏览、排序、跳转、筛选、搜索、统计、作者维度。

## 2. 决策记录

| # | 决策 | 结论 | 理由 |
|---|---|---|---|
| D1 | 改名范围 | **只改显示名**：`X Shelf` / `xshelf` | 包名一改就是另一个 App，本地数据和登录态全丢；`applicationId` 与数据库文件名永远不动 |
| D2 | 数据模型 | **单表 + `kind` 列，复合主键 `(tweet_id, kind)`** | 作者页一条 SQL 取两边；媒体表与 FTS 按 `tweet_id` 共享，不复制缓存 |
| D3 | 闭环范围 | 回填 / 增量 / 巡边 / 播放页开关 / 卡片状态 / 作者页两段 / 搜索 / 筛选 / 统计 | 用户要求「完整闭环」 |
| D4 | 视图组织 | **不喜欢与书签合并成一个流**；两个独立流 | 两个集合的 `feed_seq` 互不相干，合并需再造跨集合顺序，收益低 |
| D5 | 导航骨架 | 书签是**主页的第二个 Tab**（不 push），布局与功能**镜像喜欢页** | 用户要求「模仿喜欢页」 |
| D6 | 底栏入口 | 默认显示 **喜欢 · 书签 · 搜索 · 设置**（刷视频、Grok 默认隐藏，可在设置里恢复）；书签在「喜欢」右边；沿用 `navTabs`（可排序、可隐藏），隐藏书签时回落喜欢 | 用户指定默认四项 |
| D7 | 卡片书签 | **只显示状态，不可点击**（喜欢也是只读计数） | 保持卡片点击语义单一，避免误触 |
| D8 | 横滑语义 | 横滑先切**排序**；排序到两端时切**来源**；两端**停住**（不循环） | 用户指定；不循环避免随手滑动误切来源 |
| D9 | 排序记忆 | 按 **来源**分别记忆（同滚动位置机制） | 「按发布日期」是看内容的习惯，不该被换来源重置 |
| D10 | 切换动画 | **都做横滑**（排序切列表内容、来源切整页） | 用户指定 |

## 3. 数据模型与迁移

### 3.1 现状

`likes` 表：`tweet_id` 主键，`feed_seq` / `rand_key` / `state` / `created_at` 单维度；`sync_state` 只有一套回填游标；`media` 表按 `(tweet_id, idx)`。

### 3.2 目标 schema（v3）

```sql
-- 迁移策略：重建表（SQLite 改主键只能 copy）
CREATE TABLE items(
  tweet_id     TEXT NOT NULL,
  kind         TEXT NOT NULL,           -- 'like' | 'bookmark'
  account_id   INTEGER NOT NULL DEFAULT 0,
  feed_seq     INTEGER,                 -- 各 kind 独立的加入顺序
  rand_key     INTEGER,
  created_at   INTEGER,
  text         TEXT NOT NULL DEFAULT '',
  lang         TEXT,
  author_id    TEXT,
  author_name  TEXT,
  author_screen_name TEXT,
  author_avatar TEXT,
  media_json   TEXT,
  has_video INTEGER NOT NULL DEFAULT 0,
  has_image INTEGER NOT NULL DEFAULT 0,
  has_gif   INTEGER NOT NULL DEFAULT 0,
  sensitive INTEGER NOT NULL DEFAULT 0,
  reply_to TEXT, quote_of TEXT, retweet_of TEXT,
  state        TEXT NOT NULL DEFAULT 'normal',  -- normal | removed | deleted
  fetched_at INTEGER, verified_at INTEGER, raw_json TEXT,
  PRIMARY KEY (tweet_id, kind)
);
CREATE INDEX idx_items_kind_seq ON items(kind, feed_seq);
CREATE INDEX idx_items_kind_created ON items(kind, created_at);
CREATE INDEX idx_items_kind_state ON items(kind, state);
CREATE INDEX idx_items_author ON items(author_screen_name);

-- 同步状态按 kind 分行（原来 account_id 主键）
CREATE TABLE sync_state_v3(
  account_id INTEGER NOT NULL,
  kind       TEXT NOT NULL,             -- 'like' | 'bookmark'
  top_cursor TEXT, backfill_cursor TEXT,
  min_seq INTEGER, max_seq INTEGER,
  backfill_done INTEGER NOT NULL DEFAULT 0,
  probe_at INTEGER, probe_remote_count INTEGER, rotate_seq INTEGER,
  PRIMARY KEY (account_id, kind)
);
```

- `media` 表**不按 kind 拆分**：同一条推文的媒体无论来自喜欢还是书签都共用一份文件与画质记忆。
- FTS：`likes_fts` 重建为 `items_fts`，行来源是 `items`（同一推文若两边都有也只索引一次，搜索命中后按 kind 分组）。
- 迁移：现有 `likes` 全部落成 `kind='like'`；`sync_state` 落成 `kind='like'` 一行。
- ⚠ 迁移必须包在事务里，并在 `user_version` 递增前完成；老库（v1/v2）都要能升到 v3。

## 4. 同步链路

### 4.1 接口事实

| 操作 | 形态 | 关键点 |
|---|---|---|
| `Bookmarks` | `GET /i/api/graphql/{qid}/Bookmarks?variables&features` | 响应根 `data.bookmark_timeline_v2.timeline.instructions` |
| `CreateBookmark` | `POST /i/api/graphql/{qid}/CreateBookmark`，body `{variables:{tweet_id},queryId}` | queryId 单源、易变 |
| `DeleteBookmark` | 同上，`DeleteBookmark` | 同上 |

- `variables`：`{count, includePromotedContent:false, cursor?}`；feature 需 `graphql_timeline_v2_bookmark_timeline: true`。
- ⚠ `Bookmarks` 的 queryId 不在顶层 bundle，而在懒加载 chunk 里，自动发现可能失败；内置实测值 + 自动发现 + 失败时**只读降级**（不阻塞回填，只是无法写入）。
- 详见 `docs/x-bookmarks-graphql-api.md`。

### 4.2 复用与新增

- `SyncService.backfill / syncNew / 巡边` 全部加 `kind` 参数，游标与 `segments` 按 kind 分开。
- `syncRecent`（从 X 网页返回补齐最近一天）**同时补喜欢与书签**。
- 取消喜欢（unlike）与移除书签（DeleteBookmark）语义分开，互不影响另一边的行。
- 加入书签（CreateBookmark）成功后本地插入 `kind='bookmark'`、分配新 `feed_seq`。

### 4.3 回填入口

- 书签空态：一个「回填书签」按钮（与喜欢空态并列）。
- 设置页：两个独立按钮（回填喜欢 / 回填书签），分别显示进度。

## 5. UI 结构

### 5.1 主页

```
AppBar: 标题 + 总数（跟随当前来源） + 跳转按钮（书签也支持按位置/日期跳转）
  └ 排序 Tab：喜欢顺序/书签顺序 · 发布日期 · 随机（文案随来源切换）
body: 两页（喜欢 / 书签）
底栏: 默认「喜欢 · 书签 · 搜索 · 设置」；刷视频、Grok 默认隐藏，可在设置里恢复（全部项可排序、可隐藏，「设置」固定）
```

- 总数与跳转跟随当前来源；`mode.likeOrder` 文案按来源显示「喜欢顺序」或「书签顺序」。
- 视图状态（排序档、滚动位置）按 `(source, mode)` 两维记忆。
- 横滑手势：先切排序（列表内容横滑）；在首档右滑 / 末档左滑时切来源（整页横滑），两端停住。

### 5.2 播放页

- 右侧动作栏：头像 / 喜欢（大）/ **书签** / 在 X 打开。
- 书签按钮：`bookmark_border` ↔ `bookmark`，切换时调用 Create/Delete，失败回滚并提示。

### 5.3 卡片

- 显示书签状态（只读小图标或角标），不提供点击；与现有只读计数 chip 一致。

### 5.4 作者页

- 两个 Tab：我喜欢的 / 我加入书签的，各自独立分页。
- 空态分别提示。

### 5.5 搜索与筛选

- `LikesFilter` 增加 `source`（like / bookmark / all）；搜索页与筛选面板默认作用于当前来源。
- 本地全文搜索：对 `items` 查询，结果标出来源。
- X 全网搜索不受影响。

## 6. 改名

- 显示名：`X Shelf`（Android `android:label`、Windows 窗口标题/产品名、README、GitHub 仓库名）。
- Dart 包名与 `applicationId`（`app.xlikemanage`）、数据库文件名**保持不变**。
- 文案：`nav.browse` 保持「喜欢」，新增 `nav.bookmarks`「书签」；`list.title` 按来源切换。

## 7. 实施分期

| 里程碑 | 内容 | 可验证产物 |
|---|---|---|
| M1 数据层 | v3 schema 迁移、items/kind、FTS 重建、sync_state 分 kind | 迁移测试（v1→v3、v2→v3）+ 现有 97 测试通过 |
| M2 读 | `fetchBookmarks` 解析、回填、增量、巡边、syncRecent 双补 | 解析测试（合成夹具）+ 回填集成 |
| M3 写 | Create/DeleteBookmark、播放页按钮、失败回滚 | 单测 + 真机 |
| M4 UI | 主页两页、手势分层、底栏入口、作者页 Tab、卡片状态、统计 | 组件测试 + 真机 |
| M5 搜索筛选 | source 维度、文案、空态 | 测试 |
| M6 改名与文档 | X Shelf 显示名、README、发布 | 构建产物 |

## 8. 风险与未决

- ⚠ **bookmarks queryId 易变**：写入靠单源实测值，失效后只能回填不能添加；需要设置页提供「手动填写 queryId」的兜底。
- ⚠ **两级横滑都做横滑动画**（D10）：排序与来源切换视觉语言相同，可能分不清。缓解：时长与位移区分（排序 160ms 小幅、来源 240ms 整页），并让顶部 Tab 高亮同步变化。
- ⚠ **复合主键迁移**：SQLite 不能改主键，必须 copy 重建；迁移失败要有回滚路径（事务 + user_version）。
- 待定：X 书签是否对「评论/转推」这类条目也返回（与 Likes 的 entry 类型差异），需真机抓一次确认。
- 待定：`CreateBookmark` 是否需要 `x-client-transaction-id` 签名（第三方客户端有分歧），需实测。

## 9. 实施记录（2026-10）

- **M1 数据层**：`user_version` 升到 3。`likes` 表**保留原名**（对既有 SQL 零改动），加 `kind` 列、主键改 `(tweet_id, kind)`，并重建 `sync_state`（主键 `(account_id, kind)`）与 `segments`（加 kind）。迁移在单个事务里，失败 ROLLBACK。`test/migration_test.dart` 覆盖 v1→v3、v2→v3 与「升降之后能写书签」。
- **M2 读**：`likes_parser` 抽出 `_parseTimelinePage`，新增 `parseBookmarksPage`（`bookmark_timeline_v2` 与旧名 `bookmark_timeline` 都认）；`x_client.fetchBookmarks` 不带 `userId`、features 带 `graphql_timeline_v2_bookmark_timeline`；`SyncService.backfill/syncNew` 加 `kind`；`syncRecent` 同时补喜欢与书签。
- **M3 写**：`CreateBookmark`/`DeleteBookmark`（POST）；本地已有就 `restoreLike`，没有就插一条带**书签自己 seq** 的记录；移除走 `markRemoved`（可撤回）。
- **M4 UI**：主页是两个 `_SourceList`（各自 `BrowseState`）/`PageView` 承载，横滑先切排序、到边界切来源、两端停住；底栏默认「喜欢 · 书签 · 搜索 · 设置」；播放页动作栏加书签按钮；卡片显示只读书签标记；作者页两个 Tab；总数跟随来源。
- **M5 搜索**：本地搜索加「喜欢 / 书签 / 全部」来源分段，条件面板不碰来源维度。
- **M6 改名**：显示名改为 `X Shelf`（Android label、Windows 窗口标题与产品名、README）；`applicationId`、Dart 包名、数据库文件名**保持不变**。

真机（OnePlus 7T，无线 adb）验证：
- 旧库（4119 条喜欢）升级到 v3 后数量与内容都在；
- 底栏四项正确；书签页空态与「回填书签」正常；
- 书签回填执行无报错（该账号当前 0 条书签，故结果为 0）；
- 修复了两处真机才暴露的问题：书签页总数误用喜欢计数、书签回填确认框复用了喜欢文案。

未验证：加入/移除书签的网络写回（需要一条真实书签做样本）、bookmarks queryId 失效后的手动兜底入口（尚未实现，见 §8）。


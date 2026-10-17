# xlikemanage — 设计文档

> 状态：已与用户确认（v1）。实现中以此文档为准；改动须先改这里。
> 暂定名 `xlikemanage`，Android applicationId `app.xlikemanage`，MIT，中英双语（默认中文）。

## 1. 产品定义

把 X（Twitter）账号里的**全部喜欢**抓进本地库，以媒体网格 + 双栏播放器的方式浏览、按时间/类型/作者/全文检索，能逐条取消喜欢。一套 Flutter 代码出 Windows exe 与 Android apk，本地优先、离线可看。

**不做**：批量取消、重新喜欢、标签/笔记/收藏夹/书签、导出/备份、官方 API 通道、多账号。

## 2. 已锁定的决定

| 维度 | 决定 |
|---|---|
| 取数通道 | 登录态直连 X 网页 GraphQL（`Likes`）；官方 API 不用；X 数据归档降级为可选 ID 索引、后置 |
| 技术栈 | Flutter 单工程（Windows + Android） |
| 播放器 | Windows `media_kit`(libmpv)；Android `video_player`(ExoPlayer) |
| 写操作 | 仅「单个取消喜欢」，取消即删本地记录（不做批量、不做重新喜欢） |
| 账号 | 单账号，`account_id` 字段预留多账号 |
| 登录 | 内嵌 WebView（Windows WebView2 / Android WebView）登录取 `auth_token`+`ct0`；`flutter_secure_storage` 存储；**失败回退手动粘贴 cookie** |
| 代理 | 默认跟随系统代理（WinINET/环境变量），可手动填 HTTP / SOCKS5（含认证）；视频共用；设置页带连通性自检 |
| 媒体 | 仅 X 原生媒体，外链用浏览器打开；图片 + 视频离线缓存，上限 5GB 可调，LRU，可改存储目录 |
| 播放器功能 | 进度条 / 音量 / 静音 / 0.5–2× / 全屏 / 上下切换 / 循环 |
| 布局 | 桌面双栏（左网格 + 右播放/详情）、手机单列；断点 600 / 1000dp；主题跟系统 |
| 卡片 | 图为主，悬停/长按出信息；纯文字用排版卡片；敏感内容不模糊 |
| 时间轴 | 三模式：A 喜欢顺序 + 估算时间标签（默认）、B 按推文发布日期精确轴、C 随机（稳定随机键 + 手动洗牌） |
| 筛选 | 媒体类型 / 作者 / 发布日期范围 / 全文搜索（FTS5 trigram） |
| 同步 | 单「巡边器」调度器，见 §4 |
| 删除语义 | 作者删推 → 保留记录与已缓存媒体，标「已删除」；自己取消喜欢 → 删本地记录 |
| 位置记忆 | 视图模式 + 筛选条件 + 滚动锚点 + 当前选中/播放条 |
| 接口长寿性 | 内置 queryId + 运行时从 x.com 前端 JS 自动提取 + 失效明确提示 |
| 打包 | Windows：Inno Setup 安装包 + 便携 zip；Android：自签 release APK（keystore 本地、不入库） |
| 目标 | Win10 1809+ / Android 8.0+（minSdk 26）；≤5 万条 |
| 仓库 | 本地 `git init`，公开仓库发布时再建 |

## 3. 关键事实（来自调研，删改前请复核）

1. `data/like.js`（X 数据归档）**只有 tweetId + 文本**，无作者、无媒体、无时间戳 —— 不能当媒体数据源。
2. X **不提供「我什么时候喜欢的」**。GraphQL Likes 返回的是推文对象（`created_at` 是推文发布时间），列表整体按喜欢时间倒序。时间轴因此只能是 §5 的三模式。
3. `Likes` GraphQL：`GET /i/api/graphql/<queryId>/Likes`，需 `auth_token` + `ct0` + `x-csrf-token` + web Bearer，`count` 最大 100，cursor 翻页。
4. queryId 随 X 前端发版轮换，必须运行时发现。
5. 媒体 CDN（`pbs.twimg.com` / `video.twimg.com`）无需登录态，mp4 变体优先，HLS 兜底。
6. ToS：离线副本须在被 X 或账号主请求后 24h 内删除/更新 —— 与本地缓存设计冲突，README 声明风险。
7. 登录态直连属非公开接口，**可能触发风控或封号**，自用风险自担。

## 4. 同步：单巡边器（Reconciler）

不给每种触发写一套逻辑，而是把「首次回填 / 增量 / 滚动核对 / 自动同步」统一成**给同一个调度器投请求预算**。

**状态**：本地库按喜欢顺序切成 200 条一段的「区段」（`segments`），每段记 `verified_at`；每条 `likes` 记录也记 `verified_at`。系统里没有「同步模式」概念，只有「哪些段脏了」。

**调度器**：令牌桶限流（默认每分钟 ≤4 请求），四个任务源按优先级取任务：

| 任务源 | 行为 | 触发 |
|---|---|---|
| 1 顶部新增 | 从最新翻到已知锚点即停（增量） | 手动刷新 / 自动同步 |
| 2 视口核对 | 停留 ≥1.5s 且该段 24h 未验 → 拉该段 1–2 页比对，插队 | 滚动 |
| 3 陈段轮转 | 最久未验证的段，最低优先级，每轮顺带 1 页 | 常驻 |
| 4 计数探针 | 1 请求比对 X 的 likes 总数与本地条数；有漂移才给任务源 3 加权 | 每 24h 最多 1 次 |

**用户入口 = 投预算**：首次回填（大预算长任务，游标落库、可暂停续传）、手动刷新/自动同步（定时投预算，受时间范围与单次条数上限约束）、滚动停留（一次高优先级小预算）。

**区段比对规则**：X 返回的顺序与内容即真相。段内缺失的条目 → 标 `removed`（已取消喜欢）并删除（按 §2 语义）；多出的 → 插入；状态变化 → 更新 `verified_at`。

**自动同步面板**：开关、间隔（15/30/60 分 / 6 / 24 小时）、时间范围（不限 / 最近 7 天 / 30 天）、单次条数上限（默认 500）。默认**关**，启动时不自动拉。Android 上自动同步**仅前台生效**；用户手动发起的那次允许后台继续（前台服务）。

## 5. 时间轴三模式

- **A（默认）喜欢顺序 + 估算时间标签**：顺序 = X 的喜欢顺序；区段刻度标签取该段推文发布日期中位数，标「约 2023 年 5 月」；跳转按序号，**跳转精确、标签是估算**。
- **B 按推文发布日期**：`ORDER BY created_at DESC`，时间轴为精确年月分段。
- **C 随机**：每条入库分配 64 位稳定 `rand_key`，`ORDER BY rand_key` 分页不跳条；头部「重新洗牌」按钮批量重排；随机模式下隐藏时间轴。

筛选与排序都落到 SQL；三种模式共用同一套网格与播放器。

## 6. 数据模型（SQLite via drift + sqlite3_flutter_libs）

```
accounts(id, x_user_id UNIQUE, screen_name, display_name, avatar_url)
likes(tweet_id PK, account_id, feed_rank, rand_key, created_at, text, lang,
      author_id, author_name, author_screen_name, author_avatar,
      media_json, has_video, has_image, has_gif, sensitive,
      reply_to, quote_of, retweet_of, state(normal|removed|deleted),
      fetched_at, verified_at, raw_json)
media(id PK, tweet_id, kind(image|video|gif), url, variants_json, width, height,
      duration_ms, alt_text, local_path, bytes, last_used_at)
segments(id PK, account_id, start_rank, end_rank, cursor, verified_at)
sync_state(account_id PK, top_cursor, top_anchor_rank, bottom_rank,
           probe_count, probe_at, autosync_json)
likes_fts  -- FTS5(text, author_name, author_screen_name) tokenize='trigram'
```

索引：`likes(feed_rank)`、`likes(created_at)`、`likes(rand_key)`、`likes(state)`、`media(tweet_id)`、`media(last_used_at)`。

## 7. UI 结构

- **桌面（≥1000dp）**：顶部工具条（搜索/筛选/模式切换/刷新）｜左媒体网格（右侧竖向可拖时间刻度，顶部年月下拉）｜右播放/详情栏。
- **平板（600–1000dp）**：网格 + 覆盖式详情。
- **手机（<600dp）**：单列网格 + 底部导航（浏览/搜索/设置），详情全屏、手势上下切换。
- **快捷键（桌面）**：空格播放/暂停、J/K 上下条、Esc 退出播放、`/` 聚焦搜索。
- **启动恢复**：上次视图模式 + 筛选 + 滚动锚点 + 选中条。

## 8. 里程碑

| # | 内容 | 完成标准 |
|---|---|---|
| M0 | 环境：E:\dev 装 Flutter → VS C++（需管理员）→ JDK/Android SDK | `flutter doctor` 双端通过 |
| M1 | 脚手架：`flutter create` + 依赖 + 主题 + 三档断点空壳 | 双端能跑空白壳 |
| M2 | 登录：WebView 抓 cookie + 安全存储 + `Viewer` 校验 + 粘贴回退 | 能看到自己头像/用户名 |
| M3 | 数据层：schema、迁移、FTS、区段表 | 单测通过 |
| M4 | 取数：GraphQL 客户端 + queryId 发现 + Likes 翻页 + 进度 + 续传 | **垂直切片**：拉 100 条上屏 |
| M5 | 网格与播放：缩略图、全屏详情、双端播放器、手势、位置恢复 | 播一个视频并重开回原位 |
| M6 | 时间轴三模式 / 筛选 / 搜索 | 三种模式可切 |
| M7 | 巡边器 + 自动同步面板 + 代理 + 连通性自检 | 滚动触发核对可见 |
| M8 | 取消喜欢 + 删除语义 + 媒体缓存 LRU | 取消后本地消失 |
| M9 | 打包：Inno Setup、便携 zip、APK 签名、图标、i18n、README | 双端安装包可装 |
| M10 | 打磨：5 万条滚动性能、错误页、暗色、快捷键 | — |

## 9. 默认掉的小项

- 图片取 `name=large`，详情页按需 `orig`；视频取最高质量 mp4 ≤1080p，HLS 兜底。
- 自动同步默认关；启动不自动拉。
- 单轮核对 1–2 页；计数探针每 24h ≤1 次；调度器每分钟 ≤4 请求。
- 随机洗牌仅手动触发。
- 无导出/备份（无用户自产数据）。

## 10. 风险

1. 登录态直连可能触发风控甚至封号。
2. queryId 轮换导致接口失效。
3. X 可能拒绝 WebView 内登录（已留手动粘贴回退）。
4. ToS 24h 删除要求与本地缓存冲突（README 声明）。
5. Android 仅系统 HTTP 代理（非 TUN）时部分请求可能漏，推荐 TUN 全局。
6. Windows 原生构建需 VS C++（需管理员权限）。

## 11. 实现现状与设计偏差（持续更新）

实现过程中对设计做了这些调整，均已落到代码：

| 项 | 设计 | 实现 | 原因 |
|---|---|---|---|
| 喜欢顺序的键 | `feed_rank`（位置） | **`feed_seq`（首次入库时分配，间隔 `10^6` 递减）** | 位置会随新增喜欢整体下移，导致分页跳条、区段错位；间隔留白让「视口核对」能把漏抓的条目插回中间（`seqBetween` 取中点） |
| 区段登记 | `segments(start,end,cursor)` | 回填每进入一个新区段就登记 `cursor = page.topCursor` | 巡边器要能重新翻到任意区段 |
| 巡边器 | 四类任务源 | 已实现 **视口核对 + 陈段轮转**；计数探针留 TODO（需要服务端 likes 总数，X 暂未给稳定字段） | — |
| 代理 | HTTP + SOCKS5 | **只实现 HTTP**；SOCKS5 会给出「暂不支持，请用 TUN」的提示 | `dart:io` 不支持 SOCKS，需要本地桥接，排在 M7 |
| 媒体缓存 | 5GB LRU | `MediaCache` 已实现（按需下载 + `evictMediaCache`），UI 只接了「清空/上限」 | 播放当前走在线流 |
| 状态管理 | 未指定 | 单个 `AppController extends ChangeNotifier` + `AppScope`（InheritedNotifier） | 依赖少、审起来快 |
| 数据库层 | 未指定 | `package:sqlite3` 手写 SQL（不用 ORM/codegen） | 改起来快、无生成步骤 |
| 构建环境 | 本机装全套 | Flutter/JDK/Android SDK 装在 `E:\dev`；Gradle 走阿里云镜像；**VS C++ 需管理员，待用户执行 `tool/setup_admin.ps1`** | 无提权能力 |

**坑（写给未来的自己）**：
- 8GB 内存机器上，Flutter 模板默认 `-Xmx8G` 会让 JVM malloc 失败 → 已在 `android/gradle.properties` 收到 2G。
- `packages/flutter_tools/gradle/settings.gradle.kts` 是独立的 includeBuild，且 `FAIL_ON_PROJECT_REPOS`，只能改它本身（`tool/patch-flutter-sdk-mirrors.ps1`）；`flutter upgrade` 会覆盖。
- `.ps1` 脚本必须带 UTF-8 BOM，否则 Windows PowerShell 5.1 会把中文当 ANSI 解析失败。
- 用 PowerShell 批量改 Dart 源文件会破坏 UTF-8（必须 `[System.IO.File]::ReadAllText(path, UTF8)` + `WriteAllText(..., UTF8Encoding($false))`），我因此重写过一个 1000 行文件。


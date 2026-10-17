# X 网页 GraphQL `Likes` 接口备忘

实现取数时的参考。**这里的一切都可能随 X 前端改版而失效**，失效时要更新本文档与代码。

## 1. 请求

```
GET https://x.com/i/api/graphql/{queryId}/Likes
```

Query 参数（URL 编码的 JSON）：

- `variables`:
  ```json
  {
    "userId": "<数字 id>",
    "count": 20,
    "cursor": "<翻页游标，可为空>",
    "includePromotedContent": false,
    "withClientEventToken": false,
    "withBirdwatchNotes": false,
    "withVoice": false,
    "withV2Timeline": true
  }
  ```
  `count` 上限 100（用 100 能省最多请求）。
- `features`：一大坨开关，见 §5。
- `fieldToggles`：`{"withArticlePlainText": false}`

请求头：

| Header | 值 |
|---|---|
| `authorization` | `Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA`（公开 web bearer） |
| `x-csrf-token` | 即 `ct0` cookie |
| `x-twitter-auth-type` | `OAuth2Session` |
| `x-twitter-active-user` | `yes` |
| `cookie` | `auth_token=...; ct0=...` |
| `content-type` | `application/json` |
| `referer` | `https://x.com/` |
| `user-agent` | 桌面 Chrome UA |

## 2. queryId 发现

X 的 `main.<hash>.js` 里每个操作都有 `{queryId:"<id>",operationName:"Likes",...}` 三元组。

1. `GET https://x.com/` → 从 HTML 抓 `https://abs.twimg.com/responsive-web/client-web/main.<hash>.js`（可能有多个 chunk，全部抓）。
2. 在 JS 文本里用正则找 `queryId:"([A-Za-z0-9_-]{15,})",operationName:"Likes"`（顺序可能是 `operationName` 在前，两种都试）。
3. 带缓存：成功过的 queryId 存本地，失效（HTTP 404 / 400 `errors`）才重新发现。
4. 全部失败 → UI 明确提示「接口已变更，请更新版本」。

## 3. 响应结构（关键路径）

```
data.user.result.timeline_v2.timeline.instructions[]
├─ { type: "TimelineAddEntries", entries: [
│     { entryId: "tweet-123", content: { entryType: "TimelineTimelineItem",
│        itemContent: { itemType: "TimelineTweet",
│          tweet_results: { result: <Tweet> } } } },
│     { entryId: "cursor-bottom-...", content: { entryType: "TimelineTimelineCursor",
│        cursorType: "Bottom", value: "<下一页游标>" } }
│   ] }
└─ { type: "TimelineReplaceEntry", ... }        // 忽略
```

`<Tweet>` 可能是：

- `__typename: "Tweet"` → 正常，字段在 `legacy`
- `__typename: "TweetWithVisibilityResults"` → 真实内容在 `.tweet`
- `__typename: "TweetTombstone"` → **推文已删除**，要把本地对应条目标 `deleted`

## 4. 字段映射

| 目标 | 路径 |
|---|---|
| tweet_id | `rest_id` |
| 正文 | `note_tweet.note_tweet_results.result.text`（长推文优先），否则 `legacy.full_text` |
| 发布时间 | `legacy.created_at`（`Wed Oct 10 20:19:24 +0000 2018`，需按该格式解析） |
| 语言 | `legacy.lang` |
| 是否敏感 | `legacy.possibly_sensitive` |
| 回复/引用/转推 | `legacy.in_reply_to_status_id_str` / `legacy.quoted_status_result.result.rest_id` / `legacy.retweeted_status_result.result.rest_id` |
| 作者 | `core.user_results.result` → `rest_id`、`core.screen_name`、`core.name`、`avatar.image_url` |
| 媒体列表 | `legacy.extended_entities.media[]`（无则 `legacy.entities.media[]`） |
| 媒体类型 | `media[i].type`：`photo` / `video` / `animated_gif` |
| 图片 URL | `media_url_https`（加 `?name=large`，详情页用 `?name=orig`） |
| 视频变体 | `video_info.variants[]`：`{bit_rate, content_type, url}`；优先 `video/mp4` 且 `bit_rate` 最大、分辨率 ≤1080p；仅 `application/x-mpegURL` 时存 HLS |
| 时长 | `video_info.duration_millis` |
| 宽高 | `original_info.width/height` |
| 替代文本 | `ext_alt_text` |

`favorited`（`legacy.favorited`）可以用来兜底判断状态，但**不要依赖它**——它是请求时刻的快照。

## 5. features 开关

一坨布尔开关（`rweb_video_screen_enabled`、`longform_notetweets_consumption_enabled`…）。策略：

1. 内置一份基线（本仓库 `lib/features/sync/graphql_features.dart`）。
2. 请求失败且错误里提到未知/缺失的 feature 时，退化到**最小集合**重试一次。
3. 远程覆盖（GitHub raw JSON）作为后续增强——不改 app 就能修。

## 6. 用户 id

- 优先：调用 `Viewer` 查询拿 `data.viewer.user_results.result.rest_id`。
- 兜底：从 `twid` cookie 解析（`twid=u%3D<数字id>`）。

## 7. 限流与节奏

- 未公开限流，社区实践约 **2 秒/请求**安全。默认调度器预算：每分钟 ≤4 请求。
- 429 时按 `x-rate-limit-reset` 退避；连续 3 次失败暂停并在 UI 提示。
- 命中 403/401：多半是 cookie 失效或被风控 → 提示重新登录。

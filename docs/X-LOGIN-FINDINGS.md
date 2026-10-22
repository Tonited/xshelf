# X 登录 / 取数接口实测记录

> 记录时间：2026-10-18。环境：Windows + 系统 Chrome 155（CDP 驱动）+ 本地代理 `127.0.0.1:7897`。
> 这些是**实测结果**，不是推测；X 改版后需要重新核对。

## 1. 登录页已改版

- `/i/flow/login` 会 302 到 `https://x.com/i/jf/onboarding/web?mode=login`。
- 旧选择器 `[data-testid="ocfEnterTextTextInput"]`、`ocfEnterTextNextButton` **全部失效**。
- 新页面结构：
  - 账号框：`input[name="username_or_email"]`（id `jf-input-username_or_email`）
  - 密码框：`input[name="password"]`
  - 按钮只有文字「继续」，**没有 data-testid**
- 三个入口：「使用手机继续」「通过 Google 继续操作」「使用 Apple 继续」。

## 2. 「通过 Google 继续」链路（已跑通）

1. 点击必须用**真实鼠标事件**（CDP `Input.dispatchMouseEvent`）。
   `el.click()` 不产生用户激活，`window.open` 会被 popup blocker 直接吞掉 —— 表现就是「点了没反应」。
2. 启动参数需要 `--disable-popup-blocking`。
3. 弹出 `accounts.google.com/v3/signin/identifier?...`，`client_id=49625052041-...`（X 的 GIS SDK，
   `response_type=id_token`、`redirect_uri=gis_transform`）。
4. 流程：输入邮箱 → 下一步 → `challenge/pwd`（密码框 `input[name="Passwd"]`）→
   `signin/oauth/v3/consent`（点「继续」）→ 弹窗自动关闭。
5. **密码正确时不会有任何成功提示**，直接就进 consent；consent 之后弹窗关闭，
   CDP 连接会断开 —— 这不是失败，别把 `Runtime.evaluate` 超时当成错误。
6. 成功后 x.com 的 cookie 里出现 `auth_token` + `ct0` + `twid`（`twid` 形如 `u%3D<userId>`）。
7. 反检测要点：`--disable-blink-features=AutomationControlled` +
   页面加载前注入 `navigator.webdriver = undefined`。否则 Google 会判定「浏览器或应用可能不安全」。

## 3. `verify_credentials` 已下线（登录失败的主要根因）

| 端点 | 结果 |
|---|---|
| `/i/api/1.1/account/verify_credentials.json` | **404** `code 34 Sorry, that page does not exist` |
| `/i/api/1.1/account/settings.json` | 404 |
| `/i/api/2/account/settings.json` | 404 |
| `/i/api/1.1/users/show.json` | 403 Cloudflare 挑战页 |

**替代方案：GraphQL `Viewer`。** 返回 `data.viewer.user_results.result`，含
`rest_id`、`core.screen_name`、`core.name`、`avatar.image_url`。
`app` 里的 `XClient.verify()` 已改为调它。

## 4. 裸 HTTP 抓 x.com 首页会被 Cloudflare 挡

- `GET https://x.com/home`（带完整 cookie 也一样）→ **403 `Just a moment...`**。
- 所以 app 里「抓首页 HTML → 解析 client-web JS → 正则找 queryId」的自动发现通道
  **基本失效**：它第一步就 403。
- 对策：内置 fallback queryId（见 §5）；发现逻辑保留但只作补充，且必须容错。

## 5. 现行 queryId（来自 `main.50f2837e51ebc2a7a.js`）

| 操作 | queryId |
|---|---|
| Viewer | `TpQxQtWMTMnIAMPlMGMqNw` |
| Likes | `mu4us66Q6RRNOywVQhGtRg` |
| UnfavoriteTweet | `ZYKSe-w7KEslx3JhSIk5LA` |
| UserByScreenName | `AMIBMjtxEEATh4z8V9GtRg` |
| FavoriteTweet | `lI07N6Otwv1PhnEgXILM7A` |
| HomeTimeline | `svLglq6U2wlTyZMGDDcLYQ` |

对应代码里的 `kFallbackQueryIds`。**X 发版会轮换这些值**，过期了就更新这张表。

## 6. Likes 响应结构（解析不到数据的根因）

- 指令路径：`data.user.result.timeline.timeline.instructions`
  —— **多了一层 `timeline`**，且不再有 `timeline_v2`。
- 作者信息：`tweet.core.user_results.result.core.screen_name` / `.core.name` /
  `.avatar.image_url`；`legacy.screen_name` 已经不存在了。
- 正文仍在 `tweet.legacy.full_text`；媒体在 `legacy.extended_entities.media`。
- Like 页 URL 是 `https://x.com/i/history/likes`（访问 `/<sid>/likes` 会被重定向过去）。

## 7. 复现脚本

仓库里保留了**与个人账号无关**的复现工具：

| 脚本 | 用途 |
|---|---|
| `xhttp.js` | 走本地代理的最小 HTTP 客户端（**必须按字节解 chunked**，否则中文会截坏） |
| `find_queryids.js` | 在浏览器上下文里扫 client-web JS，提取 queryId（裸 HTTP 会被 CF 挡） |
| `probe_endpoints.js` / `probe_home.js` / `probe_proxy.js` | 探测各 endpoint 与代理连通性 |

登录流程的自动化脚本（自动填账号密码、经 CDP 驱动浏览器走完登录流程、验证会话）**没有入库** ——
它们不可避免要接触真实凭据，不适合分发。本文档前面几节记录的现象和步骤已足够自行复现。

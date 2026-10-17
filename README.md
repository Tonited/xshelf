# xlikemanage

把 X（Twitter）账号里的**全部喜欢**抓进本地，以媒体网格 + 播放器的方式浏览、按时间/类型/作者/全文检索，并能逐条取消喜欢。
一套 Flutter 代码，同时产出 Windows 桌面版与 Android APK。本地优先，离线可看。

> 设计细节见 [docs/DESIGN.md](docs/DESIGN.md)。

---

## 中文

### 它做什么

- 登录你自己的 X 账号，一次性把喜欢列表**全量回填**到本地数据库（5 万条约 20 分钟，可暂停续传）。
- 网格浏览：图片 / 视频 / GIF / 纯文字推文，悬停或长按看作者与正文。
- 播放：全屏 + 手势上下切换 + 0.5–2× 倍速 + 循环 + 离线缓存。
- 时间轴三模式：**喜欢顺序**（默认，带估算时间标签）、**按发布日期**（精确年月跳转）、**随机看**。
- 筛选：媒体类型 / 作者 / 发布日期范围 / 全文搜索。
- 管理：逐条取消喜欢（同步回 X，并从本地移除）。
- 记住上次的位置：视图模式、筛选、滚动位置、正在看的那条。

### 怎么跑起来

需要 Windows 10 1809+ 或 Android 8.0+。

```powershell
flutter pub get
flutter run -d windows     # 或 -d <android-device-id>
```

出安装包：

```powershell
# Windows：安装包 + 便携版（需要 Inno Setup 6）
.\tool\build_windows.ps1
# Android：自签 release APK
.\tool\build_apk.ps1
```

### 开发环境（本机约定）

工具链统一装在 E 盘，不占系统盘：

| 组件 | 路径 |
|---|---|
| Flutter SDK | `E:\dev\flutter` |
| Git（便携版） | `E:\dev\git` |
| JDK 17 | `E:\dev\jdk\jdk-17.0.20.1+1` |
| Android SDK | `E:\dev\android-sdk` |
| Gradle 缓存 | `E:\dev\gradle` |

```powershell
. .\tool\env.ps1        # 把上面这些塞进当前会话的 PATH
flutter doctor
```

- **Windows 桌面构建需要管理员装一次 VS C++ 生成工具**：
  `powershell -File .\tool\setup_admin.ps1`（同时打开开发者模式）。
- 国内网络：`tool\patch-flutter-sdk-mirrors.ps1` 把 Flutter SDK 自带子构建的仓库换成阿里云镜像；
  本机 Gradle 还配了 `E:\dev\gradle\gradle.properties` 走本地代理。`flutter upgrade` 后需要重跑一次补丁脚本。
- 内存 8GB 的机器务必保持 `android/gradle.properties` 里的 `-Xmx2048m`，模板默认的 8G 会让 JVM 直接崩。

### 实现方式

登录后用 WebView 拿到 X 的会话 cookie，直接调用 X 网页端自己的 GraphQL `Likes` 接口翻页取数，写进本地 SQLite；媒体走 `pbs.twimg.com` / `video.twimg.com` 公开 CDN，按需缓存。同步由一个「巡边器」统一调度：首次回填、增量更新、滚动到某区域时的顺手核对、以及后台慢速轮转核对，全部只是给同一个请求预算队列投任务。

### ⚠️ 风险声明（务必读）

1. **本项目使用 X 的非公开网页接口**，不是官方 API。这不被 X 的开发者协议允许，**可能导致账号被限流、风控甚至封禁**。请自行评估，建议只使用自己的账号。
2. 项目**不会**上传你的任何数据；所有喜欢、cookie、媒体都只存在本机。cookie 用系统钥匙串/DPAPI/Keystore 加密保存。
3. X 的接口随前端改版会变（queryId 轮换）。项目会尝试自动重新发现，仍可能失效，届时需要更新版本。
4. X 的开发者条款要求：其内容的离线副本在被 X 或内容所有者要求后 24 小时内删除或更新。本项目的本地缓存设计不满足这一条，这属于个人使用的边界地带，请自行判断。
5. 在中国大陆使用需要自备代理。默认跟随系统代理，也可在设置里手动填写 HTTP/SOCKS5 代理；Android 上推荐使用 TUN/全局模式的代理，否则部分请求可能绕过。

## English

Browse **all of your X (Twitter) likes** locally: media grid plus player, filter by time / media type / author, full-text search, and unlike individual posts. One Flutter codebase targets Windows desktop and Android; local-first and works offline once cached.

### What it does

- Sign in with your own X account and backfill your entire likes timeline into a local database (≈20 min for 50k items, resumable).
- Media grid: images, videos, GIFs and text-only posts; hover/long-press for author and text.
- Player: fullscreen, swipe to next/previous, 0.5–2× speed, loop, offline cache.
- Three timeline modes: like order (default, with estimated date labels), exact publish-date axis, and shuffle.
- Filters: media type, author, publish-date range, full-text search.
- Unlike individual posts (synced back to X and removed locally).
- Restores your last view: mode, filters, scroll anchor, current item.

### Build

```powershell
flutter pub get
flutter run -d windows
.\tool\build_windows.ps1   # Inno Setup installer + portable zip
.\tool\build_apk.ps1       # self-signed release APK
```

### ⚠️ Risks

1. This project talks to X through **undocumented web endpoints**, not the official API. That violates X's developer terms and **may get your account rate-limited, flagged or suspended**. Use your own account and at your own risk.
2. Nothing is uploaded anywhere. Likes, cookies and media stay on your machine; cookies are stored via the platform keystore (DPAPI / Keystore).
3. X rotates its front-end GraphQL ids; the app tries to rediscover them, but updates may be required.
4. X's developer terms require offline copies of X content to be deleted or refreshed within 24 hours of a request. This project's local cache does not honour that, which is a grey area for personal use.
5. A proxy is required in mainland China; system proxy is followed by default, or set an HTTP/SOCKS5 proxy manually. TUN/global mode is recommended on Android.

## License

MIT — see [LICENSE](LICENSE).

# X Shelf

把 X（Twitter）账号里的**全部喜欢与书签**抓进本地，以 **X 风格图文列表 + 全屏竖滑播放页**的方式浏览、按时间/类型/作者/全文检索，并能逐条取消喜欢、加入/移除书签；另带本地与 X 全网两种搜索。
一套 Flutter 代码，同时产出 Windows 桌面版与 Android APK。本地优先，离线可看。

> 设计细节见 [docs/DESIGN.md](docs/DESIGN.md)，接口与登录的实测记录见 [docs/X-LOGIN-FINDINGS.md](docs/X-LOGIN-FINDINGS.md)。

---

## 中文

### 它做什么

- 登录你自己的 X 账号，一次性把喜欢列表**全量回填**到本地数据库（5 万条约 20 分钟，可暂停续传）。
- 列表浏览：像 X 的时间线一样文字与图片/视频混排（1/2/3/4 张图分形布局），点头像进作者空间。
- 播放：全屏抖音式上下滑；右侧喜欢/关注/头像/画质；**双击左/右快退快进**（秒数可配置）、**长按倍速**；正文在底部，点一下向上展开全文。
- 画质：可在播放页手动选档；默认「自动」= 先最低码率秒开，缓冲够了**平滑切到最高画质**（画面+音量交叉淡化，不黑屏不重头）。单变体视频不显示画质菜单。
- 两种搜索：**我的喜欢**（本地全文搜索，即时）+ **X 全网**（走 `SearchTimeline`，支持 `from:` / `since:` / `filter:media` / `min_faves:` / `OR` 等全部高级语法，带快捷筛选与命中词高亮）。
- 时间轴三模式：**喜欢顺序**（默认）、**按发布日期**（精确年月跳转）、**随机看**；顶部这三个 Tab **可以左右滑动切换**。
- 筛选：媒体类型 / 作者 / 发布日期范围 / 全文搜索。
- 管理：逐条取消喜欢（同步回 X，并从本地移除）、关注/取关作者。
- **书签完整闭环**：全量回填、增量、巡边核对；播放页动作栏一键加入/移除；主页「喜欢 · 书签」两个来源（横滑先切排序、到边界切来源）；作者空间分「喜欢 / 书签」两个 Tab；本地搜索可按来源过滤；卡片上显示只读书签标记。
- 从内嵌 X 网页（Grok、搜索结果、推文回复、刷视频页）返回时，**自动补齐最近一天的喜欢与书签**。
- 从播放页返回列表时，**自动定位回刚才看的那一条**（点返回、系统返回键、侧滑返回都算）。
- 界面中英文可切换（设置 → 界面语言，默认跟随系统）。
- 记住上次的位置：视图模式、筛选、滚动位置（按来源分别记忆）。

### 平台与依赖

- Windows 10 1809+（桌面版，主要用于开发调试）
- Android 8.0+（主要使用场景）

### 构建

```powershell
flutter pub get
flutter run -d windows     # 或 -d <android-device-id>
```

出安装包：

```powershell
# Windows：Inno Setup 安装包 + 便携版（需要 Inno Setup 6）
.\tool\build_windows.ps1

# Android：自签 release APK（首次运行会生成 keystore）
.\tool\build_apk.ps1 -SplitPerAbi
```

Android 建议按 ABI 分开出包，**只含自己那个 ABI 的库**（混装会在另一种 CPU 上装完打不开）：

```powershell
flutter build apk --release --target-platform android-arm64 --split-per-abi
flutter build apk --release --target-platform android-arm   --split-per-abi
```

产物在 `build/app/outputs/flutter-apk/`。无线安装（手机开「开发者选项 → 无线调试」并与电脑同一 WiFi）：

```powershell
adb connect <手机IP>:<端口>
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

### 开发

工具链建议装在非系统盘。仓库里的 `tool/env.ps1` 是按本机约定写的一套路径（默认 `E:\dev`，可用 `XLI_DEV_ROOT` 覆盖），
它不是硬性要求 —— 标准安装的 Flutter/JDK/Android SDK 只要在 PATH 上即可：

```powershell
. .\tool\env.ps1     # 本机约定：把 Flutter/JDK/Android SDK 加进当前会话的 PATH
flutter doctor
flutter analyze
flutter test
```

- 国内网络：`tool/patch-flutter-sdk-mirrors.ps1` 把 Flutter SDK 自带子构建的仓库换成镜像；
  `android/` 下已配阿里云 Maven 镜像。`flutter upgrade` 后需要重跑一次补丁脚本。
- 低内存机器（8GB）务必保持 `android/gradle.properties` 里的 `-Xmx2048m`，模板默认的 8G 会让 JVM 直接崩。
- Windows 构建的完整踩坑记录见 [docs/BUILD-ENV.md](docs/BUILD-ENV.md)（本机环境备忘，可按需忽略）。

### 项目结构

```
lib/
  main.dart              入口
  src/
    app_controller.dart  外壳：库 / 设置 / 登录 / 网络
    core/                设置、i18n、UA、保活、工具
    db/                  SQLite 访问层与 schema
    media/               媒体缓存、画质阶梯、相册保存
    model/               领域模型（LikeItem / MediaItem / Author）
    net/                 代理、翻译
    state/               浏览状态（BrowseState）、同步状态、数据源
    sync/                X 客户端、解析、回填/增量/取消喜欢
    ui/                  页面与组件
test/                    单元与组件测试（含一份脱敏后的真实响应夹具）
tool/                    构建与调试脚本
docs/                    设计与实测文档
```

### 隐私与数据

- 项目**不会**上传你的任何数据；喜欢、cookie、媒体都只存在本机。
- cookie 用系统钥匙串 / DPAPI / Android Keystore 加密保存。
- 签名密钥（`android/key.properties`、`android/keystore/`）与抓取产物（`build/_private/`）都在 `.gitignore` 里。
- 测试夹具 `test/fixtures/likes_real_slim.json` 来自真实响应，但**账号、姓名、正文、id、链接、媒体地址已全部替换成合成值**，只保留结构。

### ⚠️ 风险声明（务必读）

1. **本项目使用 X 的非公开网页接口**，不是官方 API。这不被 X 的开发者协议允许，**可能导致账号被限流、风控甚至封禁**。请自行评估，建议只使用自己的账号。
2. X 的接口随前端改版会变（queryId 轮换）。项目会尝试自动重新发现，仍可能失效，届时需要更新版本。
3. X 的开发者条款要求：其内容的离线副本在被 X 或内容所有者要求后 24 小时内删除或更新。本项目的本地缓存设计不满足这一条，这属于个人使用的边界地带，请自行判断。
4. 在中国大陆使用需要自备代理。默认跟随系统代理，也可在设置里手动填写 HTTP/SOCKS5 代理；Android 上推荐使用 TUN/全局模式的代理，否则部分请求可能绕过。

## English

Browse **all of your X (Twitter) likes and bookmarks** locally through an X-style timeline that opens into a fullscreen vertical-swipe player, filter by time / media type / author, full-text search, unlike posts, and keep bookmarks in sync. One Flutter codebase ships a Windows desktop build and an Android APK. Local-first and works offline once cached.

### What it does

- Sign in with your own X account and backfill your entire likes timeline into a local database (≈20 min for 50k items, resumable).
- Feed browsing: an X-style timeline mixing text with images/videos (1/2/3/4-image layout); tap an avatar to open that author's space.
- Player: fullscreen vertical swipe (TikTok-style); right-side like/follow/avatar/quality rail; **double-tap left/right to seek back/forward** (seconds configurable), **long-press for speed**; caption at the bottom expands upward on tap.
- Quality: pick a rung manually, or leave it on **Auto** — starts on the lowest bitrate for instant playback and **smoothly cross-fades up to the best quality** (video + audio), with no black frame or restart. Single-variant videos hide the quality menu.
- Two searches: **My likes** (local full-text, instant) and **All of X** (`SearchTimeline`, full operator set — `from:` / `since:` / `filter:media` / `min_faves:` / `OR` — with quick filters and hit highlighting).
- Three timeline modes: like order (default), exact publish date (jump to a specific month), and shuffle. **Swipe left/right on the feed** to switch between them.
- Filters: media type, author, publish-date range, full-text search.
- Unlike individual posts (synced back to X and removed locally), follow/unfollow authors.
- **Full bookmark loop**: backfill, incremental sync and reconciler; add/remove from the player action rail; likes and bookmarks are two sources on the home screen (swipe switches sort first, then flips source at the edges); the author page has separate Likes / Bookmarks tabs; local search can be filtered by source; cards show a read-only bookmark marker.
- Returning from an embedded X page (Grok, search, replies, swipe feed) **backfills the last day of likes and bookmarks automatically**.
- Returning from the player **scrolls the feed back to the post you were watching** (in-app back button, system back and edge-swipe all work).
- Switchable Chinese/English UI (Settings → Language, follows the system by default).
- Restores your last view: mode, filters, scroll anchor.

### Build

```powershell
flutter pub get
flutter run -d windows
.\tool\build_windows.ps1      # Inno Setup installer + portable zip
.\tool\build_apk.ps1 -SplitPerAbi   # self-signed release APKs
```

Wireless install (Android 11+, same Wi-Fi):

```powershell
adb connect <phone-ip>:<port>
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

### Privacy

Nothing is uploaded anywhere. Likes, cookies and media stay on your machine; cookies are stored via the platform keystore (DPAPI / Keystore). Signing keys and raw captures are git-ignored, and the test fixture is fully synthetic (only the response *shape* is real).

### ⚠️ Risks

1. This project talks to X through **undocumented web endpoints**, not the official API. That violates X's developer terms and **may get your account rate-limited, flagged or suspended**. Use your own account and at your own risk.
2. X rotates its front-end GraphQL ids; the app tries to rediscover them, but updates may be required.
3. X's developer terms require offline copies of X content to be deleted or refreshed within 24 hours of a request. This project's local cache does not honour that, which is a grey area for personal use.
4. A proxy is required in mainland China; system proxy is followed by default, or set an HTTP/SOCKS5 proxy manually. TUN/global mode is recommended on Android.

## License

MIT — see [LICENSE](LICENSE).

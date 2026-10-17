# 本机构建环境（Windows 11 / 8GB RAM / 中国网络）

这份文件记录**这台机器**上装了什么、为什么这么装、踩过哪些坑。不是给开源用户看的（他们看 README 就够），
是给下一次会话的自己和接手的人看的。

## 1. 目录布局（全在 E 盘）

| 组件 | 版本 | 路径 |
|---|---|---|
| Flutter SDK | 3.47.7 stable / Dart 3.13.5 | `E:\dev\flutter` |
| Git（便携版，无安装） | 2.56.0.windows.2 | `E:\dev\git` |
| JDK | Temurin 17.0.20.1+1 | `E:\dev\jdk\jdk-17.0.20.1+1` |
| Android SDK | platform-tools / platforms;android-36 / build-tools;36.0.0 | `E:\dev\android-sdk` |
| Gradle 缓存与发行版 | Gradle 9.3.1（走腾讯镜像下载） | `E:\dev\gradle` |
| 下载的安装包 | — | `E:\dev\downloads` |

装载：`. .\tool\env.ps1`

## 2. 网络

本机 Clash 运行在 `127.0.0.1:7897`（规则模式，系统代理已开）。各地下载源实测速度：

| 源 | 直连 | 走代理 |
|---|---|---|
| storage.googleapis.com（Flutter 官方） | 卡死 | 125 KB/s |
| storage.flutter-io.cn（Flutter 国内镜像） | 4.2 MB/s | — |
| services.gradle.org | 卡死 | — |
| mirrors.cloud.tencent.com/gradle（Gradle 发行版） | 1.4 MB/s | — |
| maven.aliyun.com（Maven） | 4.8 MB/s | — |
| repo.maven.apache.org | 卡死 | 125 KB/s |

结论：**能走国内镜像的一律走镜像**，代理只做兜底。

具体落点：

- `android/gradle/wrapper/gradle-wrapper.properties` → 腾讯镜像的 Gradle 9.3.1
- `android/settings.gradle.kts`、`android/build.gradle.kts` → 阿里云 Maven 镜像
- `tool/patch-flutter-sdk-mirrors.ps1` → 改 Flutter SDK 自带子构建的 `settings.gradle.kts`
  （它是 includeBuild 且 `FAIL_ON_PROJECT_REPOS`，改工程无效）
- `E:\dev\gradle\gradle.properties`（本机级）→ 给 Gradle 配 HTTP 代理兜底 + 小内存堆

## 3. 踩过的坑（按发生顺序）

1. **Flutter SDK 1.93 GB 下载被截断**：`Invoke-WebRequest` 会静默留下截断文件。
   改用 `curl -C -` 循环续传到目标字节数。
2. **PowerShell `Get-Content -Raw` + `Set-Content` 把 Dart 文件写成 ANSI**，中文注释被毁、
   整个文件语法失效（表现为“这个 import 的文件不存在”）。用 `[System.IO.File]::ReadAllText/WriteAllText` + UTF8。
   或者根本不要用 shell 改源码，用 edit 工具。
3. **`.ps1` 脚本必须带 UTF-8 BOM**，否则 Windows PowerShell 5.1 按 ANSI 解析，中文注释直接导致语法错误。
4. **Flutter 模板默认 `-Xmx8G`**，8GB 机器上 JVM `malloc` 失败、Kotlin daemon 崩溃。收到 `-Xmx2048m`。
5. **模板会拉 NDK r28c（~2.5GB）**：因为 `ndkVersion = flutter.ndkVersion`。本项目无原生代码，删掉该行。
6. **AGP 9.1.0 移除了 `getDefaultProguardFile('proguard-android.txt')`**，
   官方 `flutter_inappwebview_android` 1.1.3 还在用它 → Android 构建直接失败。
   解决：`third_party/flutter_inappwebview_android`（只改这一行的副本）+ `dependency_overrides`。
7. **Developer Mode 未开**：Flutter 会警告 “Building with plugins requires symlink support”，
   目前不影响构建（Flutter 用 junction 兜底），但装 VS 时一起打开更稳。

## 4. 还缺的东西（需要管理员）

| 缺什么 | 影响 | 怎么补 |
|---|---|---|
| ~~VS 2022 生成工具 + C++ 工作负载~~ | 已就绪（`C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools`，含 VC.Tools） | — |
| ~~开发者模式~~ | 已开（`AllowDevelopmentWithoutDevLicense=1`） | — |
| ~~Inno Setup 6~~ | 已装（用户态），`tool\build_windows.ps1` 能直接出安装包 | — |
| VS 的 ATL 组件（`Microsoft.VisualStudio.Component.VC.ATL`） | **本机没装，但已经不需要**：`flutter_secure_storage_windows` 的 ATL 兼容层被我们裁掉（见坑 15） | 真要装：`setup.exe modify --installPath ... --add Microsoft.VisualStudio.Component.VC.ATL`（必须从提权终端运行 `--quiet`） |

## 5. 验证清单（实测结果，2026-10-18）

```powershell
. . .\tool\env.ps1
flutter doctor                  # Flutter / Android / VS(VC.Tools) 全绿
flutter analyze                 # 0 issue
flutter test                    # 46/46 通过
.\tool\build_windows.ps1        # ✅ xlikemanage.exe + 便携 zip + Inno 安装包
flutter build apk --release --target-platform android-arm64
                                # ✅ 24.9 MB（含 INTERNET / ACCESS_NETWORK_STATE）
```

Windows 产物（Release）：
- `build\windows\x64\runner\Release` 79 MB（libmpv 与 ANGLE 占大头）
- `dist\xlikemanage-windows-portable.zip` 33 MB
- `dist\xlikemanage-1.0.0-setup.exe` 25 MB（LZMA2，含中英文安装界面）

**注意**：这台机器 C: 只剩 ~3 GB，`flutter build apk --split-per-abi` 一次要 ~3 GB 峰值，
所以现在是「一次只出一个 ABI」，出完把 `build\` 清掉再出下一个。

**另外踩到的坑（后续可能复现）**：

8. **sqlite3 3.x 的 Dart build hooks 会卡死**：`hooks_runner/sqlite3/.../hook.dill` 进程
   零 CPU、无网络、无输出地挂着。已回退到 `sqlite3 2.9.x + sqlite3_flutter_libs 0.5.x`（无 hooks）。
   注意 2.x 是 `Database.dispose()`，3.x 才是 `close()`。
9. **`android/key.properties` 不能带 BOM**：PowerShell `Set-Content -Encoding utf8` 会写 BOM，
   导致 `keystoreProperties["storePassword"]` 读成 null，Gradle 报
   `null cannot be cast to non-null type kotlin.String`。用 `UTF8Encoding($false)` 写。
10. **AGP 会自己装 SDK 组件**：`android-35` 平台和 `CMake 3.22.1` 是在构建过程中自动下的（走直连，很快）。
11. **NDK r28c 2.1 GB 已经躺在 `E:\dev\android-sdk\ndk\28.2.13676358`**：模板 `ndkVersion` 触发过，
    现在 `ndkVersion` 已删除，不会再下；目录留着不影响构建。
12. **国产网络下 Maven 走代理只有 125 KB/s，直连 dl.google.com 有 1.3 MB/s**：
    `E:\dev\gradle\gradle.properties` 里用 `nonProxyHosts` 把 google/aliyun 排除在代理之外，速度差 10 倍。
13. **Windows 构建需要 `nuget.exe` 在 PATH**：`flutter_inappwebview_windows` 的 CMake 会
    `nuget install Microsoft.Web.WebView2 / nlohmann.json`，缺了就报 `NUGET-NOTFOUND`（MSB3073）。
    现在放在 `E:\dev\nuget\nuget.exe`，`tool\env.ps1` 会把它加进 PATH。
14. **项目路径太长 → MSB3491**：`flutter_inappwebview_windows` 的 `.tlog` 目录能撞上 260 字符上限。
    开 `LongPathsEnabled` 需要管理员，所以 `tool\build_windows.ps1` 会自动 `subst` 一个短盘符。
    **映射的必须是父目录**（`X:` → `myproject`，再进 `X:\xlikemanage`）；如果映射成盘符根，
    `PROJECT_DIR` 会变成 `X:`，CMake 会给 `cmake -E env` 传一个被引号粘住的参数
    （`"PROJECT_DIR=X:";"FLUTTER_TARGET=lib\main.dart"`），flutter 的 tool_backend 做 `cd /d` 时
    就 `PathNotFoundException`，构建稳定失败。
15. **`flutter_secure_storage_windows` 的 C++ 兼容层要 ATL**（`atlstr.h` → C1083）。
    它的默认后端其实是**纯 Dart + DPAPI 文件**，C++ 那套只服务 `useBackwardCompatibility=true` 的老数据。
    本项目没有历史数据，`third_party/flutter_secure_storage_windows` 里去掉了 `pluginClass:`，
    只留 `dartPluginClass`，`AuthStore` 里显式 `WindowsOptions(useBackwardCompatibility: false)`。
    结果：Windows 构建零 ATL 依赖。
16. **media_kit 首次构建要下 mpv / ANGLE 两个 7z**（GitHub releases，共 ~13 MB），
    走代理容易下断，断了会报 `ANGLE.7z Integrity check failed`。
    直接 `curl -L --proxy ... -o build\windows\x64\ANGLE.7z <url>` 预置好（脚本里有 URL 和 MD5），
    CMake 会自己校验并跳过下载。
17. **CMake 缓存会记住错误的 `CMAKE_INSTALL_PREFIX`**：第一次配置被 MAX_PATH 打断后，
    缓存里留下 `C:/Program Files/xlikemanage`，之后 `INSTALL` 步骤报 `file cannot create directory`
    （MSB3073，exit 1），看起来像权限问题其实是脏缓存。删 `build\windows` 重新配置即可。
18. **GUI 程序没法在这个 shell 里冒烟测试**：`Start-Process xlikemanage.exe` 会让宿主管道一直挂着，
    job 永远不结束。改用「有没有 Application Error 事件」判断有没有启动崩溃。



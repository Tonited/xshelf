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
| VS 2022 生成工具 + C++ 工作负载 | `flutter build windows` 无法进行 | 管理员跑 `tool\setup_admin.ps1` |
| 开发者模式 | 插件符号链接（目前不阻塞） | 同上脚本会开 |
| Inno Setup 6 | 只有便携 zip，没有安装包 | `winget install JRSoftware.InnoSetup` |

## 5. 验证清单

```powershell
. .\tool\env.ps1
flutter doctor            # 期望：Flutter/Android toolchain OK；VS 显示缺失
flutter analyze           # 期望：0 error
flutter test              # 期望：全绿
flutter build apk --debug # 期望：build\app\outputs\flutter-apk\app-debug.apk
```

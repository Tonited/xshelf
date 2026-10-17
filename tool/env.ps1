# 本机工具链位置（xlikemanage 专用）
# 用法： . .\tool\env.ps1     （点号加载到当前会话）
#
# 默认工具都装在 E 盘（避免占用系统盘），可用 XLI_DEV_ROOT 覆盖：
#   $env:XLI_DEV_ROOT = 'D:\dev'; . .\tool\env.ps1

$XlDev = if ($env:XLI_DEV_ROOT) { $env:XLI_DEV_ROOT } else { 'E:\dev' }

$flutterRoot = Join-Path $XlDev 'flutter'
if (Test-Path (Join-Path $flutterRoot 'bin\flutter.bat')) { $env:FLUTTER_ROOT = $flutterRoot }

$jdkDir = Get-ChildItem (Join-Path $XlDev 'jdk') -Directory -ErrorAction SilentlyContinue |
          Select-Object -First 1
if ($jdkDir) { $env:JAVA_HOME = $jdkDir.FullName }

$androidSdk = Join-Path $XlDev 'android-sdk'
if (Test-Path $androidSdk) {
    $env:ANDROID_HOME = $androidSdk
    $env:ANDROID_SDK_ROOT = $androidSdk
}

$paths = @(
    (Join-Path $XlDev 'flutter\bin'),
    (Join-Path $XlDev 'git\cmd'),
    (Join-Path $XlDev 'android-sdk\platform-tools'),
    (Join-Path $XlDev 'android-sdk\cmdline-tools\latest\bin')
)
if ($env:JAVA_HOME) { $paths += (Join-Path $env:JAVA_HOME 'bin') }
foreach ($p in $paths) {
    if ((Test-Path $p) -and ($env:Path -notlike "*$p*")) { $env:Path = "$p;$env:Path" }
}

$env:GRADLE_USER_HOME = Join-Path $XlDev 'gradle'

# pub 缓存默认放用户目录；如果你把缓存迁到了 E 盘，这里自动跟上。
$pubCache = Join-Path $XlDev 'pub-cache'
if (Test-Path $pubCache) { $env:PUB_CACHE = $pubCache }

# 国内镜像（下载 Flutter 引擎/Dart 包时走这个会快很多）
if (-not $env:PUB_HOSTED_URL) { $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn' }
if (-not $env:FLUTTER_STORAGE_BASE_URL) {
    $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
}

Write-Host "flutter : $env:FLUTTER_ROOT"
Write-Host "java    : $env:JAVA_HOME"
Write-Host "android : $env:ANDROID_HOME"
Write-Host "gradle  : $env:GRADLE_USER_HOME"

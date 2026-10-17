# 本机工具链位置（xlikemanage 专用）
# 用法： . .\tool\env.ps1     （点号加载到当前会话）
#
# 这里的所有工具都装在 E 盘，避免占用系统盘。

$XlDev = 'E:\dev'
$env:FLUTTER_ROOT = Join-Path $XlDev 'flutter'
$env:JAVA_HOME   = (Get-ChildItem (Join-Path $XlDev 'jdk') -Directory -ErrorAction SilentlyContinue |
                    Select-Object -First 1).FullName
$env:ANDROID_HOME = Join-Path $XlDev 'android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME

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

$env:PUB_CACHE = Join-Path $XlDev 'pub-cache'
$env:GRADLE_USER_HOME = Join-Path $XlDev 'gradle'

Write-Host "flutter : $env:FLUTTER_ROOT"
Write-Host "java    : $env:JAVA_HOME"
Write-Host "android : $env:ANDROID_HOME"
Write-Host "pubcache: $env:PUB_CACHE"

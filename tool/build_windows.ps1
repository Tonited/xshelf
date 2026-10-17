# 出 Windows 产物：便携 zip + Inno Setup 安装包
#
# 用法： .\tool\build_windows.ps1 [-SkipBuild]
#
# 关于 subst：Windows 的 MSBuild/CMake 对路径长度很敏感（`flutter_inappwebview_windows`
# 的 `.tlog` 目录就能撞上 260 字符上限，报 MSB3491）。开 LongPathsEnabled 需要管理员，
# 所以当项目所在路径较长时，这里自动挂一个短盘符再构建，结束后卸掉。
#
# 注意：映射的是**父目录**，然后进到 `X:\<项目名>` 里构建。
# 如果直接把项目映射成盘符根（PROJECT_DIR = `X:`），CMake 会给 `cmake -E env`
# 传一个被引号粘在一起的参数（`"PROJECT_DIR=X:";"FLUTTER_TARGET=lib\main.dart"`），
# flutter 的 tool_backend.bat 拿去做 `cd /d` 就会 PathNotFoundException，构建必然失败。

param([switch]$SkipBuild)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'env.ps1')
$leaf = Split-Path -Leaf $root
$parent = Split-Path -Parent $root

# 实测：root 路径 ≥ 40 字符时，插件构建目录会超过 260。
$shortDrive = $null
if ($root.Length -ge 40) {
    foreach ($c in 'X', 'Y', 'W', 'V', 'U', 'T') {
        if (-not (Test-Path "${c}:\")) {
            & subst "${c}:" $parent
            if (Test-Path "${c}:\$leaf\pubspec.yaml") { $shortDrive = $c }
            break
        }
    }
    if (-not $shortDrive) { throw '找不到可用盘符挂 subst；请把项目移到更短的路径。' }
    Write-Host "路径过长，已用 ${shortDrive}: 映射父目录后构建（subst）"
}

$buildRoot = if ($shortDrive) { "${shortDrive}:\$leaf" } else { $root }

Push-Location $buildRoot
# flutter / MSBuild 会往 stderr 写日志；PowerShell 7 在 ErrorActionPreference=Stop 下
# 会把这些当终止错误（NativeCommandError）。这里临时放松，靠 $LASTEXITCODE 判断。
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    if (-not $SkipBuild) {
        flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows 失败（exit $LASTEXITCODE）" }
    }

    $src = Join-Path $buildRoot 'build\windows\x64\runner\Release'
    if (-not (Test-Path $src)) { throw "构建产物不存在：$src" }

    $dist = Join-Path $root 'dist'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null

    # 1) 便携版
    $zip = Join-Path $dist 'xlikemanage-windows-portable.zip'
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip
    Write-Host "便携版: $zip"

    # 2) Inno Setup 安装包（未装则跳过并提示）
    $iscc = @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe',
        'E:\dev\inno\ISCC.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($iscc) {
        $version = (Get-Content (Join-Path $root 'pubspec.yaml') |
            Select-String '^version:').Line -replace '^version:\s*', '' -replace '\+.*$', ''
        & $iscc "/DAppVersion=$version" "/DSourceDir=$src" `
            (Join-Path $root 'tool\installer\xlikemanage.iss')
        if ($LASTEXITCODE -ne 0) { throw "ISCC 失败（exit $LASTEXITCODE）" }
        Write-Host "安装包: $dist\xlikemanage-$version-setup.exe"
    } else {
        Write-Warning '未找到 Inno Setup 6（ISCC.exe）。'
        Write-Warning '用户态安装： winget install --id JRSoftware.InnoSetup --scope user'
    }
} finally {
    $ErrorActionPreference = $prevEap
    Pop-Location
    if ($shortDrive) { & subst "${shortDrive}:" /d }
}

# 出 Windows 产物：便携 zip + Inno Setup 安装包
# 用法： .\tool\build_windows.ps1 [-SkipBuild]
param([switch]$SkipBuild)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'env.ps1')

Push-Location $root
try {
    if (-not $SkipBuild) {
        flutter build windows --release
    }

    $src = Join-Path $root 'build\windows\x64\runner\Release'
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
    Pop-Location
}

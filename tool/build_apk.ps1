# 出 Android release APK（自签）
# 首次运行会自动生成 keystore（存在 android/keystore/，已 gitignore）
# 用法： .\tool\build_apk.ps1 [-SplitPerAbi]
param([switch]$SplitPerAbi)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'env.ps1')

$ksDir  = Join-Path $root 'android\keystore'
$ksFile = Join-Path $ksDir 'release.jks'
$ksProp = Join-Path $root 'android\key.properties'

if (-not (Test-Path $ksFile)) {
    Write-Host '首次构建：生成自签 keystore…'
    New-Item -ItemType Directory -Force -Path $ksDir | Out-Null
    $pass = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    & keytool -genkeypair -v -keystore $ksFile -alias xlikemanage `
        -keyalg RSA -keysize 2048 -validity 10000 `
        -storepass $pass -keypass $pass `
        -dname 'CN=xlikemanage, OU=self, O=self, L=, ST=, C=CN'
    @"
storePassword=$pass
keyPassword=$pass
keyAlias=xlikemanage
storeFile=keystore/release.jks
"@ | Set-Content -Path $ksProp -Encoding utf8
    Write-Host "keystore: $ksFile（密码记在 android/key.properties，不要提交）"
}

Push-Location $root
try {
    $args = @('build', 'apk', '--release')
    if ($SplitPerAbi) { $args += '--split-per-abi' }
    & flutter @args

    $dist = Join-Path $root 'dist'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    Get-ChildItem (Join-Path $root 'build\app\outputs\flutter-apk') -Filter '*.apk' |
        ForEach-Object { Copy-Item $_.FullName $dist -Force; Write-Host "APK: $(Join-Path $dist $_.Name)" }
} finally {
    Pop-Location
}

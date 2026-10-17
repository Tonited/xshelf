<#
  需要管理员权限的一次性环境准备。用管理员 PowerShell 运行：

    powershell -NoProfile -ExecutionPolicy Bypass -File ".\tool\setup_admin.ps1"

  做两件事：
  1) 打开 Windows「开发者模式」（Flutter 在 Windows 上给插件建符号链接需要它）
  2) 安装 Visual Studio 2022 生成工具 + C++ 桌面开发工作负载（编 Windows exe 必需）

  两者都要管理员权限，agent 进程没有提权能力，所以只能由你手动跑一次。
#>
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host '需要管理员权限，正在请求提权…'
    $args = '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    Start-Process powershell -Verb RunAs -ArgumentList $args
    return
}

Write-Host '=== 1/2 开启开发者模式 ==='
$key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
New-Item -Path $key -Force | Out-Null
New-ItemProperty -Path $key -Name AllowDevelopmentWithoutDevLicense -Value 1 `
    -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $key -Name AllowAllTrustedApps -Value 1 `
    -PropertyType DWord -Force | Out-Null
Write-Host '  已开启（如不生效请重启一次）'

Write-Host '=== 2/2 安装 VS 2022 生成工具（C++ 工作负载，约 7GB） ==='
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    $hasCpp = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($hasCpp) { Write-Host "  已安装：$hasCpp" }
}

if (-not $hasCpp) {
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-package-agreements --accept-source-agreements `
        --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "winget 返回 $LASTEXITCODE。可手动装：https://visualstudio.microsoft.com/downloads/ （勾选“使用 C++ 的桌面开发”）"
    }
}

Write-Host ''
Write-Host '完成。回到普通终端执行：'
Write-Host '  . .\tool\env.ps1'
Write-Host '  flutter doctor'
Write-Host '  flutter build windows --release'

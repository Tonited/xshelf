# 启动 xlikemanage（Windows），开启 WebView2 的 CDP 端口，并截屏。
# 用法: .\tool\run_app.ps1 [-Kill] [-ShotOnly] [-NoCdp]
param(
    [switch]$Kill,
    [switch]$ShotOnly,
    [int]$CdpPort = 9444
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'build\windows\x64\runner\Release\xlikemanage.exe'
$out = Join-Path $root 'build\auth_probe'
New-Item -ItemType Directory -Force -Path $out | Out-Null

if ($Kill) {
    Get-Process xlikemanage -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    Write-Host 'killed xlikemanage'
    if ($ShotOnly) { return }
}

if (-not $ShotOnly) {
    if (-not (Test-Path $exe)) { throw "exe not found: $exe" }
    Get-Process xlikemanage -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500

    # WebView2 会把额外参数传给底层 Edge 进程，从而打开 CDP 端口。
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$CdpPort --disable-features=Translate"
    Write-Host "launching: $exe (CDP $CdpPort)"
    $p = Start-Process -FilePath $exe -PassThru
    Start-Sleep -Seconds 9
    $p.Refresh()
    Write-Host "pid=$($p.Id) exited=$($p.HasExited) title=$($p.MainWindowTitle)"

    try {
        $r = Invoke-WebRequest "http://127.0.0.1:$CdpPort/json/version" -TimeoutSec 5 -UseBasicParsing
        Write-Host "CDP OK: $($r.Content.Substring(0, [Math]::Min(120, $r.Content.Length)))"
    } catch {
        Write-Host "CDP not available: $($_.Exception.Message)"
    }
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$shot = Join-Path $out 'app-screen.png'
$bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Host "screenshot: $shot ($($bounds.Width)x$($bounds.Height))"

# 报告窗口矩形，方便后续按坐标点击
Get-Process xlikemanage -ErrorAction SilentlyContinue | ForEach-Object {
    $hwnd = $_.MainWindowHandle
    if ($hwnd -ne 0) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinRect {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
}
"@
        $r = New-Object WinRect+RECT
        if ([WinRect]::GetWindowRect($hwnd, [ref]$r)) {
            Write-Host "window rect: L=$($r.Left) T=$($r.Top) R=$($r.Right) B=$($r.Bottom) size=$($r.Right-$r.Left)x$($r.Bottom-$r.Top)"
        }
    }
}

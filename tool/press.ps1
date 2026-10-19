# 激活 xlikemanage 窗口并发送按键（Flutter 按钮不是 DOM，白屏时也能用键盘导航）。
# 用法: .\tool\press.ps1 -Keys "TAB,ENTER" [-Wait 800]
param(
    [string]$Keys = "TAB,ENTER",
    [int]$Wait = 800
)

$proc = Get-Process xlikemanage -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { throw 'xlikemanage window not found' }
$pid_ = $proc.Id
Write-Host "target pid=$pid_ title=$($proc.MainWindowTitle)"

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinFocus {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
[WinFocus]::ShowWindow($proc.MainWindowHandle, 9) | Out-Null   # SW_RESTORE
[WinFocus]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 400

$ws = New-Object -ComObject WScript.Shell
$ws.AppActivate($pid_) | Out-Null
Start-Sleep -Milliseconds 300

foreach ($k in $Keys.Split(',')) {
    $token = switch ($k.Trim().ToUpper()) {
        'TAB'   { '{TAB}' }
        'ENTER' { '{ENTER}' }
        'SPACE' { ' ' }
        'DOWN'  { '{DOWN}' }
        'UP'    { '{UP}' }
        default { $k.Trim() }
    }
    Write-Host "send: $token"
    $ws.SendKeys($token)
    Start-Sleep -Milliseconds $Wait
}
Write-Host 'keys sent'

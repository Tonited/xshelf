# 在屏幕上做真实鼠标点击（Flutter 的按钮不是 DOM，CDP 点不到，只能走系统输入）。
# 用法: .\tool\click.ps1 -X 640 -Y 400 [-Double] [-MoveOnly]
param(
    [Parameter(Mandatory = $true)][int]$X,
    [Parameter(Mandatory = $false)][int]$Y = 0,
    [switch]$Double,
    [switch]$MoveOnly
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MouseInput {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
  public const uint LEFTDOWN = 0x0002;
  public const uint LEFTUP = 0x0004;
  public const uint MOVE = 0x0001;

  public static void Click(int x, int y, bool dbl) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(120);
    mouse_event(MOVE, 0, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(60);
    mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(40);
    mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
    if (dbl) {
      System.Threading.Thread.Sleep(80);
      mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
      System.Threading.Thread.Sleep(40);
      mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
    }
  }

  public static void Move(int x, int y) {
    SetCursorPos(x, y);
  }
}
"@

if ($MoveOnly) {
    [MouseInput]::Move($X, $Y)
    Write-Host "moved to ($X, $Y)"
} else {
    [MouseInput]::Click($X, $Y, [bool]$Double)
    Write-Host "clicked ($X, $Y) double=$Double"
}

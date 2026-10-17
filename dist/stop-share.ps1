# 停止 dist 局域网文件共享服务
$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $here '_share.pid'

if (-not (Test-Path $pidFile)) {
    Write-Host '未找到 PID 文件，服务可能未运行。' -ForegroundColor Yellow
    # 兜底：按命令行匹配
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -like '*_share-server.js*' } |
        ForEach-Object {
            Write-Host "结束残留进程 PID $($_.ProcessId)"
            Stop-Process -Id $_.ProcessId -Force
        }
    exit 0
}

$procId = (Get-Content $pidFile | Select-Object -First 1)
if ($procId -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
    Stop-Process -Id $procId -Force
    Write-Host "已停止共享服务 (PID $procId)" -ForegroundColor Green
} else {
    Write-Host "PID $procId 对应的进程已不存在" -ForegroundColor Yellow
}
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue

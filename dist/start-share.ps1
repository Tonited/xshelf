# 启动 dist 局域网文件共享服务（后台运行，关闭终端不影响）
# 用法:  powershell -ExecutionPolicy Bypass -File .\start-share.ps1 [-Port 8080]
param(
    [int]$Port = 8080
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$server = Join-Path $here '_share-server.js'
$pidFile = Join-Path $here '_share.pid'
$outLog = Join-Path $here '_share.log'
$errLog = Join-Path $here '_share.err.log'

if (-not (Test-Path $server)) { throw "找不到服务脚本: $server" }

# 已有实例在运行？
if (Test-Path $pidFile) {
    $oldPid = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        Write-Host "共享服务已在运行 (PID $oldPid)，先停止旧实例..." -ForegroundColor Yellow
        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# 端口占用检查
$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($busy) {
    throw "端口 $Port 已被占用 (PID $($busy.OwningProcess))，请用 -Port 指定其他端口"
}

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { throw '未找到 node，请先安装 Node.js 并加入 PATH' }

$p = Start-Process -FilePath $node `
    -ArgumentList @("`"$server`"", $Port) `
    -WorkingDirectory $here `
    -WindowStyle Hidden `
    -RedirectStandardOutput $outLog `
    -RedirectStandardError $errLog `
    -PassThru

$p.Id | Set-Content -Path $pidFile -Encoding ascii

# 等待端口就绪
$ok = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { $ok = $true; break }
    if ($p.HasExited) { break }
}
if (-not $ok) {
    Write-Host "启动失败，错误日志：" -ForegroundColor Red
    if (Test-Path $errLog) { Get-Content $errLog -ErrorAction SilentlyContinue }
    exit 1
}

$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }

Write-Host ''
Write-Host '共享服务已启动 (PID ' -NoNewline; Write-Host $p.Id -NoNewline; Write-Host ')'
Write-Host "  目录  : $here"
Write-Host "  本机  : http://127.0.0.1:$Port/"
foreach ($ip in $ips) { Write-Host "  局域网: http://$($ip.IPAddress):$Port/   ($($ip.InterfaceAlias))" }
Write-Host ''
Write-Host "  日志  : $outLog"
Write-Host "  停止  : .\stop-share.ps1"
Write-Host ''

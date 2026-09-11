# net-warp - OFF (WARP proxy + local SOCKS5/HTTP bridge)
# 关闭隧道：停桥 -> 清 hosts 托管块 -> 还原 git 代理 -> 断开 WARP。
# 用法：net-warp-off.ps1 [-KeepHosts]
#       -KeepHosts 保留 hosts 里的固定记录（默认会清掉，让系统回到干净状态）
# 注意：模式固定保持 proxy（不是 warp/TUN）。
#   原因：WARP 设置里 "Always On" 为 true，随时可能自动重连；
#   若停留在 warp(TUN) 模式，重连后会改默认路由，远程桌面(RDP)会卡。
#   proxy 模式不建 TUN 网卡、不改路由，最安全。

param([switch]$KeepHosts)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'net-warp-common.ps1')
$Port = $script:NetWarpPort

Write-Host "=========================================================="
Write-Host "  net-warp - STOP"
Write-Host "=========================================================="
Write-Host ""

$warpExe = Get-WarpCli
if (-not $warpExe) { Write-Host "  [FAIL] warp-cli not found." -ForegroundColor Red; exit 1 }
Write-Host "  warp-cli = $warpExe"
Write-Host ""

Write-Host "[1/6] Stop local HTTP bridge ..."
try {
    if (Get-ScheduledTask -TaskName 'NetWarp-Bridge' -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName 'NetWarp-Bridge' -ErrorAction SilentlyContinue
        Write-Host "  [OK] bridge task stopped"
    }
} catch { }
$bp = Get-Process -Name 'net-warp-bridge' -ErrorAction SilentlyContinue
if ($bp) {
    Stop-Process -Name 'net-warp-bridge' -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] bridge process killed"
} else {
    Write-Host "  [OK] bridge not running"
}
Write-Host ""

Write-Host "[2/6] Clean pinned hosts block ..."
if ($KeepHosts) {
    Write-Host "  [SKIP] -KeepHosts specified, block kept" -ForegroundColor DarkGray
} elseif (Test-ManagedBlock -Path (Get-HostsPath)) {
    $bak = Backup-Hosts -BakDir (Join-Path $PSScriptRoot 'hosts-backup')
    if ($bak) { Write-Host "  backup -> $bak" -ForegroundColor DarkGray }
    $n = Remove-ManagedBlock -Path (Get-HostsPath)
    ipconfig /flushdns | Out-Null
    Write-Host "  [OK] removed $n pinned lines, DNS flushed" -ForegroundColor Green
    $pruned = Remove-OldBackups -BakDir (Join-Path $PSScriptRoot 'hosts-backup') -Keep 10
    if ($pruned -gt 0) { Write-Host "  [OK] pruned $pruned old backup(s), keep 10" -ForegroundColor DarkGray }
} else {
    Write-Host "  [OK] no pinned block in hosts"
}
Write-Host ""

Write-Host "[3/6] Restore git proxy settings ..."
& git config --global --unset http.proxy  2>$null
& git config --global --unset https.proxy 2>$null
foreach ($gh in @('https://github.com/','https://gist.github.com/')) {
    & git config --global --unset "http.$gh.proxy" 2>$null
}
$left = (& git config --global --get 'http.https://github.com/.proxy' 2>$null)
if (-not $left) { Write-Host "  [OK] git proxy removed" -ForegroundColor Green } else { Write-Host "  [WARN] still set: $left" -ForegroundColor Yellow }
Write-Host ""

Write-Host "[4/6] Disconnect tunnel ..."
$text = (& $warpExe disconnect 2>&1 | Out-String).Trim()
Write-Host "  $text"
Start-Sleep -Seconds 2
Write-Host ""

Write-Host "[5/6] Keep mode = proxy (never TUN, so RDP stays fast) ..."
$text = (& $warpExe mode proxy 2>&1 | Out-String).Trim()
if ($text -match 'Success') { Write-Host "  [OK] mode = proxy" -ForegroundColor Green } else { Write-Host "  [WARN] $text" -ForegroundColor Yellow }
Write-Host ""

Write-Host "[6/6] Verify ..."
(& $warpExe status 2>&1) | ForEach-Object { Write-Host "  $_" }
$stillUp = Test-PortListening $Port
if ($stillUp) {
    Write-Host "  [WARN] SOCKS5 port $Port still listening" -ForegroundColor Yellow
} else {
    Write-Host "  [OK] SOCKS5 port $Port closed" -ForegroundColor Green
}
Write-Host ""

Write-Host "=========================================================="
Write-Host "  STOPPED - tunnel down, git proxy cleared" -ForegroundColor Green
Write-Host "=========================================================="
Write-Host "  需要重新加速时双击  1-开启加速.bat"
Write-Host ""

# net-warp - ON  (WARP proxy + local SOCKS5/HTTP bridge)
# ---------------------------------------------------------------
# 原理：把 Cloudflare WARP 切到 proxy 模式，本机 127.0.0.1:40000 暴露 SOCKS5。
#      不创建 TUN 网卡、不改默认路由 -> 远程桌面(RDP)/局域网流量不受影响。
# 关键前提：系统 hosts 里不能有 Steam++ 的 127.0.0.1 劫持。
#      原因：WARP 的 SOCKS5 用系统解析器解析域名，若被 hosts 劫持到 127.0.0.1，
#      WARP 就会去连本机回环地址而失败（SOCKS5 error 5）。
# ---------------------------------------------------------------

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'net-warp-common.ps1')
$Port  = $script:NetWarpPort
$Socks = "socks5h://127.0.0.1:$Port"
$Hosts = Get-HostsPath

Write-Host "=========================================================="
Write-Host "  net-warp - START   (WARP proxy + SOCKS5)"
Write-Host "  RDP / LAN traffic is NOT affected"
Write-Host "=========================================================="
Write-Host ""

# --- 1 --- locate warp-cli
Write-Host "[1/9] Check warp-cli ..."
$warpExe = Get-WarpCli
if (-not $warpExe) {
    Write-Host "  [FAIL] warp-cli not found. Install Cloudflare WARP first." -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] $warpExe"
Write-Host ""

# --- 2 --- hosts 劫持检查 / 自动清理
Write-Host "[2/9] Check hosts hijack (Steam++) ..."
$hijacked = @()
try {
    $hijacked = Select-String -Path $Hosts -Pattern '^\s*127\.0\.0\.1\s+(github\.com|api\.github\.com|raw\.githubusercontent\.com|github\.dev)\s*$' -ErrorAction SilentlyContinue
} catch {}
if ($hijacked -and $hijacked.Count -gt 0) {
    Write-Host "  [WARN] hosts is hijacked by Steam++ ($($hijacked.Count) key lines). Cleaning ..." -ForegroundColor Yellow
    $bak = Backup-Hosts -BakDir (Join-Path $PSScriptRoot 'hosts-backup') -Path $Hosts
    if ($bak) { Write-Host "         backup -> $bak" }
    $lines = Get-Content $Hosts
    $out = @(); $inblk = $false; $removed = 0
    foreach ($ln in $lines) {
        $s = $ln.Trim()
        if ($s -eq '# Steam++ Start') { $inblk = $true }
        if ($inblk) {
            if ($ln -match '^\s*127\.0\.0\.1') { $removed++ }
            if ($s -eq '# Steam++ End') { $inblk = $false }
            continue
        }
        $out += $ln
    }
    # 原子写：被打断时 hosts 保持旧内容，绝不会变成 0 字节（见 net-warp-common.ps1）
    Write-HostsAtomic -Path $Hosts -Value $out | Out-Null
    ipconfig /flushdns | Out-Null
    Write-Host "  [OK] removed $removed hijack lines, DNS cache flushed" -ForegroundColor Green
} else {
    $isEmpty = Test-HostsEffectivelyEmpty -Path $Hosts
    $hasPin = Test-ManagedBlock -Path $Hosts
    if ($isEmpty) {
        Write-Host "  [WARN] hosts is EMPTY (0 bytes) - local custom entries are gone!" -ForegroundColor Yellow
        Write-Host "         [9/9] rebuilds the pinned block only; own lines must come from hosts-backup\." -ForegroundColor DarkGray
    } elseif (-not $hasPin) {
        Write-Host "  [OK] hosts is clean (no pinned block yet - [9/9] will add it)"
    } else {
        Write-Host "  [OK] hosts is clean (pinned block present)"
    }
}
Write-Host ""

# --- 3 --- Steam++ 进程检查（它会重新写 hosts）
Write-Host "[3/9] Check Steam++ process ..."
$sp = Get-Process -Name 'Steam++*' -ErrorAction SilentlyContinue
if ($sp) {
    Write-Host "  [WARN] Steam++ is RUNNING: $($sp.Name -join ', ')" -ForegroundColor Yellow
    Write-Host "         It will re-hijack hosts and break WARP. Killing it ..."
    Stop-Process -Name 'Steam++' -Force -ErrorAction SilentlyContinue
    Stop-Process -Name 'Steam++.Accelerator' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    ipconfig /flushdns | Out-Null
    Write-Host "  [OK] Steam++ stopped"
} else {
    Write-Host "  [OK] Steam++ not running"
}
Write-Host ""

# --- 4 --- WARP -> proxy mode
Write-Host "[4/9] Switch WARP to proxy mode ..."
$text = (& $warpExe mode proxy 2>&1 | Out-String).Trim()
if ($text -notmatch 'Success') {
    Write-Host "  [FAIL] $text" -ForegroundColor Red
    exit 1
}
$text = (& $warpExe proxy port $Port 2>&1 | Out-String).Trim()
if ($text -notmatch 'Success') {
    Write-Host "  [FAIL] could not set port: $text" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] mode=proxy  port=$Port"
Write-Host ""

# --- 5 --- connect + wait（登录自启时会重试，避免网络还没就绪）
Write-Host "[5/9] Establishing tunnel ..."
$listening = $false
for ($i = 1; $i -le 4; $i++) {
    $null = & $warpExe connect 2>&1
    if ($i -eq 1) { Start-Sleep -Seconds 7 } else { Start-Sleep -Seconds 5 }
    $listening = Test-PortListening $Port
    if ($listening) { break }
    Write-Host "  ... retry $i/4 waiting for tunnel" -ForegroundColor DarkGray
}
(& $warpExe status 2>&1) | ForEach-Object { Write-Host "  $_" }
if (-not $listening) {
    Write-Host "  [FAIL] 127.0.0.1:$Port is not listening." -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] SOCKS5 listening on 127.0.0.1:$Port"
Write-Host ""

# --- 6 --- 本地 HTTP->SOCKS5 桥（浏览器用；自己做解析，覆盖全部域名）
Write-Host "[6/9] Start local HTTP bridge (for browser) ..."
$bridgeExe = Join-Path $PSScriptRoot 'net-warp-bridge.exe'
$bridgeTask = 'NetWarp-Bridge'
if (-not (Test-Path $bridgeExe)) {
    Write-Host "  [SKIP] net-warp-bridge.exe not found" -ForegroundColor DarkGray
} elseif (Test-PortListening 7890) {
    Write-Host "  [OK] bridge already on 127.0.0.1:7890"
} else {
    $logDir = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $started = $false
    # 优先用独立计划任务启动（这样不会被本任务的作业对象随任务结束一起回收）
    try {
        if (Get-ScheduledTask -TaskName $bridgeTask -ErrorAction SilentlyContinue) {
            Start-ScheduledTask -TaskName $bridgeTask -ErrorAction Stop
            $started = $true
        }
    } catch { }
    if (-not $started) {
        try {
            Start-Process -FilePath $bridgeExe -WindowStyle Hidden -ArgumentList @(
                '-listen','127.0.0.1:7890','-socks',"127.0.0.1:$Port",
                '-log',(Join-Path $logDir 'net-warp-bridge.log')) -ErrorAction Stop
            $started = $true
        } catch { }
    }
    # 计划任务拉起进程需要时间，轮询最多 15 秒
    $up = $false
    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -Seconds 1
        if (Test-PortListening 7890) { $up = $true; break }
    }
    if ($up) {
        Write-Host "  [OK] bridge listening on 127.0.0.1:7890 (${i}s)"
    } else {
        Write-Host "  [WARN] bridge not listening; browser will fall back to raw SOCKS5" -ForegroundColor Yellow
        Write-Host "         see logs\net-warp-bridge.log" -ForegroundColor DarkGray
    }
}
Write-Host ""

# --- 7 --- git 走 WARP（只对 github 生效，其他源站保持直连）
Write-Host "[7/9] Point git at the tunnel ..."
# 先清掉可能存在的"全量代理"（旧版本留下的），否则 gitee/内网 git 也会被绕到国外
& git config --global --unset http.proxy  2>$null
& git config --global --unset https.proxy 2>$null
# 走本地桥（而非直连 socks5 40000）：域名经桥的 DoH 本地解析更稳，
# 且所有加速流量汇入桥的访问日志（logs/net-warp-bridge-access.log）统一记账
foreach ($gh in @('https://github.com/','https://gist.github.com/')) {
    & git config --global "http.$gh.proxy" "http://127.0.0.1:$script:NetWarpBridgePort" 2>$null
}
$gp = (& git config --global --get 'http.https://github.com/.proxy' 2>$null)
if ($gp) { Write-Host "  [OK] github.com -> $gp  (其他源站直连)" } else { Write-Host "  [WARN] git not found / config failed" -ForegroundColor Yellow }
Write-Host ""

# --- 8 --- smoke test
Write-Host "[8/9] Smoke test ..."
foreach ($h in @('github.com','api.github.com','codeload.github.com','raw.githubusercontent.com')) {
    $res = & curl.exe -s -o NUL -w "%{http_code} %{time_total}" --ssl-no-revoke -x $Socks --max-time 20 "https://$h/" 2>$null
    if ($res) {
        $p = $res -split ' '
        $color = if ($p[0] -match '^[23]') { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-30} -> HTTP {1}  ({2}s)" -f $h, $p[0], $p[1]) -ForegroundColor $color
    } else {
        Write-Host ("  {0,-30} -> FAILED" -f $h) -ForegroundColor Red
    }
}
$lsr = & git ls-remote https://github.com/git/git HEAD 2>&1 | Select-Object -First 1
if ($lsr -match '^[0-9a-f]{40}') {
    Write-Host "  git ls-remote github.com        -> OK ($($lsr.Substring(0,8)))" -ForegroundColor Green
} else {
    Write-Host "  git ls-remote github.com        -> FAILED: $lsr" -ForegroundColor Red
}
Write-Host ""

# --- 9 --- 固定被污染域名的双栈 IP（google / youtube / huggingface / docker ...）
Write-Host "[9/9] Pin poisoned domains (google/youtube) ..."
$refresher = Join-Path $PSScriptRoot 'refresh-poisoned-hosts.ps1'
if (Test-Path $refresher) {
    $rOut = (& $refresher -Port $Port *>&1 | Out-String)
    $pinned = [regex]::Match($rOut, 'resolved A=(\d+)\s+AAAA=(\d+)')
    if ($pinned.Success) {
        Write-Host ("  [OK] pinned A={0} AAAA={1}" -f $pinned.Groups[1].Value, $pinned.Groups[2].Value) -ForegroundColor Green
    } else {
        Write-Host "  [WARN] refresh did not report counts" -ForegroundColor Yellow
    }
    $g = & curl.exe -s -o NUL -w "%{http_code}" --ssl-no-revoke -x $Socks --max-time 15 "https://www.google.com/" 2>$null
    $y = & curl.exe -s -o NUL -w "%{http_code}" --ssl-no-revoke -x $Socks --max-time 15 "https://www.youtube.com/" 2>$null
    Write-Host ("  www.google.com                 -> HTTP {0}" -f $g) -ForegroundColor $(if ($g -match '^[23]') { 'Green' } else { 'Yellow' })
    Write-Host ("  www.youtube.com                -> HTTP {0}" -f $y) -ForegroundColor $(if ($y -match '^[23]') { 'Green' } else { 'Yellow' })
} else {
    Write-Host "  [SKIP] refresh-poisoned-hosts.ps1 not found" -ForegroundColor DarkGray
}
Write-Host ""

Write-Host "=========================================================="
Write-Host "  DONE - tunnel is up" -ForegroundColor Green
Write-Host "=========================================================="
Write-Host "  git 已自动走 WARP，直接 git clone/pull/push 即可。"
Write-Host "  浏览器（含 Google / YouTube / gist / twitter 等全部域名）："
Write-Host "    双击  3-浏览器走加速.bat   （优先走本地桥 7890，最全）"
Write-Host "  关闭：双击  2-关闭加速.bat"
Write-Host ""

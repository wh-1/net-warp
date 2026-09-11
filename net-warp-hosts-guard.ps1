# net-warp-hosts-guard.ps1
# hosts 守护 —— 定期检查 hosts 是否被清空，是则自动从最新非空备份回拷，
# 并把「当时的 hosts 写入者」一并记入日志（追因）。
#
# 由计划任务 NetWarp-HostsGuard 每 10 分钟调用一次（见 net-warp-autostart.ps1）。
# 也可手工运行：powershell -File net-warp-hosts-guard.ps1
#
# 行为约定：
#   - hosts 正常时不写日志（保持静默，避免日志膨胀）
#   - hosts 被清空时：先抓最近的安全日志 4663 事件（需要审计已安装），
#     再回拷 + flushdns，然后把这些都写进 logs\hosts-guard.log
#   - 退出码：0 = 正常或已恢复；1 = 被清空但无可用备份

[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'net-warp-common.ps1')

$BakDir    = Join-Path $PSScriptRoot 'hosts-backup'
$LogDir    = Join-Path $PSScriptRoot 'logs'
$LogFile   = Join-Path $LogDir 'hosts-guard.log'
$HostsPath = Get-HostsPath
$MaxLogB   = 256 * 1024      # 日志上限 256 KB，超出则只留尾部

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-GuardLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    if (-not $Quiet) { Write-Host $line }
}

function Limit-GuardLog {
    try {
        if (-not (Test-Path -LiteralPath $LogFile)) { return }
        $len = ([System.IO.File]::ReadAllBytes($LogFile)).Length
        if ($len -le $MaxLogB) { return }
        $tail = @(Get-Content -LiteralPath $LogFile -Tail 300)
        # 截尾重写走原子替换：Set-Content 打开即截断，写入期间进程被杀 = 整份日志丢
        # （与 hosts 归零同根因）。日志允许为空，故 -AllowEmpty；UTF8 与 Add-Content 一致。
        Write-HostsAtomic -Path $LogFile -Value $tail -AllowEmpty -Encoding ([System.Text.Encoding]::UTF8)
    } catch { }
}

# 抓最近写过 hosts 的进程（依赖 hosts-watch 的审计；没装审计则返回空）
function Get-RecentHostsWriters {
    param([int]$Minutes = 30)
    $res = @()
    try {
        $evs = Get-WinEvent -FilterHashtable @{
            LogName   = 'Security'
            Id        = 4663
            StartTime = (Get-Date).AddMinutes(-$Minutes)
        } -MaxEvents 200 -ErrorAction Stop
    } catch {
        return $res
    }
    foreach ($e in $evs) {
        $m = $e.Message
        if ($m -notmatch 'hosts') { continue }
        $proc = if ($m -match '进程名:\s*(.+?)\s*[\r\n]') { $Matches[1].Trim() } else { '?' }
        $acct = if ($m -match '账户名:\s*(\S+)')          { $Matches[1].Trim() } else { '?' }
        $res += ("{0}  {1}  ({2})" -f $e.TimeCreated.ToString('HH:mm:ss'), $proc, $acct)
    }
    return $res
}

function Get-HostsSize {
    try { return ([System.IO.File]::ReadAllBytes($HostsPath)).Length } catch { return -1 }
}

# ------------------------------------------------------------------ main
Limit-GuardLog

if (-not (Test-HostsEffectivelyEmpty -Path $HostsPath)) {
    # 健康：静默退出
    exit 0
}

Write-GuardLog "DETECTED: hosts is effectively empty (size=$(Get-HostsSize) B)"

# 先抓嫌疑（此时审计若已安装，能看到是谁在上游动的手）
$writers = @(Get-RecentHostsWriters -Minutes 30)
if ($writers.Count -gt 0) {
    Write-GuardLog "  recent hosts writers (last 30 min):"
    foreach ($w in $writers) { Write-GuardLog "    $w" }
} else {
    Write-GuardLog "  no 4663 records in last 30 min (audit not installed, or writer used a non-audited path)"
}

$src = Restore-HostsFromLatest -BakDir $BakDir -Path $HostsPath
if ($src) {
    Write-GuardLog "RESTORED from $(Split-Path $src -Leaf) -> size=$(Get-HostsSize) B"
    $null = ipconfig /flushdns 2>&1
    Write-GuardLog "flushdns done"
    Write-GuardLog "NOTE: run net-warp-hosts-watch.ps1 to inspect who has been writing hosts."
    exit 0
}

Write-GuardLog "FAILED: hosts empty and no usable backup in hosts-backup/"
exit 1

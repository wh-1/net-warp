# net-warp-hosts-watch.ps1
# Hosts 变更追因 —— 汇总"谁动过 hosts"，用于定位清空事故元凶。
#
# 用法：
#   net-warp-hosts-watch.ps1           # 查最近 24 小时的 hosts 写入事件
#   net-warp-hosts-watch.ps1 -Hours 72 # 自定义时间窗
#   net-warp-hosts-watch.ps1 -All      # 不限时间，输出全部
#
# 依赖：hosts 已挂 SACL 审计（由本脚本的 -Setup 安装）+ 审核策略"文件系统"已开。
#   安装：net-warp-hosts-watch.ps1 -Setup
#   卸载：net-warp-hosts-watch.ps1 -Uninstall
#
# 只读为主；-Setup / -Uninstall 需管理员。

[CmdletBinding()]
param(
    [ValidateRange(1, 8760)][int]$Hours = 24,
    [switch]$All,
    [switch]$Setup,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'net-warp-common.ps1')

$HostsPath = Get-HostsPath

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- Setup
function Install-Audit {
    if (-not (Test-IsAdmin)) { Write-Host '[X] 需要管理员权限' -ForegroundColor Red; exit 1 }

    Write-Host '[1/2] 开启「文件系统」审核策略 ...'
    $null = auditpol /set /subcategory:"文件系统" /success:enable /failure:enable 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host '[X] auditpol 失败' -ForegroundColor Red; exit 1 }
    Write-Host '      OK'

    Write-Host '[2/2] 为 hosts 添加 SACL 审计规则 ...'
    $acl = Get-Acl $HostsPath -Audit
    # 清掉旧的本脚本规则，避免重复
    $acl.Audit | Where-Object { $_.IdentityReference -eq 'Everyone' } |
        ForEach-Object { $acl.RemoveAuditRule($_) | Out-Null }

    $rights = [System.Security.AccessControl.FileSystemRights]::WriteData -bor
              [System.Security.AccessControl.FileSystemRights]::AppendData -bor
              [System.Security.AccessControl.FileSystemRights]::Delete
    $flags  = [System.Security.AccessControl.AuditFlags]::Success -bor
              [System.Security.AccessControl.AuditFlags]::Failure
    $rule = New-Object System.Security.AccessControl.FileSystemAuditRule(
        'Everyone', $rights,
        [System.Security.AccessControl.InheritanceFlags]::None,
        [System.Security.AccessControl.PropagationFlags]::None, $flags)
    $acl.AddAuditRule($rule)
    Set-Acl -Path $HostsPath -AclObject $acl
    Write-Host '      OK'

    Write-Host ''
    Write-Host '审计已就位。此后任何进程写 hosts 都会记入「安全」事件日志（ID 4663）。'
    Write-Host '查看：  net-warp-hosts-watch.ps1'
}

# ------------------------------------------------------------ Uninstall
function Remove-Audit {
    if (-not (Test-IsAdmin)) { Write-Host '[X] 需要管理员权限' -ForegroundColor Red; exit 1 }
    $acl = Get-Acl $HostsPath -Audit
    $removed = 0
    @($acl.Audit) | Where-Object { $_.IdentityReference -eq 'Everyone' } | ForEach-Object {
        $acl.RemoveAuditRule($_) | Out-Null; $removed++
    }
    Set-Acl -Path $HostsPath -AclObject $acl
    Write-Host "[OK] 已移除 $removed 条 hosts 审计规则（审核策略未动，如需全关用 auditpol /clear）"
}

# ---------------------------------------------------------------- Report
function Show-Report {
    $since = if ($All) { [datetime]::MinValue } else { (Get-Date).AddHours(-$Hours) }
    Write-Host ''
    Write-Host '=== hosts 写入事件（安全日志 4663） ===' -ForegroundColor Cyan
    Write-Host ("时间窗: " + $(if ($All) { '全部' } else { "最近 $Hours 小时（$($since.ToString('MM-dd HH:mm')) 起）" }))
    Write-Host ''

    $events = @()
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Security'
            Id        = 4663
            StartTime = $since
        } -ErrorAction SilentlyContinue
    } catch { }

    if (-not $events -or $events.Count -eq 0) {
        Write-Host '（无记录）' -ForegroundColor Yellow
        Write-Host '  可能原因：① 审计刚装上，还没发生写入；② hosts 未被修改过。'
        return
    }

    $rows = foreach ($e in $events) {
        $m = $e.Message
        if ($m -notmatch 'hosts') { continue }
        $proc = if ($m -match '进程名:\s*(.+?)\s*[\r\n]')  { $Matches[1].Trim() } else { '?' }
        $pid_ = if ($m -match '进程 ID:\s*(\S+)')          { $Matches[1].Trim() } else { '?' }
        $acct = if ($m -match '账户名:\s*(\S+)')           { $Matches[1].Trim() } else { '?' }
        [pscustomobject]@{
            时间   = $e.TimeCreated.ToString('MM-dd HH:mm:ss')
            进程   = Split-Path $proc -Leaf
            PID    = $pid_
            账户   = $acct
            路径   = $proc
        }
    }

    if (-not $rows) { Write-Host '（无匹配 hosts 的记录）' -ForegroundColor Yellow; return }

    $rows | Sort-Object 时间 -Descending | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host

    Write-Host '--- 按进程聚合 ---' -ForegroundColor Cyan
    $rows | Group-Object 进程 | Sort-Object Count -Descending |
        Select-Object Count, Name | Format-Table -AutoSize | Out-String -Width 120 | Write-Host

    Write-Host '提示：若某进程名可疑（非 net-warp 脚本、非编辑器），即为元凶候选。'
    Write-Host '      net-warp 自身的写入来自 powershell.exe 跑 refresh-poisoned-hosts.ps1。'
}

# ------------------------------------------------------------------ Main
if ($Setup)     { Install-Audit;  return }
if ($Uninstall) { Remove-Audit;   return }
Show-Report

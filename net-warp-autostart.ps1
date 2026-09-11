# net-warp - 开机自启 / 状态 / 体检 开关
# 用法：net-warp-autostart.ps1 on       -> 注册登录自启任务（含本地桥与 hosts 守护）
#       net-warp-autostart.ps1 off      -> 移除
#       net-warp-autostart.ps1 status   -> 只看任务与运行态
#       net-warp-autostart.ps1 doctor   -> 全链路体检（推荐排障第一步）
#       net-warp-autostart.ps1 restart  -> 重启本地桥
#
# 注册三个任务：
#   NetWarp-OnLogon    登录后 30s 跑 net-warp-logon.cmd（加速主流程）
#   NetWarp-Bridge     登录后 40s 跑 net-warp-bridge.exe（浏览器用的本地 HTTP 桥）
#   NetWarp-HostsGuard 登录后 + 之后每 10 分钟跑 net-warp-hosts-guard.ps1
#                      （检测 hosts 被清空则自动回拷，并记录当时的写入者）
#   三者都是最高权限、无 UAC 弹窗。

param([string]$Mode = 'status')

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'net-warp-common.ps1')

$AccelTask  = 'NetWarp-OnLogon'
$BridgeTask = 'NetWarp-Bridge'
$GuardTask  = 'NetWarp-HostsGuard'
$AccelCmd   = Join-Path $PSScriptRoot 'net-warp-logon.cmd'
$BridgeExe  = Join-Path $PSScriptRoot 'net-warp-bridge.exe'
$GuardPs1   = Join-Path $PSScriptRoot 'net-warp-hosts-guard.ps1'
$LogDir     = Join-Path $PSScriptRoot 'logs'
$BakDir     = Join-Path $PSScriptRoot 'hosts-backup'

function Show-One($name) {
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host "  [$name] 未注册"; return }
    $i = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
    Write-Host "  [$name] State=$($t.State)  RunLevel=$($t.Principal.RunLevel)  LogonType=$($t.Principal.LogonType)"
    foreach ($a in $t.Actions) { Write-Host "      动作: $($a.Execute) $($a.Arguments)" }
    foreach ($g in $t.Triggers) { Write-Host "      触发: $($g.CimClass.CimClassName) 延迟=$($g.Delay)" }
    Write-Host "      时限: $($t.Settings.ExecutionTimeLimit)   失败重启: $($t.Settings.RestartCount) 次"
    if ($i) {
        # 2147946720 = 0x800710E0，常驻任务的陈旧完成码（上次计划运行被跳过），桥进程实际在听端口就无影响。
        # 显示层直接消化掉，不再裸露让人工解释。
        # 坑：PS 5.1 里 0x800710E0 字面量按 Int32 有符号解析 = -2147020576，跟 LastTaskResult
        # （UInt32 = 2147946720）永不相等 → 比较必须用十进制字面量。
        if ($name -eq $BridgeTask -and $i.LastTaskResult -eq 2147946720) {
            Write-Host "      上次: $($i.LastRunTime)  结果=常驻运行中（陈旧完成码已忽略）"
        } else {
            Write-Host "      上次: $($i.LastRunTime)  结果=$($i.LastTaskResult)"
        }
    }
}

function Show-Status {
    Write-Host "  --- 计划任务 ---"
    Show-One $AccelTask
    Show-One $BridgeTask
    Show-One $GuardTask
    Write-Host "  --- 运行态 ---"
    Write-Host "      WARP SOCKS5 40000 : $(if (Test-PortListening 40000) {'在听'} else {'未监听'})"
    Write-Host "      本地桥 7890       : $(if (Test-PortListening 7890) {'在听'} else {'未监听'})"
    Write-Host "      日志              : $LogDir\net-warp-on.log , $LogDir\net-warp-bridge.log , $LogDir\hosts-guard.log"
}

function Show-Doctor {
    $HostsPath = Get-HostsPath
    $issues = @()

    Write-Host "  --- 1. WARP 客户端 ---"
    $warpExe = Get-WarpCli
    if (-not $warpExe) {
        Write-Host "    [FAIL] 找不到 warp-cli" -ForegroundColor Red
        $issues += "warp-cli 缺失"
    } else {
        $st = ((& $warpExe status 2>&1 | Out-String).Trim() -replace "`r?`n", ' | ')
        Write-Host "    $st"
        if ($st -notmatch 'Connected') { Write-Host "    [WARN] WARP 未连接" -ForegroundColor Yellow; $issues += "WARP 未连接" }
    }

    Write-Host "  --- 2. 端口 ---"
    $s40000 = Test-PortListening 40000
    $s7890  = Test-PortListening 7890
    Write-Host "    WARP SOCKS5 40000 : $(if ($s40000) {'在听'} else {'未监听'})" -ForegroundColor $(if ($s40000) { 'Green' } else { 'Red' })
    Write-Host "    本地桥 7890       : $(if ($s7890) {'在听'} else {'未监听'})" -ForegroundColor $(if ($s7890) { 'Green' } else { 'Red' })
    if (-not $s40000) { $issues += '40000 未监听' }
    if (-not $s7890) { $issues += '桥 7890 未监听（浏览器会退回裸 SOCKS5）' }

    Write-Host "  --- 3. git 代理 ---"
    foreach ($k in @('http.https://github.com/.proxy', 'http.https://gist.github.com/.proxy')) {
        $v = (& git config --global --get $k 2>$null)
        Write-Host "    $k = $(if ($v) { $v } else { '(未设置)' })" -ForegroundColor $(if ($v) { 'Green' } else { 'DarkGray' })
    }
    $all = (& git config --global --get http.proxy 2>$null)
    if ($all) {
        Write-Host "    [WARN] 存在全量 http.proxy=$all，会把 gitee/内网也绕出国" -ForegroundColor Yellow
        $issues += 'git 全量代理'
    }

    Write-Host "  --- 4. hosts ---"
    if (Test-Path -LiteralPath $HostsPath) {
        # 用 ReadAllBytes 读取，避免 Get-Item 的 FileInfo 缓存（同会话内可能返回旧长度）
        $len = 0
        try { $len = ([System.IO.File]::ReadAllBytes($HostsPath)).Length } catch { }
        $lines = @(Get-Content -LiteralPath $HostsPath).Count
        $hasBlock = Test-ManagedBlock -Path $HostsPath
        Write-Host "    大小 $len B / $lines 行   托管块: $(if ($hasBlock) {'有'} else {'无'})" -ForegroundColor $(if ($hasBlock) { 'Green' } else { 'Yellow' })
        if (Test-HostsEffectivelyEmpty -Path $HostsPath) {
            # 自愈：从最新非空备份回拷（管理员权限下才写得进 hosts）
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                       ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if ($isAdmin) {
                $src = Restore-HostsFromLatest -BakDir $BakDir -Path $HostsPath
                if ($src) {
                    $len2 = 0
                    try { $len2 = ([System.IO.File]::ReadAllBytes($HostsPath)).Length } catch { }
                    $lines2 = @(Get-Content -LiteralPath $HostsPath).Count
                    $blk2   = Test-ManagedBlock -Path $HostsPath
                    Write-Host "    [FIXED] hosts 曾被清空，已自动回拷：$(Split-Path $src -Leaf)" -ForegroundColor Green
                    Write-Host "            现为 $len2 B / $lines2 行   托管块: $(if ($blk2) {'有'} else {'无'})" -ForegroundColor Green
                    $issues += 'hosts 曾被清空（已自动恢复）'
                } else {
                    Write-Host "    [FAIL] hosts 是空文件，且无可用备份可回拷！" -ForegroundColor Red
                    $issues += 'hosts 被清空（无备份）'
                }
            } else {
                Write-Host "    [FAIL] hosts 是空文件！用管理员运行本命令可自动回拷（或手动从 hosts-backup 取）" -ForegroundColor Red
                $issues += 'hosts 被清空'
            }
        } elseif (-not $hasBlock) {
            Write-Host "    [WARN] 无固定块 → google/youtube 经 40000 会卡 5s（刷一次 5 号 bat 即可）" -ForegroundColor Yellow
            $issues += 'hosts 缺托管块'
        }
    } else {
        Write-Host "    [FAIL] hosts 文件不存在" -ForegroundColor Red
        $issues += 'hosts 缺失'
    }
    # 最近「可恢复」备份（排除 *empty* 现场快照，否则显示的可能是 0 字节事故文件）
    $allBk  = @(Get-ChildItem -LiteralPath $BakDir -Filter 'hosts.bak-*.txt' -ErrorAction SilentlyContinue)
    $goodBk = @($allBk | Where-Object { $_.Name -notlike '*empty*' } | Sort-Object LastWriteTime -Descending)
    $snapN  = @($allBk | Where-Object { $_.Name -like '*empty*' }).Count
    if ($goodBk.Count -gt 0) {
        Write-Host ("    可恢复备份: {0}（{1} 份，另有 {2} 份事故快照）" -f $goodBk[0].Name, $goodBk.Count, $snapN) -ForegroundColor DarkGray
    }

    # 原子写自检 —— hosts 必须走 ReplaceFile 原子替换。
    # 若退化成「截断 + 写」，写入期间进程被强杀就会把 hosts 打成 0 字节（历史两次事故）。
    $awProbe = Join-Path ([System.IO.Path]::GetTempPath()) ('netwarp-awtest-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($awProbe, "seed`r`n")
        Write-HostsAtomic -Path $awProbe -Value @('# atomic-write self-test', '127.0.0.1 localhost') | Out-Null
        $awMode = $global:NetWarpLastHostsWriteMode
        $awOk   = ($awMode -eq 'ReplaceFile') -and ([System.IO.File]::ReadAllText($awProbe)).Contains('atomic-write self-test')
        if ($awOk) {
            Write-Host "    原子写自检        : OK (ReplaceFile)" -ForegroundColor Green
        } else {
            Write-Host "    [WARN] 原子写自检 : $awMode" -ForegroundColor Yellow
            $issues += '原子写退化（非 ReplaceFile）'
        }
    } catch {
        Write-Host "    [WARN] 原子写自检 : $($_.Exception.Message)" -ForegroundColor Yellow
        $issues += '原子写不可用'
    } finally {
        try { [System.IO.File]::Delete($awProbe) } catch { }
    }

    Write-Host "  --- 5. 连通性（分层：端到端 = 真实链路，上游 = 跳过桥直测 WARP，用于出问题时定位是谁的锅） ---"
    $r = (& git ls-remote https://github.com/git/git HEAD 2>&1 | Select-Object -First 1)
    $gitOk = ($r -match '^[0-9a-f]{40}')
    Write-Host "    git ls-remote github (经桥) : $(if ($gitOk) { "OK ($($r.Substring(0,8)))" } else { "FAIL: $r" })" -ForegroundColor $(if ($gitOk) { 'Green' } else { 'Red' })
    if (-not $gitOk) { $issues += 'git ls-remote 不通' }

    if ($s40000) {
        $g = & curl.exe -s -k -o NUL -w "%{http_code} %{time_total}s" --ssl-no-revoke --socks5-hostname 127.0.0.1:40000 --max-time 20 https://www.google.com/ 2>$null
        $ok = ($g -match '^[23]')
        Write-Host "    WARP 40000 (上游直测) -> google.com : $g" -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
        if (-not $ok) { $issues += 'google 经 40000 失败（多为 hosts 问题）' }
    }
    if ($s7890) {
        $y = & curl.exe -s -k -o NUL -w "%{http_code}" --ssl-no-revoke -x http://127.0.0.1:7890 --max-time 20 https://www.youtube.com/ 2>$null
        $ok = ($y -match '^[23]')
        Write-Host "    桥 7890 (端到端) -> youtube.com : $y" -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
        if (-not $ok) { $issues += '桥不通' }
    }

    Write-Host "  --- 6. 日志 ---"
    foreach ($f in @('net-warp-on.log', 'net-warp-bridge.log')) {
        $p = Join-Path $LogDir $f
        if (Test-Path -LiteralPath $p) {
            $it = Get-Item -LiteralPath $p
            Write-Host "    $f : $([math]::Round($it.Length / 1KB, 1)) KB  ($($it.LastWriteTime.ToString('MM-dd HH:mm')))" -ForegroundColor DarkGray
            if ($it.Length -gt 5MB) { $issues += "$f 超过 5MB" }
        } else {
            Write-Host "    $f : (无)" -ForegroundColor DarkGray
        }
    }

    Write-Host "  --- 7. 任务设置 ---"
    foreach ($n in @($AccelTask, $BridgeTask, $GuardTask)) {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        if (-not $t) {
            Write-Host "    [$n] 未注册" -ForegroundColor Yellow
            # 守护任务缺失只算 WARN（加速本身仍可用，只是丢了 hosts 自愈）
            if ($n -eq $GuardTask) { Write-Host "      [WARN] hosts 失去自动守护 → 跑 4 号 bat 选 on 补上" -ForegroundColor Yellow }
            else { $issues += "$n 未注册" }
            continue
        }
        $lim = $t.Settings.ExecutionTimeLimit
        $rc = $t.Settings.RestartCount
        Write-Host "    [$n] State=$($t.State)  时限=$lim  失败重启=$rc" -ForegroundColor DarkGray
        if ($n -eq $BridgeTask) {
            if ($lim -and $lim -ne 'PT0S') {
                Write-Host "      [FAIL] 常驻桥被设了执行时限（$lim 后会被强杀）→ 跑 4 号 bat 选 on 重新注册" -ForegroundColor Red
                $issues += '桥有执行时限'
            }
            if (-not $rc -or $rc -eq 0) { Write-Host "      [WARN] 桥没有失败重启策略" -ForegroundColor Yellow }
        }
    }

    # hosts 守护日志（有内容 = 发生过自动恢复，值得看一眼）
    # 注意：不要写成 Test-Path ... -and ReadAllBytes(...) —— PS 会把 -and 当参数解析，
    # 导致文件不存在时仍调用 ReadAllBytes 抛 FileNotFoundException。用嵌套 if。
    $glog = Join-Path $LogDir 'hosts-guard.log'
    if (Test-Path -LiteralPath $glog) {
        $gsize = ([System.IO.File]::ReadAllBytes($glog)).Length
        if ($gsize -gt 0) {
            $gcnt = @(Select-String -Path $glog -Pattern 'DETECTED:' -SimpleMatch).Count
            Write-Host "    [守护] hosts-guard.log 有记录：检测到 $gcnt 次清空事件" -ForegroundColor Yellow
            Write-Host "           详情：$glog（或跑 net-warp-hosts-watch.ps1）" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    if ($issues.Count -eq 0) {
        Write-Host "  ===== 体检结论：全部正常 =====" -ForegroundColor Green
    } else {
        Write-Host "  ===== 体检结论：$($issues.Count) 项异常 =====" -ForegroundColor Red
        foreach ($i in $issues) { Write-Host "     - $i" -ForegroundColor Yellow }
    }
}

function Restart-Bridge {
    if (Get-ScheduledTask -TaskName $BridgeTask -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $BridgeTask -ErrorAction SilentlyContinue
    }
    Get-Process -Name 'net-warp-bridge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-ScheduledTask -TaskName $BridgeTask -ErrorAction SilentlyContinue)) {
        Write-Host "  [FAIL] $BridgeTask 未注册，先跑 4 号 bat 选 on" -ForegroundColor Red
        return
    }
    Start-ScheduledTask -TaskName $BridgeTask
    for ($i = 1; $i -le 15; $i++) { Start-Sleep -Seconds 1; if (Test-PortListening 7890) { break } }
    if (Test-PortListening 7890) {
        Write-Host "  [OK] bridge restarted on 127.0.0.1:7890 (${i}s)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] bridge not listening, see $LogDir\net-warp-bridge.log" -ForegroundColor Red
    }
}

function Register-All {
    $who = "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    if (Test-Path $AccelCmd) {
        $act = New-ScheduledTaskAction -Execute $AccelCmd -WorkingDirectory $PSScriptRoot
        $trg = New-ScheduledTaskTrigger -AtLogOn -User $who
        $trg.Delay = 'PT30S'
        $null = Register-ScheduledTask -TaskName $AccelTask -Action $act -Trigger $trg `
                  -Principal $principal -Settings $settings -Force -ErrorAction Stop
        Write-Host "  [OK] $AccelTask 已注册" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] 找不到 $AccelCmd" -ForegroundColor Yellow
    }

    if (Test-Path $BridgeExe) {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $ba = '-listen 127.0.0.1:7890 -socks 127.0.0.1:40000 -log "' + (Join-Path $LogDir 'net-warp-bridge.log') + '"'
        $act = New-ScheduledTaskAction -Execute $BridgeExe -Argument $ba -WorkingDirectory $PSScriptRoot
        $trg = New-ScheduledTaskTrigger -AtLogOn -User $who
        $trg.Delay = 'PT40S'
        # 桥是常驻进程，必须【显式】把执行时限设为 0：
        #   New-ScheduledTaskSettingsSet 的默认值是 PT72H —— 桥会在跑满 72 小时时被
        #   任务计划程序强杀，而且不重启，浏览器加速就此静默失效（git 仍正常，很难察觉）。
        # 再补失败重启：桥进程非 0 退出后 1 分钟自动拉起，最多 3 次。
        $bset = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                  -ExecutionTimeLimit ([TimeSpan]::Zero) `
                  -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        $null = Register-ScheduledTask -TaskName $BridgeTask -Action $act -Trigger $trg `
                  -Principal $principal -Settings $bset -Force -ErrorAction Stop
        Write-Host "  [OK] $BridgeTask 已注册（无执行时限 + 失败重启 3 次）" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] 找不到 $BridgeExe（浏览器将退回裸 SOCKS5）" -ForegroundColor Yellow
    }

    if (Test-Path $GuardPs1) {
        $ga = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $GuardPs1 + '" -Quiet'
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $ga -WorkingDirectory $PSScriptRoot

        # 触发 1：登录后 2 分钟跑一次（等加速主流程写完 hosts）
        $trg1 = New-ScheduledTaskTrigger -AtLogOn -User $who
        $trg1.Delay = 'PT2M'
        # 触发 2：之后每 10 分钟一次，从开机起算
        $trg2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3) `
                  -RepetitionInterval (New-TimeSpan -Minutes 10)

        # 短任务，但仍显式设 0，避免 PT72H 默认值带来的意外；
        # MultipleInstances=IgnoreNew 防止上一轮没跑完时叠加。
        $gset = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -StartWhenAvailable -MultipleInstances IgnoreNew `
                  -ExecutionTimeLimit ([TimeSpan]::Zero)
        $null = Register-ScheduledTask -TaskName $GuardTask -Action $act -Trigger @($trg1, $trg2) `
                  -Principal $principal -Settings $gset -Force -ErrorAction Stop
        Write-Host "  [OK] $GuardTask 已注册（登录后 + 每 10 分钟检查 hosts）" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] 找不到 $GuardPs1（hosts 失去自动守护）" -ForegroundColor Yellow
    }
}

function Unregister-All {
    foreach ($n in @($AccelTask, $BridgeTask, $GuardTask)) {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        if ($t) {
            if ($t.State -eq 'Running') { Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue }
            Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  [OK] 已移除 $n" -ForegroundColor Green
        } else {
            Write-Host "  [SKIP] $n 本来就没注册"
        }
    }
    if (Get-Process -Name 'net-warp-bridge' -ErrorAction SilentlyContinue) {
        Stop-Process -Name 'net-warp-bridge' -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] 已结束 net-warp-bridge 进程"
    }
}

switch ($Mode.ToLower()) {
    'on' { Register-All; Write-Host ""; Show-Status }
    'off' { Unregister-All; Write-Host ""; Show-Status }
    'doctor' { Show-Doctor }
    'restart' { Restart-Bridge }
    default { Show-Status }
}

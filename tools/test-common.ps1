# net-warp-common.ps1 隔离测试 —— 一律用「假 hosts」，绝不碰真 hosts
# 路径全部走 $PSScriptRoot 推导，随项目搬迁零改动。
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'net-warp-common.ps1')

$out    = @()
$work   = Join-Path $PSScriptRoot 'common-test-work'
if ([System.IO.Directory]::Exists($work)) { [System.IO.Directory]::Delete($work, $true) }
[System.IO.Directory]::CreateDirectory($work) | Out-Null

# ---------- 1) 托管块读写 ----------
$tmp = Join-Path $work 'hosts-test.txt'
@'
# Copyright (c) 1993-2009 Microsoft Corp.
# sample comment line
127.0.0.1       activate.navicat.com
127.0.0.1 aiot.us.ci
# WARP-Accel Start
1.2.3.4	google.com
::1	youtube.com
# WARP-Accel End
# tail comment must survive
9.9.9.9	keepme.example
'@ | Set-Content -Path $tmp -Encoding ASCII

$out += "before lines = " + (@(Get-Content $tmp).Count)
$out += "Test-ManagedBlock = " + (Test-ManagedBlock -Path $tmp)
$n = Remove-ManagedBlock -Path $tmp
$out += "removed lines = $n"
$after = @(Get-Content $tmp)
$out += "after lines = " + $after.Count
$out += "--- content after ---"
foreach ($l in $after) { $out += "  |$l" }
$out += "--- assertions ---"
$out += "user entry navicat kept   : " + ($after -match 'navicat').Count
$out += "user entry aiot kept      : " + ($after -match 'aiot').Count
$out += "tail comment kept         : " + ($after -match 'tail comment').Count
$out += "block marker gone         : " + (($after -match 'WARP-Accel').Count -eq 0)
$out += "pinned google gone        : " + (($after -match 'google.com').Count -eq 0)
$out += "Test-ManagedBlock now     : " + (Test-ManagedBlock -Path $tmp)
$out += "Test-PortListening 7890   : " + (Test-PortListening 7890)
$out += "Get-WarpCli               : " + (Get-WarpCli)
$out += "Get-HostsPath             : " + (Get-HostsPath)

# ---------- 2) Restore-HostsFromLatest 隔离测试 ----------
$fakeBak = Join-Path $work 'fakebak'
[System.IO.Directory]::CreateDirectory($fakeBak) | Out-Null

$good = Join-Path $fakeBak 'hosts.bak-20260101-000001.txt'
Set-Content -Path $good -Value "9.9.9.9`tgood.example" -Encoding ASCII
$emptySnap = Join-Path $fakeBak 'hosts.bak-empty-20260101-000002.txt'
Set-Content -Path $emptySnap -Value '' -Encoding ASCII

$fakeHosts = Join-Path $fakeBak 'fakehosts'
Set-Content -Path $fakeHosts -Value '' -Encoding ASCII

$out += ""
$out += "--- Restore-HostsFromLatest ---"
$out += "latest-good backup        : " + (Split-Path (Get-LatestGoodHostsBackup -BakDir $fakeBak) -Leaf)

# A: 0 字节 -> 应自愈
[System.IO.File]::WriteAllText($fakeHosts, '')
$out += "A) 0-byte  effectivelyEmpty = " + (Test-HostsEffectivelyEmpty -Path $fakeHosts)
$r = Restore-HostsFromLatest -BakDir $fakeBak -Path $fakeHosts
$out += "   restore returned        : " + $(if ($r) { Split-Path $r -Leaf } else { '$null' })
$out += "   content now             : [" + (Get-Content $fakeHosts -Raw).Trim() + "]"

# B: 只有 CRLF -> 也应判定为空（曾漏判）
[System.IO.File]::WriteAllText($fakeHosts, "`r`n")
$out += "B) CRLF-only effectivelyEmpty = " + (Test-HostsEffectivelyEmpty -Path $fakeHosts)
$r = Restore-HostsFromLatest -BakDir $fakeBak -Path $fakeHosts
$out += "   restore returned        : " + $(if ($r) { Split-Path $r -Leaf } else { '$null' })

# C: 已非空 -> 不应再动
$out += "C) non-empty effectivelyEmpty = " + (Test-HostsEffectivelyEmpty -Path $fakeHosts)
$r2 = Restore-HostsFromLatest -BakDir $fakeBak -Path $fakeHosts
$out += "   restore returned        : " + $(if ($null -eq $r2) { '$null OK' } else { 'NOT NULL!' })
$out += "snapshot count (-empty-)  : " + (@(Get-ChildItem $fakeBak -Filter '*empty*').Count)

# ---------- 3) Write-HostsAtomic 隔离测试 ----------
$out += ""
$out += "--- Write-HostsAtomic ---"
$aw = Join-Path $work 'atomic-hosts'
[System.IO.File]::WriteAllText($aw, "1.1.1.1`told.example`r`n")
Start-Sleep -Milliseconds 1100
$ctBefore = [System.IO.File]::GetCreationTimeUtc($aw)

# D: 正常写 -> 内容正确 + CreationTime 保留 + 无残留临时文件
$payload = @('# WARP-Accel Start', '1.2.3.4 google.com', '# WARP-Accel End')
$len = Write-HostsAtomic -Path $aw -Value $payload
$afterD = @(Get-Content -LiteralPath $aw)
$ctAfter = [System.IO.File]::GetCreationTimeUtc($aw)
$out += "D) written bytes           = $len"
$out += "   lines                   = " + $afterD.Count
$out += "   content ok              = " + (($afterD -join '|') -eq ($payload -join '|'))
$out += "   write mode              = " + $global:NetWarpLastHostsWriteMode
$out += "   CreationTime preserved  = " + ($ctBefore -eq $ctAfter)
$out += "   leftover tmp files      = " + (@(Get-ChildItem $work -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '.hosts.new.*' -or $_.Name -like '.hosts.old.*' }).Count)

# E: 空 payload 必须被拒（护栏）—— 这是「写空」事故的最后一道闸
$errE = ''
try { Write-HostsAtomic -Path $aw -Value @() | Out-Null } catch { $errE = $_.Exception.Message }
$sizeE = [System.IO.File]::ReadAllBytes($aw).Length
$out += "E) empty payload rejected  = " + ($errE -ne '')
$out += "   file NOT zeroed         = " + ($sizeE -gt 0) + " (size=$sizeE)"

# F: 历史毁灭路径 —— hosts 只剩托管块时 Remove-ManagedBlock 必须拒绝写空
$onlyBlk = Join-Path $work 'block-only-hosts'
Set-Content -Path $onlyBlk -Value @('# WARP-Accel Start', '1.2.3.4 google.com', '# WARP-Accel End') -Encoding ASCII
$errF = ''
try { Remove-ManagedBlock -Path $onlyBlk | Out-Null } catch { $errF = $_.Exception.Message }
$sizeF = [System.IO.File]::ReadAllBytes($onlyBlk).Length
$out += "F) block-only refused      = " + ($errF -ne '')
$out += "   file NOT zeroed         = " + ($sizeF -gt 0) + " (size=$sizeF)"

# G) 回归：含空行的正常写入必须成功（Mandatory 默认拒空串，漏 AllowEmptyString 会误拦）
$blankFile = Join-Path $work 'blank-hosts'
[System.IO.File]::WriteAllText($blankFile, "seed`r`n")
$payloadG = @('# Copyright (c)', '', '127.0.0.1 aiot.us.ci', '', '# WARP-Accel Start', '1.2.3.4 google.com', '# WARP-Accel End')
$errG = ''
$lenG = 0
try { $lenG = Write-HostsAtomic -Path $blankFile -Value $payloadG } catch { $errG = $_.Exception.Message }
$afterG = @(Get-Content -LiteralPath $blankFile)
$out += "G) write with blank lines  = " + ($errG -eq '')
$out += "   bytes / lines           = $lenG / " + $afterG.Count
$out += "   content roundtrip ok    = " + (($afterG -join '|') -eq ($payloadG -join '|'))
if ($errG) { $out += "   err: $errG" }

$out | Out-File -Encoding utf8 (Join-Path $PSScriptRoot 'common-test.txt')
[System.IO.Directory]::Delete($work, $true)
'ok'

# net-warp-common.ps1 —— 公共函数库（本地路径推导，随项目整体搬迁）
# ---------------------------------------------------------------
# 由 net-warp-on.ps1 / net-warp-off.ps1 / net-warp-autostart.ps1 /
# refresh-poisoned-hosts.ps1 通过 dot-source 引用：
#     . (Join-Path $PSScriptRoot 'net-warp-common.ps1')
# 只放跨脚本复用的东西：warp-cli 定位、端口探测、hosts 托管块操作。
# ---------------------------------------------------------------

$script:NetWarpPort      = 40000
$script:NetWarpBridgePort = 7890
$script:HostsMarkStart = '# WARP-Accel Start'
$script:HostsMarkEnd   = '# WARP-Accel End'

function Get-HostsPath { "$env:SystemRoot\System32\drivers\etc\hosts" }

# 定位 warp-cli：先 PATH，再两个标准安装位置；找不到返回 $null
function Get-WarpCli {
    $cmd = Get-Command warp-cli -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @(
            "$env:ProgramFiles\Cloudflare\Cloudflare WARP\warp-cli.exe",
            "${env:ProgramFiles(x86)}\Cloudflare\Cloudflare WARP\warp-cli.exe")) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Test-PortListening {
    param([int]$Port = $script:NetWarpPort)
    return ((netstat -an | Select-String ("127\.0\.0\.1:" + $Port + "\s.*LISTENING")) -ne $null)
}

# hosts 里是否存在托管块
function Test-ManagedBlock {
    param([string]$Path = (Get-HostsPath))
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return [bool](Select-String -Path $Path -Pattern ('^\s*' + [regex]::Escape($script:HostsMarkStart) + '\s*$') -Quiet -ErrorAction SilentlyContinue)
}

# 备份 hosts；hosts 为空（0 字节或全空白）时返回 $null（避免写出垃圾备份）
function Backup-Hosts {
    param([string]$BakDir, [string]$Path = (Get-HostsPath))
    if (-not (Test-Path -LiteralPath $BakDir)) { New-Item -ItemType Directory -Path $BakDir -Force | Out-Null }
    # 用 ReadAllBytes 判定，不用 Get-Item.Length —— 同一会话内 Get-Item 会返回缓存 FileInfo
    if (Test-HostsEffectivelyEmpty -Path $Path) { return $null }
    $dst = Join-Path $BakDir ("hosts.bak-{0}.txt" -f (Get-Date -Format yyyyMMdd-HHmmss))
    Copy-Item -LiteralPath $Path -Destination $dst -Force
    return $dst
}

# 原子写 hosts：先写同目录临时文件，再用 NTFS ReplaceFile 原子替换。
#
# 【为什么必须原子写 —— 2026-09-11 事故根因】
#   Set-Content / Out-File 的语义是「打开即截断 + 逐块写」。实测（3,188,894 字节的
#   文件，写 700ms 后杀进程）→ 文件只剩 147 字节；写入极早期被杀 → 0 字节。
#   即：进程只要在 hosts 写入期间被强制终止（手动关窗口 / 任务管理器结束进程 /
#   taskkill / 计划任务超时回收），hosts 就会停在「已写入的部分」—— 常见表现正是
#   0 字节，且 LastWrite = 打开（截断）时刻、CreationTime 不变（原地截断，非重建）。
#   历史上两次 hosts 归零（09-10 17:14、09-11 00:36）都发生在
#   「先 Backup-Hosts 成功 → 紧接着写 → 0 字节」的时序上，与此特征完全一致。
#   原子写保证 hosts 永远要么是旧内容、要么是完整新内容，没有中间态。
#   ReplaceFile 会保留目标原有的 ACL / CreationTime / 文件属性。
function Write-HostsAtomic {
    param(
        # 必须同时允许空集合与空字符串：Mandatory 默认拒绝空字符串，
        # 而 hosts 正文里本来就有空行 —— 漏了 AllowEmptyString 会导致
        # 「含空行的正常写入」被误拦（实测踩到）。
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Value,
        [string]$Path = (Get-HostsPath),
        [switch]$AllowEmpty,
        # 可选编码：默认 ASCII（hosts 正文本就纯 ASCII，行为不变）。
        # 其他文本文件（如 guard 日志）传 [System.Text.Encoding]::UTF8 复用本函数。
        [System.Text.Encoding]$Encoding = $null
    )
    $dir = Split-Path -Parent $Path

    # 清理上次异常残留的临时文件（> 1 小时）
    try {
        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '.hosts.new.*' -or $_.Name -like '.hosts.old.*' } |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
            ForEach-Object { [System.IO.File]::Delete($_.FullName) }
    } catch { }

    $text = ''
    if ($Value -and $Value.Count -gt 0) { $text = ($Value -join "`r`n") + "`r`n" }

    # 内容护栏：hosts 正常绝不该被写空 —— 一律拦住，避免「写空」变成事故
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($text)) {
        throw 'Write-HostsAtomic refused: payload is empty. Pass -AllowEmpty to override.'
    }

    $id     = [guid]::NewGuid().ToString('N')
    $tmp    = Join-Path $dir ('.hosts.new.' + $id)
    $tmpOld = Join-Path $dir ('.hosts.old.' + $id)
    $enc = if ($Encoding) { $Encoding } else { [System.Text.Encoding]::ASCII }
    [System.IO.File]::WriteAllText($tmp, $text, $enc)

    try {
        if ([System.IO.File]::Exists($Path)) {
            # ReplaceFile 是唯一「真正原子」且原生保留目标 ACL / CreationTime /
            # 文件属性的替换方式。
            # 【坑】第 3 个参数必须给真实路径：传 $null 或 [NullString]::Value 都会抛
            # 异常（"路径的形式不合法" / "在活动的激活上下文中找不到任何查找密钥"），
            # 于是静默退化到非原子的兜底分支。
            [System.IO.File]::Replace($tmp, $Path, $tmpOld)
            try { [System.IO.File]::Delete($tmpOld) } catch { }
            $global:NetWarpLastHostsWriteMode = 'ReplaceFile'
        } else {
            [System.IO.File]::Move($tmp, $Path)
            $global:NetWarpLastHostsWriteMode = 'Move-new'
        }
    } catch {
        # 兜底：Replace 失败（目标被占用 / 权限）时退回强制移动。
        # PowerShell 的 Move-Item -Force 会重建文件（不保留 CreationTime），故显式补回。
        if ([System.IO.File]::Exists($tmp)) {
            $ctLocal = $null
            if ([System.IO.File]::Exists($Path)) { $ctLocal = [System.IO.File]::GetCreationTime($Path) }
            Move-Item -LiteralPath $tmp -Destination $Path -Force
            # 只可用「本地时间」的一对 API（Get/Set 均 Local）：Utc 对在 PowerShell
            # 传参时会被隐性转成本地时间，实测偏移 +8h。
            if ($ctLocal) { try { [System.IO.File]::SetCreationTime($Path, $ctLocal) } catch { } }
            $global:NetWarpLastHostsWriteMode = 'Move-fallback: ' + $_.Exception.Message
        } else { throw }
    }

    $len = [System.IO.File]::ReadAllBytes($Path).Length
    if ($len -eq 0 -and -not $AllowEmpty) { throw 'Write-HostsAtomic: result is 0 bytes.' }
    return $len
}

# 移除托管块，保留其它一切行（含用户自定义条目）；返回移除的行数
function Remove-ManagedBlock {
    param([string]$Path = (Get-HostsPath))
    $kept = @(); $skip = $false; $removed = 0
    foreach ($ln in (Get-Content -LiteralPath $Path)) {
        $s = $ln.Trim()
        if ($s -eq $script:HostsMarkStart) { $skip = $true;  continue }
        if ($s -eq $script:HostsMarkEnd) { $skip = $false; continue }
        if ($skip) { $removed++; continue }
        $kept += $ln
    }
    Write-HostsAtomic -Path $Path -Value $kept | Out-Null
    return $removed
}

# 备份目录瘦身：只保留最近 N 份
function Remove-OldBackups {
    param([string]$BakDir, [int]$Keep = 10)
    if (-not (Test-Path -LiteralPath $BakDir)) { return 0 }
    $files = @(Get-ChildItem -LiteralPath $BakDir -Filter 'hosts.bak-*.txt' | Sort-Object LastWriteTime -Descending)
    if ($files.Count -le $Keep) { return 0 }
    $n = 0
    foreach ($f in $files[$Keep..($files.Count - 1)]) {
        try { [System.IO.File]::Delete($f.FullName); $n++ } catch { }
    }
    return $n
}

# 取「最新的非空备份」；跳过 *.bak-empty-*（那是事故现场快照，不是可恢复内容）
function Get-LatestGoodHostsBackup {
    param([string]$BakDir)
    if (-not (Test-Path -LiteralPath $BakDir)) { return $null }
    $cands = @(Get-ChildItem -LiteralPath $BakDir -Filter 'hosts.bak-*.txt' |
               Where-Object { $_.Name -notlike '*empty*' -and $_.Length -gt 0 } |
               Sort-Object LastWriteTime -Descending)
    if ($cands.Count -eq 0) { return $null }
    return $cands[0].FullName
}

# 判断 hosts 是否「实质为空」：0 字节，或只有空白/BOM。
# 注意：必须用 ReadAllBytes 而非 Get-Item.Length —— 同一 PowerShell 会话内
# Get-Item 会返回缓存的 FileInfo（实测：刚写入 20 字符仍读到旧长度 0），
# 导致连续判定时得出错误结果。
function Test-HostsEffectivelyEmpty {
    param([string]$Path = (Get-HostsPath))
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    } catch {
        return $false
    }
    if ($bytes.Length -eq 0) { return $true }
    # 剥掉 UTF-8 BOM 后判断是否全为空白
    $txt = [System.Text.Encoding]::UTF8.GetString($bytes)
    $txt = $txt.TrimStart([char]0xFEFF)
    return [string]::IsNullOrWhiteSpace($txt)
}

# hosts 变空时的自愈：先把现场存成快照，再从最新非空备份回拷。
# 返回恢复源路径；hosts 有内容或无备份可用时返回 $null。
function Restore-HostsFromLatest {
    param([string]$BakDir, [string]$Path = (Get-HostsPath))
    if (-not (Test-HostsEffectivelyEmpty -Path $Path)) { return $null }

    $src = Get-LatestGoodHostsBackup -BakDir $BakDir
    if (-not $src) { return $null }

    # 事故现场快照（-empty- 前缀，供后续追因）
    $snap = Join-Path $BakDir ("hosts.bak-empty-{0}.txt" -f (Get-Date -Format yyyyMMdd-HHmmss))
    Copy-Item -LiteralPath $Path -Destination $snap -Force -ErrorAction SilentlyContinue

    # 回拷也走原子写：Copy-Item 同样是「截断 + 写」，中断会二次破坏 hosts
    $lines = [System.IO.File]::ReadAllLines($src)
    Write-HostsAtomic -Path $Path -Value $lines | Out-Null
    return $src
}

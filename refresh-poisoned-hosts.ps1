# 刷新「被污染域名」的 hosts 记录（IPv4 + IPv6 双栈固定，并行查询）
# ---------------------------------------------------------------
# 为什么必须固定 AAAA：
#   本机 ISP DNS 对墙名单域名返回污染结果，典型特征是
#   A 记录给别的站的 IP（如 157.240.7.20 = Facebook）+
#   AAAA 给伪造的 "2001::1"。
#   WARP 的 SOCKS5 是用「系统解析器」解析域名的，Windows 默认优先 IPv6，
#   于是它挑中伪造的 AAAA -> 连不通 -> 固定卡 5s 失败。
#   只固定 A 没用（AAAA 的污染仍然胜出），必须 A + AAAA 一起固定。
# 数据来源：经 WARP SOCKS5 查 Cloudflare DoH（干净解析，实测返回真实双栈地址）。
# 性能：用 curl --parallel 并发查（串行 31 域名要 55s，并行后约 5-8s）。
# 生效范围：所有走 WARP 的流量（git / 3-浏览器走WARP）。
# ---------------------------------------------------------------

param([string]$Port = '40000')

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'net-warp-common.ps1')
$Hosts  = Get-HostsPath
$MarkS  = $script:HostsMarkStart
$MarkE  = $script:HostsMarkEnd
$BakDir = Join-Path $PSScriptRoot 'hosts-backup'

$domains = @(
    # Google 全家桶
    'google.com','www.google.com','accounts.google.com','mail.google.com',
    'drive.google.com','docs.google.com','play.google.com','apis.google.com',
    'maps.google.com','photos.google.com','news.google.com','calendar.google.com',
    'gemini.google.com',
    # YouTube / Google 静态资源
    'youtube.com','www.youtube.com','m.youtube.com','music.youtube.com',
    'i.ytimg.com','yt3.ggpht.com','s.ytimg.com',
    'www.gstatic.com','fonts.gstatic.com','fonts.googleapis.com',
    'ajax.googleapis.com','ssl.gstatic.com',
    # GitHub 本体与静态资源
    'github.com','gist.github.com','api.github.com','codeload.github.com',
    'raw.githubusercontent.com','objects.githubusercontent.com',
    'avatars.githubusercontent.com','camo.githubusercontent.com',
    'user-images.githubusercontent.com','github.githubassets.com',
    # 其他常被污染的开发 / 常用站点
    'huggingface.co','hf.co','cdn-lfs.huggingface.co','cdn-lfs-us-1.huggingface.co',
    'hub.docker.com','registry-1.docker.io','auth.docker.io','docker.io',
    'production.cloudflare.docker.com',
    'wikipedia.org','en.wikipedia.org','zh.wikipedia.org',
    'x.com','twitter.com','www.facebook.com','www.instagram.com',
    'reddit.com','www.reddit.com','medium.com',
    'chatgpt.com','chat.openai.com','openai.com'
)

$sw = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "[1/3] Querying clean A/AAAA via WARP -> Cloudflare DoH (parallel) ..."

$tmp = Join-Path $env:TEMP ("warpdoh_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$jobs = @()
$idx  = 0
foreach ($d in $domains) {
    foreach ($t in @(1, 28)) {
        $tn = if ($t -eq 1) { 'A' } else { 'AAAA' }
        $jobs += [pscustomobject]@{
            Domain = $d
            Type   = $t
            Fam    = $tn
            File   = (Join-Path $tmp ("r{0:D4}.json" -f $idx))
            Url    = "https://cloudflare-dns.com/dns-query?name=$d&type=$tn"
        }
        $idx++
    }
}
$cli = New-Object System.Collections.Generic.List[string]
foreach ($j in $jobs) { $cli.Add('-o'); $cli.Add($j.File); $cli.Add($j.Url) }
$common = @('-s','--parallel','--parallel-max','8','--max-time','25','--ssl-no-revoke',
            '--socks5-hostname',"127.0.0.1:$Port",'-H','accept: application/dns-json')
& curl.exe @common @cli 2>$null | Out-Null

$records = @()
$skipped = @()
foreach ($d in $domains) {
    $got = @()
    foreach ($j in ($jobs | Where-Object { $_.Domain -eq $d })) {
        if (-not (Test-Path -LiteralPath $j.File)) { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($j.File)
            if (-not $raw) { continue }
            $js  = $raw | ConvertFrom-Json
            $hit = @($js.Answer | Where-Object { $_.type -eq $j.Type } | ForEach-Object { $_.data })
            if ($hit.Count -gt 0) {
                $got += [pscustomobject]@{ IP = $hit[0]; Domain = $d; Fam = $j.Fam }
            }
        } catch { }
    }
    if ($got.Count -gt 0) { $records += $got } else { $skipped += $d }
}
try { [System.IO.Directory]::Delete($tmp, $true) } catch { }

$v4 = @($records | Where-Object { $_.Fam -eq 'A' }).Count
$v6 = @($records | Where-Object { $_.Fam -eq 'AAAA' }).Count
Write-Host ("  resolved A={0}  AAAA={1}   ({2:N1}s)" -f $v4, $v6, $sw.Elapsed.TotalSeconds)
if ($skipped.Count -gt 0) { Write-Host ("  skip: {0}" -f ($skipped -join ', ')) -ForegroundColor DarkGray }

if ($records.Count -eq 0) {
    Write-Host "[!] Nothing resolved - WARP may be down. Leave hosts untouched." -ForegroundColor Yellow
    exit 1
}

Write-Host "[2/3] Rewriting managed block in hosts ..."
$bak = Backup-Hosts -BakDir $BakDir -Path $Hosts
if ($bak) {
    Write-Host "  backup -> $bak" -ForegroundColor DarkGray
} else {
    Write-Host "  [WARN] hosts is empty - backup skipped (nothing to save)." -ForegroundColor Yellow
    Write-Host "         own entries are NOT recoverable; check hosts-backup\ for an older copy." -ForegroundColor DarkGray
}

$kept = @(); $skip = $false
foreach ($ln in (Get-Content $Hosts)) {
    $s = $ln.Trim()
    if ($s -eq $MarkS) { $skip = $true;  continue }
    if ($s -eq $MarkE) { $skip = $false; continue }
    if (-not $skip) { $kept += $ln }
}
$block = @($MarkS)
foreach ($r in ($records | Where-Object { $_.Fam -eq 'A' }))    { $block += ("{0}`t{1}" -f $r.IP, $r.Domain) }
foreach ($r in ($records | Where-Object { $_.Fam -eq 'AAAA' })) { $block += ("{0}`t{1}" -f $r.IP, $r.Domain) }
$block += $MarkE
# 原子写：被打断时 hosts 保持旧内容，绝不会变成 0 字节（见 net-warp-common.ps1）
Write-HostsAtomic -Path $Hosts -Value ($kept + $block) | Out-Null

Write-Host "[3/3] Flushing DNS ..."
ipconfig /flushdns | Out-Null

Write-Host ""
Write-Host ("  OK - {0} records pinned ({1} domains, {2:N1}s)" -f $records.Count, ($domains.Count - $skipped.Count), $sw.Elapsed.TotalSeconds) -ForegroundColor Green

$pruned = Remove-OldBackups -BakDir $BakDir -Keep 10
if ($pruned -gt 0) { Write-Host "  pruned $pruned old backup(s), keep 10" -ForegroundColor DarkGray }

#Requires -Version 5.1
<#
.SYNOPSIS
    scoop 与 winget 的统一更新入口。

.DESCRIPTION
    一条命令看两边有没有更新，加 -Apply 才会真的升级。
    默认只报告，不动任何已装软件。

    scoop 侧：刷新 scoop 自身和 bucket，再列出可升级项
    winget 侧：列出可升级项

    为什么要有这个脚本：软件分别由 scoop 和 winget 管，更新入口本来是两套。
    这里把两套收进一个命令，底层还是各管各的——scoop 管绿色/多版本工具，
    winget 管需要安装程序的桌面软件。

.PARAMETER Apply
    真的执行升级。scoop 用 `scoop update *`，winget 用 `winget upgrade --all`。
    不加就只看不改。

.PARAMETER SkipScoop
    跳过 scoop 部分。

.PARAMETER SkipWinget
    跳过 winget 部分。

.PARAMETER Proxy
    手动指定代理，形如 `127.0.0.1:7897`。不填则自动探测；
    探测不到就自动让 git 走 gh-proxy 镜像。

.EXAMPLE
    .\update.ps1

    只看有哪些更新。

.EXAMPLE
    .\update.ps1 -Apply

    真的升级，winget 部分可能需要管理员权限。

.EXAMPLE
    .\update.ps1 -Apply -SkipWinget

    只升级 scoop 里的软件。
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$SkipScoop,
    [switch]$SkipWinget,
    [string]$Proxy
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-Step { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Note { param($m) Write-Host "    !!  $m" -ForegroundColor Yellow }
function Write-Bad  { param($m) Write-Host "    XX  $m" -ForegroundColor Red }

function Write-Indented {
    # 工具输出原样带缩进打印。不解析列宽——scoop/winget 会按终端宽度截断
    # 名字（"Mani…"），解析出来不可靠，不如把原文交给用户。
    param($Text, [string]$Color = 'Gray')
    if (-not $Text) { return }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Trim()) { Write-Host "    $line" -ForegroundColor $Color }
    }
}

function Get-TableInfo {
    # 把 scoop/winget 的表格输出整理一下：
    #   - 表头 + 分隔线保留
    #   - 数据行按整行去重（scoop 会把同一份表打印两遍：本地一遍、全局一遍）
    # 返回 Text（整理后的文本）/ Rows（数据行）/ Names（第一列）
    param($Text)
    $res = @{ Text = ''; Rows = 0; Names = @() }
    if (-not $Text) { return $res }

    # scoop 在 bucket 拉取失败时会往输出里混 git 的报错行，那不是表格内容，
    # 先剔掉，否则会被当成表头或数据行
    $lines = @($Text -split "`r?`n" | Where-Object {
        $t = $_.Trim()
        if (-not $t) { return $false }
        if ($t -match '^(fatal|error|warning)\b') { return $false }
        if ($t -match '^schannel\s*:') { return $false }
        if ($t -match 'CONNECT tunnel failed') { return $false }
        return $true
    })

    $sep = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-{3,}') { $sep = $i; break }
    }
    if ($sep -lt 0) {
        # 没有表格（"已是最新"这类提示），原样返回
        $res.Text = ($lines | Where-Object { $_.Trim() }) -join "`n"
        return $res
    }

    # 分隔线紧挨着的上一行才是表头。再往前的行是工具自己的提示语
    # （scoop 会先打一句 "Scoop is up to date."），不该混进表头
    $head = @($lines[[Math]::Max(0, $sep - 1)..$sep])
    $seen = @{}
    $rows = @()
    $names = @()
    for ($i = $sep + 1; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].TrimEnd()
        if (-not $t.Trim()) { continue }
        if ($seen.ContainsKey($t)) { continue }
        $seen[$t] = $true
        $rows += $t
        $names += ($t.Trim() -split '\s+')[0]
    }

    $res.Text  = (@($head) + $rows) -join "`n"
    $res.Rows  = $rows.Count
    $res.Names = $names
    return $res
}

function Get-ScoopRoot {
    if ($env:SCOOP -and (Test-Path $env:SCOOP)) { return $env:SCOOP.TrimEnd('\') }
    $c = Get-Command scoop -ErrorAction SilentlyContinue
    if ($c) { return (Split-Path -Parent (Split-Path -Parent $c.Source)) }
    return (Join-Path $env:USERPROFILE 'scoop')
}

function Find-Winget {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $p) { return $p }
    return $null
}

function Invoke-Winget {
    # winget 的输出是 UTF-8，而中文系统的控制台代码页是 936，PowerShell 会按
    # GBK 去解码 → 中文全变乱码（"名称" 变成 "鍚嶇О"）。调用前后临时把
    # OutputEncoding 切到 UTF-8，回来再还原，不影响其他输出。
    param([string]$Winget, [string[]]$Arguments)
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        return (& $Winget @Arguments 2>&1 | Out-String)
    } finally {
        [Console]::OutputEncoding = $prev
    }
}

# ---------------------------------------------------------------------------
# 网络：与 setup.ps1 里的 Initialize-Network 同一套判断
# 代理只在本进程内生效，不写任何配置文件
# ---------------------------------------------------------------------------
function Get-ProxyCandidate {
    if ($Proxy) { return $Proxy }
    foreach ($v in 'HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy') {
        $val = [Environment]::GetEnvironmentVariable($v)
        if ($val) { return ($val -replace '^https?://', '') }
    }
    try {
        $p = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($p.ProxyServer) {
            $s = [string]$p.ProxyServer
            if ($s -match '=') {
                $m = [regex]::Match($s, 'https?=([^;]+)')
                if ($m.Success) { return $m.Groups[1].Value.Trim() }
            }
            return $s.Trim()
        }
    } catch { }
    return $null
}

function Test-ProxyAlive {
    # 只测端口不够：注册表留着旧地址、只代理内网、需要认证的端口都会通但用不了
    param([string]$Addr)
    if (-not $Addr) { return $false }
    $hp = ($Addr -replace '^https?://', '').TrimEnd('/')
    $parts = $hp.Split(':')
    $h = $parts[0]
    $port = 80
    if ($parts.Count -gt 1) { [void][int]::TryParse($parts[1], [ref]$port) }
    if (-not $h -or $port -le 0) { return $false }

    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($h, $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(800)) { return $false }
        $client.EndConnect($ar)
    } catch { return $false } finally { $client.Close() }

    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { return $true }
    $probe = Join-Path $env:TEMP ("proxyprobe-" + [guid]::NewGuid().ToString('N') + ".txt")
    try {
        $code = & $curl -k -s -o $probe -w '%{http_code}' -x "http://$hp" --max-time 10 https://github.com 2>$null
        return ("$code" -match '^[23]')
    } catch { return $false } finally { Remove-Item $probe -Force -ErrorAction SilentlyContinue }
}

function Initialize-Network {
    $cand = Get-ProxyCandidate
    if ($cand -and (Test-ProxyAlive -Addr $cand)) {
        $env:HTTP_PROXY  = "http://$cand"
        $env:HTTPS_PROXY = "http://$cand"
        Write-Ok "代理 $cand 可用，本次更新走它"
        return
    }

    # 没可用代理：先清掉可能残留的坏代理变量（否则 git 还是会去连它），
    # 再用 git 的 insteadOf 把所有 github.com 请求改写到镜像。
    # GIT_CONFIG_COUNT 是 git 2.31+ 的机制，只影响当前进程，不写配置文件。
    foreach ($v in 'HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'ALL_PROXY', 'all_proxy') {
        Remove-Item "Env:$v" -ErrorAction SilentlyContinue
    }
    $env:GIT_CONFIG_COUNT   = '1'
    $env:GIT_CONFIG_KEY_0   = 'url.https://gh-proxy.com/https://github.com/.insteadOf'
    $env:GIT_CONFIG_VALUE_0 = 'https://github.com/'
    Write-Note '没有可用代理，git 的 github.com 请求改走 gh-proxy 镜像'
}

function Get-ManifestIndex {
    # 所有 bucket 里出现过的 manifest 名。用来判断一个应用还有没有可用的
    # manifest：install.json 记的 bucket 被删了，只要别的 bucket 有同名包，
    # scoop 照样能找到并升级它（pixpin 就属于这种，从 apps 迁到了 dorado）
    param([string]$BucketsDir)
    $idx = @{}
    if (-not (Test-Path $BucketsDir)) { return $idx }
    foreach ($f in (Get-ChildItem (Join-Path $BucketsDir '*\bucket\*.json') -ErrorAction SilentlyContinue)) {
        $idx[$f.BaseName] = $true
    }
    return $idx
}

function Invoke-WingetLive {
    # 和 Invoke-Winget 一样切 UTF-8，但不捕获输出——升级动辄十几分钟，
    # 全程静默会让人以为卡死了
    param([string]$Winget, [string[]]$Arguments)
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        & $Winget @Arguments
    } finally {
        [Console]::OutputEncoding = $prev
    }
}

function Get-WingetUpgrades {
    # 返回 @{ Count; Text }
    # winget 末尾会打一行 "20 升级可用。"，那是汇总不是数据行。与其自己
    # 数行（容易多数），不如直接用它的数字
    param([string]$Winget)
    $info = Get-TableInfo (Invoke-Winget -Winget $Winget -Arguments @(
        'upgrade', '--include-unknown', '--accept-source-agreements'
    ))
    $m = [regex]::Match($info.Text, '(?m)^\s*(\d+)\s+(?:\S*升级|upgrades?\s+available)')
    if ($m.Success) {
        $text = (($info.Text -split "`r?`n") | Where-Object {
            $_ -notmatch '^\s*\d+\s+(?:\S*升级|upgrades?\s+available)'
        }) -join "`n"
        return @{ Count = [int]$m.Groups[1].Value; Text = $text }
    }
    return @{ Count = $info.Rows; Text = $info.Text }
}

function Get-AppHealth {
    # 扫 %SCOOP%\apps，把已装目录分成三类：
    #   Ok      能正常更新的
    #   Broken  装失败的残留：有版本目录但没有 current 链接，重装才能修
    #   Orphan  manifest 已经找不到了：install.json 记的 bucket 被移除，且
    #           所有现存 bucket 里都没有同名包，这类永远升不了，status 却
    #           照样列出来
    # bucket 字段为 null 的目录是手动放的，本来就不归 scoop 管，算 Ok
    param([string]$AppsDir, [string]$BucketsDir)
    $r = @{ Ok = @(); Broken = @(); Orphan = @() }
    if (-not (Test-Path $AppsDir)) { return $r }

    $index = $null   # 按需构建，没有孤儿时不做这次全盘扫描
    foreach ($d in (Get-ChildItem $AppsDir -Directory -ErrorAction SilentlyContinue)) {
        $cur = Join-Path $d.FullName 'current'
        if (-not (Test-Path $cur)) { $r.Broken += $d.Name; continue }

        $ij = Join-Path $cur 'install.json'
        if (Test-Path $ij) {
            $bucket = $null
            try {
                $bucket = (Get-Content $ij -Raw -Encoding UTF8 | ConvertFrom-Json).bucket
            } catch { }
            if ($bucket -and -not (Test-Path (Join-Path $BucketsDir $bucket))) {
                if ($null -eq $index) { $index = Get-ManifestIndex -BucketsDir $BucketsDir }
                if (-not $index.ContainsKey($d.Name)) { $r.Orphan += $d.Name; continue }
            }
        }
        $r.Ok += $d.Name
    }
    return $r
}

function Remove-TableRows {
    # 从 Get-TableInfo 的结果里去掉指定名字的行，行数与文本同步更新
    param($Info, [string[]]$Names)
    if (-not $Names -or $Names.Count -eq 0) { return $Info }
    $Info.Names = @($Info.Names | Where-Object { $Names -notcontains $_ })
    $Info.Rows  = $Info.Names.Count
    $Info.Text  = (($Info.Text -split "`r?`n") | Where-Object {
        $n = ($_.Trim() -split '\s+')[0]
        $Names -notcontains $n
    }) -join "`n"
    return $Info
}

$scoopCount  = 0
$wingetCount = 0
$scoopOk     = $true
$wingetOk    = $true

Write-Step '检查网络'
Initialize-Network
Write-Host ''

# ---------------------------------------------------------------------------
# scoop
# ---------------------------------------------------------------------------
if (-not $SkipScoop) {
    Write-Step 'scoop'
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        Write-Note '本机没有 scoop，跳过'
    } else {
        # 不刷新 bucket 的话，status 拿到的是上次的清单，判断不出新版本。
        # scoop 用 Write-Host 输出，普通 `2>&1` 抓不到，必须 `*>&1` 连
        # information 流一起收；代价是刷新期间没有实时回显，所以先打一句提示。
        Write-Host '    刷新 scoop 与 bucket...' -NoNewline -ForegroundColor DarkGray
        $log = (& scoop update *>&1 | Out-String)
        Write-Host ''

        $bad = @(($log -split "`r?`n") | Where-Object {
            $_ -match '^(fatal|error|warning)\b' -or
            $_ -match 'CONNECT tunnel failed' -or
            $_ -match 'Uncommitted changes'
        })
        if ($bad.Count -gt 0) {
            Write-Bad 'bucket 刷新没完全成功，下面看到的版本可能不是最新的'
            Write-Indented $bad 'DarkYellow'
            $scoopOk = $false
        }

        # 先摸一遍已装目录：装失败的残留和 bucket 已移除的孤儿都升不了，
        # 但 scoop 照样把它们列进 status / 塞进 `update *` 里报错，先摘出去
        $root   = Get-ScoopRoot
        $health = Get-AppHealth -AppsDir (Join-Path $root 'apps') -BucketsDir (Join-Path $root 'buckets')

        if ($Apply) {
            # 用显式名单而不是 `update *`，避免为孤儿目录刷一堆报错。
            # 这里不捕获输出，让 scoop 的进度实时打出来。
            $targets = @($health.Ok)
            Write-Note "升级 $($targets.Count) 个 scoop 软件（可能要几分钟）"
            if ($targets.Count -gt 0) {
                & scoop update @targets
                # 升完再数一遍：需要管理员、或者程序正在运行的包会留在原地
                $left = Get-TableInfo (& scoop status *>&1 | Out-String)
                $left = Remove-TableRows $left (@($health.Broken) + @($health.Orphan))
                if ($left.Rows -gt 0) {
                    Write-Note "还有 $($left.Rows) 个没升上去（多半是程序正在运行或需要管理员）："
                    Write-Indented $left.Text
                    $scoopOk = $false
                } else {
                    Write-Ok 'scoop 侧全部升到最新'
                }
            }
        } else {
            $info = Get-TableInfo (& scoop status *>&1 | Out-String)
            $info = Remove-TableRows $info (@($health.Broken) + @($health.Orphan))

            $scoopCount = $info.Rows
            if ($scoopCount -gt 0) {
                Write-Note "有 $scoopCount 个可更新："
                Write-Indented $info.Text
            } else {
                Write-Ok '已是最新'
            }
        }

        if ($health.Broken.Count -gt 0) {
            Write-Note ("另有 $($health.Broken.Count) 个装失败的残留，不计入更新：" + ($health.Broken -join ', '))
            Write-Host ("        处理：scoop uninstall " + $health.Broken[0] + " 后重装") -ForegroundColor DarkGray
        }
        if ($health.Orphan.Count -gt 0) {
            Write-Note ("另有 $($health.Orphan.Count) 个应用所属 bucket 已移除，scoop 升不了它们：" + ($health.Orphan -join ', '))
            Write-Host '        处理：换到 winget（清单见 assets\packages.json）或直接卸载' -ForegroundColor DarkGray
        }
    }
}

# ---------------------------------------------------------------------------
# winget
# ---------------------------------------------------------------------------
if (-not $SkipWinget) {
    Write-Step 'winget'
    $winget = Find-Winget
    if (-not $winget) {
        Write-Note '本机没有 winget，跳过'
    } else {
        if ($Apply) {
            Write-Note '升级全部 winget 软件（可能需要管理员权限，会逐个弹 UAC）'
            Invoke-WingetLive -Winget $winget -Arguments @(
                'upgrade', '--all', '--include-unknown', '--silent',
                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
            )
            # 升完再扫一遍：需要管理员、或者程序正在运行的包会留在原地
            $left = Get-WingetUpgrades -Winget $winget
            if ($left.Count -gt 0) {
                Write-Note "还有 $($left.Count) 个没升上去（多半需要管理员，或程序正在运行）："
                Write-Indented $left.Text
                $wingetOk = $false
            } else {
                Write-Ok 'winget 侧全部升到最新'
            }
        } else {
            $info = Get-WingetUpgrades -Winget $winget
            $wingetCount = $info.Count
            if ($wingetCount -gt 0) {
                Write-Note "有 $wingetCount 个可更新："
                Write-Indented $info.Text
            } else {
                Write-Ok '已是最新'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
Write-Host ''
Write-Step '汇总'
if (-not $SkipScoop) {
    $s = if ($Apply) { '已尝试升级' } elseif ($scoopCount -gt 0) { "$scoopCount 个可更新" } else { '无更新' }
    Write-Host ("    scoop  {0}" -f $s) -ForegroundColor DarkGray
}
if (-not $SkipWinget) {
    $w = if ($Apply) { '已尝试升级' } elseif ($wingetCount -gt 0) { "$wingetCount 个可更新" } else { '无更新' }
    Write-Host ("    winget {0}" -f $w) -ForegroundColor DarkGray
}

if (-not $Apply -and ($scoopCount -gt 0 -or $wingetCount -gt 0)) {
    Write-Host ''
    Write-Host '    要真的升级：  .\update.ps1 -Apply' -ForegroundColor DarkGray
}

if (-not $scoopOk -or -not $wingetOk) {
    Write-Host ''
    Write-Note '有失败项，见上方输出'
    if (-not $IsAdmin -and (Find-Winget)) {
        Write-Note 'winget 升级多数包需要管理员，可在管理员 PowerShell 里重跑'
    }
    exit 1
}

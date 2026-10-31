#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Terminal 配置一键部署脚本。

.DESCRIPTION
    把本仓库的配置复刻到当前机器，全过程无人值守：
      1. 补齐依赖工具：winget / git / scoop，缺什么装什么
      2. 按 assets/packages.json 配置 scoop bucket，安装 scoop 软件
      3. 用 winget 补齐 scoop 里没有的软件
      4. 没装 Windows Terminal 就自动安装
      5. 定位配置目录（Store / Store 预览版 / 非 Store 便携版三种形态）
      6. 备份原配置，然后以符号链接（优先）或复制方式落地 settings.json
      7. 放置背景图
      8. 缺 Meslo Nerd Font 就自动安装
      9. 检测 WSL 发行版，报告或清理本机打不开的 profile

    脚本同时兼容 Windows PowerShell 5.1 与 PowerShell 7。Appx 相关操作
    在 PowerShell 7 下不可用（模块不兼容），会自动转交 5.1 子进程执行。

.PARAMETER Copy
    强制使用复制模式，不创建符号链接。

.PARAMETER SkipBackground
    不复制背景图。

.PARAMETER SkipFont
    不自动安装 Nerd Font。

.PARAMETER SkipTerminal
    即使检测不到 Windows Terminal 也不自动安装，只提示。

.PARAMETER SkipWinget
    不检查、不安装 winget。
    不加这个参数时 winget 也是惰性的：只有 assets/packages.json 里有 winget
    条目才会去装它，否则整台机器只保留 scoop 一套工具链。

.PARAMETER SkipScoop
    不检查、不安装 scoop。

.PARAMETER SkipApps
    不安装 packages.json 里的软件（只部署配置）。

.PARAMETER AppsOnly
    只装软件，不碰 Windows Terminal 配置。适合先把环境备好再单独调配置。

.PARAMETER ExportApps
    把当前机器的 scoop bucket / 软件、winget 软件导回 assets/packages.json。

.PARAMETER DryRun
    只报告"会装什么"，不实际安装任何软件。

.PARAMETER Proxy
    手动指定代理，形如 `127.0.0.1:7897`。不填则自动探测：先看环境变量，
    再看系统代理设置，并且**实际连接测试**端口通不通——注册表里留着旧地址
    或系统代理开关是关的都很常见，光看配置会误判。
    探测不到就自动改用 gh-proxy 镜像，不需要代理也能装。

.PARAMETER PruneProfiles
    把本机不存在的 WSL 发行版对应的 profile 从配置中移除。
    注意：符号链接模式下这会改动仓库文件。

.PARAMETER Force
    覆盖已存在的背景图；跳过 PruneProfiles 的确认提示。

.PARAMETER Verify
    只检查当前配置文件的链接状态，不做任何修改。

.PARAMETER Elevate
    没有符号链接权限或 winget 装包失败时，自动以管理员身份重启脚本（会弹 UAC）。

.EXAMPLE
    .\setup.ps1

.EXAMPLE
    .\setup.ps1 -AppsOnly

.EXAMPLE
    .\setup.ps1 -ExportApps

.EXAMPLE
    .\setup.ps1 -PruneProfiles

.EXAMPLE
    .\setup.ps1 -Verify
#>
[CmdletBinding()]
param(
    [switch]$Copy,
    [switch]$SkipBackground,
    [switch]$SkipFont,
    [switch]$SkipTerminal,
    [switch]$SkipWinget,
    [switch]$SkipScoop,
    [switch]$SkipApps,
    [switch]$AppsOnly,
    [switch]$ExportApps,
    [switch]$DryRun,
    [string]$Proxy,
    [switch]$PruneProfiles,
    [switch]$SyncProfiles,
    [switch]$Force,
    [switch]$Verify,
    [switch]$Elevate
)

$ErrorActionPreference = 'Stop'
$RepoRoot     = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoSettings = Join-Path $RepoRoot 'settings.json'
$IsPS7        = $PSVersionTable.PSVersion.Major -ge 6
$IsAdmin      = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# 老版本 .NET 默认可能不启用 TLS 1.2，下载 GitHub 会失败
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }
$ProgressPreference = 'SilentlyContinue'

function Write-Step { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Note { param($m) Write-Host "    !!  $m" -ForegroundColor Yellow }
function Write-Bad  { param($m) Write-Host "    XX  $m" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 通用：在 PowerShell 5.1 子进程里执行脚本块（Appx 模块只能在 5.1 用）
# ---------------------------------------------------------------------------
function Invoke-InPS51 {
    param([string]$Code)
    if (-not $IsPS7) { return (& ([scriptblock]::Create($Code))) }
    $tmp = Join-Path $env:TEMP ("ps51-" + [guid]::NewGuid().ToString('N') + ".ps1")
    [IO.File]::WriteAllText($tmp, $Code, (New-Object System.Text.UTF8Encoding $true))
    try {
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-RemoteFile {
    param([string]$Uri, [string]$OutFile)
    # 国内直连 GitHub 常年龟速甚至挂死（慢但不报错，超时兜不住），
    # 所以 GitHub 链接优先走加速镜像，失败再回退直连。
    # 下载统一交给系统自带的 curl.exe：Invoke-WebRequest 在 5.1 下处理
    # 这种大文件 + 镜像分块响应会挂死。代理环境的证书链不被 curl 自带
    # CA 认可，故用 -k 跳过校验（只影响本次下载，不改变系统信任设置）。
    $mirror = $null
    if ($Uri -like 'https://github.com/*') { $mirror = 'https://gh-proxy.com/' + $Uri }

    $attempts = @()
    if ($mirror) {
        # 有可用代理时直连就够快，镜像留作兜底；没有代理才让镜像打头
        if ($script:ProxyAddr) { $attempts += $Uri; $attempts += $mirror }
        else { $attempts += $mirror; $attempts += $Uri }
    } else {
        $attempts += $Uri
    }

    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $last = $null
    foreach ($u in $attempts) {
        try {
            if (Test-Path $curl) {
                & $curl -k -L -s --fail --retry 2 --connect-timeout 20 -o $OutFile $u
                if ($LASTEXITCODE -eq 0 -and (Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) { return }
                throw "curl 退出码 $LASTEXITCODE"
            }
            Invoke-WebRequest -Uri $u -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
            return
        } catch {
            $last = $_
            Write-Note "下载失败，换备用源重试：$($_.Exception.Message)"
        }
    }
    throw $last
}

# ---------------------------------------------------------------------------
# 网络：有本地代理就用代理，没有就走镜像
#
# 现实情况是「代理只在自己机器上有，而且不是常开」。所以不能把代理写死进
# 任何配置——一旦写死，换台机器或关掉代理，所有下载都会卡住。
# 这里只在本次运行内用环境变量带代理（git/curl/scoop 都认），进程结束就没了。
# ---------------------------------------------------------------------------
$script:UseMirror = $false
$script:ProxyAddr = $null

function Get-ProxyCandidate {
    # 显式参数优先
    if ($Proxy) { return $Proxy }

    # 环境变量（git/curl 本来就认）
    foreach ($v in 'HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy') {
        $val = [Environment]::GetEnvironmentVariable($v)
        if ($val) { return ($val -replace '^https?://', '') }
    }

    # 系统代理设置
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
    # 不能只看 ProxyEnable：常见情况是代理软件关掉了、注册表里还留着上次的
    # 地址，或者代理在跑、系统代理开关却是关的。只能实测。
    # 也不能只测端口：端口开着不代表能出去（可能只代理内网、或要认证、
    # 或像某些工具注入的代理一样连不上 GitHub）。所以再做一次真实请求。
    param([string]$Addr)
    if (-not $Addr) { return $false }

    $hp = ($Addr -replace '^https?://', '').TrimEnd('/')
    $parts = $hp.Split(':')
    $h = $parts[0]
    $port = 80
    if ($parts.Count -gt 1) { [void][int]::TryParse($parts[1], [ref]$port) }
    if (-not $h -or $port -le 0) { return $false }

    # 第一步：端口通不通（快速排除没启动的）
    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($h, $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(800)) { return $false }
        $client.EndConnect($ar)
    } catch {
        return $false
    } finally {
        $client.Close()
    }

    # 第二步：能不能真的到 GitHub
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { return $true }
    $probe = Join-Path $env:TEMP ("proxyprobe-" + [guid]::NewGuid().ToString('N') + ".txt")
    try {
        $code = & $curl -k -s -o $probe -w '%{http_code}' -x "http://$hp" --max-time 10 https://github.com 2>$null
        return ("$code" -match '^[23]')
    } catch {
        return $false
    } finally {
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-Network {
    $cand = Get-ProxyCandidate
    if ($cand -and (Test-ProxyAlive -Addr $cand)) {
        $script:ProxyAddr = $cand
        $env:HTTP_PROXY  = "http://$cand"
        $env:HTTPS_PROXY = "http://$cand"
        Write-Ok "检测到可用代理 $cand，本次运行的下载都走它"
        return
    }

    $script:UseMirror = $true
    if ($cand) {
        Write-Note "代理 $cand 连不上（可能没开），改用 gh-proxy 镜像"
    } else {
        Write-Note '本机没有代理，GitHub 相关操作走 gh-proxy 镜像'
    }
    Write-Note '镜像只影响本次运行，不会写进任何配置文件'
}

function Get-BucketSource {
    # 没有代理时，bucket 的 git clone 也走镜像（gh-proxy 支持 git 协议）
    param([string]$Source)
    if ($script:UseMirror -and $Source -like 'https://github.com/*') {
        return 'https://gh-proxy.com/' + $Source
    }
    return $Source
}

# ---------------------------------------------------------------------------
# 1. 检测 Windows Terminal 是否安装，没有就装
# ---------------------------------------------------------------------------
function Find-WtExe {
    $cmd = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'),
        'C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_8wekyb3d8bbwe\wt.exe'
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Find-Winget {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # 刚装好的 winget 可能还没进入当前会话的 PATH
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $p) { return $p }
    return $null
}

# 这两个函数要在 -Verify 分支之前就可用（脚本里函数是执行到定义行才生效的，
# 所以不能放在文件后半段）
function Get-WtConfigDir {
    param([string]$WtExe)
    $store    = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
    $preview  = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState'
    $portable = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal'
    $all      = @($store, $preview, $portable)

    foreach ($p in $all) {
        if (Test-Path (Join-Path $p 'settings.json')) { return $p }
    }
    foreach ($p in $all) {
        if (Test-Path $p) { return $p }
    }

    # 全新机器：按 wt.exe 位置判断形态
    if ($WtExe -and $WtExe -like '*\WindowsApps\*') { return $store }
    if ($WtExe -and $WtExe -match 'Preview') { return $preview }
    return $portable
}

function Get-LinkState {
    param([string]$Path, [string]$Source)
    if (-not (Test-Path $Path)) { return 'missing' }
    $item = Get-Item $Path -Force
    if (-not $item.LinkType) { return 'file' }
    $t = $item.Target
    if ($t -is [array]) { $t = $t[0] }
    if ([string]::Equals($t, $Source, 'OrdinalIgnoreCase')) { return 'linked-ok' }
    return 'linked-other'
}

# ---------------------------------------------------------------------------
# 依赖工具：winget / scoop 缺失时自动安装
# ---------------------------------------------------------------------------
function Ensure-Winget {
    $wg = Find-Winget
    if ($wg) { Write-Ok "winget 已就绪：$wg"; return $wg }

    Write-Note '未检测到 winget，开始自动安装（需下载约 300 MB）'
    $work = Join-Path $env:TEMP 'winget-bootstrap'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $bundleUrl = $null
    $depsUrl   = $null

    try {
        # 查最新版本；API 不通时回退到内置版本号
        try {
            $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' `
                -TimeoutSec 60 -Headers @{ 'User-Agent' = 'wt-config-setup' }
            $bundleAsset = $rel.assets | Where-Object { $_.name -like '*8wekyb3d8bbwe.msixbundle' } | Select-Object -First 1
            $depsAsset   = $rel.assets | Where-Object { $_.name -eq 'DesktopAppInstaller_Dependencies.zip' } | Select-Object -First 1
            if ($bundleAsset) { $bundleUrl = $bundleAsset.browser_download_url }
            if ($depsAsset)   { $depsUrl   = $depsAsset.browser_download_url }
        } catch {
            Write-Note "查询 winget 版本失败，使用内置版本号"
        }

        if (-not $bundleUrl) {
            $v    = 'v1.29.380'
            $base = "https://github.com/microsoft/winget-cli/releases/download/$v"
            $bundleUrl = "$base/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
            $depsUrl   = "$base/DesktopAppInstaller_Dependencies.zip"
        }

        $bundle = Join-Path $work 'appinstaller.msixbundle'
        Get-RemoteFile -Uri $bundleUrl -OutFile $bundle

        $depDir = Join-Path $work 'deps'
        if ($depsUrl) {
            $depsZip = Join-Path $work 'deps.zip'
            Get-RemoteFile -Uri $depsUrl -OutFile $depsZip
            Expand-Archive -Path $depsZip -DestinationPath $depDir -Force
        }

        # Appx 模块只在 Windows PowerShell 5.1 可用，PS7 下必须转交子进程
        $code = @"
`$ErrorActionPreference = 'Continue'
Get-ChildItem '$depDir\x64' -Filter *.appx -ErrorAction SilentlyContinue | ForEach-Object {
    try { Add-AppxPackage -Path `$_.FullName -ErrorAction Stop } catch { }
}
Add-AppxPackage -Path '$bundle' -ErrorAction Stop
"@
        Invoke-InPS51 -Code $code | Out-Null
    } catch {
        Write-Bad "winget 自动安装失败：$($_.Exception.Message)"
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    $wg = Find-Winget
    if ($wg) { Write-Ok "winget 安装完成：$wg" }
    else { Write-Note 'winget 仍不可用，后续步骤会走不依赖它的路径' }
    return $wg
}

function Ensure-Scoop {
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Ok 'scoop 已就绪'
        return $true
    }

    Write-Note '未检测到 scoop，开始自动安装'
    try {
        $code = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Invoke-Expression (New-Object Net.WebClient).DownloadString("https://get.scoop.sh")
'@
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command $code 2>&1 | Out-Null
    } catch {
        Write-Note "scoop 安装脚本执行异常：$($_.Exception.Message)"
    }

    # 刷新当前会话 PATH，让新装的 scoop 立即可见
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')

    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Ok 'scoop 安装完成'
        return $true
    }
    Write-Note 'scoop 仍不可用'
    return $false
}

function Test-ScoopEnv {
    # SCOOP_GLOBAL 和 SCOOP 指向同一处时，scoop 判断"是否全局应用"的路径比对
    # 恒为真，所有本地应用都会被当成全局的，scoop reset / uninstall 一律要
    # 管理员。这里只提示，不动用户的系统设置。
    if (-not $env:SCOOP -or -not $env:SCOOP_GLOBAL) { return }
    $a = ($env:SCOOP -replace '[\\/]+$', '').ToLowerInvariant()
    $b = ($env:SCOOP_GLOBAL -replace '[\\/]+$', '').ToLowerInvariant()
    if ($a -ne $b) { return }

    Write-Note 'SCOOP 和 SCOOP_GLOBAL 指向同一个目录'
    Write-Host '        后果：scoop 会把所有本地应用当成全局应用，reset / uninstall 一律要管理员' -ForegroundColor DarkGray
    Write-Host '        修法：管理员 PowerShell 删掉机器级 SCOOP_GLOBAL，或给当前用户设 C:\ProgramData\scoop' -ForegroundColor DarkGray
}

function Set-ScoopConfig {
    $src = Join-Path $RepoRoot 'assets\scoop-config.json'
    if (-not (Test-Path $src)) { return }

    $dst = Join-Path $env:USERPROFILE '.config\scoop\config.json'
    $dir = Split-Path -Parent $dst
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if (-not (Test-Path $dst)) {
        Copy-Item $src $dst -Force
        Write-Ok "scoop 配置已写入：$dst"
        return
    }

    # 已存在时只补充缺失的键，绝不覆盖本机已有设置
    # （gh_token、proxy 这类本机专属且敏感的项必须保留原样）
    try {
        $cur = Get-Content $dst -Raw -Encoding UTF8 | ConvertFrom-Json
        $new = Get-Content $src -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Note "scoop 配置解析失败，跳过：$($_.Exception.Message)"
        return
    }

    $changed = $false
    foreach ($p in $new.PSObject.Properties) {
        if ($cur.PSObject.Properties.Name -notcontains $p.Name) {
            $cur | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
            $changed = $true
        }
    }

    # 老版本仓库里 scoop_repo 写的是已停服的 mirror.ghproxy.com，照搬过去
    # 会让人以为网络坏了。这一项定向纠正，其它仍然保留本机设置。
    if ($cur.PSObject.Properties.Name -contains 'scoop_repo' -and
        "$($cur.scoop_repo)" -match 'ghproxy|gh-proxy') {
        $cur.scoop_repo = 'https://github.com/ScoopInstaller/Scoop'
        $changed = $true
    }

    if ($changed) {
        Copy-Item $dst "$dst.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
        $json = $cur | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText($dst, $json, (New-Object System.Text.UTF8Encoding $false))
        Write-Ok 'scoop 配置已补充缺失项（原有设置保留）'
    } else {
        Write-Ok 'scoop 配置已包含所需项'
    }
}

# ---------------------------------------------------------------------------
# 软件清单：先配齐 bucket，再装 scoop 包，最后用 winget 补 scoop 没有的
# ---------------------------------------------------------------------------
$PackageManifest = Join-Path $RepoRoot 'assets\packages.json'

function Get-PackageManifest {
    if (-not (Test-Path $PackageManifest)) { return $null }
    try {
        return (Get-Content $PackageManifest -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-Bad "packages.json 解析失败：$($_.Exception.Message)"
        return $null
    }
}

function Get-ScoopRoot {
    if ($env:SCOOP -and (Test-Path $env:SCOOP)) { return $env:SCOOP.TrimEnd('\') }
    $c = Get-Command scoop -ErrorAction SilentlyContinue
    if ($c) { return (Split-Path -Parent (Split-Path -Parent $c.Source)) }
    return (Join-Path $env:USERPROFILE 'scoop')
}

function Refresh-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'Machine')
}

function Ensure-Git {
    # scoop 的 bucket 本质是 git 仓库，没有 git 连 bucket 都加不了
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Ok "git 已就绪：$((Get-Command git).Source)"
        return $true
    }

    $winget = Find-Winget
    if ($winget) {
        Write-Note '未检测到 git，先通过 winget 安装'
        & $winget install --id Git.Git -e --silent --no-upgrade `
            --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 97) {
            Refresh-SessionPath
            if (Get-Command git -ErrorAction SilentlyContinue) {
                Write-Ok 'git 安装完成'
                return $true
            }
        }
    }

    # 回退：MinGit 便携版，免安装免管理员
    Write-Note '改用 MinGit 便携版'
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' `
            -TimeoutSec 60 -Headers @{ 'User-Agent' = 'wt-config-setup' }
        $asset = $rel.assets | Where-Object { $_.name -like 'MinGit-*-64-bit.zip' } | Select-Object -First 1
        if (-not $asset) { throw '未找到 MinGit 资源' }

        $zip = Join-Path $env:TEMP 'MinGit.zip'
        Write-Note "下载 $($asset.name)（约 $([math]::Round($asset.size/1MB)) MB）"
        Get-RemoteFile -Uri $asset.browser_download_url -OutFile $zip

        $dst = Join-Path $env:LOCALAPPDATA 'Programs\MinGit'
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $dst -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue

        $gitCmd = Join-Path $dst 'cmd'
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -notlike "*$gitCmd*") {
            [Environment]::SetEnvironmentVariable('Path', "$userPath;$gitCmd", 'User')
        }
        $env:Path = "$env:Path;$gitCmd"
        if (Get-Command git -ErrorAction SilentlyContinue) {
            Write-Ok "git 便携版就绪：$gitCmd"
            return $true
        }
        throw '解压后仍找不到 git.exe'
    } catch {
        Write-Bad "git 自动安装失败：$($_.Exception.Message)"
        return $false
    }
}

function Ensure-ScoopBuckets {
    param($Manifest)
    if (-not $Manifest) { return }
    if (@($Manifest.buckets).Count -eq 0) { return }

    $bdir = Join-Path (Get-ScoopRoot) 'buckets'
    $have = @()
    if (Test-Path $bdir) {
        $have = @(Get-ChildItem $bdir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    }

    $added  = 0
    $failed = @()
    $retargeted = @()
    $missing = @($Manifest.buckets | Where-Object { $have -notcontains $_.name })

    # 已存在的 bucket 也要对一下地址：仓库搬家（比如 sysinternals 捐给官方）后
    # 旧地址还在重定向，能用但迟早失效，这里顺手改过来。
    foreach ($b in @($Manifest.buckets | Where-Object { $have -contains $_.name })) {
        $dir = Join-Path $bdir $b.name
        $cur = $null
        try {
            Push-Location $dir
            $cur = (& git config --get remote.origin.url 2>$null | Select-Object -First 1)
        } catch { } finally { Pop-Location }
        if (-not $cur) { continue }

        $norm = $cur -replace '^https://gh-proxy\.com/', ''
        if ($norm -ne $b.source) {
            if (-not $DryRun) {
                Push-Location $dir
                try { & git remote set-url origin (Get-BucketSource -Source $b.source) 2>&1 | Out-Null } catch { }
                Pop-Location
            }
            $retargeted += $b.name
        }
    }

    if ($missing.Count -eq 0) {
        if ($retargeted.Count -gt 0) { Write-Ok ("bucket 已齐全（$($have.Count) 个），已更新地址：" + ($retargeted -join ', ')) }
        else { Write-Ok "bucket 已齐全（$($have.Count) 个）" }
        return
    }
    if ($DryRun) {
        Write-Note ("将添加 {0} 个 bucket：{1}" -f $missing.Count, (($missing | ForEach-Object { $_.name }) -join ', '))
        if ($retargeted.Count -gt 0) { Write-Note ("将更新地址：{0}" -f ($retargeted -join ', ')) }
        return
    }

    foreach ($b in $missing) {
        Write-Note "添加 bucket：$($b.name)"
        & scoop bucket add $b.name (Get-BucketSource -Source $b.source) 2>&1 | Out-Null
        # scoop bucket add 不返回可靠的退出码，直接看目录有没有建出来
        if (Test-Path (Join-Path $bdir $b.name)) { $added++ } else { $failed += $b.name }
    }

    if ($failed.Count -gt 0) {
        Write-Bad ("bucket 添加失败：" + ($failed -join ', '))
        Write-Note '通常是网络问题，重跑本脚本会重试缺失的 bucket'
    }
    if ($retargeted.Count -gt 0) { Write-Ok ("已更新地址：" + ($retargeted -join ', ')) }
    if ($added -eq 0) { Write-Ok "bucket 已齐全（$($have.Count) 个）" }
    else { Write-Ok "已补充 $added 个 bucket" }
}

function Install-ScoopPackages {
    param($Manifest)
    if (-not $Manifest) { return }
    if (@($Manifest.scoop).Count -eq 0) { Write-Ok '清单里没有 scoop 软件'; return }

    $adir = Join-Path (Get-ScoopRoot) 'apps'
    $have = @()
    if (Test-Path $adir) {
        # 有 current 链接才算真装上了（装失败的残留只有版本目录）
        $have = @(Get-ChildItem $adir -Directory -ErrorAction SilentlyContinue |
                  Where-Object { Test-Path (Join-Path $_.FullName 'current') } |
                  Select-Object -ExpandProperty Name)
    }

    $todo = @($Manifest.scoop | Where-Object { $have -notcontains $_ })
    if ($todo.Count -eq 0) {
        Write-Ok "scoop 软件已全部安装（$($have.Count) 个）"
        return
    }

    Write-Note "scoop 待安装 $($todo.Count) 个（已装 $($have.Count) 个）"
    if ($DryRun) {
        Write-Note ("将安装：{0}" -f ($todo -join ', '))
        return
    }

    $failed = @()
    $i = 0
    foreach ($a in $todo) {
        $i++
        Write-Host ("    [{0}/{1}] {2}" -f $i, $todo.Count, $a) -ForegroundColor DarkGray
        $log = & scoop install $a 2>&1 | Out-String
        # 装没装上看 current 链接，不看退出码（scoop 是 PS 函数，退出码不可靠）
        if (-not (Test-Path (Join-Path $adir $a))) {
            $failed += $a
            $tail = ($log -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' / '
            if ($tail) { Write-Host "        $tail" -ForegroundColor DarkYellow }
        }
    }

    if ($failed.Count -eq 0) { Write-Ok 'scoop 软件安装完成' }
    else {
        Write-Bad ("scoop 安装失败 $($failed.Count) 个：" + ($failed -join ', '))
        Write-Note '可以单独重试，例如：scoop install <名字>'
    }
}

function Install-WingetPackages {
    param($Manifest)
    if (-not $Manifest) { return }
    if (@($Manifest.winget).Count -eq 0) { Write-Ok '清单里没有 winget 软件'; return }

    $winget = Find-Winget
    if (-not $winget) { Write-Note 'winget 不可用，跳过 winget 软件'; return }

    if ($DryRun) {
        Write-Note ("将安装 {0} 个 winget 包：{1}" -f $Manifest.winget.Count, ($Manifest.winget -join ', '))
        return
    }

    $failed  = @()
    $skipped = 0
    $i = 0
    foreach ($id in $Manifest.winget) {
        $i++
        Write-Host ("    [{0}/{1}] {2}" -f $i, $Manifest.winget.Count, $id) -ForegroundColor DarkGray
        # --no-upgrade 很关键：否则已装的包会被当成"升级"，遇到正在运行的程序
        # 会报 0x80070020 文件占用而失败，还会白白耗掉几分钟。
        & $winget install --id $id -e --silent --no-upgrade `
            --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        # winget 表示"已装过"的返回值不止一个：
        #   97          = 已安装同版本，主动取消
        #   -1978335135 = 0x8A150061 APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED
        switch ($LASTEXITCODE) {
            0           { }
            97          { $skipped++ }
            -1978335135 { $skipped++ }
            default     { $failed += ('{0} (exit {1})' -f $id, $LASTEXITCODE) }
        }
    }

    if ($failed.Count -eq 0) {
        Write-Ok "winget 软件就绪（跳过已装 $skipped 个）"
    } else {
        Write-Bad "winget 安装失败 $($failed.Count) 个："
        foreach ($f in $failed) { Write-Host "        - $f" -ForegroundColor Red }
        if (-not $IsAdmin) {
            Write-Note '多数 winget 包需要管理员权限，可运行  .\setup.ps1 -Elevate  重试'
        }
    }
}

function Export-PackageManifest {
    # 把当前机器实际装的软件导回 assets/packages.json，方便以后同步仓库
    $root  = Get-ScoopRoot
    $bdir  = Join-Path $root 'buckets'
    $adir  = Join-Path $root 'apps'

    $buckets = @()
    if (Test-Path $bdir) {
        foreach ($d in Get-ChildItem $bdir -Directory -ErrorAction SilentlyContinue) {
            $remote = $null
            try {
                Push-Location $d.FullName
                $remote = (& git config --get remote.origin.url 2>$null | Select-Object -First 1)
            } catch { } finally { Pop-Location }
            if ($remote) {
                # 镜像地址只在本机生效，不能带进仓库
                $remote = $remote -replace '^https://gh-proxy\.com/', ''
                $buckets += [pscustomobject]@{ name = $d.Name; source = $remote }
            }
        }
    }

    # 清单里还留着哪些 bucket —— 用来判断某个应用还能不能装回来
    $knownBuckets = @($buckets | ForEach-Object { $_.name })

    # 这些 bucket 里能装到的应用名（判断"换个 bucket 还能装"的情况，
    # 比如 pixpin 当初装在 apps，apps 删了但 dorado 里有同名的）
    $available = @{}
    foreach ($bn in $knownBuckets) {
        $bp = Join-Path $bdir "$bn\bucket"
        if (-not (Test-Path $bp)) { continue }
        foreach ($f in Get-ChildItem $bp -Filter *.json -ErrorAction SilentlyContinue) {
            $available[$f.BaseName.ToLower()] = $true
        }
    }

    $apps   = @()
    $orphan = @()
    if (Test-Path $adir) {
        foreach ($d in Get-ChildItem $adir -Directory -ErrorAction SilentlyContinue) {
            if ($d.Name -eq 'scoop') { continue }                      # scoop 自己也在 apps 里
            if (-not (Test-Path (Join-Path $d.FullName 'current'))) { continue }  # 装失败的残留

            # 当初装的 bucket 已经不在清单里、别的 bucket 也没有同名包的话，
            # 导出去在别的机器上也装不回来
            $bk = $null
            $ij = Join-Path $d.FullName 'current\install.json'
            if (Test-Path $ij) {
                try { $bk = (Get-Content $ij -Raw -Encoding UTF8 | ConvertFrom-Json).bucket } catch { }
            }
            if ($bk -and $knownBuckets -notcontains $bk -and -not $available[$d.Name.ToLower()]) {
                $orphan += $d.Name
                continue
            }

            $apps += $d.Name
        }
        $apps = @($apps | Sort-Object)
    }

    # winget 侧只保留"用户主动装的软件"，系统运行库/框架一律剔除
    $skipPattern = '^(Microsoft\.VCRedist|Microsoft\.VCLibs|Microsoft\.WindowsAppRuntime|' +
                   'Microsoft\.DotNet|Microsoft\.AppInstaller|Microsoft\.Edge|Microsoft\.Office|' +
                   'Microsoft\.WSL|Canonical\.Ubuntu|Apple\.Bonjour)'
    $wingetIds = @()
    $winget = Find-Winget
    if ($winget) {
        $tmp = Join-Path $env:TEMP ("winget-export-" + [guid]::NewGuid().ToString('N') + ".json")
        try {
            & $winget export -o $tmp --accept-source-agreements 2>&1 | Out-Null
            if (Test-Path $tmp) {
                $j = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
                $wingetIds = @($j.Sources[0].Packages |
                    Select-Object -ExpandProperty PackageIdentifier |
                    Where-Object { $_ -and $_ -notmatch $skipPattern } |
                    Sort-Object -Unique)
            }
        } catch {
            Write-Note "winget 导出失败：$($_.Exception.Message)"
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    # 同一个软件如果 scoop 里已经装了，就不要再列到 winget，避免两边重复
    $wingetDupeOfScoop = @{
        'FastCopy.FastCopy'       = 'fastcopy'
        'JanDeDobbeleer.OhMyPosh' = 'oh-my-posh'
        'Tencent.TIM'             = 'tim'
        'Tencent.WeChat'          = 'wechat'
        'Microsoft.PowerToys'     = 'powertoys'
        'voidtools.Everything'    = 'everything'
        'Obsidian.Obsidian'       = 'obsidian'
        '7zip.7zip'               = '7zip'
        'Git.Git'                 = 'git'
        'Neovim.Neovim'           = 'neovim'
        'GoLang.Go'               = 'go'
        'Pandoc.Pandoc'           = 'pandoc'
        'Python.Python.3.13'      = 'python'
    }
    $wingetIds = @($wingetIds | Where-Object {
        $k = $_
        -not ($wingetDupeOfScoop.ContainsKey($k) -and ($apps -contains $wingetDupeOfScoop[$k]))
    })

    # winget export 只能识别"它自己装过"的包，用安装程序手动装的（Chrome、
    # Firefox、夸克、迅雷之类）会整个丢失。所以和旧清单取并集，保住手工补的条目。
    $oldIds = @()
    if (Test-Path $PackageManifest) {
        try {
            $old = Get-Content $PackageManifest -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($old.winget) { $oldIds = @($old.winget) }
        } catch { }
    }
    $onlyOld = @($oldIds | Where-Object { $wingetIds -notcontains $_ })
    $wingetIds = @(($wingetIds + $oldIds) | Sort-Object -Unique)

    $obj = [pscustomobject]@{
        buckets = $buckets
        scoop   = $apps
        winget  = $wingetIds
    }
    $json = $obj | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($PackageManifest, $json, (New-Object System.Text.UTF8Encoding $false))

    Write-Ok "已写入 $PackageManifest"
    Write-Host ("    bucket {0} 个 / scoop {1} 个 / winget {2} 个" -f `
        $buckets.Count, $apps.Count, $wingetIds.Count) -ForegroundColor DarkGray
    if ($onlyOld.Count -gt 0) {
        Write-Note ("winget 识别不出、但保留在清单里的 $($onlyOld.Count) 个：")
        Write-Host ("        " + ($onlyOld -join ', ')) -ForegroundColor DarkGray
    }
    if ($orphan.Count -gt 0) {
        Write-Note ("所属 bucket 已不在清单里、导出时跳过的 $($orphan.Count) 个：")
        Write-Host ("        " + ($orphan -join ', ')) -ForegroundColor DarkGray
    }
    Write-Note '检查无误后用 sync.ps1 -Push 提交'
}

function Install-WindowsTerminal {
    # 优先 winget
    $winget = Find-Winget
    if ($winget) {
        Write-Note '通过 winget 安装 Windows Terminal（可能需要几分钟）'
        & $winget install --id Microsoft.WindowsTerminal -e --silent `
            --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-String | Write-Host
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-Note "winget 返回 $LASTEXITCODE，改用 msixbundle 安装"
    }

    # 退回到官方 msixbundle
    Write-Note '从 GitHub 下载官方安装包'
    try {
        $api = 'https://api.github.com/repos/microsoft/terminal/releases/latest'
        $rel = Invoke-RestMethod -Uri $api -TimeoutSec 60 -Headers @{ 'User-Agent' = 'wt-config-setup' }
        $asset = $rel.assets | Where-Object { $_.name -like '*8wekyb3d8bbwe.msixbundle' } | Select-Object -First 1
        if (-not $asset) { throw '未找到 msixbundle 资源' }

        $bundle = Join-Path $env:TEMP 'WindowsTerminal.msixbundle'
        Write-Note "下载 $($asset.name)（约 $([math]::Round($asset.size/1MB)) MB）"
        Get-RemoteFile -Uri $asset.browser_download_url -OutFile $bundle

        # Appx 依赖：VCLibs.UWPDesktop 与 UI.Xaml
        $depDir = Join-Path $env:TEMP 'wt-deps'
        New-Item -ItemType Directory -Path $depDir -Force | Out-Null
        $deps = @(
            @{ Name = 'VCLibs'; Url = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' }
        )
        foreach ($d in $deps) {
            $f = Join-Path $depDir "$($d.Name).appx"
            try { Get-RemoteFile -Uri $d.Url -OutFile $f } catch { Write-Note "依赖 $($d.Name) 下载失败，跳过" }
        }

        $code = @"
`$ErrorActionPreference = 'Stop'
Get-ChildItem '$depDir' -Filter *.appx -ErrorAction SilentlyContinue | ForEach-Object {
    try { Add-AppxPackage -Path `$_.FullName -ErrorAction Stop } catch { }
}
Add-AppxPackage -Path '$bundle' -ErrorAction Stop
"@
        Invoke-InPS51 -Code $code | Write-Host
        return $true
    } catch {
        Write-Bad "自动安装失败：$($_.Exception.Message)"
        return $false
    }
}

# ---------------------------------------------------------------------------
# 依赖工具：winget / git / scoop，以及软件安装
# ---------------------------------------------------------------------------
if ($ExportApps) {
    Write-Step '导出本机软件清单'
    Export-PackageManifest
    exit 0
}

if ($Verify) {
    # 纯只读检查，必须在装软件之前就退出
    $wtExe      = Find-WtExe
    $cfgDir     = Get-WtConfigDir -WtExe $wtExe
    $targetFile = Join-Path $cfgDir 'settings.json'
    Write-Step '检查链接状态'
    Write-Ok $cfgDir
    switch (Get-LinkState -Path $targetFile -Source $RepoSettings) {
        'linked-ok'    { Write-Ok 'settings.json 已正确链接到本仓库' }
        'linked-other' { Write-Note "链接指向了其他位置：$((Get-Item $targetFile -Force).Target)" }
        'file'         { Write-Note 'settings.json 是普通文件而非链接（多半是 Windows Terminal 保存配置时替换了它），运行 .\setup.ps1 修复' }
        'missing'      { Write-Note 'settings.json 不存在，运行 .\setup.ps1 部署' }
    }
    exit 0
}

Write-Step '检查网络'
Initialize-Network

# 先读清单，决定到底需不需要 winget。
# 清单里没有 winget 条目时，本机就只保留 scoop 一套工具链，不白下 300 MB。
$mf = $null
if (-not $SkipApps) { $mf = Get-PackageManifest }
$needWinget = ($mf -and @($mf.winget).Count -gt 0)

if (-not $SkipWinget) {
    Write-Step '检查 winget'
    if (-not $needWinget) {
        if (Find-Winget) { Write-Ok 'winget 已就绪（清单里没有 winget 软件，不需要它）' }
        else { Write-Ok '清单里没有 winget 软件，跳过（本机只保留 scoop 一套）' }
    } elseif ($DryRun) {
        if (Find-Winget) { Write-Ok 'winget 已就绪' } else { Write-Note 'winget 未安装，正式运行时会自动装' }
    } else {
        $null = Ensure-Winget
    }
}

$scoopReady = $false
if (-not $SkipScoop) {
    if ($DryRun) {
        Write-Step '检查 git / scoop'
        if (Get-Command git -ErrorAction SilentlyContinue) { Write-Ok 'git 已就绪' }
        else { Write-Note 'git 未安装，正式运行时会自动装' }
        if (Get-Command scoop -ErrorAction SilentlyContinue) { Write-Ok 'scoop 已就绪'; $scoopReady = $true; Test-ScoopEnv }
        else { Write-Note 'scoop 未安装，正式运行时会自动装' }
    } else {
        Write-Step '检查 git'
        $null = Ensure-Git

        Write-Step '检查 scoop'
        if (Ensure-Scoop) {
            Set-ScoopConfig
            Test-ScoopEnv
            $scoopReady = $true
        }
    }
}

if (-not $SkipApps) {
    if (-not $mf) {
        Write-Note 'assets/packages.json 不存在或无法解析，跳过软件安装'
    } else {
        if ($scoopReady) {
            Write-Step '配置 scoop bucket'
            Ensure-ScoopBuckets -Manifest $mf

            Write-Step '安装 scoop 软件'
            Install-ScoopPackages -Manifest $mf
        }
        if (@($mf.winget).Count -gt 0) {
            Write-Step '安装 winget 软件'
            Install-WingetPackages -Manifest $mf
        } else {
            Write-Step '安装 winget 软件'
            Write-Ok '清单里没有 winget 软件'
        }
    }
}

if ($AppsOnly) {
    Write-Host ''
    Write-Step '完成（-AppsOnly，未改动 Windows Terminal 配置）'
    exit 0
}

Write-Step '检查 Windows Terminal'
$wtExe = Find-WtExe
if ($wtExe) {
    Write-Ok "已安装：$wtExe"
} else {
    Write-Note '未检测到 Windows Terminal'
    if ($SkipTerminal) {
        Write-Note '已指定 -SkipTerminal，跳过安装。请手动安装后再运行本脚本。'
        exit 1
    }
    if (-not (Install-WindowsTerminal)) {
        Write-Bad 'Windows Terminal 自动安装失败，请手动安装后重试。'
        exit 1
    }
    Write-Ok 'Windows Terminal 安装完成'
}

# ---------------------------------------------------------------------------
# 2. 定位配置目录（Get-WtConfigDir / Get-LinkState 定义在文件前半段）
# ---------------------------------------------------------------------------
Write-Step '定位配置目录'
$cfgDir     = Get-WtConfigDir -WtExe $wtExe
$targetFile = Join-Path $cfgDir 'settings.json'
Write-Ok $cfgDir

if (-not (Test-Path $cfgDir)) {
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    Write-Note '目录原本不存在，已创建。首次部署建议先启动一次 Windows Terminal 再重跑本脚本。'
}

# ---------------------------------------------------------------------------
# 3. 链接状态检查
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 4. 判断能否创建符号链接（实测，比读注册表可靠）
# ---------------------------------------------------------------------------
function Test-SymlinkAbility {
    $probe  = Join-Path $env:TEMP ("wt-linktest-" + [guid]::NewGuid().ToString('N'))
    $target = Join-Path $probe 'target.txt'
    $link   = Join-Path $probe 'link.txt'
    try {
        New-Item -ItemType Directory -Path $probe -Force | Out-Null
        Set-Content -Path $target -Value 'probe' -Encoding ASCII
        New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        Remove-Item $link   -Force -ErrorAction SilentlyContinue
        Remove-Item $target -Force -ErrorAction SilentlyContinue
        Remove-Item $probe  -Force -ErrorAction SilentlyContinue
    }
}

$canLink = $false
if (-not $Copy) { $canLink = Test-SymlinkAbility }

function Show-LinkHint {
    Write-Note '无法创建符号链接，已退回复制模式：配置能用，但本机改动不会自动进仓库。'
    Write-Note '解决办法任选其一：'
    Write-Note '  1) 运行  .\setup.ps1 -Elevate   自动提权重跑'
    Write-Note '  2) 管理员 PowerShell 里重跑本脚本'
    Write-Note '  3) 重启电脑后重跑（开发者模式授予的权限要重新登录才进令牌）'
}

if ($Elevate -and -not $canLink -and -not $Copy) {
    if ($IsAdmin) {
        Write-Note '当前已是管理员，仍无符号链接权限，可能被组策略限制，将使用复制模式。'
    } else {
        Write-Step '请求管理员权限重启脚本'
        # 把当前用到的开关原样带过去，避免提权后变成"裸跑"
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        foreach ($s in 'Copy', 'SkipBackground', 'SkipFont', 'SkipTerminal', 'SkipWinget',
                       'SkipScoop', 'SkipApps', 'AppsOnly', 'PruneProfiles', 'SyncProfiles', 'Force') {
            $v = Get-Variable -Name $s -ValueOnly -ErrorAction SilentlyContinue
            if ($v) { $argList += "-$s" }
        }
        $argList += '-Elevate'
        if ($Proxy) { $argList += @('-Proxy', $Proxy) }
        Start-Process powershell -Verb RunAs -ArgumentList $argList
        exit 0
    }
}

# ---------------------------------------------------------------------------
# 5. 备份并落地配置
# ---------------------------------------------------------------------------
Write-Step '部署 settings.json'
$state = Get-LinkState -Path $targetFile -Source $RepoSettings

if ($state -eq 'linked-other') {
    Remove-Item $targetFile -Force
    Write-Note '已移除指向其他位置的旧链接'
    $state = 'missing'
}

if ($state -eq 'linked-ok') {
    Write-Ok '已链接到本仓库，无需处理'
}
elseif ($state -eq 'file') {
    $backup = "$targetFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $targetFile $backup -Force
    Write-Ok "原配置已备份：$backup"

    Remove-Item $targetFile -Force
    if ($canLink) {
        try {
            New-Item -ItemType SymbolicLink -Path $targetFile -Target $RepoSettings -Force | Out-Null
            Write-Ok '已创建符号链接（settings.json -> 仓库）'
        } catch {
            Write-Note "创建符号链接失败：$($_.Exception.Message)"
            Copy-Item $RepoSettings $targetFile -Force
            Show-LinkHint
        }
    } else {
        Copy-Item $RepoSettings $targetFile -Force
        if ($Copy) { Write-Ok '已复制配置（-Copy 模式）' }
        else { Show-LinkHint }
    }
}
elseif ($state -eq 'missing') {
    if ($canLink) {
        try {
            New-Item -ItemType SymbolicLink -Path $targetFile -Target $RepoSettings -Force | Out-Null
            Write-Ok '已创建符号链接（settings.json -> 仓库）'
        } catch {
            Copy-Item $RepoSettings $targetFile -Force
            Show-LinkHint
        }
    } else {
        Copy-Item $RepoSettings $targetFile -Force
        Write-Ok '已复制配置'
    }
}

# ---------------------------------------------------------------------------
# 6. 背景图
# ---------------------------------------------------------------------------
if (-not $SkipBackground) {
    Write-Step '处理背景图'
    $bgSrc = Join-Path $RepoRoot 'assets\2.jpg'
    $bgDst = Join-Path $env:USERPROFILE 'Pictures\2.jpg'
    if (-not (Test-Path $bgSrc)) {
        Write-Note '仓库里缺少 assets\2.jpg，跳过'
    }
    elseif ((Test-Path $bgDst) -and -not $Force) {
        Write-Note "目标已存在同名文件，未覆盖：$bgDst（需要覆盖请加 -Force）"
    }
    else {
        $picsDir = Split-Path -Parent $bgDst
        if (-not (Test-Path $picsDir)) { New-Item -ItemType Directory -Path $picsDir -Force | Out-Null }
        Copy-Item $bgSrc $bgDst -Force
        Write-Ok "背景图已就位：$bgDst"
    }
}

# ---------------------------------------------------------------------------
# 7. Nerd Font 自动安装（装到用户字体目录，不需要管理员）
# ---------------------------------------------------------------------------
function Test-MesloInstalled {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
        'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    )
    foreach ($k in $keys) {
        try {
            $names = (Get-ItemProperty $k -ErrorAction Stop).PSObject.Properties.Name
            if ($names -match 'Meslo') { return $true }
        } catch { }
    }
    return $false
}

function Install-NerdFont {
    $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    if (-not (Test-Path $fontDir)) { New-Item -ItemType Directory -Path $fontDir -Force | Out-Null }

    # 优先用仓库内置字体（assets\fonts），仓库里没有才联网下载兜底
    $bundled = Join-Path $RepoRoot 'assets\fonts'
    $ttfs    = @()
    $cleanup = @()

    if (Test-Path $bundled) {
        $ttfs = @(Get-ChildItem $bundled -Filter '*.ttf' -Recurse)
    }

    if ($ttfs.Count -gt 0) {
        Write-Ok "使用仓库内置字体：$($ttfs.Count) 个文件（无需联网）"
    } else {
        Write-Note '仓库未内置字体，改为联网下载 Meslo（约 60 MB）'
        $zip     = Join-Path $env:TEMP 'Meslo.zip'
        $extract = Join-Path $env:TEMP 'MesloFont'
        if (Test-Path $extract) { Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue }

        Get-RemoteFile -Uri 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip' -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $extract -Force
        $ttfs = @(Get-ChildItem $extract -Filter '*.ttf' -Recurse)
        if (-not $ttfs) { throw '压缩包里没有找到 ttf 文件' }
        $cleanup = @($zip, $extract)

        # 下载的是 Meslo 全套，只取配置里实际用到的字体族
        $wanted = $null
        try {
            $cfg = Get-Content $RepoSettings -Raw -Encoding UTF8 | ConvertFrom-Json
            $face = ($cfg.profiles.list | Where-Object { $_.font -and $_.font.face } | Select-Object -First 1).font.face
            if ($face) { $wanted = ($face -replace '\s', '') }
        } catch { }

        if ($wanted) {
            $matched = @($ttfs | Where-Object { ($_.BaseName -replace '\s', '') -like "$wanted*" })
            if ($matched.Count -gt 0) { $ttfs = $matched }
        }
    }

    # 注册字体所需的 P/Invoke
    if (-not ('WinFont' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinFont {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern int AddFontResource(string lpFileName);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
}
'@
    }

    $regPath = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

    $installed = 0
    foreach ($f in $ttfs) {
        $dest = Join-Path $fontDir $f.Name
        try {
            Copy-Item $f.FullName $dest -Force -ErrorAction Stop
        } catch {
            # 已加载的字体文件会被系统锁定，无法覆盖。沿用现有文件继续注册即可。
            if (-not (Test-Path $dest)) { throw }
            Write-Note "字体文件被占用，沿用已有文件：$($f.Name)"
        }
        $regName = [IO.Path]::GetFileNameWithoutExtension($f.Name) + ' (TrueType)'
        New-ItemProperty -Path $regPath -Name $regName -Value $dest -PropertyType String -Force | Out-Null
        [void][WinFont]::AddFontResource($dest)
        $installed++
    }
    # 通知其他窗口字体已变化
    [void][WinFont]::SendMessage([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero)

    foreach ($c in $cleanup) { Remove-Item $c -Recurse -Force -ErrorAction SilentlyContinue }
    return $installed
}

if (-not $SkipFont) {
    Write-Step '检查 Nerd Font'
    if (Test-MesloInstalled) {
        Write-Ok 'Meslo Nerd Font 已安装'
    } else {
        try {
            $n = Install-NerdFont
            Write-Ok "已安装 $n 个 Meslo 字体文件到用户字体目录"
            Write-Note '个别已打开的窗口可能仍显示旧字体，重启终端即可。'
        } catch {
            Write-Bad "字体自动安装失败：$($_.Exception.Message)"
            Write-Note '可手动从 https://www.nerdfonts.com/font-downloads 下载 Meslo 安装'
        }
    }
}

# ---------------------------------------------------------------------------
# 8. WSL profile 检查
# ---------------------------------------------------------------------------
# Windows Terminal 生成动态 profile GUID 用的命名空间（见源码 DynamicProfileUtils.h）。
# 注意 name 必须按 UTF-16LE 取字节，否则算出的 GUID 与终端自己生成的对应不上，
# 会导致同一个发行版在列表里出现两次。
$script:WtProfileNamespace = '2bde4a90-d05f-401c-9492-e40884ead1d8'

function New-V5Uuid {
    param([string]$Namespace, [string]$Name)
    $g = [guid]$Namespace
    $b = $g.ToByteArray()
    # .NET Guid 前 3 段是小端，转成 RFC 4122 网络字节序
    [byte[]]$ns = @($b[3],$b[2],$b[1],$b[0], $b[5],$b[4], $b[7],$b[6],
                    $b[8],$b[9],$b[10],$b[11],$b[12],$b[13],$b[14],$b[15])
    [byte[]]$nb = [Text.Encoding]::Unicode.GetBytes($Name)
    [byte[]]$data = New-Object byte[] ($ns.Length + $nb.Length)
    [Array]::Copy($ns, 0, $data, 0, $ns.Length)
    [Array]::Copy($nb, 0, $data, $ns.Length, $nb.Length)
    $h = [Security.Cryptography.SHA1]::Create().ComputeHash($data)
    $h[6] = ($h[6] -band 0x0F) -bor 0x50
    $h[8] = ($h[8] -band 0x3F) -bor 0x80
    $hex = ($h[0..15] | ForEach-Object { $_.ToString('x2') }) -join ''
    '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0,8), $hex.Substring(8,4), $hex.Substring(12,4), $hex.Substring(16,4), $hex.Substring(20,12)
}

function Get-WslDistros {
    # 优先读注册表：不依赖 wsl.exe，没有输出编码问题，也不受执行策略影响
    $names = @()
    $root  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (Test-Path $root) {
        try {
            Get-ChildItem $root -ErrorAction Stop | ForEach-Object {
                $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($p.DistributionName) { $names += $p.DistributionName }
            }
        } catch { }
    }
    if ($names.Count -gt 0) { return $names }

    # 兜底：调用 wsl.exe
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        try {
            $raw = & $wsl.Source -l -q 2>$null
            return @($raw | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
        } catch { }
    }
    return @()
}

function Test-DistroPresent {
    param([string]$ProfileName, [string[]]$Distros)
    if (-not $Distros -or $Distros.Count -eq 0) { return $false }

    $p  = ($ProfileName -replace '[^a-zA-Z0-9]', '').ToLower()
    $pv = [regex]::Match($ProfileName, '\d+\.\d+').Value
    $pw = ($ProfileName -replace '[^a-zA-Z]', '').ToLower()

    foreach ($d in $Distros) {
        $dn = ($d -replace '[^a-zA-Z0-9]', '').ToLower()
        if ($p -eq $dn) { return $true }

        $dv = [regex]::Match($d, '\d+\.\d+').Value
        $dw = ($d -replace '[^a-zA-Z]', '').ToLower()

        # 版本号一致且主要词一致，视为同一发行版
        if ($pv -and $dv -and $pv -eq $dv -and $pw -and $dw -and ($pw.Contains($dw) -or $dw.Contains($pw))) {
            return $true
        }
        # 双方都没有版本号时，主要词完全一致才算
        if (-not $pv -and -not $dv -and $pw -and $pw -eq $dw) { return $true }
    }
    return $false
}

Write-Step '检查 WSL profile'
try {
    $settings = Get-Content $targetFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $distros  = @(Get-WslDistros)
    if ($distros.Count -gt 0) { Write-Ok ("宿主机已安装：" + ($distros -join ', ')) }
    else { Write-Note '本机没有检测到任何 WSL 发行版' }

    $wslProfiles = @()
    if ($settings.profiles -and $settings.profiles.list) {
        $wslProfiles = @($settings.profiles.list | Where-Object {
            $_.source -and ($_.source -match 'Wsl|Microsoft\.WSL|CanonicalGroupLimited|SUSE|kali|Debian|Oracle|AlmaLinux|Rocky')
        })
    }

    # 配置里有、宿主机没有 → 无效
    $invalid = @($wslProfiles | Where-Object { -not (Test-DistroPresent -ProfileName $_.name -Distros $distros) })

    # 宿主机有、配置里没有 → 缺失
    $absent = @()
    foreach ($d in $distros) {
        $hit = $wslProfiles | Where-Object { Test-DistroPresent -ProfileName $_.name -Distros @($d) }
        if (-not $hit) { $absent += $d }
    }

    if ($invalid.Count -eq 0 -and $absent.Count -eq 0) {
        Write-Ok "配置与宿主机一致（$($wslProfiles.Count) 个 WSL profile）"
    } else {
        if ($invalid.Count -gt 0) {
            Write-Note "配置里有 $($invalid.Count) 个 profile 在本机找不到对应发行版："
            foreach ($m in $invalid) { Write-Host "        - $($m.name)" -ForegroundColor DarkYellow }
        }
        if ($absent.Count -gt 0) {
            Write-Note "本机有 $($absent.Count) 个发行版还没写进配置："
            foreach ($d in $absent) { Write-Host "        + $d" -ForegroundColor DarkCyan }
            Write-Note '它们目前由 Windows Terminal 自动以默认样式显示（newTabMenu 里的 remainingProfiles）。'
        }

        $doPrune = $PruneProfiles -or $SyncProfiles
        $doAdd   = $SyncProfiles

        if (($doPrune -and $invalid.Count -gt 0) -or ($doAdd -and $absent.Count -gt 0)) {
            if ((Get-LinkState -Path $targetFile -Source $RepoSettings) -eq 'linked-ok' -and -not $Force) {
                Write-Note '当前是符号链接模式，同步会直接改到仓库文件。确认请加 -Force 重跑。'
            } else {
                $list = @($settings.profiles.list)
                if ($doPrune) {
                    $list = @($list | Where-Object { $invalid.guid -notcontains $_.guid })
                }
                if ($doAdd) {
                    foreach ($d in $absent) {
                        $list += [pscustomobject]@{
                            guid   = '{' + (New-V5Uuid -Namespace $script:WtProfileNamespace -Name $d) + '}'
                            name   = $d
                            source = 'Windows.Terminal.Wsl'
                            hidden = $false
                        }
                    }
                }
                $settings.profiles.list = $list
                $json = $settings | ConvertTo-Json -Depth 32
                [IO.File]::WriteAllText($targetFile, $json, (New-Object System.Text.UTF8Encoding $false))
                Write-Ok ("已同步：删除 {0} 个、新增 {1} 个" -f $invalid.Count, $absent.Count)
            }
        } else {
            Write-Note '想让配置与本机一致，加 -SyncProfiles -Force 重跑。'
        }
    }
} catch {
    Write-Note "WSL profile 检查跳过：$($_.Exception.Message)"
}

Write-Host ''
Write-Step '完成'
Write-Host '    重启 Windows Terminal 让配置生效。' -ForegroundColor DarkGray
Write-Host '    如果在 WT 设置界面里保存过配置，建议运行  .\setup.ps1 -Verify  确认链接没被替换。' -ForegroundColor DarkGray

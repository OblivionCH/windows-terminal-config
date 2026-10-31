#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Terminal 配置一键部署脚本。

.DESCRIPTION
    把本仓库的配置复刻到当前机器，全过程无人值守：
      1. 没装 Windows Terminal 就自动安装
      2. 定位配置目录（Store / Store 预览版 / 非 Store 便携版三种形态）
      3. 备份原配置，然后以符号链接（优先）或复制方式落地 settings.json
      4. 放置背景图
      5. 缺 Meslo Nerd Font 就自动下载安装到用户字体目录
      6. 检测 WSL 发行版，报告或清理本机打不开的 profile

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

.PARAMETER PruneProfiles
    把本机不存在的 WSL 发行版对应的 profile 从配置中移除。
    注意：符号链接模式下这会改动仓库文件。

.PARAMETER Force
    覆盖已存在的背景图；跳过 PruneProfiles 的确认提示。

.PARAMETER Verify
    只检查当前配置文件的链接状态，不做任何修改。

.PARAMETER Elevate
    没有符号链接权限时，自动以管理员身份重启脚本（会弹 UAC）。

.EXAMPLE
    .\setup.ps1

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
    [switch]$PruneProfiles,
    [switch]$Force,
    [switch]$Verify,
    [switch]$Elevate
)

$ErrorActionPreference = 'Stop'
$RepoRoot     = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoSettings = Join-Path $RepoRoot 'settings.json'
$IsPS7        = $PSVersionTable.PSVersion.Major -ge 6

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
    # 直连 GitHub 在国内经常超时，失败时自动切到加速镜像
    $attempts = @($Uri)
    if ($Uri -like 'https://github.com/*') { $attempts += ('https://gh-proxy.com/' + $Uri) }

    $last = $null
    foreach ($u in $attempts) {
        try {
            Invoke-WebRequest -Uri $u -OutFile $OutFile -UseBasicParsing -TimeoutSec 600
            return
        } catch {
            $last = $_
            Write-Note "下载失败（$($u.Substring(0, [Math]::Min(40, $u.Length)))...），换备用源重试"
        }
    }
    throw $last
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
# 2. 定位配置目录
# ---------------------------------------------------------------------------
function Get-WtConfigDir {
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
    if ($wtExe -and $wtExe -like '*\WindowsApps\*') { return $store }
    if ($wtExe -and $wtExe -match 'Preview') { return $preview }
    return $portable
}

Write-Step '定位配置目录'
$cfgDir     = Get-WtConfigDir
$targetFile = Join-Path $cfgDir 'settings.json'
Write-Ok $cfgDir

if (-not (Test-Path $cfgDir)) {
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    Write-Note '目录原本不存在，已创建。首次部署建议先启动一次 Windows Terminal 再重跑本脚本。'
}

# ---------------------------------------------------------------------------
# 3. 链接状态检查
# ---------------------------------------------------------------------------
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

if ($Verify) {
    Write-Step '检查链接状态'
    switch (Get-LinkState -Path $targetFile -Source $RepoSettings) {
        'linked-ok'    { Write-Ok 'settings.json 已正确链接到本仓库' }
        'linked-other' { Write-Note "链接指向了其他位置：$((Get-Item $targetFile -Force).Target)" }
        'file'         { Write-Note 'settings.json 是普通文件而非链接（多半是 Windows Terminal 保存配置时替换了它），运行 .\setup.ps1 修复' }
        'missing'      { Write-Note 'settings.json 不存在，运行 .\setup.ps1 部署' }
    }
    exit 0
}

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

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

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
    if ($isAdmin) {
        Write-Note '当前已是管理员，仍无符号链接权限，可能被组策略限制，将使用复制模式。'
    } else {
        Write-Step '请求管理员权限重启脚本'
        Start-Process powershell -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
        )
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
    $zip     = Join-Path $env:TEMP 'Meslo.zip'
    $extract = Join-Path $env:TEMP 'MesloFont'

    if (-not (Test-Path $fontDir)) { New-Item -ItemType Directory -Path $fontDir -Force | Out-Null }
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Note '下载 Meslo Nerd Font（约 20 MB）'
    Get-RemoteFile -Uri 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip' -OutFile $zip

    Expand-Archive -Path $zip -DestinationPath $extract -Force
    $ttfs = Get-ChildItem $extract -Filter '*.ttf' -Recurse
    if (-not $ttfs) { throw '压缩包里没有找到 ttf 文件' }

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
        Copy-Item $f.FullName $dest -Force
        $regName = [IO.Path]::GetFileNameWithoutExtension($f.Name) + ' (TrueType)'
        New-ItemProperty -Path $regPath -Name $regName -Value $dest -PropertyType String -Force | Out-Null
        [void][WinFont]::AddFontResource($dest)
        $installed++
    }
    # 通知其他窗口字体已变化
    [void][WinFont]::SendMessage([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero)

    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
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
    $distros  = Get-WslDistros
    if ($distros.Count -gt 0) { Write-Ok ("已安装的 WSL 发行版：" + ($distros -join ', ')) }
    else { Write-Note '本机没有检测到任何 WSL 发行版' }

    $wslProfiles = @()
    if ($settings.profiles -and $settings.profiles.list) {
        $wslProfiles = @($settings.profiles.list | Where-Object {
            $_.source -and ($_.source -match 'Wsl|Microsoft\.WSL|CanonicalGroupLimited|SUSE|kali|Debian|Oracle|AlmaLinux|Rocky')
        })
    }

    if ($wslProfiles.Count -eq 0) {
        Write-Ok '配置里没有 WSL profile'
    } else {
        $missing = @($wslProfiles | Where-Object { -not (Test-DistroPresent -ProfileName $_.name -Distros $distros) })
        if ($missing.Count -eq 0) {
            Write-Ok "全部 $($wslProfiles.Count) 个 WSL profile 在本机都能打开"
        } else {
            Write-Note "以下 $($missing.Count) 个 profile 在本机找不到对应发行版，标签页会存在但打不开："
            foreach ($m in $missing) { Write-Host "        - $($m.name)  (source: $($m.source))" -ForegroundColor DarkYellow }

            if ($PruneProfiles) {
                if ((Get-LinkState -Path $targetFile -Source $RepoSettings) -eq 'linked-ok' -and -not $Force) {
                    Write-Note '当前是符号链接模式，裁剪会直接修改仓库文件。确认请加 -Force 重跑。'
                } else {
                    $keep = @($settings.profiles.list | Where-Object {
                        $missing.guid -notcontains $_.guid
                    })
                    $settings.profiles.list = $keep
                    $json = $settings | ConvertTo-Json -Depth 32
                    [IO.File]::WriteAllText($targetFile, $json, (New-Object System.Text.UTF8Encoding $false))
                    Write-Ok "已移除 $($missing.Count) 个无效 profile"
                }
            } else {
                Write-Note '想让它们自动消失，可加 -PruneProfiles 重跑；也可以稍后在终端设置里手动隐藏。'
            }
        }
    }
} catch {
    Write-Note "WSL profile 检查跳过：$($_.Exception.Message)"
}

Write-Host ''
Write-Step '完成'
Write-Host '    重启 Windows Terminal 让配置生效。' -ForegroundColor DarkGray
Write-Host '    如果在 WT 设置界面里保存过配置，建议运行  .\setup.ps1 -Verify  确认链接没被替换。' -ForegroundColor DarkGray

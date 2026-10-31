#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Terminal 配置一键部署脚本。

.DESCRIPTION
    把本仓库的 settings.json 部署到当前机器的 Windows Terminal 配置目录。
    自动识别 Store 版 / Store 预览版 / 非 Store（便携、Scoop、winget unpackaged）三种安装形态的配置路径。
    优先创建符号链接，让仓库文件与本机配置始终是同一份；无法创建链接时自动退回复制模式。
    部署前会备份原有的 settings.json。

.PARAMETER Copy
    强制使用复制模式，不创建符号链接。

.PARAMETER SkipBackground
    不复制背景图。

.PARAMETER Force
    覆盖已存在的背景图。

.PARAMETER Verify
    只检查当前配置文件的链接状态，不做任何修改。

.PARAMETER Elevate
    当前会话没有权限创建符号链接时，自动以管理员身份重新启动本脚本（会弹 UAC）。

.EXAMPLE
    .\setup.ps1

.EXAMPLE
    .\setup.ps1 -Elevate

.EXAMPLE
    .\setup.ps1 -Verify

.EXAMPLE
    .\setup.ps1 -Copy
#>
[CmdletBinding()]
param(
    [switch]$Copy,
    [switch]$SkipBackground,
    [switch]$Force,
    [switch]$Verify,
    [switch]$Elevate
)

$ErrorActionPreference = 'Stop'
$RepoRoot     = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoSettings = Join-Path $RepoRoot 'settings.json'

function Write-Step { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Note { param($m) Write-Host "    !!  $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 1. 定位配置目录
# ---------------------------------------------------------------------------
function Get-WtConfigDir {
    $store    = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
    $preview  = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState'
    $portable = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal'
    $all      = @($store, $preview, $portable)

    # 已经有配置文件的最可信
    foreach ($p in $all) {
        if (Test-Path (Join-Path $p 'settings.json')) { return @{ Path = $p; Kind = 'existing' } }
    }
    # 目录存在但还没生成配置
    foreach ($p in $all) {
        if (Test-Path $p) { return @{ Path = $p; Kind = 'existing' } }
    }
    # 全新机器：按安装的包类型推断
    $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal*' -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($pkg) {
        if ($pkg.Name -like '*Preview*') { return @{ Path = $preview; Kind = 'new' } }
        return @{ Path = $store; Kind = 'new' }
    }
    return @{ Path = $portable; Kind = 'new' }
}

Write-Step '检测 Windows Terminal 配置目录'
$cfg        = Get-WtConfigDir
$cfgDir     = $cfg.Path
$targetFile = Join-Path $cfgDir 'settings.json'
Write-Ok "配置目录：$cfgDir"

if (-not (Test-Path $cfgDir)) {
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    Write-Note '该目录原本不存在，已创建。如果 Windows Terminal 从未启动过，建议先启动一次再重跑本脚本。'
}

# ---------------------------------------------------------------------------
# 2. 链接状态检查
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
        'file'         { Write-Note 'settings.json 是普通文件而非链接（多半是 Windows Terminal 保存配置时把它替换了），运行 .\setup.ps1 修复' }
        'missing'      { Write-Note 'settings.json 不存在，运行 .\setup.ps1 部署' }
    }
    exit 0
}

# ---------------------------------------------------------------------------
# 3. 判断能否创建符号链接（实测一次，比读注册表可靠）
# ---------------------------------------------------------------------------
function Test-SymlinkAbility {
    $probe = Join-Path $env:TEMP ("wt-linktest-" + [guid]::NewGuid().ToString('N'))
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
# 4. 备份并落地配置
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
# 5. 背景图
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
# 6. 字体检查
# ---------------------------------------------------------------------------
Write-Step '检查 Nerd Font'
try {
    $fontNames = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts').PSObject.Properties.Name
    if ($fontNames -match 'Meslo') {
        Write-Ok 'Meslo Nerd Font 已安装'
    } else {
        Write-Note '未检测到 Meslo Nerd Font，终端会回退到默认字体（显示效果会变差）'
        Write-Note '安装：winget search nerd font，或到 https://www.nerdfonts.com/font-downloads 下载 Meslo'
    }
} catch {
    Write-Note '字体检查跳过'
}

Write-Host ''
Write-Step '完成'
Write-Host '    重启 Windows Terminal 让配置生效。' -ForegroundColor DarkGray
Write-Host '    如果在 WT 设置界面里保存过配置，建议运行  .\setup.ps1 -Verify  确认链接没被替换。' -ForegroundColor DarkGray

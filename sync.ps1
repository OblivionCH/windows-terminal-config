#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Terminal 配置仓库的同步辅助脚本。

.DESCRIPTION
    符号链接模式下，在 Windows Terminal 里改设置就等于改仓库文件，不需要额外的同步动作。
    本脚本只是把常用的 git 操作包一层，避免每次都敲长命令。

.PARAMETER Pull
    拉取远程更新，然后校验链接是否仍然有效。

.PARAMETER Push
    提交本机改动并推送到远程。推送前会展示 git diff 并做机器相关泄露检查
    （绝对用户路径、窗口尺寸微调等），确认后才提交。-Message 可选。

.PARAMETER Message
    提交信息。不填则自动生成带时间戳的信息。

.PARAMETER Force
    跳过交互确认（仍会展示 diff 与泄露检查结果），用于自动化场景。

.PARAMETER Verify
    只校验链接状态。

.EXAMPLE
    .\sync.ps1 -Pull

.EXAMPLE
    .\sync.ps1 -Push -Message "调整字体和透明度"

.EXAMPLE
    .\sync.ps1 -Push -Force
#>
[CmdletBinding()]
param(
    [switch]$Pull,
    [switch]$Push,
    [switch]$Verify,
    [switch]$Force,
    [string]$Message
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# 共用库：输出函数 + 网络处理。sync.ps1 只取里面的 Write-* 与 Invoke-Git，
# 不调用 Initialize-Network（否则全局 insteadOf 会把 git push 改写到只读镜像）。
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\net.ps1')

# 机器相关泄露检查：在 -Push 前扫描 diff，提示可能仅属于本机的内容，
# 避免把不可移植的改动带进可复用的基线。
function Test-MachineSpecificLeak {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [string]$Diff
    )
    $issues = @()
    if ($Diff -match 'C:\\Users\\[^\\/\s"'' ]+') {
        $issues += '本机用户绝对路径 (C:\Users\...) — 换机后路径失效，建议改用相对路径或环境变量'
    }
    if ($Diff -match 'initialCols|initialRows') {
        $issues += '窗口尺寸字段 (initialCols/initialRows) — 多为临时调整，一般不进基线'
    }
    if ($Diff -match '(?i)\b(DESKTOP|LAPTOP)-[A-Z0-9]{4,}\b') {
        $issues += '疑似本机设备名 (DESKTOP-/LAPTOP-...) — 可能暴露设备信息'
    }
    return $issues
}


if ($Pull) {
    Write-Step '拉取远程更新'
    if ((Invoke-Git -Arguments @('-C', $RepoRoot, 'pull', '--ff-only')) -ne 0) {
        throw 'git pull 失败，请检查网络或本地改动'
    }
    Write-Ok '已更新'
    & (Join-Path $RepoRoot 'setup.ps1') -Verify
    Write-Host '    重启 Windows Terminal 让新配置生效。' -ForegroundColor DarkGray
    exit 0
}

if ($Push) {
    Write-Step '检查本机改动'
    $status = & git -C $RepoRoot status --porcelain
    if (-not $status) {
        Write-Note '没有需要提交或推送的改动'
        exit 0
    }

    Write-Host ''
    Write-Host '以下改动将被提交并推送：' -ForegroundColor Cyan
    & git -C $RepoRoot diff --stat HEAD
    Write-Host ''

    $diff = & git -C $RepoRoot diff HEAD
    $leaks = Test-MachineSpecificLeak -Diff $diff
    if ($leaks) {
        Write-Bad '检测到可能仅属于本机的改动，请确认是否要落库：'
        foreach ($leak in $leaks) { Write-Indented $leak }
        Write-Host ''
    }

    if (-not $Force) {
        $ans = Read-Host '确认提交并推送以上改动？(y/N)'
        if ($ans -notmatch '^[yY]') {
            Write-Note '已取消，未做任何提交'
            exit 0
        }
    }

    Write-Step '提交并推送'
    if (-not $Message) { $Message = "update: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" }
    & git -C $RepoRoot add -A
    & git -C $RepoRoot commit -m $Message | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Note '没有可提交的改动（可能与基线无差异）'
    }
    else {
        Write-Ok '已提交'
    }
    if ((Invoke-Git -Arguments @('-C', $RepoRoot, 'push')) -ne 0) {
        throw 'git push 失败，请检查远程配置与凭据'
    }
    Write-Ok '已推送'
    exit 0
}

if ($Verify) {
    & (Join-Path $RepoRoot 'setup.ps1') -Verify
    exit 0
}

# 无参数：打印当前状态
Write-Step '仓库状态'
git -C $RepoRoot status --short --branch
Write-Host ''
Write-Step '链接状态'
& (Join-Path $RepoRoot 'setup.ps1') -Verify
Write-Host ''
Write-Host '用法：' -ForegroundColor DarkGray
Write-Host '    .\sync.ps1 -Pull                    拉取远程更新' -ForegroundColor DarkGray
Write-Host '    .\sync.ps1 -Push -Message "说明"     复核并提交本机改动' -ForegroundColor DarkGray
Write-Host '    .\sync.ps1 -Push -Force            跳过确认直接推送（自动化用）' -ForegroundColor DarkGray
Write-Host '    .\sync.ps1 -Verify                  只检查链接状态' -ForegroundColor DarkGray

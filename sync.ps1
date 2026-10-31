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
    提交本机所有改动并推送到远程。-Message 可选。

.PARAMETER Message
    提交信息。不填则自动生成带时间戳的信息。

.PARAMETER Verify
    只校验链接状态。

.EXAMPLE
    .\sync.ps1 -Pull

.EXAMPLE
    .\sync.ps1 -Push -Message "调整字体和透明度"
#>
[CmdletBinding()]
param(
    [switch]$Pull,
    [switch]$Push,
    [switch]$Verify,
    [string]$Message
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Note { param($m) Write-Host "    !!  $m" -ForegroundColor Yellow }

function Invoke-Git {
    # 直连 github.com 在国内经常失败（502 / TLS 握手失败）。第一次失败后
    # 用 git 的进程级 insteadOf 把 github.com 改写到 gh-proxy 再试一次，
    # 不写任何配置文件，进程结束即失效。
    param([string[]]$Arguments)

    # 输出直接送控制台（Out-Host），不走管道，否则函数返回值会混进 git 的输出
    & git @Arguments 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0) { return 0 }

    Write-Note '直连失败，改走 gh-proxy 镜像重试一次'
    $env:GIT_CONFIG_COUNT   = '1'
    $env:GIT_CONFIG_KEY_0   = 'url.https://gh-proxy.com/https://github.com/.insteadOf'
    $env:GIT_CONFIG_VALUE_0 = 'https://github.com/'
    try {
        & git @Arguments 2>&1 | Out-Host
        return $LASTEXITCODE
    } finally {
        Remove-Item Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
    }
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
    Write-Step '提交并推送'
    if (-not $Message) { $Message = "update: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" }
    & git -C $RepoRoot add -A
    & git -C $RepoRoot commit -m $Message
    if ($LASTEXITCODE -ne 0) { Write-Ok '没有需要提交的改动' }
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
Write-Host '    .\sync.ps1 -Push -Message "说明"     提交并推送本机改动' -ForegroundColor DarkGray
Write-Host '    .\sync.ps1 -Verify                  只检查链接状态' -ForegroundColor DarkGray

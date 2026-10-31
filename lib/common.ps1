# lib/common.ps1 — 三个脚本共用的输出函数
#
# 三个脚本（setup / update / sync）原来各抄了一份，颜色与格式一致。
# 集中到这里，改一处全局生效。本文件必须在使用它的脚本里 dot-source。

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

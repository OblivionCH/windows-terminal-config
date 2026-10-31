# lib/common.ps1 — 三个脚本共用的输出函数
#
# 三个脚本（setup / update / sync）原来各抄了一份，颜色与格式一致。
# 集中到这里，改一处全局生效。本文件必须在使用它的脚本里 dot-source。

# ---------------------------------------------------------------------------
# 编码加固（针对宿主机一键安装）
#
# 中文 Windows 上 PowerShell 5.1 默认按系统代码页（GBK 936）做文件读写与子
# 进程输出解码：不写 -Encoding 的 Get-Content/Set-Content 会写出 GBK，git/curl/
# scoop/winget 的 UTF-8 输出会被当成 GBK 解码成乱码。这里强制本脚本全程 UTF-8，
# 不依赖宿主机的代码页设置——无论目标机是中文 / 日文 / 英文环境都能正确跑。
# （脚本 .ps1 文件本身也已带 UTF-8 BOM，保证 powershell -File 在 5.1 下能解析）
# ---------------------------------------------------------------------------
$PSDefaultParameterValues['Get-Content:Encoding'] = 'utf8'
$PSDefaultParameterValues['Set-Content:Encoding'] = 'utf8'
$PSDefaultParameterValues['Out-File:Encoding']     = 'utf8'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

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

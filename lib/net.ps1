# lib/net.ps1 — 三个脚本共用的网络处理
#
# 设计目标：不管机器有没有代理，只要能联网，脚本就该能跑。
#
# 统一策略（原先三处实现各搞一套，这里收敛成一份）：
#   - 有可用代理 → 设 HTTP(S)_PROXY，git/curl/scoop 都认（直连优先、镜像兜底）
#   - 没有代理 → $UseMirror=$true，并且注入 git 进程级 insteadOf，让所有
#     github.com 的 git 操作（含 scoop 内部的 fetch/update）自动走镜像；
#     显式构造 URL 的地方（bucket clone、API、下载）用 Get-MirrorUrl 改写。
#     （之前 setup.ps1 只做后者，漏掉了 scoop 内部的 git；现在补齐）
#
# 所有开关只影响当前进程，不写任何配置文件。dot-source 后这些函数与
# 脚本共享同一个 script 作用域，所以 $UseMirror / $ProxyAddr 在脚本主流程
# 里也能直接读到。

$script:UseMirror = $false
$script:ProxyAddr = $null

$MirrorHost = 'https://gh-proxy.com/'

function Get-ProxyCandidate {
    # 解析一个可用的代理地址，优先级：显式参数 > 环境变量 > 系统代理注册表。
    # 返回纯 host:port（去掉协议头），拿不到返回 $null。
    param([string]$Proxy)
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
    # 两步判定，缺一不可：
    #   1) 端口通不通（快速排除代理软件没启动）
    #   2) 能不能真的到 GitHub（端口开着不代表能用：可能只代理内网、要认证、
    #      或像某些注入的临时代理一样时通时不通）
    # 只测端口会误判（注册表留着旧地址、临时代理连不上 GitHub）。
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
    } catch {
        return $false
    } finally {
        $client.Close()
    }

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
    # 探测并应用网络策略。无参数时用 $Proxy 调用方变量（dot-source 后可见）；
    # 显式传 -Proxy 更稳妥。
    param([string]$Proxy = '')
    $cand = Get-ProxyCandidate -Proxy $Proxy
    if ($cand -and (Test-ProxyAlive -Addr $cand)) {
        $script:ProxyAddr = $cand
        $env:HTTP_PROXY  = "http://$cand"
        $env:HTTPS_PROXY = "http://$cand"
        Write-Ok "检测到可用代理 $cand，本次运行的下载都走它"
        return
    }

    # 没有可用代理：先清掉可能残留的坏代理变量（否则 git 还是会去连它），
    # 再统一开镜像。
    $script:UseMirror = $true
    foreach ($v in 'HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'ALL_PROXY', 'all_proxy') {
        Remove-Item "Env:$v" -ErrorAction SilentlyContinue
    }
    # git 进程级 insteadOf：让所有 github.com 的 git 操作（含 scoop 内部的
    # fetch/update）自动改走镜像。不写配置文件，进程结束即失效。
    $env:GIT_CONFIG_COUNT   = '1'
    $env:GIT_CONFIG_KEY_0   = ('url.' + $MirrorHost + 'https://github.com/.insteadOf')
    $env:GIT_CONFIG_VALUE_0 = 'https://github.com/'

    if ($cand) {
        Write-Note "代理 $cand 连不上（可能没开），改用 gh-proxy 镜像"
    } else {
        Write-Note '本机没有代理，GitHub 相关操作走 gh-proxy 镜像'
    }
    Write-Note '镜像只影响本次运行，不会写进任何配置文件'
}

function Get-MirrorUrl {
    # 把一个 GitHub 链接改写成镜像链接；镜像未启用或非 GitHub 域名返回 $null。
    # gh-proxy 不只代理 github.com，api / raw / codeload 也通（实测都能 200）。
    param([string]$Url)
    if (-not $script:UseMirror) { return $null }
    if ($Url -notmatch '^https://(github\.com|api\.github\.com|raw\.githubusercontent\.com|codeload\.github\.com)/') { return $null }
    return $MirrorHost + $Url
}

function Get-BucketSource {
    # bucket 的 git clone 地址：没有代理时改走镜像（gh-proxy 支持 git 协议）。
    param([string]$Source)
    if ($script:UseMirror -and $Source -like 'https://github.com/*') {
        return $MirrorHost + $Source
    }
    return $Source
}

function Invoke-GitHubApi {
    # 查 GitHub 最新 release。无代理时镜像优先、直连兜底；有代理时反之。
    # 两次都失败才抛，让调用方退回内置版本号。
    param([string]$Url)
    $mirror = Get-MirrorUrl -Url $Url
    $order  = @()
    if ($mirror) {
        if ($script:ProxyAddr) { $order = @($Url, $mirror) } else { $order = @($mirror, $Url) }
    } else {
        $order = @($Url)
    }

    $last = $null
    foreach ($u in $order) {
        try {
            return Invoke-RestMethod -Uri $u -TimeoutSec 60 -Headers @{ 'User-Agent' = 'wt-config-setup' }
        } catch { $last = $_ }
    }
    throw $last
}

function Get-RemoteFile {
    # 下载一个文件。统一交给系统自带的 curl.exe：Invoke-WebRequest 在 5.1 下
    # 处理大文件 + 镜像分块响应会挂死。代理环境的证书链不被 curl 自带 CA
    # 认可，故用 -k 跳过校验（只影响本次下载，不改系统信任）。
    param([string]$Uri, [string]$OutFile)
    $mirror = Get-MirrorUrl -Uri $Uri

    $attempts = @()
    if ($mirror) {
        # 有代理时直连够快，镜像兜底；无代理时镜像打头
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

function Invoke-Git {
    # 执行 git 命令：先直连，失败再用 git 进程级 insteadOf 改走镜像重试一次。
    # 用于 sync.ps1 这类「不能把镜像全局化」的场景——git push 一旦被 insteadOf
    # 改写到 gh-proxy 会静默失败（gh-proxy 只读），所以 push 必须走直连。
    # 每次调用各自注入 insteadOf，刚用完就撤，绝不污染全局环境。
    param([string[]]$Arguments)
    & git @Arguments 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0) { return 0 }

    Write-Note '直连失败，改走 gh-proxy 镜像重试一次'
    $env:GIT_CONFIG_COUNT   = '1'
    $env:GIT_CONFIG_KEY_0   = ('url.' + $MirrorHost + 'https://github.com/.insteadOf')
    $env:GIT_CONFIG_VALUE_0 = 'https://github.com/'
    try {
        & git @Arguments 2>&1 | Out-Host
        return $LASTEXITCODE
    } finally {
        Remove-Item Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
    }
}

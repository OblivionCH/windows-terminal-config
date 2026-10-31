# Windows Terminal 配置 + 软件环境

我的 Windows Terminal 设置和常用软件清单，一条命令复刻到任意一台 Windows 机器——配置、字体、背景图、scoop bucket、几十个软件全都能一次性到位。

## 仓库内容

| 路径 | 说明 |
| --- | --- |
| `settings.json` | 主配置（主题、字体、快捷键、配色方案、profile 列表） |
| `assets/packages.json` | 软件清单：scoop bucket / scoop 软件 / winget 软件 |
| `assets/2.jpg` | 终端背景图 |
| `assets/fonts/` | Meslo Nerd Font（4 个 ttf，安装时无需联网） |
| `assets/scoop-config.json` | Scoop 配置（已脱敏，不含 token） |
| `setup.ps1` | 一键部署脚本 |
| `sync.ps1` | git 拉取 / 推送的便捷封装 |

## 在新机器上部署

PowerShell 里执行一行（全新系统也能跑，不需要预装 git）：

```powershell
$d="$env:USERPROFILE\dotfiles\windows-terminal";$u="https://github.com/OblivionCH/windows-terminal-config/archive/refs/heads/main.zip";if(Test-Path "$d\setup.ps1"){if(Get-Command git -ErrorAction SilentlyContinue){git -C $d pull}}else{$z="$env:TEMP\wtcfg.zip";$t="$env:TEMP\wtcfg";foreach($s in @("https://gh-proxy.com/$u",$u)){& "$env:SystemRoot\System32\curl.exe" -k -L -s --fail -o $z $s;if((Test-Path $z) -and (Get-Item $z).Length -gt 0){break}};Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue;Expand-Archive $z $t -Force;New-Item -ItemType Directory $d -Force|Out-Null;Copy-Item "$t\windows-terminal-config-main\*" $d -Recurse -Force};powershell -NoProfile -ExecutionPolicy Bypass -File "$d\setup.ps1"
```

已经装过 git 的话，用短一点的版本（能 `git pull` 增量更新）：

```powershell
$d="$env:USERPROFILE\dotfiles\windows-terminal"; if(Test-Path $d){git -C $d pull}else{git clone https://github.com/OblivionCH/windows-terminal-config.git $d}; powershell -NoProfile -ExecutionPolicy Bypass -File "$d\setup.ps1"
```

想先看看会装什么、不动系统：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\dotfiles\windows-terminal\setup.ps1" -DryRun
```

脚本依次完成：

1. **winget** —— 没有就自动下载安装（msixbundle + VCLibs 依赖，用 5.1 的 Appx 装）
2. **git** —— 没有就先装。scoop 的 bucket 本质是 git 仓库，没 git 连 bucket 都加不了
3. **scoop** —— 没有就自动安装，并把仓库里的配置合并进去（只补缺失项，不动本机已有的 token / proxy）
4. **scoop bucket** —— 按清单配齐 `main` / `extras` / `versions` / `nirsoft` / `sysinternals` / `nerd-fonts` / `apps`，不用手动一个个 `bucket add`
5. **scoop 软件** —— 装清单里的 47 个命令行工具和应用，已装的自动跳过
6. **winget 软件** —— 装 scoop 里没有的 22 个（浏览器、微信生态、办公、驱动类工具等）
7. **Windows Terminal** —— 没装就自动安装。优先 winget，回退官方 msixbundle
8. **定位配置目录** —— Store 版 `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState`，预览版走 `...TerminalPreview...`，非 Store 便携版走 `%LOCALAPPDATA%\Microsoft\Windows Terminal`
9. **备份并落地配置** —— 原文件存为 `settings.json.bak-<时间戳>`，本机配置换成指向仓库文件的符号链接（无权限时退回复制模式）
10. **背景图** —— 复制到 `%USERPROFILE%\Pictures\2.jpg`
11. **字体** —— 优先用仓库内置的 ttf，仓库缺失才联网下载兜底
12. **WSL profile** —— 对比宿主机实际安装的发行版，报告差异

最后重启 Windows Terminal 生效。

## 软件清单 `assets/packages.json`

```json
{
  "buckets": [ { "name": "extras", "source": "https://github.com/ScoopInstaller/Extras" } ],
  "scoop":   [ "7zip", "git", "neovim", "..." ],
  "winget":  [ "Google.Chrome", "Microsoft.VisualStudioCode", "..." ]
}
```

三段各管一件事：

- **`buckets`** —— 先配仓库，再装软件。缺哪个 bucket 就 `scoop bucket add`，已有的跳过
- **`scoop`** —— scoop 能覆盖的全部走这里，安装到 `%SCOOP%`，不需要管理员权限
- **`winget`** —— scoop 里没有的走 winget，覆盖浏览器、微信/飞书/豆包、PDF24、Quicker 这类

**判断"装没装"的方式**：scoop 侧看 `%SCOOP%\apps\<名字>\current` 这个链接在不在（装失败只留版本目录、没有 `current`）；winget 侧用 `--no-upgrade` 让 winget 自己判断，已装会返回 97 直接跳过。

`--no-upgrade` 这个参数很关键。不加的话 winget 会把"已安装"当成"可以升级"，遇到正在运行的程序就报 `0x80070020` 文件占用失败，还会白白耗掉几分钟。

### 维护清单

装/卸了软件之后，让仓库跟上：

```powershell
.\setup.ps1 -ExportApps
```

它会扫本机实际情况重写 `packages.json`，然后 `.\sync.ps1 -Push` 提交。

两个已知取舍：

- **winget export 有盲区**：它只认自己装过的包，用安装程序手动装的（Chrome、Firefox、夸克网盘、迅雷）完全识别不出来。所以导出时会把**旧清单里的条目并回去**，并在输出里列出「识别不出但保留」的几项——看到这个提示不用慌，那是正常的
- **卸载不会自动从清单里消失**：因为是并集，手工删条目就行

### 装不上怎么办

- **scoop 包失败** —— 多半是网络。单个重试：`scoop install <名字>`；bucket 没配齐就重跑 `setup.ps1`
- **winget 包失败** —— 多数 winget 包需要管理员权限，用 `.\setup.ps1 -Elevate` 提权重跑，或手动 `winget install --id <ID> -e`
- **两边都没有的** —— 比如向日葵、Watt Toolkit（后者只在 msstore 源里），脚本不会碰，自己装

## 自动安装的边界

**winget**：`DesktopAppInstaller` 的 msixbundle 约 207 MB，依赖包 93 MB。查 GitHub API 拿最新版本，失败时用内置版本号 `v1.29.380`。Appx 操作全部转交 5.1 子进程。

**git**：优先 `winget install Git.Git`；winget 不可用时下载 MinGit 便携版 zip 解压到 `%LOCALAPPDATA%\Programs\MinGit`，写进用户 PATH，免安装免管理员。

**scoop**：跑官方 `get.scoop.sh` 安装脚本。装完刷新当前会话 PATH，再把 `assets/scoop-config.json` 合并进 `~/.config/scoop/config.json`。**只补本机没有的键**——`gh_token`、`proxy` 这类本机专属项绝不会被覆盖。

**Windows Terminal**：winget 可用就 `winget install Microsoft.WindowsTerminal`；不可用则拉 msixbundle + VCLibs 用 Appx 装。

**字体**：仓库里带 4 个 Meslo ttf，直接复制 + 写注册表 + `AddFontResource`，全程离线。仓库没有字体文件时才回退到从 `ryanoasis/nerd-fonts` 下载 `Meslo.zip`（63 MB），并只提取配置里 `font.face` 对应的族。

跳过某些步骤：`-SkipApps`（不装软件）、`-SkipWinget`、`-SkipScoop`、`-SkipTerminal`、`-SkipFont`、`-SkipBackground`。
只装软件不碰配置：`-AppsOnly`。只看不装：`-DryRun`。

## WSL profile 同步

配置里的 WSL 标签页跟着机器走。脚本读注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss` 拿到本机真实安装的发行版，做双向比对：

```
==> 检查 WSL profile
    OK  宿主机已安装：Ubuntu-22.04, MyBooksService
    !!  配置里有 2 个 profile 在本机找不到对应发行版：
        - Ubuntu 18.04.6 LTS
        - Ubuntu
    !!  本机有 1 个发行版还没写进配置：
        + Arch
```

- `-PruneProfiles` —— 删掉本机打不开的
- `-SyncProfiles` —— 双向同步：删掉无效的，同时把本机有但配置没有的加进去
- 加 `-Force` 确认（符号链接模式下会直接改仓库文件）

**关于自动添加的 GUID**：Windows Terminal 用 UUIDv5 从发行版名生成动态 profile 的 GUID，命名空间是 `2bde4a90-d05f-401c-9492-e40884ead1d8`，name 按 **UTF-16LE** 取字节（见源码 `DynamicProfileUtils.h`）。脚本复现了这个算法，`Alpine → 1777cdf0-b2c4-5a63-a204-eb60f349ea7c` 这类样本可以精确对上。

但要注意：只有 `Windows.Terminal.Wsl` 源用这套规则，`Microsoft.WSL`（新 WSL 生成器）和 Store 应用包（`CanonicalGroupLimited.*`）各有自己的算法。所以如果宿主机某个发行版本来的 profile 是 `Microsoft.WSL` 源，脚本补出来的可能是另一个 GUID，终端里会看到两个同名标签——删掉其中一个即可。**新机器上首次部署通常不受影响**（那时还没有历史 profile）。

## PowerShell 版本

脚本同时兼容 Windows PowerShell 5.1 和 PowerShell 7：

- 检测到 PS7 运行时，`Add-AppxPackage` / `Get-AppxPackage` 这类操作会自动转交 `powershell.exe`（5.1）子进程执行，因为 **Appx 模块在 PS7 下会报 `Operation is not supported on this platform`**
- 脚本本身不需要 PS7，系统自带的 5.1 就能跑完全部流程

**关于卸载 PS7**：不建议。PowerShell 7 常被其他工具链依赖（VS Code 终端配置、各类 CLI 的 pwsh 脚本等），贸然卸载可能连带打断这些工具。本仓库的脚本不依赖 PS7，装或不装都不影响使用。

## 国内网络

脚本里所有 GitHub 下载都优先走 `gh-proxy.com` 镜像，失败才回退直连。原因很实际：直连 GitHub 经常是「龟速但不报错」，超时参数兜不住，会让人以为脚本卡死。

下载统一交给系统自带的 `curl.exe` 而不是 `Invoke-WebRequest`——后者在 PowerShell 5.1 下处理大文件加镜像分块响应时会挂死。curl 因代理环境的证书链问题加了 `-k`，只影响本次下载，不改动系统信任设置。

## 为什么用符号链接

链接建好之后，仓库文件就是本机配置本身：

- 在 Windows Terminal 设置界面里改动 → 仓库里 `git diff` 立刻能看到
- `git pull` 之后重启终端 → 新配置生效

不需要任何「导出 / 导入」的中间步骤。

符号链接需要当前登录令牌带 `SeCreateSymbolicLinkPrivilege`：要么开启开发者模式**并重新登录**，要么用管理员权限。都没有的话脚本自动改用复制模式，此时本机改动不会自动进仓库。

## 日常使用

```powershell
.\sync.ps1                 # 看当前状态
.\sync.ps1 -Pull           # 拉取更新并校验链接
.\sync.ps1 -Push           # 提交并推送本机改动
.\setup.ps1 -Verify        # 只检查链接是否还有效
.\setup.ps1 -DryRun        # 预览会装哪些软件，不动系统
.\setup.ps1 -ExportApps    # 把本机软件导回 packages.json
.\setup.ps1 -SyncProfiles -Force   # 按本机实际情况同步 WSL profile
```

装完新软件后同步仓库的标准动作：

```powershell
.\setup.ps1 -ExportApps
git diff assets/packages.json     # 看一眼新增了什么
.\sync.ps1 -Push
```

## 跨机器差异是怎么处理的

| 差异点 | 处理方式 |
| --- | --- |
| 配置目录路径 | `setup.ps1` 运行时探测，不写进仓库 |
| 背景图路径 | `settings.json` 里写 `%USERPROFILE%\Pictures\2.jpg`，WT 会展开环境变量 |
| 字体 | 仓库内置 ttf，离线安装；缺失时联网兜底 |
| WSL 发行版 | 注册表检测，报告 / `-PruneProfiles` / `-SyncProfiles` |
| 软件 | `assets/packages.json` 声明，scoop 优先、winget 兜底 |
| scoop 安装位置 | 跟随目标机自己的 `%SCOOP%`（本机是 `D:\scoop`，新机器默认 `~\scoop`） |
| winget、git、scoop、Windows Terminal | 检测缺失则自动安装 |

## 故障排查

**提示「创建符号链接失败：此操作需要管理员权限」，但开发者模式明明是开的**

开发者模式的注册表开关（`AllowDevelopmentWithoutDevLicense = 1`）只是「允许」，真正决定能否建链接的是登录令牌里的 `SeCreateSymbolicLinkPrivilege`。开启开发者模式后**必须重新登录（或重启）**，这个权限才会进入令牌。

实测当前是否具备权限：

```powershell
$p="$env:TEMP\lt"; New-Item -ItemType Directory $p -Force|Out-Null; Set-Content "$p\t.txt" x; try{New-Item -ItemType SymbolicLink -Path "$p\l.txt" -Target "$p\t.txt" -ErrorAction Stop|Out-Null; "可以创建"}catch{"无权限"}; Remove-Item $p -Recurse -Force
```

解决：`.\setup.ps1 -Elevate` 自动提权，或管理员窗口里直接跑，或重启后重跑。

**git push 报 `CONNECT tunnel failed, response 502`**

环境里有多个代理在跑时，git 可能连到了错误的那个（比如工具注入的代理不支持 CONNECT 隧道）。用 `git -c http.proxy=...` 显式指定可用代理：

```powershell
git -c http.proxy=http://127.0.0.1:7897 -c https.proxy=http://127.0.0.1:7897 push
```

先用 `curl -x http://127.0.0.1:7897 -s -o /dev/null -w "%{http_code}" https://github.com` 确认哪个端口返回 200。

**git 报 `CRYPT_E_NO_REVOCATION_CHECK` 或证书错误**

代理或公司网络环境下常见，证书吊销检查（OCSP）被阻断。临时关掉：

```powershell
git config --global http.schannelCheckRevoke false
```

**`Get-AppxPackage` 报 `Operation is not supported on this platform`**

在 PowerShell 7 里执行了 Appx 命令，该模块只支持 5.1。本脚本已自动处理；手动操作时用 `powershell.exe` 而不是 `pwsh.exe`。

**在 WT 设置界面保存过配置后，`-Verify` 报「是普通文件而非链接」**

部分 WT 版本保存设置时会用临时文件替换原文件，把符号链接替换成实体文件。重跑 `.\setup.ps1` 恢复即可。

**背景图不显示**

确认 `%USERPROFILE%\Pictures\2.jpg` 存在；目标机已有同名文件时脚本默认不覆盖，需要 `.\setup.ps1 -Force`。

**配置被改坏了**

每次部署前都会生成 `settings.json.bak-<时间戳>`，直接复制回去即可。

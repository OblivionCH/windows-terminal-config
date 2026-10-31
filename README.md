# Windows Terminal 配置

我的 Windows Terminal 设置，一条命令复刻到任意一台 Windows 机器。

## 仓库内容

| 路径 | 说明 |
| --- | --- |
| `settings.json` | 主配置（主题、字体、快捷键、配色方案、profile 列表） |
| `assets/2.jpg` | 终端背景图 |
| `assets/fonts/` | Meslo Nerd Font（4 个 ttf，安装时无需联网） |
| `assets/scoop-config.json` | Scoop 配置（已脱敏，不含 token） |
| `setup.ps1` | 一键部署脚本 |
| `sync.ps1` | git 拉取 / 推送的便捷封装 |

## 在新机器上部署

PowerShell 里执行一行：

```powershell
$d="$env:USERPROFILE\dotfiles\windows-terminal"; if(Test-Path $d){git -C $d pull}else{git clone https://github.com/OblivionCH/windows-terminal-config.git $d}; powershell -NoProfile -ExecutionPolicy Bypass -File "$d\setup.ps1"
```

脚本依次完成：

1. **winget** —— 没有就自动下载安装（msixbundle + VCLibs 依赖，用 5.1 的 Appx 装）
2. **scoop** —— 没有就自动安装，并把仓库里的配置合并进去（只补缺失项，不动本机已有的 token / proxy）
3. **Windows Terminal** —— 没装就自动安装。优先 winget，回退官方 msixbundle
4. **定位配置目录** —— Store 版 `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState`，预览版走 `...TerminalPreview...`，非 Store 便携版走 `%LOCALAPPDATA%\Microsoft\Windows Terminal`
5. **备份并落地配置** —— 原文件存为 `settings.json.bak-<时间戳>`，本机配置换成指向仓库文件的符号链接（无权限时退回复制模式）
6. **背景图** —— 复制到 `%USERPROFILE%\Pictures\2.jpg`
7. **字体** —— 优先用仓库内置的 ttf，仓库缺失才联网下载兜底
8. **WSL profile** —— 对比宿主机实际安装的发行版，报告差异

最后重启 Windows Terminal 生效。

## 自动安装的边界

**winget**：`DesktopAppInstaller` 的 msixbundle 约 207 MB，依赖包 93 MB。查 GitHub API 拿最新版本，失败时用内置版本号 `v1.29.380`。Appx 操作全部转交 5.1 子进程。

**scoop**：跑官方 `get.scoop.sh` 安装脚本。装完刷新当前会话 PATH，再把 `assets/scoop-config.json` 合并进 `~/.config/scoop/config.json`。**只补本机没有的键**——`gh_token`、`proxy` 这类本机专属项绝不会被覆盖。

**Windows Terminal**：winget 可用就 `winget install Microsoft.WindowsTerminal`；不可用则拉 msixbundle + VCLibs 用 Appx 装。

**字体**：仓库里带 4 个 Meslo ttf，直接复制 + 写注册表 + `AddFontResource`，全程离线。仓库没有字体文件时才回退到从 `ryanoasis/nerd-fonts` 下载 `Meslo.zip`（63 MB），并只提取配置里 `font.face` 对应的族。

跳过某些步骤：`-SkipWinget`、`-SkipScoop`、`-SkipTerminal`、`-SkipFont`。

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
.\setup.ps1 -SyncProfiles -Force   # 按本机实际情况同步 WSL profile
```

## 跨机器差异是怎么处理的

| 差异点 | 处理方式 |
| --- | --- |
| 配置目录路径 | `setup.ps1` 运行时探测，不写进仓库 |
| 背景图路径 | `settings.json` 里写 `%USERPROFILE%\Pictures\2.jpg`，WT 会展开环境变量 |
| 字体 | 仓库内置 ttf，离线安装；缺失时联网兜底 |
| WSL 发行版 | 注册表检测，报告 / `-PruneProfiles` / `-SyncProfiles` |
| winget、scoop、Windows Terminal | 检测缺失则自动安装 |

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

# Windows Terminal 配置 + 软件环境（dotfiles）

一套**可复现的 Windows 开发环境**：把我的 Windows Terminal 设置、终端字体、背景图，以及几十个常用软件的清单，**一条命令**复刻到任意一台 Windows 机器上——配置、字体、bucket、软件全部一次性到位，不用一项项手动装。

> 设计哲学：**可复现 + 有意晋升**。
> - 配置通过**符号链接**直接指向仓库文件，本机在 WT 里改设置就等于改仓库，靠 `git diff` 就能看到。
> - 软件清单（`packages.json`）是「标准基线」，只有显式 `sync.ps1 -Push` / `setup.ps1 -ExportApps` 才会改动它，随手微调不会污染可复用的基线。

---

## 一、这个仓库是做什么的

| 目标 | 说明 |
| --- | --- |
| 复刻终端配置 | 主题、字体、快捷键、配色方案、profile 列表，落盘成本机配置（符号链接优先，无权限则复制） |
| 复刻软件环境 | 自动装好 scoop + winget 两套包管理器，再按清单装齐 41 个 scoop 包 + 25 个 winget 包 |
| 自动补齐依赖 | 缺 winget / git / scoop / Windows Terminal 任何一个，脚本自己装好 |
| 网络自适应 | 有代理用代理，没有就自动走 gh-proxy 镜像；中文 Windows 下强制 UTF-8，不受系统代码页影响 |
| 可维护 | `update.ps1` 统一看/升两边更新；`sync.ps1` 包一层 git 操作；`-ExportApps` 把本机实况导回清单 |

**适用人群**：经常在新机器上搭环境的人；想把自己的「标准工具箱」版本化管理的人。

---

## 二、在什么环境下工作

| 项 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 / 11（x64） |
| PowerShell | 系统自带的 **5.1** 即可跑完整流程；也兼容 **PowerShell 7**。Appx 相关操作在 PS7 下会自动转交 5.1 子进程 |
| 管理员权限 | **可选**。建符号链接需要 `SeCreateSymbolicLinkPrivilege`——开启开发者模式并重新登录，或用管理员。都没有时脚本自动退回复制模式（本机改动不会自动进仓库）。`setup.ps1 -Elevate` 可一键提权 |
| 网络 | 三种都支持：① 有可用代理；② 无代理但能直连镜像；③ 完全离线（字体已随仓库内置，软件安装仍需联网）。代理**绝不写进任何配置**，只在本次运行内用环境变量带 |
| 区域设置 | 中文 / 日文 / 英文均可。脚本 `.ps1` 均带 UTF-8 BOM，且运行时强制 `Get-Content`/`Set-Content`/`Out-File` 走 UTF-8，子进程输出也切 UTF-8，中文 Windows 不会乱码 |

> 全新系统也能跑：引导命令不依赖预装 git——没有 git 就先用系统自带 `curl.exe` 拉 `archive zip`，展开后再跑 `setup.ps1`（内部会装好 git）。

---

## 三、怎么部署

### 方式 A：全新机器（无需预装 git）

PowerShell 里执行一行（首次部署推荐）：

```powershell
$d="$env:USERPROFILE\dotfiles\windows-terminal";$u="https://github.com/OblivionCH/windows-terminal-config/archive/refs/heads/main.zip";if(Test-Path "$d\setup.ps1"){if(Get-Command git -ErrorAction SilentlyContinue){git -C $d pull}}else{$z="$env:TEMP\wtcfg.zip";$t="$env:TEMP\wtcfg";foreach($s in @("https://gh-proxy.com/$u",$u)){& "$env:SystemRoot\System32\curl.exe" -k -L -s --fail -o $z $s;if((Test-Path $z) -and (Get-Item $z).Length -gt 0){break}};Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue;Expand-Archive $z $t -Force;New-Item -ItemType Directory $d -Force|Out-Null;Copy-Item "$t\windows-terminal-config-main\*" $d -Recurse -Force};powershell -NoProfile -ExecutionPolicy Bypass -File "$d\setup.ps1"
```

### 方式 B：已装 git（可增量更新）

```powershell
$d="$env:USERPROFILE\dotfiles\windows-terminal"; if(Test-Path $d){git -C $d pull}else{git clone https://github.com/OblivionCH/windows-terminal-config.git $d}; powershell -NoProfile -ExecutionPolicy Bypass -File "$d\setup.ps1"
```

### 先看会装什么、不动系统

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\dotfiles\windows-terminal\setup.ps1" -DryRun
```

### 部署流程（脚本自动完成 12 步）

1. **winget** —— 没有就自动装（msixbundle + VCLibs 依赖，用 5.1 的 Appx 装）
2. **git** —— 没有就先装（scoop 的 bucket 本质是 git 仓库，没 git 连 bucket 都加不了）
3. **scoop** —— 没有就自动装，并把仓库里的 scoop 配置合并进去（**只补缺失项**，不动本机已有的 `gh_token` / `proxy`）
4. **scoop bucket** —— 按清单配齐 7 个；已存在的会核对地址（仓库搬家后自动改 remote）
5. **scoop 软件** —— 装清单里的包，已装的自动跳过
6. **winget 软件** —— 装 scoop 里没有的包
7. **Windows Terminal** —— 没装就自动装（winget 优先，回退官方 msixbundle）
8. **定位配置目录** —— Store 版 / 预览版 / 非 Store 便携版三种形态自动探测
9. **备份并落地配置** —— 原文件存为 `settings.json.bak-<时间戳>`，本机配置换成指向仓库的符号链接（无权限退回复制）
10. **背景图** —— 复制到 `%USERPROFILE%\Pictures\2.jpg`
11. **字体** —— 优先仓库内置 ttf，缺失才联网下载兜底
12. **WSL profile** —— 对比宿主机实际发行版，报告差异

最后**重启 Windows Terminal** 生效。

### 常用开关

```powershell
.\setup.ps1 -DryRun            # 只看会装什么，不动系统
.\setup.ps1 -AppsOnly          # 只装软件，不碰 WT 配置
.\setup.ps1 -SkipApps          # 不装软件，只部署配置
.\setup.ps1 -SkipWinget        # 跳过 winget（只留 scoop 一套）
.\setup.ps1 -SkipScoop         # 跳过 scoop
.\setup.ps1 -SkipTerminal      # 不自动装 Windows Terminal
.\setup.ps1 -SkipFont          # 不装 Nerd Font
.\setup.ps1 -SkipBackground    # 不复制背景图
.\setup.ps1 -Proxy 127.0.0.1:7897   # 手动指定代理
.\setup.ps1 -Elevate           # 提权重跑（符号链接 / 多数 winget 包需要）
```

#### 按需裁剪软件（仅当次生效，不改仓库）

一键安装时如果某些软件你不想装，可以临时跳过，不影响「标准基线」本身：

```powershell
.\setup.ps1 -Skip wechat,obsidian              # 跳过指定包（按 id，逗号分隔）
.\setup.ps1 -SkipOptional                        # 跳过所有标记为 optional 的包
.\setup.ps1 -Group dev,media                     # 只装指定分组（未分组的核心包始终保留）
```

- 包条目在 `packages.json` 里兼容两种写法：纯字符串 `"git"`，或带标注的对象 `{"id":"git","optional":true,"group":"dev"}`
- `optional` 只影响 `-SkipOptional`，**默认安装仍装全部**
- `-Group` 会保留未分组的「核心包」，所以 `-Group dev` = 核心 + dev，不会把基础环境剔掉
- `-ExportApps` 导出时会保留你已有的 `optional`/`group` 标注，不覆盖人工分类

---

## 四、部署了哪些内容

仓库结构：

| 路径 | 说明 |
| --- | --- |
| `settings.json` | 主配置（主题、字体、快捷键、配色方案、profile 列表），落地为符号链接 |
| `assets/packages.json` | 软件清单：7 个 bucket + 41 个 scoop 包 + 25 个 winget 包（含 `optional`/`group` 标注） |
| `assets/2.jpg` | 终端背景图 |
| `assets/fonts/` | Meslo Nerd Font（4 个 ttf，安装时无需联网） |
| `assets/scoop-config.json` | Scoop 配置（已脱敏，不含 token） |
| `setup.ps1` | 一键部署脚本 |
| `update.ps1` | 一键更新脚本（scoop + winget 统一入口） |
| `sync.ps1` | git 拉取 / 推送的便捷封装（带复核闸门） |
| `lib/common.ps1` | 三脚本共用的输出函数 |
| `lib/net.ps1` | 三脚本共用的网络处理（代理探测、镜像改写、GitHub API、下载、git 镜像重试） |

### 软件清单 `assets/packages.json`

```json
{
  "buckets": [ { "name": "extras", "source": "https://github.com/ScoopInstaller/Extras" } ],
  "scoop":  [ "7zip", { "id": "Inkscape", "optional": true, "group": "media" }, "..." ],
  "winget": [ "Google.Chrome", { "id": "Tencent.TencentDocs", "optional": true, "group": "office" }, "..." ]
}
```

三段各管一件事：

- **`buckets`** —— 先配仓库，再装软件。缺哪个就 `scoop bucket add`，已有的跳过
- **`scoop`** —— scoop 能覆盖的全部走这里，装到 `%SCOOP%`，不需要管理员
- **`winget`** —— scoop 里没有的走 winget，覆盖浏览器、微信/飞书/豆包、PDF24、Quicker 等

### 配了哪 7 个 bucket

| bucket | 用途 |
| --- | --- |
| `main` | 命令行工具主力库 |
| `extras` | GUI 应用（Inkscape、Sublime、Obsidian、PowerToys…） |
| `versions` | 同一软件的多版本（`python@3.9` 这种写法） |
| `nirsoft` | NirSoft 那套小工具 |
| `sysinternals` | 微软 Sysinternals 全套 |
| `dorado` | 中文软件：QQ NT、网易云、钉钉、飞书、企业微信、阿里云盘、B 站 |
| `java` | 多版本 JDK：Temurin、Zulu、Corretto、GraalVM |

**为什么不放 `kkzzhizhou/scoop-apps`**：那个聚合库有 14903 个 manifest、33.7 MB，是其他所有 bucket 加起来的三倍多，但实际只贡献了 4 个包，且和 `dorado` 已出现同名冲突。删掉后 `scoop update` 明显变快。要装回：`scoop bucket add apps https://github.com/kkzzhizhou/scoop-apps`。

**为什么不放 `nerd-fonts`**：367 个 manifest 全是字体变体，配置只用 `MesloLGLDZ Nerd Font Mono` 一个族，而 4 个 ttf 已随仓库内置。之前清单里那三个 `CascadiaCode-NF*` 共 206 MB，配置一次没引用，已移除。

**判断「装没装」**：scoop 侧看 `%SCOOP%\apps\<名字>\current` 链接在不在（装失败只留版本目录、没有 `current`）；winget 侧用 `--no-upgrade` 让 winget 自己判断，已装返回 `97` 或 `0x8A150061` 直接跳过。`--no-upgrade` 很关键——不加的话 winget 会把「已安装」当「可升级」，遇到运行中的程序报 `0x80070020` 文件占用失败。

---

## 五、维护清单（把仓库跟上本机）

装/卸了软件之后：

```powershell
.\setup.ps1 -ExportApps     # 扫本机实况重写 packages.json
git diff assets/packages.json
.\sync.ps1 -Push            # 复核并提交（见下方 sync 复核闸门）
```

三个已知取舍：

- **winget export 有盲区**：它只认自己装过的包，用安装程序手动装的（Chrome、Firefox、夸克、迅雷）识别不出。导出时会把**旧清单条目并回去**，输出里列出「识别不出但保留」的项——正常，不用慌
- **卸载不会自动从清单消失**：因为是并集，手工删条目即可
- **bucket 已不在清单的应用会被跳过**：若当初装的 bucket 已移除、别的 bucket 也没有同名包，导出时不写进 `scoop` 段（写了在别的机器也装不回），而是单独提醒你

---

## 六、更新软件

`update.ps1` 是更新软件的唯一入口，默认只报告不改动：

```powershell
.\update.ps1          # 看 scoop / winget 各有哪些更新，不动系统
.\update.ps1 -Apply   # 真的升级（winget 部分可能需要管理员）
```

- **scoop 侧** —— 先 `scoop update` 刷新自身和 7 个 bucket，再列可升级项
- **winget 侧** —— 列可升级项
- **汇总** —— 两边各几个可更新；`-Apply` 升完会再扫一遍，把「程序正在运行 / 需要管理员」没升上去的单独列出

自动摘掉两类「看着像可更新、其实升不了」的条目：

| 类别 | 特征 | 处理 |
| --- | --- | --- |
| 装失败的残留 | 有版本目录但没有 `current` 链接 | 提示 `scoop uninstall <名>` 后重装 |
| 孤儿 | `install.json` 里记的 bucket 已移除，且没有任何现存 bucket 有同名包 | 提示换 winget 或卸载 |

---

## 七、日常同步（sync.ps1）

```powershell
.\sync.ps1                 # 看当前状态
.\sync.ps1 -Pull           # 拉取更新并校验链接
.\sync.ps1 -Push           # 提交并推送本机改动（带复核闸门）
.\sync.ps1 -Verify         # 只检查链接是否还有效
```

**`-Push` 复核闸门**：推送前会展示 `git diff`，并扫描三类「可能仅属于本机」的改动——
本机用户绝对路径（`C:\Users\...`）、窗口尺寸微调（`initialCols`/`initialRows`）、本机设备名（`DESKTOP-`/`LAPTOP-`）——
默认需 `y/N` 确认；`-Force` 跳过确认但仍展示 diff 与泄露结果（供自动化用）。这样随手微调不会污染可复用的基线。

`git push` 直连失败后会自动用 git 进程级 `insteadOf` 改走镜像重试一次，不写全局配置（只读镜像不会把 push 改写坏）。

---

## 八、跨机器差异是怎么处理的

| 差异点 | 处理方式 |
| --- | --- |
| 配置目录路径 | 运行时探测，不写进仓库 |
| 背景图路径 | `settings.json` 里写 `%USERPROFILE%\Pictures\2.jpg`，WT 展开环境变量 |
| 字体 | 仓库内置 ttf，离线安装；缺失时联网兜底 |
| WSL 发行版 | 注册表检测，报告 / `-PruneProfiles` / `-SyncProfiles` |
| 软件 | `packages.json` 声明，scoop 优先、winget 兜底 |
| scoop 安装位置 | 跟随目标机自己的 `%SCOOP%`（本机 `D:\scoop`，新机默认 `~\scoop`） |
| 网络 / 代理 | 运行时实测，有代理用代理、没有走镜像；代理不写进任何配置 |
| winget、git、scoop、Windows Terminal | 检测缺失则自动安装 |

### WSL profile 同步

脚本读注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss` 拿本机真实发行版，做双向比对：

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
- `-SyncProfiles` —— 双向同步（删无效 + 补缺失）
- 加 `-Force` 确认（符号链接模式下会直接改仓库文件）

新加的 profile 用 UUIDv5 从发行版名生成 GUID（命名空间 `2bde4a90-d05f-401c-9492-e40884ead1d8`，name 按 UTF-16LE 取字节），与 WT 动态生成一致。注意 `Microsoft.WSL` 源的发行版走另一套规则，补出来可能同名不同 ID——新机器首次部署通常不受影响。

---

## 九、网络：有代理就用，没有就走镜像

代理只在自己机器上有、且不常开，所以**绝不写进配置**，只在本次运行内用环境变量带（git / curl / scoop 都认），进程结束即失效。

启动判断规则：

1. 候选代理来源：`-Proxy` 参数 → `HTTPS_PROXY` 等环境变量 → 系统代理注册表
2. 逐个实测：先 TCP 连端口，**再真的发一次请求到 github.com**
3. 通得过 → 本次全走它；通不过 → 自动切 gh-proxy 镜像

第二步不能省：代理软件关了但注册表留着旧地址、或端口开着却连不上 GitHub（只代理内网 / 需认证 / 工具注入的代理），只测端口会误判成可用，导致所有下载卡死。

镜像模式下：

- bucket 的 `git clone` 走 `https://gh-proxy.com/https://github.com/...`
- 脚本自身下载走镜像，失败回退直连
- `api.github.com` / `raw.githubusercontent.com` 也一并改写（实测都返回 200），否则无代理时只镜像 `github.com` 会让 winget/git/WT 查版本静默退回内置版本号
- 装 scoop 时先试 `get.scoop.sh`，失败从镜像拉 `ScoopInstaller/Install` 的 `install.ps1`
- 导出的 `packages.json` 会剥掉镜像前缀，不固化进仓库

直连 GitHub 常「龟速但不报错」，超时兜不住，会让人以为脚本卡死——所以镜像不是可选项，是默认项。下载统一用系统 `curl.exe`（5.1 的 `Invoke-WebRequest` 处理大文件 + 分块响应会挂死），代理证书问题加 `-k`，只影响本次下载。

---

## 十、故障排查

**创建符号链接失败，提示需要管理员，但开发者模式明明开着**
开发者模式只是「允许」，真正决定能否建链接的是登录令牌里的 `SeCreateSymbolicLinkPrivilege`。开启后**必须重新登录（或重启）**权限才进令牌。解决：`.\setup.ps1 -Elevate`，或管理员窗口跑，或重启后重跑。

**脚本说「代理连不上」，但我明明开着代理**
判断标准是「能不能真访问 github.com」，不是「端口开着没」。三种情况：代理关了注册表留旧地址（自动切镜像）、代理开但系统开关关（TUN 模式，仍会实测）、代理只代理内网或需认证（自动切镜像）。强制指定：`.\setup.ps1 -Proxy 127.0.0.1:7897`。确认通不通：

```powershell
curl.exe -k -s -o NUL -w "%{http_code}`n" -x http://127.0.0.1:7897 --max-time 10 https://github.com
```

返回 200/301 即通，`000` 即不通。

**git push 报 `CONNECT tunnel failed, response 502`**
环境有多个代理时，git 可能连到不支持 CONNECT 隧道的那个（比如工具注入的代理）。显式指定可用代理：

```powershell
git -c http.proxy=http://127.0.0.1:7897 -c https.proxy=http://127.0.0.1:7897 push
```

**git 报 `CRYPT_E_NO_REVOCATION_CHECK` 或证书错误**
代理/公司网络下 OCSP 被阻断。临时关掉：`git config --global http.schannelCheckRevoke false`。

**`Get-AppxPackage` 报 `Operation is not supported on this platform`**
在 PS7 里执行了 Appx 命令。手动操作用 `powershell.exe` 而非 `pwsh.exe`；本脚本已自动处理。

**`-Verify` 报「是普通文件而非链接」**
部分 WT 版本保存设置时会用临时文件替换原文件，把符号链接变成实体文件。重跑 `.\setup.ps1` 恢复。

**背景图不显示**
确认 `%USERPROFILE%\Pictures\2.jpg` 存在；目标机已有同名文件时默认不覆盖，需 `.\setup.ps1 -Force`。

**`scoop reset` / `uninstall` 说「是全局应用，需要管理员」**
`SCOOP_GLOBAL` 被设成和 `SCOOP` 同一路径，scoop 靠路径比对误判。删掉机器级变量，或给用户设不冲突的值：

```powershell
[Environment]::SetEnvironmentVariable('SCOOP_GLOBAL','C:\ProgramData\scoop','User')
```

**`scoop update` 报 `Uncommitted changes detected`**
scoop 自身是 git 仓库，本地被改过就拒绝更新。看改动、确认无保留后 `git -C "$env:SCOOP\apps\scoop\current" checkout -- .`。

**`scoop update` 报 `fatal: unable to access 'https://mirror.ghproxy.com/...'`**
scoop 的 `scoop_repo` 指向停服镜像。改回官方：`scoop config scoop_repo https://github.com/ScoopInstaller/Scoop`。

**scoop 在代理关掉后所有操作失败**
`scoop config proxy` 写死了代理地址。删掉让 scoop 跟系统走：`scoop config rm proxy`。

**配置被改坏了**
每次部署前生成 `settings.json.bak-<时间戳>`，复制回去即可。

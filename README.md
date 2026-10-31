# Windows Terminal 配置

我的 Windows Terminal 设置，一条命令复刻到任意一台 Windows 机器。

## 仓库内容

| 文件 | 说明 |
| --- | --- |
| `settings.json` | 主配置（主题、字体、快捷键、配色方案、profile 列表） |
| `assets/2.jpg` | 终端背景图 |
| `setup.ps1` | 一键部署脚本 |
| `sync.ps1` | git 拉取 / 推送的便捷封装 |

## 在新机器上部署

PowerShell 里执行一行：

```powershell
$d="$env:USERPROFILE\dotfiles\windows-terminal"; if(Test-Path $d){git -C $d pull}else{git clone https://github.com/OblivionCH/windows-terminal-config.git $d}; powershell -NoProfile -ExecutionPolicy Bypass -File "$d\setup.ps1"
```

脚本会依次完成：

1. **检查 Windows Terminal** —— 没装就自动安装。优先用 winget，没有 winget 时回退到下载官方 msixbundle 并用 Appx 安装
2. **定位配置目录** —— Store 版 `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState`，预览版走 `...TerminalPreview...`，非 Store 便携版走 `%LOCALAPPDATA%\Microsoft\Windows Terminal`
3. **备份并落地配置** —— 原文件存为 `settings.json.bak-<时间戳>`，然后把本机配置换成指向仓库文件的符号链接（无权限时自动退回复制模式）
4. **放置背景图** —— 复制到 `%USERPROFILE%\Pictures\2.jpg`
5. **检查 Nerd Font** —— 缺 Meslo 就自动下载并安装到用户字体目录（免管理员，装完即时生效）
6. **检查 WSL profile** —— 报告本机打不开的标签页

最后重启 Windows Terminal 生效。

### 关于自动安装

**Windows Terminal**：winget 可用时直接 `winget install Microsoft.WindowsTerminal`；不可用时从 GitHub 拉最新 msixbundle，连同 VCLibs 依赖一起用 Appx 装。两个都失败会明确报错并退出，不会留下半成品。

**字体**：从 `ryanoasis/nerd-fonts` 下载 `Meslo.zip`，解压后**只安装配置里实际用到的字体族**（读 `settings.json` 的 `font.face` 匹配，避免把 Meslo 全套二十多个文件都塞进系统），复制到 `%LOCALAPPDATA%\Microsoft\Windows\Fonts`，写 `HKCU` 字体注册表项，再调 `AddFontResource` + `WM_FONTCHANGE` 通知系统。不需要管理员，也不需要重启。

不想自动做的话：`-SkipTerminal` 跳过装终端，`-SkipFont` 跳过装字体。

### 国内网络

脚本里所有 GitHub 下载都优先走 `gh-proxy.com` 镜像，失败才回退直连。原因很实际：直连 GitHub 经常是"龟速但不报错"，超时参数兜不住，会让人以为脚本卡死。

下载统一交给系统自带的 `curl.exe` 而不是 `Invoke-WebRequest`——后者在 PowerShell 5.1 下处理大文件加镜像分块响应时会挂死。curl 因代理环境的证书链问题加了 `-k`，只影响本次下载，不改动系统信任设置。

如果镜像失效，可以改 `setup.ps1` 里 `Get-RemoteFile` 的 `gh-proxy.com` 为其他加速站。

### 关于 WSL profile

配置里记着的 WSL 标签页，在没装对应发行版的机器上是打不开的。脚本会读注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss` 拿到本机实际安装的发行版，逐个比对后告诉你哪些是无效的：

```
==> 检查 WSL profile
    OK  已安装的 WSL 发行版：Ubuntu-22.04, MyBooksService
    !!  以下 2 个 profile 在本机找不到对应发行版，标签页会存在但打不开：
        - Ubuntu 18.04.6 LTS  (source: CanonicalGroupLimited.Ubuntu18.04LTS_79rhkp1fndgsc)
        - Ubuntu  (source: CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc)
```

加 `-PruneProfiles` 可以直接把它们从配置里删掉。注意符号链接模式下这会改到仓库文件，脚本会要求加 `-Force` 确认。

匹配用的是「发行版名归一化 + 版本号比对」，`Ubuntu 18.04.6 LTS` 和 `Ubuntu-18.04` 能对上，`Ubuntu` 和 `Ubuntu-22.04` 不会被误判成同一个。

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
```

## 跨机器差异是怎么处理的

配置里不能写死本机路径，否则换台机器就废了。这里的处理方式：

| 差异点 | 处理方式 |
| --- | --- |
| 配置目录路径 | `setup.ps1` 运行时探测，不写进仓库 |
| 背景图路径 | `settings.json` 里写 `%USERPROFILE%\Pictures\2.jpg`，Windows Terminal 会展开环境变量 |
| 字体 | 脚本检测并自动安装 |
| WSL 发行版 | 脚本检测，报告或 `-PruneProfiles` 清理 |
| Windows Terminal 是否安装 | 脚本检测并自动安装 |

## 故障排查

**提示「创建符号链接失败：此操作需要管理员权限」，但开发者模式明明是开的**

开发者模式的注册表开关（`AllowDevelopmentWithoutDevLicense = 1`）只是「允许」，真正决定能否建链接的是登录令牌里的 `SeCreateSymbolicLinkPrivilege`。开启开发者模式后**必须重新登录（或重启）**，这个权限才会进入令牌。

实测当前是否具备权限：

```powershell
$p="$env:TEMP\lt"; New-Item -ItemType Directory $p -Force|Out-Null; Set-Content "$p\t.txt" x; try{New-Item -ItemType SymbolicLink -Path "$p\l.txt" -Target "$p\t.txt" -ErrorAction Stop|Out-Null; "可以创建"}catch{"无权限"}; Remove-Item $p -Recurse -Force
```

解决：`.\setup.ps1 -Elevate` 自动提权，或管理员窗口里直接跑，或重启后重跑。

**在 WT 设置界面保存过配置后，`-Verify` 报「是普通文件而非链接」**

部分 Windows Terminal 版本保存设置时会用临时文件替换原文件，把符号链接替换成实体文件。重跑一次 `.\setup.ps1` 即可恢复（脚本会保留当前内容）。

**git 报 `CRYPT_E_NO_REVOCATION_CHECK` 或证书错误**

代理或公司网络环境下常见，证书吊销检查（OCSP）被阻断。临时关掉：

```powershell
git config --global http.schannelCheckRevoke false
```

**`Get-AppxPackage` 报 `Operation is not supported on this platform`**

说明在 PowerShell 7 里执行 Appx 命令，Appx 模块只支持 Windows PowerShell 5.1。本脚本已处理：检测到 PS7 时自动把 Appx 操作转交 5.1 子进程。手动操作时用 `powershell.exe` 而不是 `pwsh.exe`。

**背景图不显示**

确认 `%USERPROFILE%\Pictures\2.jpg` 存在；目标机已有同名文件时脚本默认不覆盖，需要 `.\setup.ps1 -Force`。

**配置被改坏了**

每次部署前都会生成 `settings.json.bak-<时间戳>`，直接复制回去即可。

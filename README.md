# Windows Terminal 配置

我的 Windows Terminal 设置，用一份仓库在多台机器之间复刻。

## 仓库内容

| 文件 | 说明 |
| --- | --- |
| `settings.json` | Windows Terminal 主配置（主题、字体、快捷键、配色方案、profile 列表） |
| `assets/2.jpg` | 终端背景图 |
| `setup.ps1` | 一键部署脚本，自动适配目标机器的安装形态 |
| `sync.ps1` | git 拉取 / 推送的便捷封装 |

## 在新机器上部署

PowerShell 里执行一行：

```powershell
$d="$env:USERPROFILE\dotfiles\windows-terminal"; if(Test-Path $d){git -C $d pull}else{git clone https://github.com/OblivionCH/windows-terminal-config.git $d}; powershell -NoProfile -ExecutionPolicy Bypass -File "$d\setup.ps1"
```

脚本会依次完成：

1. 探测配置目录 —— Store 版走 `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState`，预览版走 `...TerminalPreview...`，非 Store / 便携版走 `%LOCALAPPDATA%\Microsoft\Windows Terminal`
2. 备份原有 `settings.json` 为 `settings.json.bak-<时间戳>`
3. 把本机 `settings.json` 替换为指向仓库文件的**符号链接**（没有权限时自动退回复制模式）
4. 把 `assets/2.jpg` 复制到 `%USERPROFILE%\Pictures\2.jpg`
5. 检查 Meslo Nerd Font 是否安装，缺失时给出提示

最后重启 Windows Terminal 生效。

### 为什么用符号链接

链接建好之后，仓库文件就是本机配置本身：

- 在 Windows Terminal 设置界面里改动 → 仓库里 `git diff` 立刻能看到
- `git pull` 之后重启终端 → 新配置生效

不需要任何"导出 / 导入"的中间步骤。

符号链接需要**开发者模式**（设置 → 系统 → 开发者选项）或管理员权限。都没有的话脚本会自动改用复制模式，此时本机改动不会自动进仓库，需要手动 `Copy-Item` 覆盖后再 `.\sync.ps1 -Push`。

## 日常使用

```powershell
.\sync.ps1                 # 看当前状态
.\sync.ps1 -Pull           # 拉取更新并校验链接
.\sync.ps1 -Push           # 提交并推送本机改动
.\setup.ps1 -Verify        # 只检查链接是否还有效
```

## 跨机器差异是怎么处理的

配置里不能直接写死本机路径，否则换台机器就废了。这里的处理方式：

| 差异点 | 处理方式 |
| --- | --- |
| 配置目录路径 | `setup.ps1` 运行时探测，不写进仓库 |
| 背景图路径 | `settings.json` 里写 `%USERPROFILE%\Pictures\2.jpg`，Windows Terminal 会展开环境变量，换用户名也能解析 |
| 字体 | 脚本检测注册表，缺失时提示安装，不阻断部署 |
| WSL 发行版 profile | 保留在配置里。目标机器没装对应发行版时，那个标签页打不开，但不影响其他功能 |

## 故障排查

**在 WT 设置界面保存过配置后，`-Verify` 报 "是普通文件而非链接"**

部分 Windows Terminal 版本保存设置时会用临时文件替换原文件，从而把符号链接替换成实体文件。重新跑一次 `.\setup.ps1` 即可恢复链接（脚本会保留当前内容，不会丢改动）。

**背景图不显示**

确认 `%USERPROFILE%\Pictures\2.jpg` 存在；如果目标机已有同名文件，脚本默认不覆盖，需要 `.\setup.ps1 -Force`。

**字体显示异常 / 出现方块乱码**

没装 Nerd Font。执行 `winget search "nerd font"` 或从 <https://www.nerdfonts.com/font-downloads> 下载 Meslo 安装。

**配置被改坏了**

脚本每次部署前都会生成 `settings.json.bak-<时间戳>`，直接复制回去即可。

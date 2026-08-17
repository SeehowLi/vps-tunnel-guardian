# VPS Tunnel Guardian — 项目交接 README

## 1. 项目目的

这是一个 Windows 桌面端 OpenSSH 本地端口转发守护工具。它替代手动在 PowerShell 中长期运行 `ssh -L ... -N` 的方式：用户在图形界面配置连接，点击启动后，程序负责保活、检测 SSH 会话退出并按配置自动重连。

程序采用深色、高 DPI 界面；关闭主窗口时不会停止隧道，而是隐藏到系统托盘。仅在托盘菜单中选择“退出应用”时才会停止隧道并结束程序。

## 2. 当前交付状态

- 图形界面支持启动、停止、连接状态、运行日志和连接参数配置。
- 可配置 SSH 用户名/服务器、本地监听端口、目标主机/端口和重连间隔。
- SSH 参数固定包含 `BatchMode=yes`、15 秒连接超时、`ExitOnForwardFailure=yes`、30 秒保活和 3 次保活失败退出。
- 主窗口关闭后转入系统托盘；双击托盘图标或选择“显示窗口”可恢复。
- 使用原生 WinForms、Windows OpenSSH 和 .NET Framework；不依赖第三方运行时或后台服务。
- 提供源码启动、静态检查和 EXE 构建入口。

## 3. 仓库目录与职责

| 文件 | 职责 |
| --- | --- |
| `VPS-Tunnel-Guardian.ps1` | 主 WinForms 应用、SSH 生命周期、配置校验、托盘行为和深色 UI。 |
| `Launcher.cs` | EXE 启动器：释放嵌入资源到 `%LOCALAPPDATA%\VpsTunnelGuardian`，再启动 GUI。 |
| `Build-Release.ps1` | 使用系统 C# 编译器生成 `release\VPS-Tunnel-Guardian.exe`。 |
| `Test-VPS-Tunnel-Guardian.ps1` | 无网络、无隧道的语法和关键安全参数静态检查。 |
| `settings.json` | 可公开的示例配置；不是任何真实环境配置。 |
| `Start-VPS-Tunnel-Guardian.cmd` | 从源码直接启动 GUI 的便捷入口。 |
| `tunnel-logo.ico` | EXE、窗口和托盘使用的 Windows 图标。 |
| `THIRD_PARTY_NOTICES.txt` | 图标来源与许可说明。 |

`release/` 是本地生成目录，已被 Git 忽略；不应提交二进制构建产物。

## 4. 运行方式

### 从源码运行

双击 `Start-VPS-Tunnel-Guardian.cmd`，或在仓库根目录运行：

```powershell
powershell.exe -NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -File .\VPS-Tunnel-Guardian.ps1
```

在应用内选择“配置”，填写你自己的 SSH 服务器与端口转发目标，保存后点击“启动隧道”。

### 构建 EXE

需要 Windows PowerShell 5.1、Windows OpenSSH Client 和 .NET Framework C# 编译器：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Build-Release.ps1
```

输出文件为：

```text
release\VPS-Tunnel-Guardian.exe
```

EXE 首次运行会将脚本、图标和示例配置释放到：

```text
%LOCALAPPDATA%\VpsTunnelGuardian
```

真实运行配置也保存在该目录，因此更新 EXE 不会覆盖用户已保存的配置。

## 5. 配置和安全边界

- `settings.json` 只使用 `ssh.example.com` 与 `target.example.com` 等示例值。
- 不要将真实服务器地址、内部目标地址、私钥、密码、SSH 配置或 `%LOCALAPPDATA%\VpsTunnelGuardian\settings.json` 提交到仓库。
- 程序不保存密码，不处理私钥；认证完全交给本机 Windows OpenSSH 客户端及其已有的密钥/代理配置。
- `BatchMode=yes` 使认证失败立即返回，避免 GUI 在后台等待密码输入。
- `ExitOnForwardFailure=yes` 可在本地端口不能绑定时退出并按重试策略处理。

## 6. 验证与维护

提交前至少运行：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Test-VPS-Tunnel-Guardian.ps1
```

预期输出以 `PASS:` 开头。该检查不会连接 SSH 服务器，也不会启动隧道。

修改主程序后，依次执行静态检查、`Build-Release.ps1`，再在未启动隧道的情况下打开 EXE，确认：

1. GUI 可正常打开并显示深色标题栏、窗口图标和托盘图标。
2. 点击标题栏 `×` 后窗口隐藏而进程保持运行。
3. 托盘菜单可恢复窗口和完全退出应用。
4. 配置弹窗拒绝非法端口与包含空格/注入字符的主机名。

## 7. 已知限制

- 工具监控的是 SSH 隧道进程。远端目标服务在没有客户端访问时不可用，不一定会立即导致 SSH 进程退出。
- 目前仅针对 Windows 和系统自带 `ssh.exe` 设计；未提供 macOS/Linux 版本。
- Windows Shell 使用 `.ico` 作为应用图标格式；窗口中的路由标记则由抗锯齿矢量图元实时绘制，文字使用原生 TrueType/OpenType 字体并启用 DPI 自适应。
- 若 Windows 显示 SmartScreen 提示，通常是因为本地构建的 EXE 未使用代码签名证书；如需面向广泛用户分发，应在发布流程中加入代码签名。

## 8. 第三方许可

路由图标基于 MIT 许可的 Tabler Icons。详情见 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)。

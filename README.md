# VPS Tunnel Guardian 2.1

Windows 桌面 SSH 隧道守护工具：多配置、批量启停、自动重连、暗色界面、关闭到托盘。

[下载 Windows EXE](https://github.com/SeehowLi/vps-tunnel-guardian/releases/latest)

## 支持的连接方式

- **本地转发（`-L`）**：本机端口 → SSH 服务器 → 指定目标主机/端口。适合通过 SSH 转发上游 SOCKS 服务，保留该上游作为最终出口。上游代理凭据需在使用它的代理客户端中配置。
- **SOCKS5（`-D`）**：本机 SOCKS5 端口 → SSH 服务器出网。浏览器代理地址为 `127.0.0.1`，端口为条目设置值。本机 SOCKS5 不要求用户名/密码；应用中的 SSH 密码用于登录 SSH 服务器。

两种模式分别配置，程序不会擅自把 `-L` 改成 `-D`，也不会修改 Clash、系统代理、DNS 或系统路由。SSH 隧道仅承载 TCP，不提供 UDP 转发。

## 2.1 更新

- 每条隧道独立启停和重连；主窗口/托盘支持全部启动、全部停止，重复启动会跳过已经运行的条目。
- 启动后核对本地监听端口归属，确认由该 SSH 进程监听才显示就绪。
- 端口被占用时继续等待释放，不会终止其他进程。
- 从配置的重试间隔开始指数退避，默认最高约 60 秒，加不足一秒的随机错峰；稳定 120 秒后重置。原设定超过 60 秒时尊重原值。
- 认证失败、服务器主机密钥变化时暂停对应条目，修复后手动启动。
- SSH 参数使用 `Compression=no`、`IPQoS=none`、`TCPKeepAlive=yes`、15 秒连接超时、15 秒保活/6 次失败退出，保留 `ExitOnForwardFailure=yes`。
- C# 异步读取 SSH 错误，队列有上限；日志自动轮换。原生 TCP 表查询代替频繁 WMI 查询，窗口隐藏时跳过列表重绘。
- 深色表头、状态汇总、重试次数、错误悬停提示、双击编辑、复制代理地址、新建时选择空闲端口。
- 修复配置弹窗 Point 构造异常及 askpass 参数处理；原子保存配置，异常配置保留原文件。
- 新启动器检查已有实例，避免重复启动和覆盖正在使用的运行文件。

这些措施有助于故障恢复和减少额外开销，但不能保证网络永不中断，也不能让已经断开的 TCP 会话无损续传。显示“就绪”不代表所有目标网站均可访问。

## 运行

从 Releases 下载 EXE 后双击，创建配置并启动。运行环境为 Windows、Windows PowerShell 5.1、Windows OpenSSH Client 和 .NET Framework 4.8。EXE 未进行代码签名。

运行数据保存在 `%LOCALAPPDATA%\VpsTunnelGuardianMulti`。首次运行可只读导入 V1 目录 `%LOCALAPPDATA%\VpsTunnelGuardian` 中的旧配置，但不会自动启动或接管其连接。

更新时需要先在旧版托盘选择“退出应用”，再打开新版并启动所需条目；切换期间会短暂断网。原配置与加密凭据保留。点击窗口 × 仅隐藏到托盘，真正退出才停止该实例管理的隧道。

## 构建与测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Release.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VPS-Tunnel-Guardian.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Test-Stability.ps1
```

构建生成 `release\VPS-Tunnel-Guardian-v2.1.exe`，并同步更新常用文件名 `release\VPS-Tunnel-Guardian-v2.exe`。二进制通过 GitHub Releases 分发，不提交到 Git 历史。

也可以双击 `Start-VPS-Tunnel-Guardian.cmd`：缺少 EXE 时先构建，再启动。直接运行主 PowerShell 脚本前必须构建辅助 DLL；不要用 `-WindowStyle Hidden` 隐藏整个 GUI。

静态测试检查语法和关键参数；功能测试使用临时本地假 SSH 进程，覆盖批量启停幂等、就绪归属、独立重连、端口冲突恢复、退避上限、DPAPI askpass、原子保存和新增/编辑保存事件。测试不连接真实 VPS、不读取生产密码，并清理临时凭据和进程。

`Test-UI.ps1` 使用虚构配置预览界面，不启动 SSH、不读取生产设置。测试不能替代真实网络环境中的长期稳定性验证。

## 源码交接

| 文件 | 职责 |
| --- | --- |
| `VPS-Tunnel-Guardian.ps1` | WinForms、多配置、生命周期、重连、持久化、托盘。 |
| `GuardianRuntime.cs` | 原生 TCP 表查询、线程安全的 SSH 错误队列、深色按钮。 |
| `SshAskPass.cs` | 当前 Windows 用户 DPAPI 解密，响应 SSH 密码提示。 |
| `Launcher.cs` | 实例检查、资源释放、无控制台 GUI 启动。 |
| `Build-Release.ps1` | 编译辅助 DLL/EXE 并嵌入单文件启动器。 |
| `Test-Stability.ps1` / `Test-FakeSsh.cs` | 无外网的功能回归。 |
| `settings.json` | 空的公开示例配置。 |
| `THIRD_PARTY_NOTICES.txt` | 图标来源与许可。 |

修改 `.ps1` 时保留 UTF-8 BOM，以兼容 Windows PowerShell 5.1。维护时先构建和运行回归，再在独立环境验证 UI；不要为了测试而停止用户的现有 SSH。

## 密码、日志与发布边界

- 密码模式使用 DPAPI CurrentUser 加密，保存于运行目录 `credentials\<id>.bin`；配置 JSON 与 SSH 命令行中没有明文密码。文件路径仅经 SSH 子进程环境变量传给 askpass。
- 加密数据仍是敏感凭据；同一 Windows 用户下的程序可能解密，不能把它当作抵抗本机恶意软件的保险箱。
- 不启用密码模式时交给本机 OpenSSH 的既有密钥/代理配置，使用 `BatchMode=yes`。
- 首次连接采用 `StrictHostKeyChecking=accept-new`；这是首次信任机制，不是预先核验服务器身份。后续密钥变化会拒绝连接。
- 运行目录 `guardian.log` 和 `guardian.log.1` 各约 512 KiB，可能包含服务器地址及错误，不应公开上传。
- 仓库和 Release 仅包含源码、图标和空配置；不包含真实节点地址、上游凭据、Clash 配置、私钥或运行日志。

图标基于 MIT 许可的 Tabler Icons，详见 [第三方许可](THIRD_PARTY_NOTICES.txt)。

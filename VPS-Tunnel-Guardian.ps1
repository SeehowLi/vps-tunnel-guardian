#requires -Version 5.1
param([switch]$TestMode)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security
$runtimeDll = Join-Path $PSScriptRoot 'GuardianRuntime.dll'
if (-not (Test-Path -LiteralPath $runtimeDll)) { $runtimeDll = Join-Path $PSScriptRoot 'build\GuardianRuntime.dll' }
Add-Type -Path $runtimeDll

[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Stop'
$script:sshPath = (Get-Command ssh.exe -ErrorAction Stop).Source
$script:configPath = Join-Path $PSScriptRoot 'settings.json'
$script:credentialsDirectory = Join-Path $PSScriptRoot 'credentials'
$script:askPassPath = Join-Path $PSScriptRoot 'SshAskPass.exe'
$script:tunnels = New-Object System.Collections.ArrayList
$script:isExiting = $false
$script:hasShownTrayHint = $false
$script:clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:lastMonitor = 0.0
$script:logPath = Join-Path $PSScriptRoot 'guardian.log'
$script:logAvailable = -not $TestMode
$script:configurationWritable = $true
$script:loadingWarning = $null
$script:instanceLock = $null
if (-not $TestMode) {
    $newInstance = $false
    $script:instanceLock = [System.Threading.Mutex]::new($true, 'Local\VpsTunnelGuardianMulti.UI', [ref]$newInstance)
    if (-not $newInstance) { $script:instanceLock.Dispose(); return }
}
$runtimeDirectory = Join-Path $env:LOCALAPPDATA 'VpsTunnelGuardianMulti'
$script:allowLegacyMigration = [string]::Equals(
    [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\'),
    [System.IO.Path]::GetFullPath($runtimeDirectory).TrimEnd('\'),
    [System.StringComparison]::OrdinalIgnoreCase
)

function New-TunnelConfiguration {
    param(
        [string]$Id = ([guid]::NewGuid().ToString('N')),
        [string]$Name = '新 SOCKS5 代理',
        [string]$Mode = 'Socks5',
        [string]$SshUser = '',
        [string]$SshServer = '',
        [int]$LocalPort = 1082,
        [string]$TargetHost = 'target.example.com',
        [int]$TargetPort = 443,
        [int]$RetrySeconds = 5,
        [bool]$UsePasswordAuthentication = $false
    )

    [pscustomobject]@{
        Id                        = $Id
        Name                      = $Name
        Mode                      = $Mode
        SshUser                   = $SshUser
        SshServer                 = $SshServer
        LocalPort                 = $LocalPort
        TargetHost                = $TargetHost
        TargetPort                = $TargetPort
        RetrySeconds              = $RetrySeconds
        UsePasswordAuthentication = $UsePasswordAuthentication
        Process                   = $null
        ShouldRun                 = $false
        RetryAt                   = 0.0
        StartedAt                 = $null
        Session                   = $null
        Failures                  = 0
        Reconnects                = 0
        LastError                 = ''
        ReadyAt                   = $null
        CheckAt                   = 0.0
        ExitObservedAt            = $null
        LastStatus                = '已停止'
        LastStatusColor           = [System.Drawing.Color]::FromArgb(203, 213, 225)
    }
}

function Test-HostValue {
    param([string]$Value)
    return $Value -match '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$'
}

function Test-TunnelConfiguration {
    param($Configuration)

    if ([string]::IsNullOrWhiteSpace($Configuration.Name) -or $Configuration.Name.Trim().Length -gt 48 -or $Configuration.Name -match '[\r\n]') {
        return '名称不能为空，且最多 48 个字符。'
    }
    if ($Configuration.Id -notmatch '^[0-9a-f]{32}$') {
        return '隧道标识无效。'
    }
    if ($Configuration.Mode -notin @('Socks5', 'LocalForward')) {
        return '隧道模式无效。'
    }
    if ($Configuration.SshUser -notmatch '^[A-Za-z0-9._-]+$') {
        return 'SSH 用户名只能包含字母、数字、点、下划线或连字符。'
    }
    if (-not (Test-HostValue $Configuration.SshServer)) {
        return 'SSH 服务器只能填写 IPv4 地址或普通主机名，且不能包含空格。'
    }
    if ($Configuration.LocalPort -lt 1 -or $Configuration.LocalPort -gt 65535) {
        return '本地端口必须在 1 到 65535 之间。'
    }
    if ($Configuration.Mode -eq 'LocalForward') {
        if (-not (Test-HostValue $Configuration.TargetHost)) {
            return '转发目标只能填写 IPv4 地址或普通主机名，且不能包含空格。'
        }
        if ($Configuration.TargetPort -lt 1 -or $Configuration.TargetPort -gt 65535) {
            return '转发目标端口必须在 1 到 65535 之间。'
        }
    }
    if ($Configuration.RetrySeconds -lt 1 -or $Configuration.RetrySeconds -gt 3600) {
        return '重连间隔必须在 1 到 3600 秒之间。'
    }
    return $null
}

function Get-ConfigurationValue {
    param($Configuration, [string]$Name, $Default)
    $property = $Configuration.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Get-PersistedTunnel {
    param($Tunnel)
    [ordered]@{
        Id                        = $Tunnel.Id
        Name                      = $Tunnel.Name
        Mode                      = $Tunnel.Mode
        SshUser                   = $Tunnel.SshUser
        SshServer                 = $Tunnel.SshServer
        LocalPort                 = $Tunnel.LocalPort
        TargetHost                = $Tunnel.TargetHost
        TargetPort                = $Tunnel.TargetPort
        RetrySeconds              = $Tunnel.RetrySeconds
        UsePasswordAuthentication = $Tunnel.UsePasswordAuthentication
    }
}

function Get-CredentialPath {
    param($Tunnel)
    return (Join-Path $script:credentialsDirectory "$($Tunnel.Id).bin")
}

function Test-PasswordAvailable {
    param($Tunnel)
    return (Test-Path -LiteralPath (Get-CredentialPath $Tunnel))
}

function Save-TunnelPassword {
    param($Tunnel, [string]$Password)
    if ([string]::IsNullOrEmpty($Password)) {
        throw '密码不能为空。'
    }
    New-Item -ItemType Directory -Path $script:credentialsDirectory -Force | Out-Null
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
    try {
        $protected = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [System.IO.File]::WriteAllBytes((Get-CredentialPath $Tunnel), $protected)
    }
    finally {
        if ($null -ne $bytes) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
}

function Remove-TunnelPassword {
    param($Tunnel)
    $credentialPath = Get-CredentialPath $Tunnel
    if (Test-Path -LiteralPath $credentialPath) {
        Remove-Item -LiteralPath $credentialPath -Force
    }
}

function Save-AppConfiguration {
    if (-not $script:configurationWritable) { throw '配置文件异常，原文件已保护；请修复 settings.json 后重启。' }
    $content = [ordered]@{
        Version        = 2
        MigratedLegacy = $script:migratedLegacy
        Tunnels        = @($script:tunnels | ForEach-Object { Get-PersistedTunnel $_ })
    } | ConvertTo-Json -Depth 5
    $temporary = $script:configPath + '.tmp'
    [System.IO.File]::WriteAllText($temporary, $content, [System.Text.UTF8Encoding]::new($true))
    if (Test-Path -LiteralPath $script:configPath) {
        [System.IO.File]::Replace($temporary, $script:configPath, [System.Management.Automation.Language.NullString]::Value)
    } else { [System.IO.File]::Move($temporary, $script:configPath) }
}

function Import-LegacyTunnel {
    $legacyPath = Join-Path (Join-Path $env:LOCALAPPDATA 'VpsTunnelGuardian') 'settings.json'
    if (-not (Test-Path -LiteralPath $legacyPath)) {
        return $null
    }
    try {
        $legacy = Get-Content -LiteralPath $legacyPath -Raw -Encoding utf8 | ConvertFrom-Json
        $candidate = New-TunnelConfiguration `
            -Name '旧版本地转发（未接管）' `
            -Mode 'LocalForward' `
            -SshUser ([string]$legacy.SshUser) `
            -SshServer ([string]$legacy.SshServer) `
            -LocalPort ([int]$legacy.LocalPort) `
            -TargetHost ([string]$legacy.TargetHost) `
            -TargetPort ([int]$legacy.TargetPort) `
            -RetrySeconds ([int](Get-ConfigurationValue $legacy 'RetrySeconds' 5))
        if ($null -eq (Test-TunnelConfiguration $candidate)) {
            return $candidate
        }
    }
    catch {
        # A legacy configuration must never prevent the new independent app from opening.
    }
    return $null
}

function Load-AppConfiguration {
    $script:migratedLegacy = $false
    $storedTunnels = @()
    try {
        if (Test-Path -LiteralPath $script:configPath) {
            $stored = Get-Content -LiteralPath $script:configPath -Raw -Encoding utf8 | ConvertFrom-Json
            $script:migratedLegacy = [bool](Get-ConfigurationValue $stored 'MigratedLegacy' $false)
            $storedTunnels = @($stored.Tunnels)
        }
    }
    catch {
        $script:configurationWritable = $false
        $script:loadingWarning = '配置文件无法读取，原文件已保留，请修复后重启。'
        return
    }

    foreach ($storedTunnel in $storedTunnels) {
        try {
            $candidate = New-TunnelConfiguration `
                -Id ([string](Get-ConfigurationValue $storedTunnel 'Id' ([guid]::NewGuid().ToString('N')))) `
                -Name ([string](Get-ConfigurationValue $storedTunnel 'Name' '未命名隧道')) `
                -Mode ([string](Get-ConfigurationValue $storedTunnel 'Mode' 'LocalForward')) `
                -SshUser ([string](Get-ConfigurationValue $storedTunnel 'SshUser' '')) `
                -SshServer ([string](Get-ConfigurationValue $storedTunnel 'SshServer' '')) `
                -LocalPort ([int](Get-ConfigurationValue $storedTunnel 'LocalPort' 1082)) `
                -TargetHost ([string](Get-ConfigurationValue $storedTunnel 'TargetHost' 'target.example.com')) `
                -TargetPort ([int](Get-ConfigurationValue $storedTunnel 'TargetPort' 443)) `
                -RetrySeconds ([int](Get-ConfigurationValue $storedTunnel 'RetrySeconds' 5)) `
                -UsePasswordAuthentication ([bool](Get-ConfigurationValue $storedTunnel 'UsePasswordAuthentication' $false))
            if ($null -eq (Test-TunnelConfiguration $candidate) -and @($script:tunnels | Where-Object { $_.Id -eq $candidate.Id -or $_.LocalPort -eq $candidate.LocalPort }).Count -eq 0) {
                [void]$script:tunnels.Add($candidate)
            } else {
                $script:configurationWritable = $false
                $script:loadingWarning = '配置存在无效或重复条目，原文件已保护。'
            }
        }
        catch {
            $script:configurationWritable = $false
            $script:loadingWarning = '配置存在无法读取的条目，原文件已保护。'
        }
    }

    if ($script:configurationWritable -and $script:allowLegacyMigration -and -not $script:migratedLegacy -and -not $TestMode) {
        $legacyTunnel = Import-LegacyTunnel
        if ($null -ne $legacyTunnel) {
            [void]$script:tunnels.Add($legacyTunnel)
        }
        $script:migratedLegacy = $true
        Save-AppConfiguration
    }
}

if (-not $TestMode) { Load-AppConfiguration } else { $script:migratedLegacy = $true }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'VPS Tunnel Guardian 2.1 · 多隧道'
$form.ClientSize = New-Object System.Drawing.Size(780, 570)
$form.MinimumSize = New-Object System.Drawing.Size(780, 610)
$form.MaximumSize = New-Object System.Drawing.Size(780, 610)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(11, 18, 32)

$iconPath = Join-Path $PSScriptRoot 'tunnel-logo.ico'
$appIcon = $null
if (Test-Path -LiteralPath $iconPath) {
    $appIcon = New-Object System.Drawing.Icon($iconPath)
    $form.Icon = $appIcon
}
$form.Add_HandleCreated({
    param($sender, $eventArgs)
    $enableDarkTitleBar = 1
    [void][GuardianRuntime.Native]::DwmSetWindowAttribute($sender.Handle, 20, [ref]$enableDarkTitleBar, 4)
})

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 92
$header.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$form.Controls.Add($header)

$logoBadge = New-Object System.Windows.Forms.Panel
$logoBadge.BackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
$logoBadge.Location = New-Object System.Drawing.Point(20, 20)
$logoBadge.Size = New-Object System.Drawing.Size(52, 52)
$logoBadge.Add_Paint({
    param($sender, $paintEventArgs)
    $graphics = $paintEventArgs.Graphics
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $linePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(219, 234, 254), 2.2)
    $dotBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    try {
        $graphics.DrawLine($linePen, 14, 37, 14, 28)
        $graphics.DrawLine($linePen, 14, 28, 34, 28)
        $graphics.DrawLine($linePen, 34, 28, 34, 15)
        $graphics.FillEllipse($dotBrush, 10, 33, 8, 8)
        $graphics.FillEllipse($dotBrush, 10, 24, 8, 8)
        $graphics.FillEllipse($dotBrush, 30, 11, 8, 8)
    }
    finally {
        $linePen.Dispose()
        $dotBrush.Dispose()
    }
})
$header.Controls.Add($logoBadge)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'VPS 隧道守护'
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 17, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(88, 19)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = '多隧道 · SOCKS5 代理 · 自动保活与重连'
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(91, 52)
$header.Controls.Add($subtitle)

$headerState = New-Object System.Windows.Forms.Label
$headerState.Text = '0 / 0 就绪'
$headerState.ForeColor = [System.Drawing.Color]::FromArgb(96, 165, 250)
$headerState.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$headerState.AutoSize = $true
$headerState.Location = New-Object System.Drawing.Point(662, 38)
$header.Controls.Add($headerState)

$cardBorderPaint = {
    param($sender, $paintEventArgs)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(51, 65, 85))
    try {
        $paintEventArgs.Graphics.DrawRectangle($pen, 0, 0, $sender.ClientSize.Width - 1, $sender.ClientSize.Height - 1)
    }
    finally {
        $pen.Dispose()
    }
}

$tunnelCard = New-Object System.Windows.Forms.Panel
$tunnelCard.Location = New-Object System.Drawing.Point(20, 112)
$tunnelCard.Size = New-Object System.Drawing.Size(740, 218)
$tunnelCard.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$tunnelCard.Add_Paint($cardBorderPaint)
$form.Controls.Add($tunnelCard)

$tunnelTitle = New-Object System.Windows.Forms.Label
$tunnelTitle.Text = '隧道列表'
$tunnelTitle.AutoSize = $true
$tunnelTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$tunnelTitle.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$tunnelTitle.Location = New-Object System.Drawing.Point(16, 13)
$tunnelCard.Controls.Add($tunnelTitle)

$tunnelHint = New-Object System.Windows.Forms.Label
$tunnelHint.Text = '新建 SOCKS5 后，在浏览器填 127.0.0.1 和本地端口'
$tunnelHint.AutoSize = $true
$tunnelHint.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$tunnelHint.Location = New-Object System.Drawing.Point(332, 15)
$tunnelCard.Controls.Add($tunnelHint)

$tunnelList = New-Object System.Windows.Forms.ListView
$tunnelList.Location = New-Object System.Drawing.Point(16, 42)
$tunnelList.Size = New-Object System.Drawing.Size(708, 159)
$tunnelList.View = [System.Windows.Forms.View]::Details
$tunnelList.FullRowSelect = $true
$tunnelList.HideSelection = $false
$tunnelList.MultiSelect = $false
$tunnelList.BackColor = [System.Drawing.Color]::FromArgb(11, 18, 32)
$tunnelList.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$tunnelList.BorderStyle = 'FixedSingle'
$tunnelList.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.6)
[System.Windows.Forms.ListView].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($tunnelList, $true, $null)
$tunnelList.ShowItemToolTips = $true
[void]$tunnelList.Columns.Add('名称', 150)
[void]$tunnelList.Columns.Add('状态', 136)
[void]$tunnelList.Columns.Add('模式', 93)
[void]$tunnelList.Columns.Add('本地端口', 82)
[void]$tunnelList.Columns.Add('目标 / SSH 服务器', 177)
[void]$tunnelList.Columns.Add('重试', 68)
$tunnelList.OwnerDraw = $true
$tunnelList.Add_DrawColumnHeader({
    param($sender,$e)
    $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(30,41,59))
    try {
        $e.Graphics.FillRectangle($brush, $e.Bounds)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $sender.Font, $e.Bounds, [System.Drawing.Color]::FromArgb(203,213,225), [System.Windows.Forms.TextFormatFlags]'Left,VerticalCenter,EndEllipsis')
    } finally { $brush.Dispose() }
})
$tunnelList.Add_DrawSubItem({ param($sender,$e) $e.DrawDefault = $true })
$tunnelCard.Controls.Add($tunnelList)

$selectionHint = New-Object System.Windows.Forms.Label
$selectionHint.Text = '双击编辑 · 悬停查看失败原因 · 每条隧道独立恢复'
$selectionHint.AutoSize = $true
$selectionHint.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$selectionHint.Location = New-Object System.Drawing.Point(20, 347)
$form.Controls.Add($selectionHint)

function New-DarkButton {
    param([string]$Text, [int]$Left, [int]$Width, [System.Drawing.Color]$Background)
    $button = New-Object GuardianRuntime.DarkButton
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($Left, 372)
    $button.Size = New-Object System.Drawing.Size($Width, 34)
    $button.BackColor = $Background
    $button.ForeColor = [System.Drawing.Color]::White
    $button.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5, [System.Drawing.FontStyle]::Bold)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $form.Controls.Add($button)
    return $button
}

$addButton = New-DarkButton '＋ 新建 SOCKS5' 20 120 ([System.Drawing.Color]::FromArgb(37, 99, 235))
$editButton = New-DarkButton '编辑' 148 72 ([System.Drawing.Color]::FromArgb(30, 41, 59))
$startButton = New-DarkButton '启动' 228 72 ([System.Drawing.Color]::FromArgb(22, 163, 74))
$stopButton = New-DarkButton '停止' 308 72 ([System.Drawing.Color]::FromArgb(220, 38, 38))
$deleteButton = New-DarkButton '删除' 388 72 ([System.Drawing.Color]::FromArgb(71, 85, 105))

$startAllButton = New-DarkButton '全部启动' 548 100 ([System.Drawing.Color]::FromArgb(37,99,235))
$stopAllButton = New-DarkButton '全部停止' 660 100 ([System.Drawing.Color]::FromArgb(71,85,105))
$copyButton = New-DarkButton '复制' 468 72 ([System.Drawing.Color]::FromArgb(30,41,59))

$activityCard = New-Object System.Windows.Forms.Panel
$activityCard.Location = New-Object System.Drawing.Point(20, 424)
$activityCard.Size = New-Object System.Drawing.Size(740, 122)
$activityCard.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$activityCard.Add_Paint($cardBorderPaint)
$form.Controls.Add($activityCard)

$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Text = '活动日志'
$logTitle.AutoSize = $true
$logTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$logTitle.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$logTitle.Location = New-Object System.Drawing.Point(16, 11)
$activityCard.Controls.Add($logTitle)

$logHint = New-Object System.Windows.Forms.Label
$logHint.Text = '诊断日志自动轮换 · 关闭窗口继续守护'
$logHint.AutoSize = $true
$logHint.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$logHint.Location = New-Object System.Drawing.Point(405, 13)
$activityCard.Controls.Add($logHint)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(11, 18, 32)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$logBox.BorderStyle = 'None'
$logBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$logBox.Location = New-Object System.Drawing.Point(16, 37)
$logBox.Size = New-Object System.Drawing.Size(708, 72)
$activityCard.Controls.Add($logBox)

function Add-Log {
    param([string]$Message)
    if ($logBox.Lines.Count -gt 180) {
        $logBox.Lines = @($logBox.Lines | Select-Object -Last 160)
    }
    if ($script:logAvailable) {
        try {
            if ((Test-Path -LiteralPath $script:logPath) -and (Get-Item -LiteralPath $script:logPath).Length -gt 524288) {
                [System.IO.File]::Copy($script:logPath, $script:logPath + '.1', $true)
                [System.IO.File]::WriteAllText($script:logPath, '', [System.Text.Encoding]::UTF8)
            }
            [System.IO.File]::AppendAllText($script:logPath, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message`r`n", [System.Text.Encoding]::UTF8)
        } catch { $script:logAvailable = $false }
    }
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $logBox.AppendText("[$timestamp] $Message`r`n")
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Get-ModeLabel {
    param($Tunnel)
    if ($Tunnel.Mode -eq 'Socks5') { return 'SOCKS5 代理' }
    return '本地转发'
}

function Get-EndpointLabel {
    param($Tunnel)
    if ($Tunnel.Mode -eq 'Socks5') {
        return "$($Tunnel.SshUser)@$($Tunnel.SshServer)"
    }
    return "$($Tunnel.TargetHost):$($Tunnel.TargetPort) via $($Tunnel.SshServer)"
}

function Set-TunnelStatus {
    param($Tunnel, [string]$Status, [System.Drawing.Color]$Color)
    $Tunnel.LastStatus = $Status
    $Tunnel.LastStatusColor = $Color
}

function Get-SelectedTunnel {
    if ($tunnelList.SelectedItems.Count -eq 0) { return $null }
    return $tunnelList.SelectedItems[0].Tag
}

function Update-TunnelRows {
    if (-not $form.Visible) { return }
    $ready = @($script:tunnels | Where-Object { $null -ne $_.ReadyAt }).Count
    $headerState.Text = "$ready / $($script:tunnels.Count) 就绪"
    foreach ($item in $tunnelList.Items) {
        $tunnel = $item.Tag
        $item.Text = $tunnel.Name
        $item.SubItems[1].Text = $tunnel.LastStatus
        $item.SubItems[1].ForeColor = $tunnel.LastStatusColor
        $item.SubItems[2].Text = Get-ModeLabel $tunnel
        $item.SubItems[3].Text = [string]$tunnel.LocalPort
        $item.SubItems[4].Text = Get-EndpointLabel $tunnel
        $item.SubItems[5].Text = [string]$tunnel.Reconnects
        $item.ToolTipText = if ($tunnel.LastError) { $tunnel.LastError } else { '就绪表示 SSH 已建立监听，不代表目标网站可达。' }
    }
}

function Refresh-TunnelList {
    $selectedId = $null
    $selectedTunnel = Get-SelectedTunnel
    if ($null -ne $selectedTunnel) { $selectedId = $selectedTunnel.Id }
    $tunnelList.BeginUpdate()
    try {
        $tunnelList.Items.Clear()
        foreach ($tunnel in $script:tunnels) {
            $item = New-Object System.Windows.Forms.ListViewItem($tunnel.Name)
            [void]$item.SubItems.Add($tunnel.LastStatus)
            [void]$item.SubItems.Add((Get-ModeLabel $tunnel))
            [void]$item.SubItems.Add([string]$tunnel.LocalPort)
            [void]$item.SubItems.Add((Get-EndpointLabel $tunnel))
            [void]$item.SubItems.Add([string]$tunnel.Reconnects)
            $item.Tag = $tunnel
            $item.UseItemStyleForSubItems = $false
            $item.SubItems[1].ForeColor = $tunnel.LastStatusColor
            [void]$tunnelList.Items.Add($item)
            if ($tunnel.Id -eq $selectedId) { $item.Selected = $true }
        }
    }
    finally {
        $tunnelList.EndUpdate()
    }
    Update-ActionButtons
}

function Update-ActionButtons {
    $selected = Get-SelectedTunnel
    $hasSelection = $null -ne $selected
    $editButton.Enabled = $hasSelection -and -not $selected.ShouldRun
    $deleteButton.Enabled = $hasSelection -and -not $selected.ShouldRun
    $startButton.Enabled = $hasSelection -and -not $selected.ShouldRun
    $stopButton.Enabled = $hasSelection -and $selected.ShouldRun
    $copyButton.Enabled = $hasSelection
    $startAllButton.Enabled = @($script:tunnels | Where-Object { -not $_.ShouldRun }).Count -gt 0
    $stopAllButton.Enabled = @($script:tunnels | Where-Object { $_.ShouldRun }).Count -gt 0
    $addButton.Enabled = $script:configurationWritable
    if (-not $script:configurationWritable) { $editButton.Enabled = $false; $deleteButton.Enabled = $false }
}

function Test-UniqueLocalPort {
    param($Candidate, $ExcludeId)
    foreach ($tunnel in $script:tunnels) {
        if ($tunnel.Id -ne $ExcludeId -and $tunnel.LocalPort -eq $Candidate.LocalPort) {
            return "本地端口 $($Candidate.LocalPort) 已被 [$($tunnel.Name)] 使用。"
        }
    }
    return $null
}

function Get-LocalPortListener {
    param([int]$Port)
    $owners = [GuardianRuntime.Native]::Listeners()
    if ($owners.ContainsKey($Port)) { return $owners[$Port] }
    return 0
}

function Stop-Tunnel {
    param($Tunnel)
    if ($null -eq $Tunnel.Process) { return }
    try {
        if (-not $Tunnel.Process.HasExited) {
            $Tunnel.Process.Kill()
            [void]$Tunnel.Process.WaitForExit(200)
        }
    }
    catch {
        Add-Log "[$($Tunnel.Name)] 停止 SSH 时出现异常：$($_.Exception.Message)"
    }
    finally {
        if ($null -ne $Tunnel.Session) { $Tunnel.Session.Dispose(); $Tunnel.Session = $null }
        else { $Tunnel.Process.Dispose() }
        $Tunnel.ReadyAt = $null
        $Tunnel.Process = $null
        $Tunnel.StartedAt = $null
    }
}

function Schedule-Retry {
    param($Tunnel, [string]$Reason)
    $Tunnel.Failures = [Math]::Min(10, $Tunnel.Failures + 1)
    $Tunnel.Reconnects++
    $cap = [Math]::Max(60, $Tunnel.RetrySeconds)
    $delay = [Math]::Min($cap, $Tunnel.RetrySeconds * [Math]::Pow(2, $Tunnel.Failures - 1))
    $delay += (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
    $Tunnel.RetryAt = $script:clock.Elapsed.TotalSeconds + $delay
    $Tunnel.LastError = $Reason
    $Tunnel.ReadyAt = $null
    Set-TunnelStatus $Tunnel '等待重连' ([System.Drawing.Color]::FromArgb(217,119,6))
    Add-Log "[$($Tunnel.Name)] $Reason；$([Math]::Ceiling($delay)) 秒后重试。"
}

function Start-Tunnel {
    param($Tunnel)
    if ($null -ne $Tunnel.Process -and -not $Tunnel.Process.HasExited) { return }
    try { $owner = Get-LocalPortListener $Tunnel.LocalPort }
    catch { Schedule-Retry $Tunnel '暂时无法读取本地监听表'; return }
    if ($owner -gt 0) {
        Schedule-Retry $Tunnel "端口 $($Tunnel.LocalPort) 被 PID $owner 占用，等待释放"
        return
    }
    if ($Tunnel.UsePasswordAuthentication -and -not (Test-PasswordAvailable $Tunnel)) {
        $Tunnel.ShouldRun = $false
        Set-TunnelStatus $Tunnel '缺少已保存密码' ([System.Drawing.Color]::FromArgb(220, 38, 38))
        Add-Log "[$($Tunnel.Name)] 未启动：请编辑条目并保存 SSH 密码。"
        return
    }
    if ($Tunnel.UsePasswordAuthentication -and -not (Test-Path -LiteralPath $script:askPassPath)) {
        $Tunnel.ShouldRun = $false
        Set-TunnelStatus $Tunnel '密码组件缺失' ([System.Drawing.Color]::FromArgb(220, 38, 38))
        Add-Log "[$($Tunnel.Name)] 未启动：SshAskPass.exe 不存在。请重新构建或重新释放 EXE。"
        return
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:sshPath
    $arguments = @()
    if ($Tunnel.Mode -eq 'Socks5') {
        $arguments += '-D'
        $arguments += "127.0.0.1:$($Tunnel.LocalPort)"
    }
    else {
        $arguments += '-L'
        $arguments += "127.0.0.1:$($Tunnel.LocalPort):$($Tunnel.TargetHost):$($Tunnel.TargetPort)"
    }
    $arguments += '-N', '-T', '-o', 'Compression=no', '-o', 'IPQoS=none', '-o', 'TCPKeepAlive=yes', '-o', 'ConnectTimeout=15', '-o', 'ConnectionAttempts=1', '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=6', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'LogLevel=ERROR'
    if ($Tunnel.UsePasswordAuthentication) {
        $arguments += '-o', 'BatchMode=no', '-o', 'NumberOfPasswordPrompts=1', '-o', 'KbdInteractiveAuthentication=no', '-o', 'PasswordAuthentication=yes', '-o', 'PreferredAuthentications=password'
        $psi.EnvironmentVariables['SSH_ASKPASS'] = $script:askPassPath
        $psi.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
        $psi.EnvironmentVariables['DISPLAY'] = 'VpsTunnelGuardian'
        $psi.EnvironmentVariables['GUARDIAN_CREDENTIAL_FILE'] = Get-CredentialPath $Tunnel
    }
    else {
        $arguments += '-o', 'BatchMode=yes'
    }
    $arguments += "$($Tunnel.SshUser)@$($Tunnel.SshServer)"
    $psi.Arguments = $arguments -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = $null
    try {
        $Tunnel.Session = [GuardianRuntime.SshSession]::new($psi)
        $Tunnel.Process = $Tunnel.Session.Process
        $Tunnel.LastError = ''
        $Tunnel.ExitObservedAt = $null
        $Tunnel.StartedAt = $script:clock.Elapsed.TotalSeconds
        $Tunnel.ReadyAt = $null
        $Tunnel.CheckAt = 0.0
        Set-TunnelStatus $Tunnel '正在连接' ([System.Drawing.Color]::FromArgb(96, 165, 250))
        $kind = if ($Tunnel.Mode -eq 'Socks5') { 'SOCKS5 代理' } else { '本地转发' }
        Add-Log "[$($Tunnel.Name)] 已启动 $kind：127.0.0.1:$($Tunnel.LocalPort)。"
    }
    catch {
        if ($null -ne $process) { $process.Dispose() }
        $Tunnel.Process = $null
        Schedule-Retry $Tunnel "启动失败：$($_.Exception.Message)"
    }
}

function Add-SettingsInput {
    param([System.Windows.Forms.Form]$Dialog, [string]$Label, [int]$Top, [string]$Value)
    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = $Label
    $caption.AutoSize = $true
    $caption.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $caption.Location = [System.Drawing.Point]::new(20, [int]($Top + 4))
    $Dialog.Controls.Add($caption)
    $input = New-Object System.Windows.Forms.TextBox
    $input.Text = $Value
    $input.Location = New-Object System.Drawing.Point(192, $Top)
    $input.Size = New-Object System.Drawing.Size(300, 26)
    $input.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $input.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $input.BorderStyle = 'FixedSingle'
    $Dialog.Controls.Add($input)
    return [pscustomobject]@{ Caption = $caption; Input = $input }
}

function Open-TunnelSettings {
    param($ExistingTunnel)
    if ($null -ne $ExistingTunnel -and $ExistingTunnel.ShouldRun) {
        [void][System.Windows.Forms.MessageBox]::Show('请先停止该隧道，再修改配置。', 'VPS 隧道守护')
        return
    }
    $isNew = $null -eq $ExistingTunnel
    $working = if ($isNew) { New-TunnelConfiguration } else { New-TunnelConfiguration `
        -Id $ExistingTunnel.Id -Name $ExistingTunnel.Name -Mode $ExistingTunnel.Mode -SshUser $ExistingTunnel.SshUser -SshServer $ExistingTunnel.SshServer `
        -LocalPort $ExistingTunnel.LocalPort -TargetHost $ExistingTunnel.TargetHost -TargetPort $ExistingTunnel.TargetPort -RetrySeconds $ExistingTunnel.RetrySeconds `
        -UsePasswordAuthentication $ExistingTunnel.UsePasswordAuthentication }

    if ($isNew) {
        $listeners = [GuardianRuntime.Native]::Listeners()
        for ($port = 1082; $port -le 65535; $port++) {
            if (-not $listeners.ContainsKey($port) -and @($script:tunnels | Where-Object { $_.LocalPort -eq $port }).Count -eq 0) { $working.LocalPort = $port; break }
        }
    }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = if ($isNew) { '新建隧道' } else { '编辑隧道' }
    $dialog.ClientSize = New-Object System.Drawing.Size(548, 470)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = 'CenterParent'
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    if ($null -ne $appIcon) { $dialog.Icon = $appIcon }

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'SOCKS5 可直接作为指纹浏览器代理；密码仅以当前 Windows 用户加密保存。'
    $intro.AutoSize = $true
    $intro.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $intro.Location = New-Object System.Drawing.Point(20, 15)
    $dialog.Controls.Add($intro)

    $nameRow = Add-SettingsInput $dialog '名称' 48 $working.Name
    $modeCaption = New-Object System.Windows.Forms.Label
    $modeCaption.Text = '隧道模式'
    $modeCaption.AutoSize = $true
    $modeCaption.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $modeCaption.Location = New-Object System.Drawing.Point(20, 88)
    $dialog.Controls.Add($modeCaption)
    $modeInput = New-Object System.Windows.Forms.ComboBox
    $modeInput.DropDownStyle = 'DropDownList'
    $modeInput.Location = New-Object System.Drawing.Point(192, 84)
    $modeInput.Size = New-Object System.Drawing.Size(300, 26)
    $modeInput.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $modeInput.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    [void]$modeInput.Items.Add('SOCKS5 代理（-D，浏览器使用）')
    [void]$modeInput.Items.Add('本地端口转发（-L）')
    $modeInput.SelectedIndex = if ($working.Mode -eq 'Socks5') { 0 } else { 1 }
    $dialog.Controls.Add($modeInput)
    $sshUserRow = Add-SettingsInput $dialog 'SSH 用户名' 120 $working.SshUser
    $sshServerRow = Add-SettingsInput $dialog 'VPS IP / 主机名' 156 $working.SshServer
    $localPortRow = Add-SettingsInput $dialog '本地监听端口' 192 ([string]$working.LocalPort)
    $targetHostRow = Add-SettingsInput $dialog '转发目标 IP / 主机名' 228 $working.TargetHost
    $targetPortRow = Add-SettingsInput $dialog '转发目标端口' 264 ([string]$working.TargetPort)
    $retryRow = Add-SettingsInput $dialog '断线重连间隔（秒）' 300 ([string]$working.RetrySeconds)

    $passwordCheck = New-Object System.Windows.Forms.CheckBox
    $passwordCheck.Text = '保存 SSH 密码（Windows 用户加密；编辑时留空保留）'
    $passwordCheck.AutoSize = $true
    $passwordCheck.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $passwordCheck.Location = New-Object System.Drawing.Point(20, 338)
    $passwordCheck.Checked = $working.UsePasswordAuthentication
    $dialog.Controls.Add($passwordCheck)

    $passwordInput = New-Object System.Windows.Forms.TextBox
    $passwordInput.Location = New-Object System.Drawing.Point(192, 368)
    $passwordInput.Size = New-Object System.Drawing.Size(300, 26)
    $passwordInput.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $passwordInput.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $passwordInput.BorderStyle = 'FixedSingle'
    $passwordInput.UseSystemPasswordChar = $true
    $passwordInput.Enabled = $passwordCheck.Checked
    $dialog.Controls.Add($passwordInput)

    $modeChanged = {
        $isLocalForward = $modeInput.SelectedIndex -eq 1
        foreach ($control in @($targetHostRow.Caption, $targetHostRow.Input, $targetPortRow.Caption, $targetPortRow.Input)) {
            $control.Enabled = $isLocalForward
            $control.Visible = $isLocalForward
        }
    }
    $modeInput.Add_SelectedIndexChanged($modeChanged)
    & $modeChanged
    $passwordCheck.Add_CheckedChanged({ $passwordInput.Enabled = $passwordCheck.Checked })

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = '保存配置'
    $saveButton.Location = New-Object System.Drawing.Point(304, 422)
    $saveButton.Size = New-Object System.Drawing.Size(88, 32)
    $saveButton.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $saveButton.ForeColor = [System.Drawing.Color]::White
    $saveButton.FlatStyle = 'Flat'
    $saveButton.FlatAppearance.BorderSize = 0
    $dialog.Controls.Add($saveButton)
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = '取消'
    $cancelButton.Location = New-Object System.Drawing.Point(404, 422)
    $cancelButton.Size = New-Object System.Drawing.Size(88, 32)
    $cancelButton.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $cancelButton.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $cancelButton.FlatStyle = 'Flat'
    $cancelButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $dialog.Controls.Add($cancelButton)
    $cancelButton.Add_Click({ $dialog.Close() })
    $dialog.CancelButton = $cancelButton
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $saveButton.Add_Click({
        $localPort = 0; $targetPort = 443; $retrySeconds = 0
        if (-not [int]::TryParse($localPortRow.Input.Text.Trim(), [ref]$localPort) -or -not [int]::TryParse($retryRow.Input.Text.Trim(), [ref]$retrySeconds)) {
            [void][System.Windows.Forms.MessageBox]::Show('本地端口和重连间隔必须填写整数。', '配置无效')
            return
        }
        $mode = if ($modeInput.SelectedIndex -eq 0) { 'Socks5' } else { 'LocalForward' }
        if ($mode -eq 'LocalForward' -and -not [int]::TryParse($targetPortRow.Input.Text.Trim(), [ref]$targetPort)) {
            [void][System.Windows.Forms.MessageBox]::Show('转发目标端口必须填写整数。', '配置无效')
            return
        }
        $candidate = New-TunnelConfiguration `
            -Id $working.Id -Name $nameRow.Input.Text.Trim() -Mode $mode -SshUser $sshUserRow.Input.Text.Trim() -SshServer $sshServerRow.Input.Text.Trim() `
            -LocalPort $localPort -TargetHost $targetHostRow.Input.Text.Trim() -TargetPort $targetPort -RetrySeconds $retrySeconds `
            -UsePasswordAuthentication $passwordCheck.Checked
        $validationError = Test-TunnelConfiguration $candidate
        if ($null -ne $validationError) {
            [void][System.Windows.Forms.MessageBox]::Show($validationError, '配置无效')
            return
        }
        $portError = Test-UniqueLocalPort $candidate $(if ($isNew) { '' } else { $ExistingTunnel.Id })
        if ($null -ne $portError) {
            [void][System.Windows.Forms.MessageBox]::Show($portError, '配置无效')
            return
        }
        if ($candidate.UsePasswordAuthentication -and [string]::IsNullOrEmpty($passwordInput.Text) -and ($isNew -or -not (Test-PasswordAvailable $ExistingTunnel))) {
            [void][System.Windows.Forms.MessageBox]::Show('请填写 SSH 密码；密码不会写入 settings.json。', '配置无效')
            return
        }
        try {
            if ($candidate.UsePasswordAuthentication -and -not [string]::IsNullOrEmpty($passwordInput.Text)) {
                Save-TunnelPassword $candidate $passwordInput.Text
            }
            elseif (-not $candidate.UsePasswordAuthentication -and -not $isNew) {
                Remove-TunnelPassword $ExistingTunnel
            }
            if ($isNew) {
                [void]$script:tunnels.Add($candidate)
                Add-Log "[$($candidate.Name)] 已创建，尚未启动。"
            }
            else {
                $index = $script:tunnels.IndexOf($ExistingTunnel)
                $script:tunnels[$index] = $candidate
                Add-Log "[$($candidate.Name)] 配置已保存。"
            }
            Save-AppConfiguration
            Refresh-TunnelList
            foreach ($item in $tunnelList.Items) { if ($item.Tag.Id -eq $candidate.Id) { $item.Selected = $true; $item.Focused = $true } }
            $dialog.Close()
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show("无法保存配置：$($_.Exception.Message)", '保存失败')
        }
    })
    [void]$dialog.ShowDialog($form)
}

function Show-ApplicationWindow {
    $form.ShowInTaskbar = $true
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
}

function Exit-Application {
    $script:isExiting = $true
    $form.Close()
}

function Enable-Tunnel {
    param($Tunnel)
    if ($Tunnel.ShouldRun) { return }
    $Tunnel.ShouldRun = $true
    $Tunnel.Failures = 0
    $Tunnel.RetryAt = $script:clock.Elapsed.TotalSeconds
    Set-TunnelStatus $Tunnel '等待启动' ([System.Drawing.Color]::FromArgb(96,165,250))
}
function Disable-Tunnel {
    param($Tunnel)
    $Tunnel.ShouldRun = $false
    Stop-Tunnel $Tunnel
    Set-TunnelStatus $Tunnel '已停止' ([System.Drawing.Color]::FromArgb(203,213,225))
}
function Start-AllTunnels {
    foreach ($tunnel in $script:tunnels) { Enable-Tunnel $tunnel }
    Update-TunnelRows
    Update-ActionButtons
}
function Stop-AllTunnels {
    foreach ($tunnel in $script:tunnels) { Disable-Tunnel $tunnel }
    Update-TunnelRows
    Update-ActionButtons
}
function Update-TunnelState {
    param($Tunnel)
    if (-not $Tunnel.ShouldRun) { return }
    $now = $script:clock.Elapsed.TotalSeconds
    if ($null -eq $Tunnel.Process) {
        if ($now -ge $Tunnel.RetryAt) { Start-Tunnel $Tunnel }
        else { Set-TunnelStatus $Tunnel "$([Math]::Ceiling($Tunnel.RetryAt - $now)) 秒后重试" ([System.Drawing.Color]::FromArgb(217,119,6)) }
        return
    }
    foreach ($message in $Tunnel.Session.Drain()) {
        $Tunnel.LastError = $message
        Add-Log "[$($Tunnel.Name)] SSH: $message"
    }
    if ($Tunnel.Process.HasExited) {
        # Give the asynchronous stderr reader one tick to finish, bounded to two seconds.
        if (-not $Tunnel.Session.ErrorClosed) {
            if ($null -eq $Tunnel.ExitObservedAt) { $Tunnel.ExitObservedAt = $now; return }
            if ($now - $Tunnel.ExitObservedAt -lt 2) { return }
        }
        foreach ($message in $Tunnel.Session.Drain()) {
            $Tunnel.LastError = $message
            Add-Log "[$($Tunnel.Name)] SSH: $message"
        }
        $exitCode = $Tunnel.Process.ExitCode
        $Tunnel.Session.Dispose()
        $Tunnel.Session = $null
        $Tunnel.Process = $null
        $Tunnel.StartedAt = $null
        $Tunnel.ReadyAt = $null
        $reason = "SSH 退出 $exitCode；$($Tunnel.LastError)"
        if ($Tunnel.LastError -match 'Permission denied|REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed|Too many authentication failures') {
            $Tunnel.ShouldRun = $false
            Set-TunnelStatus $Tunnel '请检查认证' ([System.Drawing.Color]::FromArgb(248,113,113))
            Add-Log "[$($Tunnel.Name)] $reason；修复配置后点击启动。"
        } else { Schedule-Retry $Tunnel $reason }
        return
    }
    if ($now -ge $Tunnel.CheckAt) {
        $owner = Get-LocalPortListener $Tunnel.LocalPort
        $Tunnel.CheckAt = $now + $(if ($null -eq $Tunnel.ReadyAt) { 1 } else { 5 })
        if ($owner -eq $Tunnel.Process.Id) {
            if ($null -eq $Tunnel.ReadyAt) {
                $Tunnel.ReadyAt = $now
                Add-Log "[$($Tunnel.Name)] SSH 已建立监听，隧道就绪。"
            }
        } elseif ($null -ne $Tunnel.ReadyAt -or $now - $Tunnel.StartedAt -gt 45) {
            Stop-Tunnel $Tunnel
            Schedule-Retry $Tunnel '监听消失或连接超时'
            return
        }
    }
    if ($null -ne $Tunnel.ReadyAt) {
        if ($now - $Tunnel.ReadyAt -ge 120) { $Tunnel.Failures = 0 }
        $elapsed = [TimeSpan]::FromSeconds($now - $Tunnel.ReadyAt).ToString('hh\:mm\:ss')
        Set-TunnelStatus $Tunnel "就绪 $elapsed" ([System.Drawing.Color]::FromArgb(74,222,128))
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    foreach ($tunnel in $script:tunnels) {
        try { Update-TunnelState $tunnel }
        catch {
            $now = $script:clock.Elapsed.TotalSeconds
            if ($now -ge $tunnel.CheckAt) {
                Add-Log "[$($tunnel.Name)] 检查异常：$($_.Exception.Message)"
                $tunnel.CheckAt = $now + 10
            }
        }
    }
    if ($form.Visible) { Update-TunnelRows; Update-ActionButtons }
})

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showWindowItem = $trayMenu.Items.Add('显示窗口')
$trayStartAll = $trayMenu.Items.Add('全部启动')
$trayStopAll = $trayMenu.Items.Add('全部停止')
$trayStartAll.Add_Click({ Start-AllTunnels })
$trayStopAll.Add_Click({ Stop-AllTunnels })
[void]$trayMenu.Items.Add('-')
$exitApplicationItem = $trayMenu.Items.Add('退出应用')
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Text = 'VPS 隧道守护（多隧道）'
$trayIcon.Icon = if ($null -ne $appIcon) { $appIcon } else { [System.Drawing.SystemIcons]::Application }
$trayIcon.ContextMenuStrip = $trayMenu
$trayIcon.Visible = -not $TestMode
$showWindowItem.Add_Click({ Show-ApplicationWindow })
$exitApplicationItem.Add_Click({ Exit-Application })
$trayIcon.Add_MouseDoubleClick({ Show-ApplicationWindow })

$addButton.Add_Click({ Open-TunnelSettings $null })
$editButton.Add_Click({ $selected = Get-SelectedTunnel; if ($null -ne $selected) { Open-TunnelSettings $selected } })
$startButton.Add_Click({
    $selected = Get-SelectedTunnel
    if ($null -ne $selected) { Enable-Tunnel $selected; Update-TunnelRows; Update-ActionButtons }
})
$stopButton.Add_Click({
    $selected = Get-SelectedTunnel
    if ($null -ne $selected) { Disable-Tunnel $selected; Update-TunnelRows; Update-ActionButtons }
})
$startAllButton.Add_Click({ Start-AllTunnels })
$stopAllButton.Add_Click({ Stop-AllTunnels })
$copyButton.Add_Click({
    $selected = Get-SelectedTunnel
    if ($null -ne $selected) {
        try {
            $address = "127.0.0.1:$($selected.LocalPort)"
            if ($selected.Mode -eq 'Socks5') { $address = 'socks5://' + $address }
            [System.Windows.Forms.Clipboard]::SetText($address)
            Add-Log "已复制：$address"
        } catch { Add-Log '剪贴板正忙，请重试。' }
    }
})
$tunnelList.Add_DoubleClick({
    $selected = Get-SelectedTunnel
    if ($null -ne $selected -and -not $selected.ShouldRun) { Open-TunnelSettings $selected }
})
$deleteButton.Add_Click({
    $selected = Get-SelectedTunnel
    if ($null -eq $selected -or $selected.ShouldRun) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show("删除 [$($selected.Name)] 的本应用配置？不会影响旧版 V1 正在运行的任何隧道。", '确认删除', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Remove-TunnelPassword $selected
    [void]$script:tunnels.Remove($selected)
    Save-AppConfiguration
    Add-Log "[$($selected.Name)] 已删除本应用配置。"
    Refresh-TunnelList
})
$tunnelList.Add_SelectedIndexChanged({ Update-ActionButtons })

$form.Add_FormClosing({
    param($sender, $eventArgs)
    $isSystemShutdown = $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown -or $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::TaskManagerClosing
    if (-not $script:isExiting -and -not $isSystemShutdown) {
        $eventArgs.Cancel = $true
        $form.Hide()
        $form.ShowInTaskbar = $false
        if (-not $script:hasShownTrayHint) {
            $trayIcon.ShowBalloonTip(3000, 'VPS 隧道守护', '应用已在系统托盘后台运行。右键图标可显示窗口或退出。', [System.Windows.Forms.ToolTipIcon]::Info)
            $script:hasShownTrayHint = $true
        }
        return
    }
    $timer.Stop()
    foreach ($tunnel in @($script:tunnels)) {
        $tunnel.ShouldRun = $false
        Stop-Tunnel $tunnel
    }
    if ($null -ne $script:instanceLock) { $script:instanceLock.ReleaseMutex(); $script:instanceLock.Dispose(); $script:instanceLock = $null }
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    $trayMenu.Dispose()
    if ($null -ne $appIcon) { $appIcon.Dispose() }
})

Refresh-TunnelList
if ($script:allowLegacyMigration -and $script:tunnels.Count -gt 0) {
    Add-Log '已加载已保存配置；可点击全部启动。'
}
Add-Log '2.1 已就绪 · 全部启动 / 独立重连 · 鼠标悬停查看错误原因。'
if ($script:loadingWarning) { Add-Log $script:loadingWarning }
if (-not $TestMode) {
    $timer.Start()
    $form.Show()
    [System.Windows.Forms.Application]::Run($form)
}

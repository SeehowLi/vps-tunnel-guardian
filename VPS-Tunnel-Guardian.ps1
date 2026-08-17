#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GuardianDwmTheme
{
    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr windowHandle, int attribute, ref int attributeValue, int attributeSize);
}
'@

[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Stop'
$script:process = $null
$script:shouldRun = $false
$script:retryAt = [datetime]::MinValue
$script:startedAt = $null
$script:retrySeconds = 5
$script:sshPath = (Get-Command ssh.exe -ErrorAction Stop).Source
$script:configPath = Join-Path $PSScriptRoot 'settings.json'
$script:isExiting = $false
$script:hasShownTrayHint = $false

function New-TunnelConfiguration {
    param(
        [string]$SshUser = 'your-user',
        [string]$SshServer = 'ssh.example.com',
        [int]$LocalPort = 1081,
        [string]$TargetHost = 'target.example.com',
        [int]$TargetPort = 443,
        [int]$RetrySeconds = 5
    )

    [pscustomobject]@{
        SshUser      = $SshUser
        SshServer    = $SshServer
        LocalPort    = $LocalPort
        TargetHost   = $TargetHost
        TargetPort   = $TargetPort
        RetrySeconds = $RetrySeconds
    }
}

function Test-HostValue {
    param([string]$Value)
    return $Value -match '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$'
}

function Test-TunnelConfiguration {
    param($Configuration)

    if ($Configuration.SshUser -notmatch '^[A-Za-z0-9._-]+$') {
        return 'SSH 用户名只能包含字母、数字、点、下划线或连字符。'
    }
    foreach ($hostName in @($Configuration.SshServer, $Configuration.TargetHost)) {
        if (-not (Test-HostValue $hostName)) {
            return 'SSH 服务器和目标地址只能填写 IPv4 地址或普通主机名，且不能包含空格。'
        }
    }
    foreach ($port in @($Configuration.LocalPort, $Configuration.TargetPort)) {
        if ($port -lt 1 -or $port -gt 65535) {
            return '端口必须在 1 到 65535 之间。'
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

function Load-TunnelConfiguration {
    $defaults = New-TunnelConfiguration
    if (-not (Test-Path -LiteralPath $script:configPath)) {
        return $defaults
    }

    try {
        $stored = Get-Content -LiteralPath $script:configPath -Encoding utf8 -Raw | ConvertFrom-Json
        $candidate = New-TunnelConfiguration `
            -SshUser ([string](Get-ConfigurationValue $stored 'SshUser' $defaults.SshUser)) `
            -SshServer ([string](Get-ConfigurationValue $stored 'SshServer' $defaults.SshServer)) `
            -LocalPort ([int](Get-ConfigurationValue $stored 'LocalPort' $defaults.LocalPort)) `
            -TargetHost ([string](Get-ConfigurationValue $stored 'TargetHost' $defaults.TargetHost)) `
            -TargetPort ([int](Get-ConfigurationValue $stored 'TargetPort' $defaults.TargetPort)) `
            -RetrySeconds ([int](Get-ConfigurationValue $stored 'RetrySeconds' $defaults.RetrySeconds))
        if ($null -eq (Test-TunnelConfiguration $candidate)) {
            return $candidate
        }
    }
    catch {
        # Keep the application usable if a manually edited settings file is invalid.
    }
    return $defaults
}

function Save-TunnelConfiguration {
    $script:config | ConvertTo-Json | Set-Content -LiteralPath $script:configPath -Encoding utf8
}

$script:config = Load-TunnelConfiguration
$script:retrySeconds = $script:config.RetrySeconds

$form = New-Object System.Windows.Forms.Form
$form.Text = 'VPS Tunnel Guardian'
$form.ClientSize = New-Object System.Drawing.Size(620, 440)
$form.MinimumSize = New-Object System.Drawing.Size(620, 480)
$form.MaximumSize = New-Object System.Drawing.Size(620, 480)
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
    [void][GuardianDwmTheme]::DwmSetWindowAttribute($sender.Handle, 20, [ref]$enableDarkTitleBar, 4)
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

$logo = $null

$title = New-Object System.Windows.Forms.Label
$title.Text = 'VPS 隧道守护'
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 17, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(88, 19)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = '轻量守护 · 自动保活 · 断线重连'
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(91, 52)
$header.Controls.Add($subtitle)

$headerState = New-Object System.Windows.Forms.Label
$headerState.Text = '后台守护'
$headerState.ForeColor = [System.Drawing.Color]::FromArgb(96, 165, 250)
$headerState.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$headerState.AutoSize = $true
$headerState.Location = New-Object System.Drawing.Point(528, 38)
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

$connectionCard = New-Object System.Windows.Forms.Panel
$connectionCard.Location = New-Object System.Drawing.Point(20, 112)
$connectionCard.Size = New-Object System.Drawing.Size(580, 94)
$connectionCard.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$connectionCard.Add_Paint($cardBorderPaint)
$form.Controls.Add($connectionCard)

$statusCaption = New-Object System.Windows.Forms.Label
$statusCaption.Text = '隧道状态'
$statusCaption.AutoSize = $true
$statusCaption.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$statusCaption.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$statusCaption.Location = New-Object System.Drawing.Point(20, 16)
$connectionCard.Controls.Add($statusCaption)

$statusDot = New-Object System.Windows.Forms.Panel
$statusDot.Size = New-Object System.Drawing.Size(10, 10)
$statusDot.Location = New-Object System.Drawing.Point(21, 51)
$statusDot.BackColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
$connectionCard.Controls.Add($statusDot)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '已停止'
$statusLabel.AutoSize = $true
$statusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11.5, [System.Drawing.FontStyle]::Bold)
$statusLabel.Location = New-Object System.Drawing.Point(40, 43)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$connectionCard.Controls.Add($statusLabel)

$endpointCaption = New-Object System.Windows.Forms.Label
$endpointCaption.Text = '连接路径'
$endpointCaption.AutoSize = $true
$endpointCaption.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$endpointCaption.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$endpointCaption.Location = New-Object System.Drawing.Point(142, 16)
$connectionCard.Controls.Add($endpointCaption)

$endpointLabel = New-Object System.Windows.Forms.Label
$endpointLabel.Text = "127.0.0.1:$($script:config.LocalPort)  →  $($script:config.TargetHost):$($script:config.TargetPort)"
$endpointLabel.AutoEllipsis = $true
$endpointLabel.Size = New-Object System.Drawing.Size(260, 25)
$endpointLabel.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$endpointLabel.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$endpointLabel.Location = New-Object System.Drawing.Point(142, 46)
$connectionCard.Controls.Add($endpointLabel)

$settingsButton = New-Object System.Windows.Forms.Button
$settingsButton.Text = '配置'
$settingsButton.Location = New-Object System.Drawing.Point(410, 30)
$settingsButton.Size = New-Object System.Drawing.Size(70, 36)
$settingsButton.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$settingsButton.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$settingsButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$settingsButton.FlatStyle = 'Flat'
$settingsButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$connectionCard.Controls.Add($settingsButton)

$toggleButton = New-Object System.Windows.Forms.Button
$toggleButton.Text = '启动隧道'
$toggleButton.Location = New-Object System.Drawing.Point(490, 25)
$toggleButton.Size = New-Object System.Drawing.Size(72, 46)
$toggleButton.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$toggleButton.ForeColor = [System.Drawing.Color]::White
$toggleButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$toggleButton.FlatStyle = 'Flat'
$toggleButton.FlatAppearance.BorderSize = 0
$connectionCard.Controls.Add($toggleButton)

$activityCard = New-Object System.Windows.Forms.Panel
$activityCard.Location = New-Object System.Drawing.Point(20, 222)
$activityCard.Size = New-Object System.Drawing.Size(580, 168)
$activityCard.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$activityCard.Add_Paint($cardBorderPaint)
$form.Controls.Add($activityCard)

$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Text = '活动日志'
$logTitle.AutoSize = $true
$logTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$logTitle.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$logTitle.Location = New-Object System.Drawing.Point(16, 13)
$activityCard.Controls.Add($logTitle)

$logHint = New-Object System.Windows.Forms.Label
$logHint.Text = '实时记录连接与重连状态'
$logHint.AutoSize = $true
$logHint.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$logHint.Location = New-Object System.Drawing.Point(389, 15)
$activityCard.Controls.Add($logHint)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(11, 18, 32)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$logBox.BorderStyle = 'None'
$logBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$logBox.Location = New-Object System.Drawing.Point(16, 42)
$logBox.Size = New-Object System.Drawing.Size(548, 109)
$logBox.Anchor = 'Top, Left, Right'
$activityCard.Controls.Add($logBox)

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Text = 'SSH 每 30 秒保活 · 连续 3 次无响应自动重连 · 关闭窗口后仍在托盘运行'
$hintLabel.AutoSize = $true
$hintLabel.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$hintLabel.Location = New-Object System.Drawing.Point(21, 409)
$form.Controls.Add($hintLabel)

function Add-Log {
    param([string]$Message)

    if ($logBox.Lines.Count -gt 180) {
        $logBox.Lines = @($logBox.Lines | Select-Object -Last 160)
    }
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $logBox.AppendText("[$timestamp] $Message`r`n")
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
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

function Refresh-Endpoint {
    $endpointLabel.Text = "127.0.0.1:$($script:config.LocalPort)  →  $($script:config.TargetHost):$($script:config.TargetPort)"
}

function Set-ToggleButtonMode {
    param([bool]$IsRunning)

    if ($IsRunning) {
        $toggleButton.Text = '停止守护'
        $toggleButton.BackColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
        return
    }

    $toggleButton.Text = '启动隧道'
    $toggleButton.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
}

function Add-SettingsInput {
    param(
        [System.Windows.Forms.Form]$Dialog,
        [string]$Label,
        [int]$Top,
        [string]$Value
    )

    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = $Label
    $caption.AutoSize = $true
    $caption.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $caption.Location = New-Object System.Drawing.Point(20, $Top + 4)
    $Dialog.Controls.Add($caption)

    $input = New-Object System.Windows.Forms.TextBox
    $input.Text = $Value
    $input.Location = New-Object System.Drawing.Point(170, $Top)
    $input.Size = New-Object System.Drawing.Size(270, 26)
    $input.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $input.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $input.BorderStyle = 'FixedSingle'
    $Dialog.Controls.Add($input)
    return $input
}

function Open-TunnelSettings {
    if ($script:shouldRun) {
        [void][System.Windows.Forms.MessageBox]::Show(
            '请先停止当前隧道，再修改连接配置。',
            'VPS 隧道守护',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '隧道配置'
    $dialog.ClientSize = New-Object System.Drawing.Size(465, 330)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = 'CenterParent'
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    if ($null -ne $appIcon) {
        $dialog.Icon = $appIcon
    }

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = '保存后，下次点击“启动隧道”即使用新配置。'
    $intro.AutoSize = $true
    $intro.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $intro.Location = New-Object System.Drawing.Point(20, 15)
    $dialog.Controls.Add($intro)

    $sshUserInput = Add-SettingsInput $dialog 'SSH 用户名' 48 $script:config.SshUser
    $sshServerInput = Add-SettingsInput $dialog 'SSH 服务器 IP / 主机名' 84 $script:config.SshServer
    $localPortInput = Add-SettingsInput $dialog '本地监听端口' 120 ([string]$script:config.LocalPort)
    $targetHostInput = Add-SettingsInput $dialog '转发目标 IP / 主机名' 156 $script:config.TargetHost
    $targetPortInput = Add-SettingsInput $dialog '转发目标端口' 192 ([string]$script:config.TargetPort)
    $retrySecondsInput = Add-SettingsInput $dialog '断线重连间隔（秒）' 228 ([string]$script:config.RetrySeconds)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = '保存配置'
    $saveButton.Location = New-Object System.Drawing.Point(260, 278)
    $saveButton.Size = New-Object System.Drawing.Size(86, 32)
    $saveButton.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $saveButton.ForeColor = [System.Drawing.Color]::White
    $saveButton.FlatStyle = 'Flat'
    $saveButton.FlatAppearance.BorderSize = 0
    $dialog.Controls.Add($saveButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = '取消'
    $cancelButton.Location = New-Object System.Drawing.Point(354, 278)
    $cancelButton.Size = New-Object System.Drawing.Size(86, 32)
    $cancelButton.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $cancelButton.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $cancelButton.FlatStyle = 'Flat'
    $cancelButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $dialog.Controls.Add($cancelButton)

    $cancelButton.Add_Click({ $dialog.Close() })
    $saveButton.Add_Click({
        $localPort = 0
        $targetPort = 0
        $retrySeconds = 0
        if (-not [int]::TryParse($localPortInput.Text.Trim(), [ref]$localPort) -or
            -not [int]::TryParse($targetPortInput.Text.Trim(), [ref]$targetPort) -or
            -not [int]::TryParse($retrySecondsInput.Text.Trim(), [ref]$retrySeconds)) {
            [void][System.Windows.Forms.MessageBox]::Show('端口和重连间隔必须填写整数。', '配置无效')
            return
        }

        $candidate = New-TunnelConfiguration `
            -SshUser $sshUserInput.Text.Trim() `
            -SshServer $sshServerInput.Text.Trim() `
            -LocalPort $localPort `
            -TargetHost $targetHostInput.Text.Trim() `
            -TargetPort $targetPort `
            -RetrySeconds $retrySeconds
        $validationError = Test-TunnelConfiguration $candidate
        if ($null -ne $validationError) {
            [void][System.Windows.Forms.MessageBox]::Show($validationError, '配置无效')
            return
        }

        try {
            $script:config = $candidate
            $script:retrySeconds = $candidate.RetrySeconds
            Save-TunnelConfiguration
            Refresh-Endpoint
            Add-Log '配置已保存。'
            $dialog.Close()
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show("无法保存配置：$($_.Exception.Message)", '保存失败')
        }
    })

    [void]$dialog.ShowDialog($form)
}

function Set-Status {
    param(
        [string]$Text,
        [System.Drawing.Color]$Color
    )

    $statusLabel.Text = $Text
    $statusLabel.ForeColor = $Color
    $statusDot.BackColor = $Color
}

function Stop-Tunnel {
    if ($null -eq $script:process) {
        return
    }

    try {
        if (-not $script:process.HasExited) {
            $script:process.Kill()
            $script:process.WaitForExit(2000)
        }
    }
    catch {
        Add-Log "停止 SSH 时出现异常：$($_.Exception.Message)"
    }
    finally {
        $script:process.Dispose()
        $script:process = $null
        $script:startedAt = $null
    }
}

function Schedule-Retry {
    param([string]$Reason)

    $script:retryAt = (Get-Date).AddSeconds($script:retrySeconds)
    Set-Status "已断开，将在 $script:retrySeconds 秒后重连" ([System.Drawing.Color]::FromArgb(217, 119, 6))
    Add-Log "$Reason；$script:retrySeconds 秒后重试。"
}

function Start-Tunnel {
    if ($null -ne $script:process -and -not $script:process.HasExited) {
        return
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:sshPath
    $forward = "127.0.0.1:$($script:config.LocalPort):$($script:config.TargetHost):$($script:config.TargetPort)"
    $psi.Arguments = "-L $forward -C -N -o BatchMode=yes -o ConnectTimeout=15 -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 $($script:config.SshUser)@$($script:config.SshServer)"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    try {
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        if (-not $process.Start()) {
            throw 'ssh.exe 未能启动。'
        }
        $script:process = $process
        $script:startedAt = Get-Date
        Set-Status '隧道在线' ([System.Drawing.Color]::FromArgb(22, 163, 74))
        Add-Log "SSH 隧道已启动：127.0.0.1:$($script:config.LocalPort) → $($script:config.TargetHost):$($script:config.TargetPort)。"
    }
    catch {
        if ($null -ne $process) {
            $process.Dispose()
        }
        $script:process = $null
        Schedule-Retry "启动失败：$($_.Exception.Message)"
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if (-not $script:shouldRun) {
        return
    }

    if ($null -ne $script:process) {
        if ($script:process.HasExited) {
            $exitCode = $script:process.ExitCode
            $script:process.Dispose()
            $script:process = $null
            $script:startedAt = $null
            Schedule-Retry "SSH 已退出（退出码：$exitCode）"
        }
        elseif ($null -ne $script:startedAt) {
            $elapsed = (New-TimeSpan -Start $script:startedAt -End (Get-Date)).ToString('hh\:mm\:ss')
            Set-Status "隧道在线（$elapsed）" ([System.Drawing.Color]::FromArgb(22, 163, 74))
        }
    }
    elseif ((Get-Date) -ge $script:retryAt) {
        Start-Tunnel
    }
})

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showWindowItem = $trayMenu.Items.Add('显示窗口')
[void]$trayMenu.Items.Add('-')
$exitApplicationItem = $trayMenu.Items.Add('退出应用')

$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Text = 'VPS 隧道守护'
$trayIcon.Icon = if ($null -ne $appIcon) { $appIcon } else { [System.Drawing.SystemIcons]::Application }
$trayIcon.ContextMenuStrip = $trayMenu
$trayIcon.Visible = $true

$showWindowItem.Add_Click({ Show-ApplicationWindow })
$exitApplicationItem.Add_Click({ Exit-Application })
$trayIcon.Add_MouseDoubleClick({ Show-ApplicationWindow })

$settingsButton.Add_MouseEnter({
    $settingsButton.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $settingsButton.ForeColor = [System.Drawing.Color]::FromArgb(147, 197, 253)
})
$settingsButton.Add_MouseLeave({
    $settingsButton.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $settingsButton.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
})
$toggleButton.Add_MouseEnter({
    if ($script:shouldRun) {
        $toggleButton.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    }
    else {
        $toggleButton.BackColor = [System.Drawing.Color]::FromArgb(59, 130, 246)
    }
})
$toggleButton.Add_MouseLeave({ Set-ToggleButtonMode $script:shouldRun })

$toggleButton.Add_Click({
    if ($script:shouldRun) {
        $script:shouldRun = $false
        Stop-Tunnel
        Set-Status '已停止' ([System.Drawing.Color]::FromArgb(203, 213, 225))
        Add-Log '已由用户停止。'
        Set-ToggleButtonMode $false
        return
    }

    $script:shouldRun = $true
    $script:retryAt = [datetime]::MinValue
    Set-ToggleButtonMode $true
    Add-Log "开始守护，重连间隔为 $script:retrySeconds 秒。"
    Start-Tunnel
})

$settingsButton.Add_Click({ Open-TunnelSettings })

$form.Add_FormClosing({
    param($sender, $eventArgs)

    $isSystemShutdown = $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown -or
        $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::TaskManagerClosing
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

    $script:shouldRun = $false
    $timer.Stop()
    Stop-Tunnel
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    $trayMenu.Dispose()
    if ($null -ne $logo) {
        $logo.Dispose()
    }
    if ($null -ne $appIcon) {
        $appIcon.Dispose()
    }
})

Set-ToggleButtonMode $false
Add-Log '应用已就绪。点击“启动隧道”开始。'
$timer.Start()
$form.Show()
[System.Windows.Forms.Application]::Run($form)

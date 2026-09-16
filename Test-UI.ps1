#requires -Version 5.1
param([switch]$RenderOnly)
# Preview uses synthetic data, starts no SSH and never reads production settings.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\VPS-Tunnel-Guardian.ps1" -TestMode
$a = New-TunnelConfiguration -Name '浏览器代理' -SshUser demo -SshServer ssh.example.com -LocalPort 1082
$b = New-TunnelConfiguration -Name '服务转发' -Mode LocalForward -SshUser demo -SshServer ssh.example.com -LocalPort 1081
[void]$script:tunnels.Add($a); [void]$script:tunnels.Add($b)
Refresh-TunnelList
$form.Text += ' [界面预览]'
$form.Show()
if ($RenderOnly) {
    [System.Windows.Forms.Application]::DoEvents()
    $bitmap = [System.Drawing.Bitmap]::new($form.Width,$form.Height)
    try {
        $form.DrawToBitmap($bitmap, [System.Drawing.Rectangle]::new(0,0,$form.Width,$form.Height))
        $bitmap.Save((Join-Path $PSScriptRoot 'build\ui-preview.png'))
    } finally { $bitmap.Dispose(); $form.Dispose(); $trayIcon.Dispose() }
} else { [System.Windows.Forms.Application]::Run($form) }

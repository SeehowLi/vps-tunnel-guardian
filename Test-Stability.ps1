#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\VPS-Tunnel-Guardian.ps1" -TestMode
$testRoot = Join-Path $PSScriptRoot ('build\test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:configPath = Join-Path $testRoot 'settings.json'
$script:credentialsDirectory = Join-Path $testRoot 'credentials'
$script:askPassPath = Join-Path $PSScriptRoot 'build\SshAskPass.exe'
$script:logAvailable = $false
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function FreePort {
    $socket = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,0)
    $socket.Start()
    $port = $socket.LocalEndpoint.Port
    $socket.Stop()
    return $port
}
try {
    $compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $fake = Join-Path $testRoot 'FakeSsh.exe'
    & $compiler /nologo /target:exe "/out:$fake" "$PSScriptRoot\Test-FakeSsh.cs"
    Assert ($LASTEXITCODE -eq 0) 'Fake SSH compilation failed'
    $script:sshPath = $fake
    $a = New-TunnelConfiguration -Name A -SshUser test -SshServer example.com -LocalPort (FreePort)
    $b = New-TunnelConfiguration -Name B -Mode LocalForward -SshUser test -SshServer example.com -LocalPort (FreePort)
    [void]$script:tunnels.Add($a); [void]$script:tunnels.Add($b)
    Refresh-TunnelList
    Start-AllTunnels
    Assert ($a.ShouldRun -and $b.ShouldRun) 'Start all did not enable both entries'
    Update-TunnelState $a; Update-TunnelState $b
    Assert ($null -eq $a.ReadyAt) 'Must not claim ready merely because process started'
    Start-Sleep -Milliseconds 350
    Update-TunnelState $a; Update-TunnelState $b
    Assert ($null -ne $a.ReadyAt -and $null -ne $b.ReadyAt) 'Owned listeners did not become ready'
    $aPid = $a.Process.Id; $bPid = $b.Process.Id
    Start-AllTunnels
    Update-TunnelState $a; Update-TunnelState $b
    Assert ($a.Process.Id -eq $aPid -and $b.Process.Id -eq $bPid) 'Start all duplicated a running tunnel'
    $a.Process.Kill(); [void]$a.Process.WaitForExit(1000)
    Start-Sleep -Milliseconds 100
    Update-TunnelState $a
    Assert ($a.ShouldRun -and $a.Reconnects -eq 1 -and $null -eq $a.Process) 'Dropped tunnel not queued for recovery'
    Assert ($a.LastError -match 'fixture') 'SSH stderr not recorded'
    Assert (-not $b.Process.HasExited) 'Other tunnel disrupted'
    $a.RetryAt = 0; Update-TunnelState $a
    Start-Sleep -Milliseconds 250
    Update-TunnelState $a
    Assert ($a.Process.Id -ne $aPid -and $null -ne $a.ReadyAt) 'Recovery failed'
    Stop-AllTunnels
    Assert (-not $a.ShouldRun -and -not $b.ShouldRun -and $null -eq $a.Process -and $null -eq $b.Process) 'Stop all left a managed process'
    $occupied = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $a.LocalPort)
    $occupied.Start()
    try {
        Enable-Tunnel $a; Update-TunnelState $a
        Assert ($a.ShouldRun -and $null -eq $a.Process -and $a.LastError -match 'PID') 'Port collision must keep waiting without killing owner'
    } finally { $occupied.Stop() }
    $a.RetryAt = 0; Update-TunnelState $a
    Assert ($null -ne $a.Process) 'Port release did not allow recovery'
    Stop-AllTunnels
    for ($i=0; $i -lt 15; $i++) { Schedule-Retry $a 'retry test' }
    Assert ($a.RetryAt - $script:clock.Elapsed.TotalSeconds -le 61) 'Backoff exceeded cap'

    $password = 'test-only-' + [guid]::NewGuid().ToString('N')
    Save-TunnelPassword $a $password
    $a.UsePasswordAuthentication = $true
    Save-AppConfiguration
    $json = Get-Content -LiteralPath $script:configPath -Raw -Encoding utf8
    Assert (-not $json.Contains($password)) 'Plaintext password leaked into settings'
    Save-AppConfiguration # Exercises atomic replacement of an existing file.
    $psi = [System.Diagnostics.ProcessStartInfo]::new($script:askPassPath)
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.Arguments = '"test@example.com password:"'
    $psi.EnvironmentVariables['GUARDIAN_CREDENTIAL_FILE'] = Get-CredentialPath $a
    $helper = [System.Diagnostics.Process]::Start($psi)
    $answer = $helper.StandardOutput.ReadToEnd(); $helper.WaitForExit()
    Assert ($helper.ExitCode -eq 0 -and $answer -ceq $password) 'Real askpass prompt DPAPI round trip failed'
    $helper.Dispose()
    $psi.Arguments = '"Enter passphrase for key:"'
    $helper = [System.Diagnostics.Process]::Start($psi)
    $answer = $helper.StandardOutput.ReadToEnd(); $helper.WaitForExit()
    Assert ($helper.ExitCode -ne 0 -and $answer.Length -eq 0) 'Askpass answered an unrelated prompt'
    $helper.Dispose()
    Enable-Tunnel $a; Update-TunnelState $a
    Assert (-not $a.Process.StartInfo.Arguments.Contains($password)) 'Password exposed in SSH command line'
    Assert ($a.Process.StartInfo.EnvironmentVariables['GUARDIAN_CREDENTIAL_FILE'] -eq (Get-CredentialPath $a)) 'Credential path not passed to SSH child'
    Stop-AllTunnels
    $script:tunnels.Clear(); Load-AppConfiguration
    Assert ($script:tunnels.Count -eq 2) 'Config round trip lost profiles'
    # Exercise actual dialog save handlers in their modal function scope, without displaying or connecting.
    $source = Get-Content -LiteralPath "$PSScriptRoot\VPS-Tunnel-Guardian.ps1" -Raw -Encoding utf8
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$null)
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Open-TunnelSettings' }, $true).Extent.Text
    $saveProbe = @'
    if ($isNew) {
        $nameRow.Input.Text = 'Dialog test'
        $sshUserRow.Input.Text = 'test'
        $sshServerRow.Input.Text = 'example.com'
    } else { $nameRow.Input.Text = 'Dialog edited' }
    [void][System.Windows.Forms.Button].GetMethod('OnClick', [System.Reflection.BindingFlags]'NonPublic,Instance').Invoke($saveButton, @([System.EventArgs]::Empty))
    $dialog.Dispose()
'@
    Invoke-Expression $definition.Replace('[void]$dialog.ShowDialog($form)', $saveProbe)
    Open-TunnelSettings $null
    Assert ($script:tunnels.Count -eq 3) 'New dialog save handler failed'
    $saved = $script:tunnels[2]
    Open-TunnelSettings $saved
    Assert ($script:tunnels[2].Name -eq 'Dialog edited') 'Edit dialog save handler failed'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i=0; $i -lt 100; $i++) { [void][GuardianRuntime.Native]::Listeners() }
    $watch.Stop()
    Write-Output "PASS: multi-start idempotence, ready ownership, independent reconnect, collision recovery, capped backoff, atomic config, real askpass prompt. Native query average $([Math]::Round($watch.Elapsed.TotalMilliseconds/100,2)) ms."
} finally {
    Stop-AllTunnels
    $timer.Dispose(); $trayIcon.Dispose(); $trayMenu.Dispose(); $form.Dispose()
    $resolved = [System.IO.Path]::GetFullPath($testRoot)
    Assert ($resolved.StartsWith([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'build')) + '\')) 'Unsafe test cleanup path'
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

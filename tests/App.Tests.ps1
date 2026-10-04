# The whole app, in a process of its own, in development mode and without its window: it starts,
# its worker brings the simulated connection up, and Exit - as the tray menu's - stops the worker,
# which closes the AT port, and ends the process.

Describe 'Start-Fm350App' {
    It 'starts, connects, and exits cleanly when asked' {
        $local = Join-Path $TestDrive 'local'
        $runner = Join-Path $TestDrive 'run-app.ps1'
        $outputFile = Join-Path $TestDrive 'output.txt'
        $module = "$PSScriptRoot/../src/App/FibocomFm350.App.psd1"
        # Once the worker reports online, the runner exits as the tray menu's Exit does.
        Set-Content -LiteralPath $runner -Value @"
`$env:LOCALAPPDATA = '$local'
Import-Module '$module'
`$app = Get-Module FibocomFm350.App
`$timer = [System.Windows.Threading.DispatcherTimer]::new()
`$timer.Interval = [timespan]::FromMilliseconds(200)
`$timer.Add_Tick({ & `$app { if (`$script:App -and `$script:App.LastSnapshot -and `$script:App.LastSnapshot.State -eq 'Online') { Stop-App } } })
`$timer.Start()
Start-Fm350App -Simulated -Scenario Connect -Hidden
`$timer.Stop()
'exited'
"@
        $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-File', $runner `
            -RedirectStandardOutput $outputFile -PassThru -WindowStyle Hidden
        try {
            $process.WaitForExit(90000) | Should -BeTrue -Because 'the app ends once its worker has stopped'
        }
        finally {
            if (-not $process.HasExited) {
                $process.Kill()
            }
        }
        $process.ExitCode | Should -Be 0
        Get-Content -LiteralPath $outputFile | Should -Contain 'exited'

        $log = @(Get-ChildItem -Path "$local/fibocom-fm350-gl-windows-gui/simulated/logs" -Filter '*.log' | Get-Content)
        $expected = 'App started - simulated, scenario Connect', 'Worker 1 started', 'State \(start\) -> Online', 'Exiting', 'Worker 1 stopped', 'App stopped'
        $at = -1
        foreach ($line in $expected) {
            $found = @(for ($i = $at + 1; $i -lt $log.Count; $i++) { if ($log[$i] -match $line) { $i } }) | Select-Object -First 1
            $found | Should -Not -BeNullOrEmpty -Because "the log says '$line', after what came before"
            $at = $found
        }
        $log -match 'ERROR' | Should -BeNullOrEmpty
    }
}

Describe 'The tray menu' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
        Import-Module "$PSScriptRoot/../src/App/FibocomFm350.App.psd1" -Force
        $link = New-ModemWorkerLink
        $worker = New-ModemWorker -Link $link -Simulation (New-SimulatedDevice -Scenario Online) -DataFolder (Join-Path $TestDrive 'data')
        try {
            Invoke-ModemWorkerCycle -Worker $worker
            $script:snapshot = $link['Snapshot']
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $link
        }
    }

    AfterAll {
        Remove-Module FibocomFm350.App, FibocomFm350 -ErrorAction SilentlyContinue
    }

    It 'lists the network modes as it opens, the modem''s checked, and a click sends the mode chosen' {
        $link = New-ModemWorkerLink
        try {
            $items = & (Get-Module FibocomFm350.App) {
                param($snapshot, $link)
                $script:App = @{ LastSnapshot = $snapshot; Worker = @{ Link = $link }; ResumedAt = 0; Tray = New-AppTray }
                try {
                    Update-AppTrayMenu
                    $modes = $script:App.Tray.ContextMenuStrip.Items['NetworkMode']
                    $state = @($modes.DropDownItems | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Text = $_.Text; Checked = $_.Checked; Enabled = $_.Enabled } })
                    $modes.DropDownItems['LteOnly'].PerformClick()
                    [pscustomobject]@{ Text = $modes.Text; Items = $state }
                }
                finally {
                    $script:App.Tray.ContextMenuStrip.Dispose()
                    $script:App.Tray.Dispose()
                    $script:App = $null
                }
            } $script:snapshot $link
            $items.Text | Should -Be 'Network mode: 4G + 5G'
            $items.Items.Text | Should -Be @('4G + 5G', '4G only', '5G only (SA)')
            $items.Items.Checked | Should -Be @($true, $false, $false)
            $items.Items.Enabled | Should -Be @($false, $true, $true)
            $command = $null
            $link['Commands'].TryDequeue([ref]$command) | Should -BeTrue
            $command.Kind | Should -Be 'SetNetworkMode'
            $command.Parameter | Should -BeOfType ([hashtable])
            $command.Parameter['NetworkMode'] | Should -Be 'LteOnly'
            $command.Parameter.ContainsKey('LteBands') | Should -BeFalse -Because 'the bands stay as the settings have them'
        }
        finally {
            Close-ModemWorkerLink -Link $link
        }
    }
}

Describe 'Tray notifications' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
        Import-Module "$PSScriptRoot/../src/App/FibocomFm350.App.psd1" -Force
    }

    AfterAll {
        Remove-Module FibocomFm350.App, FibocomFm350 -ErrorAction SilentlyContinue
    }

    It 'shows a notice once the tray icon shows, and each notice once' {
        $notice = [pscustomobject]@{ Sender = 'Info'; Count = 2; Id = 1; Time = [DateTimeOffset]::Now }
        $snapshot = [pscustomobject]@{ MessageNotice = $notice; UsageNotice = $null }
        $shown = & (Get-Module FibocomFm350.App) {
            param($snapshot)
            $tray = [pscustomobject]@{ Visible = $false; Shown = [System.Collections.Generic.List[string]]::new() }
            $tray | Add-Member -MemberType ScriptMethod -Name ShowBalloonTip -Value { param($timeout, $title, $text, $icon) $this.Shown.Add("$timeout|$title|$text|$icon") }
            $script:App = @{ Tray = $tray; Shown = @{}; NoticeKind = $null }
            try {
                Show-AppNotice -Snapshot $snapshot
                $hidden = $tray.Shown.Count
                $tray.Visible = $true
                Show-AppNotice -Snapshot $snapshot
                Show-AppNotice -Snapshot $snapshot
                [pscustomobject]@{ Hidden = $hidden; Shown = [string[]]$tray.Shown; Kind = $script:App.NoticeKind }
            }
            finally {
                $script:App = $null
            }
        } $snapshot

        $shown.Hidden | Should -Be 0 -Because 'a notice the user can''t see waits'
        $shown.Shown | Should -Be @('10000|2 new messages|From Info|Info')
        $shown.Kind | Should -Be 'Messages'
    }
}

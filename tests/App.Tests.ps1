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

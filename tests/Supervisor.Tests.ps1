# The supervisor: when to replace a worker and how long to wait (pure); real worker runspaces on the
# simulated modem - started, stopped with the AT port closed, restarted without a write, ended by
# an error, abandoned while stuck; and the single instance, also after one that died holding it.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    Import-Module "$PSScriptRoot/../src/App/FibocomFm350.App.psd1" -Force

    function Get-WriteCommand {
        param($Modem)
        @($Modem.Received | Where-Object {
                $_ -match '=' -and $_ -notmatch '=\?$' -and $_ -notin 'AT+CMEE=1', 'AT+CLCK="SC",2', 'AT+CMGF=0', 'AT+CNMI=2,1,0,0,0', 'AT+CMGL=4' -and
                $_ -notmatch '^AT\+(CGCONTRDP|CGPADDR|GTDNS)='
            })
    }

    # Waits until -Condition holds, at most -TimeoutMs; returns whether it did.
    function Wait-Until {
        param([scriptblock] $Condition, [int] $TimeoutMs = 20000)
        $deadline = [Environment]::TickCount64 + $TimeoutMs
        while (-not (& $Condition)) {
            if ([Environment]::TickCount64 -ge $deadline) {
                return $false
            }
            Start-Sleep -Milliseconds 100
        }
        $true
    }

    # Stops a worker and waits until it is released.
    function Complete-TestWorker {
        param([object] $Worker)
        Stop-WorkerRunspace -Worker $Worker -Confirm:$false
        Wait-Until { Complete-WorkerRunspace -Worker $Worker } | Should -BeTrue
    }
}

AfterAll {
    Remove-Module FibocomFm350.App, FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Resolve-SupervisorAction' {
    It '<Name>: <Action>, wait <DelayMs> ms' -ForEach @(
        @{ Name = 'a worker that beats'; Arguments = @{ HeartbeatAgeMs = 900; UptimeMs = 60000; Failures = 0 }; Action = 'None'; Reason = $null; Failures = 0; DelayMs = 0 }
        @{ Name = 'silent for less than the limit'; Arguments = @{ HeartbeatAgeMs = 59000; UptimeMs = 60000; Failures = 0 }; Action = 'None'; Reason = $null; Failures = 0; DelayMs = 0 }
        @{ Name = 'silent beyond the limit'; Arguments = @{ HeartbeatAgeMs = 61000; UptimeMs = 120000; Failures = 0 }; Action = 'Replace'; Reason = 'Hung'; Failures = 1; DelayMs = 5000 }
        @{ Name = 'ended'; Arguments = @{ Ended = $true; UptimeMs = 30000; Failures = 0 }; Action = 'Restart'; Reason = 'Ended'; Failures = 1; DelayMs = 5000 }
        @{ Name = 'ended again soon after'; Arguments = @{ Ended = $true; UptimeMs = 30000; Failures = 1 }; Action = 'Restart'; Reason = 'Ended'; Failures = 2; DelayMs = 10000 }
        @{ Name = 'the fourth in a row'; Arguments = @{ Ended = $true; UptimeMs = 1000; Failures = 3 }; Action = 'Restart'; Reason = 'Ended'; Failures = 4; DelayMs = 40000 }
        @{ Name = 'many in a row: the longest wait'; Arguments = @{ Ended = $true; UptimeMs = 1000; Failures = 40 }; Action = 'Restart'; Reason = 'Ended'; Failures = 41; DelayMs = 300000 }
        @{ Name = 'ended after running for long: the count starts over'; Arguments = @{ Ended = $true; UptimeMs = 600000; Failures = 5 }; Action = 'Restart'; Reason = 'Ended'; Failures = 1; DelayMs = 5000 }
        @{ Name = 'ended while the app exits'; Arguments = @{ Ended = $true; UptimeMs = 1000; Failures = 0; Stopping = $true }; Action = 'None'; Reason = $null; Failures = 0; DelayMs = 0 }
        @{ Name = 'silent while the app exits'; Arguments = @{ HeartbeatAgeMs = 90000; UptimeMs = 120000; Failures = 0; Stopping = $true }; Action = 'None'; Reason = $null; Failures = 0; DelayMs = 0 }
        @{ Name = 'silent across a sleep, resumed a moment ago'; Arguments = @{ HeartbeatAgeMs = 3600000; UptimeMs = 4000000; Failures = 0; SinceResumeMs = 600 }; Action = 'None'; Reason = $null; Failures = 0; DelayMs = 0 }
        @{ Name = 'silent since well after the resume'; Arguments = @{ HeartbeatAgeMs = 3600000; UptimeMs = 4000000; Failures = 0; SinceResumeMs = 61000 }; Action = 'Replace'; Reason = 'Hung'; Failures = 1; DelayMs = 5000 }
        @{ Name = 'ended right after a resume'; Arguments = @{ Ended = $true; UptimeMs = 30000; Failures = 0; SinceResumeMs = 600 }; Action = 'Restart'; Reason = 'Ended'; Failures = 1; DelayMs = 5000 }
    ) {
        $decision = Resolve-SupervisorAction @Arguments
        $decision.Action | Should -Be $Action
        $decision.Reason | Should -Be $Reason
        $decision.Failures | Should -Be $Failures
        $decision.DelayMs | Should -Be $DelayMs
    }
}

Describe 'Worker runspaces' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
    }

    It 'starts a worker that brings the connection up, and stops it with the AT port closed' {
        $device = New-SimulatedDevice -Scenario Connect
        $worker = Start-WorkerRunspace -Generation 1 -Worker @{ Simulation = $device; DataFolder = $script:folder } -Confirm:$false
        try {
            Wait-Until { $worker.Link['Snapshot'] -and $worker.Link['Snapshot'].State -eq 'Online' } | Should -BeTrue
            $worker.Runspace.Name | Should -Be 'fm350-worker-1'
        }
        finally {
            Complete-TestWorker -Worker $worker
        }
        $device.Modem.Closed | Should -BeTrue
        $worker.Reason | Should -BeNullOrEmpty
        $worker.Runspace.RunspaceStateInfo.State | Should -Be 'Closed'
        { $worker.Link['Wake'].WaitOne(0) } | Should -Throw -Because 'the link was released'
    }

    It 'restarts a worker that attaches to the connection without a write' {
        $device = New-SimulatedDevice -Scenario Connect
        $first = Start-WorkerRunspace -Generation 1 -Worker @{ Simulation = $device; DataFolder = $script:folder } -Confirm:$false
        try {
            Wait-Until { $first.Link['Snapshot'] -and $first.Link['Snapshot'].State -eq 'Online' } | Should -BeTrue
        }
        finally {
            Complete-TestWorker -Worker $first
        }
        $last = $first.Link['Snapshot']
        $device.Modem.Received.Clear()

        $second = Start-WorkerRunspace -Generation 2 -Worker @{ Simulation = $device; DataFolder = $script:folder } -Previous $last -Confirm:$false
        try {
            Wait-Until { $second.Link['Snapshot'].Generation -eq 2 } | Should -BeTrue
            $snapshot = $second.Link['Snapshot']
            $snapshot.State | Should -Be 'Online'
            $snapshot.Version | Should -BeGreaterThan $last.Version
        }
        finally {
            Complete-TestWorker -Worker $second
        }
        Get-WriteCommand -Modem $device.Modem | Should -BeNullOrEmpty
    }

    It 'keeps the module path the app started with, which opening the runspace changes' {
        # As Start-Fm350App.ps1 sets it: this PowerShell's modules and Windows' own, no user folder.
        $saved = $env:PSModulePath
        $app = Get-Module FibocomFm350.App
        $kept = & $app { $script:ModulePath }
        $restricted = [IO.Path]::Combine($PSHOME, 'Modules') + [IO.Path]::PathSeparator + [IO.Path]::Combine([Environment]::GetFolderPath('System'), 'WindowsPowerShell\v1.0\Modules')
        & $app { param($path) $script:ModulePath = $path } $restricted
        $env:PSModulePath = $restricted
        try {
            $worker = Start-WorkerRunspace -Generation 1 -Worker @{ Simulation = (New-SimulatedDevice); DataFolder = $script:folder } -Confirm:$false
            try {
                $env:PSModulePath | Should -BeExactly $restricted -Because 'opening a runspace prefixes the user''s module folder, for the whole process'
                Wait-Until { $worker.Link['Snapshot'] -and $worker.Link['Snapshot'].State -eq 'Online' } | Should -BeTrue
                $env:PSModulePath | Should -BeExactly $restricted
            }
            finally {
                Complete-TestWorker -Worker $worker
            }
        }
        finally {
            $env:PSModulePath = $saved
            & $app { param($path) $script:ModulePath = $path } $kept
        }
    }

    It 'ends a worker whose every cycle fails, and says why' {
        $device = New-SimulatedDevice
        $worker = Start-WorkerRunspace -Generation 1 -Worker @{ Simulation = $device; DataFolder = $script:folder } -Confirm:$false
        Wait-Until { $worker.Link['Snapshot'] -and $worker.Link['Snapshot'].State -eq 'Online' } | Should -BeTrue
        # Broken under it, its port open: every cycle fails from now on.
        $worker.Link['Commands'] = $null
        Wait-Until { Complete-WorkerRunspace -Worker $worker } | Should -BeTrue
        $worker.Reason | Should -Not -BeNullOrEmpty
        $worker.Reason | Should -Not -Match 'EndInvoke' -Because 'the error itself is told, not its wrapper'
        $device.Modem.Closed | Should -BeTrue -Because 'the port is closed on the way out'
        $log = @(Get-ChildItem (Join-Path $script:folder 'logs') | Get-Content)
        $log -match 'Cycle failed \(3 in a row\)' | Should -Not -BeNullOrEmpty
    }

    It 'keeps working when its log can''t be written' {
        $file = Join-Path $TestDrive 'not-a-folder.txt'
        Set-Content -LiteralPath $file -Value ''
        $worker = Start-WorkerRunspace -Generation 1 -Worker @{ Simulation = (New-SimulatedDevice); DataFolder = (Join-Path $file 'data') } -Confirm:$false
        try {
            Wait-Until { $worker.Link['Snapshot'] -and $worker.Link['Snapshot'].State -eq 'Online' } | Should -BeTrue
        }
        finally {
            Complete-TestWorker -Worker $worker
        }
    }

    It 'abandons a worker stuck in a call, which ends when the call returns' {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $powershell = [powershell]::Create($runspace)
        [void]$powershell.AddScript({ Start-Sleep -Seconds 60 })
        $stuck = [pscustomobject]@{ Generation = 9; Link = (New-ModemWorkerLink); Runspace = $runspace; PowerShell = $powershell; Handle = $powershell.BeginInvoke(); Started = [Environment]::TickCount64 }
        Complete-WorkerRunspace -Worker $stuck | Should -BeFalse
        Stop-WorkerRunspace -Worker $stuck -Abandon -Confirm:$false
        Wait-Until { Complete-WorkerRunspace -Worker $stuck } -TimeoutMs 10000 | Should -BeTrue
    }

    It 'takes the errors and warnings a worker wrote, so that they don''t pile up' {
        $powershell = [powershell]::Create()
        [void]$powershell.AddScript({ Write-Error 'something failed'; Write-Warning 'something odd' })
        [void]$powershell.Invoke()
        $worker = [pscustomobject]@{ Generation = 3; PowerShell = $powershell }
        Receive-WorkerMessage -Worker $worker | Should -Be @('Worker 3 error: something failed', 'Worker 3 warning: something odd')
        Receive-WorkerMessage -Worker $worker | Should -BeNullOrEmpty
        $powershell.Dispose()
    }
}

Describe 'The single instance' {
    BeforeEach {
        $script:name = "fm350-test-$([guid]::NewGuid().ToString('N'))"
    }

    It 'is taken by the first, and a second launch signals it to show its window' {
        $first = Enter-AppInstance -Name $script:name
        try {
            $first.Owned | Should -BeTrue
            $first.ShowEvent.WaitOne(0) | Should -BeFalse
            # The second launch, on another thread: a mutex is held per thread.
            $appModule = "$PSScriptRoot/../src/App/FibocomFm350.App.psd1"
            $instanceName = $script:name
            $second = Start-ThreadJob -ScriptBlock {
                Import-Module $using:appModule
                (Enter-AppInstance -Name $using:instanceName).Owned
            } | Wait-Job | Receive-Job
            $second | Should -BeFalse
            $first.ShowEvent.WaitOne(0) | Should -BeTrue
        }
        finally {
            Exit-AppInstance -Instance $first
        }
    }

    It 'waits on an exit event of its session, which the installer signals' {
        $first = Enter-AppInstance -Name $script:name
        try {
            $first.ExitEvent.WaitOne(0) | Should -BeFalse
            $exit = $null
            [System.Threading.EventWaitHandle]::TryOpenExisting("Local\$script:name-exit", [ref]$exit) | Should -BeTrue
            [void]$exit.Set()
            $exit.Dispose()
            $first.ExitEvent.WaitOne(0) | Should -BeTrue
        }
        finally {
            Exit-AppInstance -Instance $first
        }
        $gone = $null
        [System.Threading.EventWaitHandle]::TryOpenExisting("Local\$script:name-exit", [ref]$gone) | Should -BeFalse -Because 'it is released on exit'
    }

    It 'lets a second launch without the first one''s rights exit quietly' {
        # The first instance, as if elevated: its mutex held on another thread, its show event
        # open to waiting only - signalling it is denied.
        $ready = Join-Path $TestDrive "$script:name.ready"
        $finish = Join-Path $TestDrive "$script:name.finish"
        $mutexName = "Global\$script:name"
        $holder = Start-ThreadJob -ScriptBlock {
            $mutex = [System.Threading.Mutex]::new($true, $using:mutexName)
            New-Item -Path $using:ready | Out-Null
            while (-not (Test-Path $using:finish)) { Start-Sleep -Milliseconds 50 }
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        }
        $security = [System.Security.AccessControl.EventWaitHandleSecurity]::new()
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $security.AddAccessRule([System.Security.AccessControl.EventWaitHandleAccessRule]::new($user, 'Synchronize', 'Allow'))
        $created = $false
        $show = [System.Threading.EventWaitHandleAcl]::Create($false, 'AutoReset', "Local\$script:name-show", [ref]$created, $security)
        try {
            Wait-Until { Test-Path $ready } | Should -BeTrue
            $instance = Enter-AppInstance -Name $script:name -ErrorAction Stop
            $instance.Owned | Should -BeFalse
        }
        finally {
            New-Item -Path $finish | Out-Null
            $holder | Wait-Job -Timeout 10 | Remove-Job -Force
            $show.Dispose()
        }
    }

    It 'is free again once the first has exited' {
        Exit-AppInstance -Instance (Enter-AppInstance -Name $script:name)
        $again = Enter-AppInstance -Name $script:name
        try {
            $again.Owned | Should -BeTrue
        }
        finally {
            Exit-AppInstance -Instance $again
        }
    }

    It 'is taken over from an instance that died holding it' {
        $ready = Join-Path $TestDrive "$script:name.ready"
        $finish = Join-Path $TestDrive "$script:name.finish"
        $command = "`$m = [System.Threading.Mutex]::new(`$true, 'Global\$script:name'); New-Item -Path '$ready' | Out-Null; while (-not (Test-Path '$finish')) { Start-Sleep -Milliseconds 50 }"
        $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', $command -PassThru -WindowStyle Hidden
        try {
            Wait-Until { Test-Path $ready } | Should -BeTrue
            # A handle of our own keeps the mutex alive, abandoned, once its owner is gone.
            $handle = [System.Threading.Mutex]::OpenExisting("Global\$script:name")
            New-Item -Path $finish | Out-Null
            $process.WaitForExit(10000) | Should -BeTrue
            $instance = Enter-AppInstance -Name $script:name
            try {
                $instance.Owned | Should -BeTrue
            }
            finally {
                Exit-AppInstance -Instance $instance
                $handle.Dispose()
            }
        }
        finally {
            if (-not $process.HasExited) {
                $process.Kill()
            }
        }
    }
}

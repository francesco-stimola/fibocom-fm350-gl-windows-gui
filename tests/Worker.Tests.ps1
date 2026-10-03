# The worker: its schedule (pure), its snapshots, and its cycles on the simulated modem - attaching
# without a write, a restarted worker that attaches, the user's commands, a port lost and found
# again by PnP under another COM number, a port held by another program, the heartbeat while the
# modem takes its time; health and recovery over time, scenario by scenario; and the whole loop in
# a runspace of its own.

BeforeDiscovery {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    $script:probe = & (Get-Module FibocomFm350) { $script:DataProbe }
}

BeforeAll {
    $script:modulePath = "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1"
    Import-Module $script:modulePath -Force
    $script:probe = & (Get-Module FibocomFm350) { $script:DataProbe }

    # Commands that change the modem's state; reads and the channel's own setup left out.
    function Get-WriteCommand {
        param($Modem)
        @($Modem.Received | Where-Object {
                $_ -match '=' -and $_ -notmatch '=\?$' -and $_ -notin 'AT+CMEE=1', 'AT+CLCK="SC",2' -and $_ -notmatch '^AT\+(CGCONTRDP|CGPADDR|GTDNS)='
            })
    }

    function ConvertTo-TestSecret {
        param([string] $Text)
        $secret = [securestring]::new()
        foreach ($character in $Text.ToCharArray()) { $secret.AppendChar($character) }
        $secret
    }

    # A worker on a simulated device, its files in the test drive, its clock $script:now.
    function Get-TestWorker {
        param([object] $Device, [hashtable] $Extra = @{})
        $script:link = New-ModemWorkerLink
        New-ModemWorker -Link $script:link -Simulation $Device -DataFolder $script:folder -Clock { $script:now } @Extra
    }

    # Sends a command and runs the cycle that carries it out.
    function Invoke-TestCommand {
        param([hashtable] $Worker, [string] $Kind, [hashtable] $Parameter = @{})
        $id = Send-ModemCommand -Link $Worker.Link -Kind $Kind -Parameter $Parameter
        Invoke-ModemWorkerCycle -Worker $Worker
        $Worker.Link['Snapshot'].Results | Where-Object Id -EQ $id
    }

    function Get-TestLog {
        Get-ChildItem -Path (Join-Path $script:folder 'logs') -Filter '*.log' | Get-Content
    }

    # The commands of the recovery steps R2-R5 the modem received, in order.
    function Get-RecoveryCommand {
        param($Modem)
        @($Modem.Received | Where-Object { $_ -in 'AT+CGACT=0,1', 'AT+COPS=2', 'AT+CFUN=4', 'AT+CFUN=15' })
    }

    # Runs cycles until -Until holds on the snapshot (or -Max cycles), the clock moving on as the
    # worker's wait says - or, with -Jump, straight to the next recovery decision while a check
    # fails and nothing is due at once: the passes in between would read the same. Returns what
    # each cycle published.
    function Invoke-TestCycle {
        param([hashtable] $Worker, [scriptblock] $Until = { $false }, [int] $Max = 50, [switch] $Jump)
        $trace = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $Max; $i++) {
            Invoke-ModemWorkerCycle -Worker $Worker
            $snapshot = $Worker.Link['Snapshot']
            $trace.Add([pscustomobject]@{
                    Now = $script:now; State = $snapshot.State; Reason = $snapshot.Reason
                    Recovery = $snapshot.Recovery.Status; Check = $snapshot.Recovery.Check; Step = $snapshot.Recovery.Step; DataPath = $snapshot.DataPath.Healthy
                })
            if (& $Until $snapshot) {
                break
            }
            $wait = [Math]::Max(1, $Worker.WaitMs)
            if ($Jump -and $Worker.WaitMs -gt 0 -and $snapshot.Recovery.Status -ne 'Healthy' -and $null -ne $Worker.RecoveryAt -and $Worker.RecoveryAt -gt $script:now) {
                $wait = $Worker.RecoveryAt - $script:now
            }
            $script:now += $wait
        }
        $trace.ToArray()
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Resolve-WorkerSchedule' {
    It '<Name>' -ForEach @(
        @{ Name = 'no port, never looked: a scan now'; Arguments = @{ Now = 1000 }; Scan = $true; Pass = $false; Status = $false; Wait = 0 }
        @{ Name = 'no port, looked 2 s ago: the next scan in 3 s'; Arguments = @{ Now = 10000; LastScan = 8000 }; Scan = $false; Pass = $false; Status = $false; Wait = 3000 }
        @{ Name = 'a port just opened: a pass now'; Arguments = @{ Now = 1000; PortOpen = $true; PassForced = $true; State = 'NoDevice' }; Scan = $false; Pass = $true; Status = $false; Wait = 0 }
        @{ Name = 'online, read lately: the status read next'; Arguments = @{ Now = 20000; LastPass = 10000; LastStatus = 19000; State = 'Online'; PortOpen = $true }; Scan = $false; Pass = $false; Status = $false; Wait = 4000 }
        @{ Name = 'online, the last pass 30 s ago: a pass and a status read now'; Arguments = @{ Now = 30000; LastPass = 0; State = 'Online'; PortOpen = $true }; Scan = $false; Pass = $true; Status = $true; Wait = 0 }
        @{ Name = 'on its way, the last pass 10 s ago: a pass now'; Arguments = @{ Now = 10000; LastPass = 0; LastStatus = 9000; State = 'Registered'; PortOpen = $true }; Scan = $false; Pass = $true; Status = $false; Wait = 0 }
        @{ Name = 'waiting for the user, the last pass 10 s ago: no pass yet'; Arguments = @{ Now = 10000; LastPass = 0; LastStatus = 9000; State = 'Registered'; Blocked = $true; PortOpen = $true }; Scan = $false; Pass = $false; Status = $false; Wait = 4000 }
        @{ Name = 'the SIM not ready: no status read'; Arguments = @{ Now = 1000; LastPass = 0; State = 'Identified'; Blocked = $true; PortOpen = $true }; Scan = $false; Pass = $false; Status = $false; Wait = 29000 }
        @{ Name = 'a pass asked for: at once, whatever the last one'; Arguments = @{ Now = 1000; LastPass = 1000; LastStatus = 1000; State = 'Online'; PortOpen = $true; PassForced = $true }; Scan = $false; Pass = $true; Status = $false; Wait = 0 }
        @{ Name = 'a port open: no scan'; Arguments = @{ Now = 100000; LastPass = 99000; LastStatus = 99000; State = 'Online'; PortOpen = $true }; Scan = $false; Pass = $false; Status = $false; Wait = 4000 }
        @{ Name = 'no adapter found, never looked again: a look now'; Arguments = @{ Now = 10000; LastPass = 9000; LastStatus = 9000; State = 'DataActive'; Blocked = $true; PortOpen = $true; AdapterMissing = $true }; Scan = $false; Pass = $false; Status = $false; AdapterLook = $true; Wait = 0 }
        @{ Name = 'no adapter found, looked 2 s ago: the next look in 3 s'; Arguments = @{ Now = 10000; LastPass = 9000; LastStatus = 9000; LastAdapterLook = 8000; State = 'DataActive'; Blocked = $true; PortOpen = $true; AdapterMissing = $true }; Scan = $false; Pass = $false; Status = $false; AdapterLook = $false; Wait = 3000 }
        @{ Name = 'the adapter there: no look'; Arguments = @{ Now = 10000; LastPass = 9000; LastStatus = 9000; State = 'Online'; PortOpen = $true }; Scan = $false; Pass = $false; Status = $false; AdapterLook = $false; Wait = 4000 }
    ) {
        $schedule = Resolve-WorkerSchedule @Arguments
        $schedule.Scan | Should -Be $Scan
        $schedule.Pass | Should -Be $Pass
        $schedule.Status | Should -Be $Status
        $schedule.WaitMs | Should -Be $Wait
        if ($null -ne $AdapterLook) {
            $schedule.AdapterLook | Should -Be $AdapterLook
        }
    }

    It 'probes the data path: <Name>' -ForEach @(
        # Pass and status read just done: the next of those 5 s away, so a nearer probe shows.
        @{ Name = 'a settled address never probed: now'; Arguments = @{ ProbeWanted = $true; ProbeNotBefore = 100000 }; Probe = $true; Wait = 0 }
        @{ Name = 'an address just set: once settled'; Arguments = @{ ProbeWanted = $true; ProbeNotBefore = 103000 }; Probe = $false; Wait = 3000 }
        @{ Name = 'a round passed: the next after the interval'; Arguments = @{ ProbeWanted = $true; LastProbe = 100000 - $script:probe.IntervalMs + 2000 }; Probe = $false; Wait = 2000 }
        @{ Name = 'a round failed: the next after the retry interval'; Arguments = @{ ProbeWanted = $true; ProbeFailed = $true; LastProbe = 100000 - $script:probe.RetryMs + 1000 }; Probe = $false; Wait = 1000 }
        @{ Name = 'a round failed long enough ago: now'; Arguments = @{ ProbeWanted = $true; ProbeFailed = $true; LastProbe = 100000 - $script:probe.RetryMs }; Probe = $true; Wait = 0 }
        @{ Name = 'nothing to probe'; Arguments = @{ LastProbe = 0 }; Probe = $false; Wait = 5000 }
        @{ Name = 'a recovery decision due sooner'; Arguments = @{ RecoveryAt = 101500 }; Probe = $false; Wait = 1500 }
        @{ Name = 'a recovery decision overdue'; Arguments = @{ RecoveryAt = 90000 }; Probe = $false; Wait = 0 }
    ) {
        $schedule = Resolve-WorkerSchedule -Now 100000 -LastPass 100000 -LastStatus 100000 -State 'Online' -PortOpen @Arguments
        $schedule.Probe | Should -Be $Probe
        $schedule.WaitMs | Should -Be $Wait
    }

    It 'probes nothing without an open port' {
        $schedule = Resolve-WorkerSchedule -Now 100000 -LastScan 99000 -ProbeWanted -ProbeNotBefore 0
        $schedule.Probe | Should -BeFalse
        $schedule.WaitMs | Should -Be 4000
    }
}

Describe 'Invoke-ModemWorkerCycle' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
        $script:now = 100000
    }

    Context 'attaching and connecting' {
        It 'attaches to a connection that is up: no write, online, one snapshot' {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $snapshot = $script:link['Snapshot']
            $snapshot.State | Should -Be 'Online'
            $snapshot.Version | Should -Be 1
            $snapshot.Radio.Technology | Should -Be '5G NSA'
            Get-WriteCommand -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'brings a registered modem online: defines and activates the context, configures the adapter' {
            $device = New-SimulatedDevice -Scenario Connect
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $script:link['Snapshot'].State | Should -Be 'Online'
            Get-WriteCommand -Modem $device.Modem | Should -Be @('AT+CGDCONT=1,"IPV4V6",""', 'AT+CGACT=1,1')
            $device.Adapter.Read().Gateways | Should -Be @('0.0.0.0')
        }

        It 'restarted, attaches without a write; its snapshots go on from the last one' {
            $device = New-SimulatedDevice -Scenario Connect
            $first = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $first
            $last = $script:link['Snapshot']
            Close-ModemWorker -Worker $first
            $device.Modem.Received.Clear()

            $second = Get-TestWorker -Device $device -Extra @{ Previous = $last; Generation = 2 }
            Invoke-ModemWorkerCycle -Worker $second
            $snapshot = $script:link['Snapshot']
            $snapshot.State | Should -Be 'Online'
            $snapshot.Dropped | Should -BeFalse
            $snapshot.Generation | Should -Be 2
            $snapshot.Version | Should -Be ($last.Version + 1)
            $snapshot.StateSince | Should -Be $last.StateSince
            Get-WriteCommand -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'reads only, and takes no step, when it only observes' {
            $device = New-SimulatedDevice -Scenario Connect
            $worker = Get-TestWorker -Device $device -Extra @{ ObserveOnly = $true }
            Invoke-ModemWorkerCycle -Worker $worker
            $snapshot = $script:link['Snapshot']
            $snapshot.Action | Should -Be 'DefineContext'
            $snapshot.ObserveOnly | Should -BeTrue
            Get-WriteCommand -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'says what blocks the connection: <Scenario> -> <Reason>' -ForEach @(
            @{ Scenario = 'ApnNeeded'; State = 'Registered'; Reason = 'ApnNeeded' }
            @{ Scenario = 'PinRequired'; State = 'Identified'; Reason = 'NoPin' }
            @{ Scenario = 'FccLocked'; State = 'SimReady'; Reason = 'FccLocked' }
            @{ Scenario = 'AdapterDisabled'; State = 'DataActive'; Reason = 'AdapterDisabled' }
            @{ Scenario = 'NoDevice'; State = 'NoDevice'; Reason = 'NoDevice' }
            @{ Scenario = 'NoDriver'; State = 'NoDevice'; Reason = 'NoDriver' }
        ) {
            $device = New-SimulatedDevice -Scenario $Scenario
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $snapshot = $script:link['Snapshot']
            $snapshot.State | Should -Be $State
            $snapshot.Reason | Should -Be $Reason
            $snapshot.Blocked | Should -BeTrue
            Get-WriteCommand -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'waits the scan interval for a modem that is not there' {
            $worker = Get-TestWorker -Device (New-SimulatedDevice -Scenario NoDevice)
            Invoke-ModemWorkerCycle -Worker $worker
            $worker.WaitMs | Should -Be 5000
            Invoke-ModemWorkerCycle -Worker $worker
            $script:link['Snapshot'].Version | Should -Be 1 -Because 'nothing was due, so nothing was published'
        }
    }

    Context 'snapshots' {
        It 'are new objects that never change once published' {
            $device = New-SimulatedDevice -Scenario ApnNeeded
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $first = $script:link['Snapshot']
            $before = $first | ConvertTo-Json -Depth 8
            $settings = (ConvertTo-AppSetting -InputObject @{ Apn = 'internet' }).Settings
            [void](Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = $settings })
            $second = $script:link['Snapshot']
            $second.State | Should -Be 'Online'
            [object]::ReferenceEquals($first, $second) | Should -BeFalse
            $first | ConvertTo-Json -Depth 8 | Should -Be $before
        }

        It 'carry no secret and no identifier' {
            $device = New-SimulatedDevice -Scenario PinRequired
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            [void](Invoke-TestCommand -Worker $worker -Kind SaveSimPin -Parameter @{ Pin = ConvertTo-TestSecret '1234' })
            $settings = (ConvertTo-AppSetting -InputObject @{ ApnAuthentication = 'PAP'; ApnUser = 'user' }).Settings
            [void](Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = $settings; ApnPassword = ConvertTo-TestSecret 'apn-secret' })
            $snapshot = $script:link['Snapshot']
            $snapshot.Sim.PinStored | Should -BeTrue
            $snapshot.ApnPasswordStored | Should -BeTrue
            $json = $snapshot | ConvertTo-Json -Depth 8
            $json | Should -Not -Match '1234'
            $json | Should -Not -Match 'apn-secret'
            $json | Should -Not -Match '8900100000000000000' -Because 'the ICCID stays in the worker'
            $json | Should -Not -Match 'ABCD' -Because 'cells carry no location'
            $json | Should -Not -Match 'System.Security.SecureString'
        }

        It 'keep the last ten command results' {
            $worker = Get-TestWorker -Device (New-SimulatedDevice -Scenario Online)
            Invoke-ModemWorkerCycle -Worker $worker
            $ids = foreach ($i in 1..12) { Send-ModemCommand -Link $script:link -Kind ConnectNow }
            Invoke-ModemWorkerCycle -Worker $worker
            $results = $script:link['Snapshot'].Results
            $results.Count | Should -Be 10
            $results.Id | Should -Be @($ids | Select-Object -Last 10)
        }
    }

    Context 'the user''s commands' {
        It 'saves the APN the user gives, and the next pass brings the connection up' {
            $device = New-SimulatedDevice -Scenario ApnNeeded
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $settings = (ConvertTo-AppSetting -InputObject @{ Apn = 'internet' }).Settings
            $result = Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = $settings }
            $result.Result | Should -Be 'Done'
            (Get-Content (Join-Path $script:folder 'settings.json') -Raw | ConvertFrom-Json).Apn | Should -Be 'internet'
            $script:link['Snapshot'].Settings.Apn | Should -Be 'internet'
            $script:link['Snapshot'].State | Should -Be 'Online'
            Get-WriteCommand -Modem $device.Modem | Should -Be @('AT+CGACT=0,1', 'AT+CGDCONT=1,"IPV4V6","internet"', 'AT+CGACT=1,1')
        }

        It 'refuses invalid settings, and says why' {
            $worker = Get-TestWorker -Device (New-SimulatedDevice -Scenario Online)
            Invoke-ModemWorkerCycle -Worker $worker
            $result = Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = @{ InterfaceMetric = 0 } }
            $result.Result | Should -Be 'Failed'
            $result.Detail | Should -Match 'InterfaceMetric'
            Test-Path (Join-Path $script:folder 'settings.json') | Should -BeFalse
        }

        It 'stores the APN password, and an empty one deletes it' {
            $worker = Get-TestWorker -Device (New-SimulatedDevice -Scenario Online)
            Invoke-ModemWorkerCycle -Worker $worker
            $settings = $script:link['Snapshot'].Settings
            [void](Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = $settings; ApnPassword = ConvertTo-TestSecret 'pass' })
            $script:link['Snapshot'].ApnPasswordStored | Should -BeTrue
            [void](Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = $settings; ApnPassword = [securestring]::new() })
            $script:link['Snapshot'].ApnPasswordStored | Should -BeFalse
        }

        It 'stores the PIN with its SIM, which the next pass enters once' {
            $device = New-SimulatedDevice -Scenario PinRequired
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $result = Invoke-TestCommand -Worker $worker -Kind SaveSimPin -Parameter @{ Pin = ConvertTo-TestSecret '1234' }
            $result.Result | Should -Be 'Done'
            $script:link['Snapshot'].State | Should -Be 'Online'
            @($device.Modem.Received | Where-Object { $_ -like 'AT+CPIN=*' }).Count | Should -Be 1
        }

        It 'never tries a rejected PIN again, and says it was rejected' {
            $device = New-SimulatedDevice -Scenario PinRequired
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            [void](Invoke-TestCommand -Worker $worker -Kind SaveSimPin -Parameter @{ Pin = ConvertTo-TestSecret '0000' })
            foreach ($i in 1..3) {
                [void](Invoke-TestCommand -Worker $worker -Kind ConnectNow)
            }
            $snapshot = $script:link['Snapshot']
            $snapshot.Sim.PinRejected | Should -BeTrue
            $snapshot.Sim.PinStored | Should -BeFalse
            $snapshot.Reason | Should -Be 'NoPin'
            @($device.Modem.Received | Where-Object { $_ -like 'AT+CPIN=*' }).Count | Should -Be 1
        }

        It 'forgets the stored PIN' {
            $device = New-SimulatedDevice -Scenario PinRequired
            $worker = Get-TestWorker -Device $device
            $device.Modem.SetAnswer('AT+CPIN?', @('+CPIN: READY', 'OK'))
            Invoke-ModemWorkerCycle -Worker $worker
            [void](Invoke-TestCommand -Worker $worker -Kind SaveSimPin -Parameter @{ Pin = ConvertTo-TestSecret '1234' })
            $script:link['Snapshot'].Sim.PinStored | Should -BeTrue
            (Invoke-TestCommand -Worker $worker -Kind ForgetSimPin).Result | Should -Be 'Done'
            $script:link['Snapshot'].Sim.PinStored | Should -BeFalse
        }

        It 'turns the SIM''s PIN request off when asked, and reads it again' {
            $device = New-SimulatedDevice -Scenario PinRequired
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            [void](Invoke-TestCommand -Worker $worker -Kind SaveSimPin -Parameter @{ Pin = ConvertTo-TestSecret '1234' })
            $script:link['Snapshot'].Sim.PinRequestOn | Should -BeTrue
            $result = Invoke-TestCommand -Worker $worker -Kind DisableSimPin -Parameter @{ Pin = ConvertTo-TestSecret '1234' }
            $result.Result | Should -Be 'Disabled'
            $script:link['Snapshot'].Sim.PinRequestOn | Should -BeFalse
        }

        It 'unlocks an FCC-locked modem when asked: it restarts, comes back and connects' {
            $device = New-SimulatedDevice -Scenario FccLocked
            $device.AwayMs = 0
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $result = Invoke-TestCommand -Worker $worker -Kind UnlockFcc
            $result.Result | Should -Be 'Restarted'
            Invoke-ModemWorkerCycle -Worker $worker
            $script:link['Snapshot'].State | Should -Be 'Online'
            Get-WriteCommand -Modem $device.Modem | Should -Be @('AT+GTFCCLOCKMODE=0', 'AT+GTFCCLOCKSTATE=0', 'AT+GTFCCEFFSTATUS=0,0', 'AT+CFUN=1,1')
            @(Get-TestLog) -match 'AT port SIMULATED lost' | Should -Not -BeNullOrEmpty
        }

        It 'enables the adapter the user disabled, only when asked' {
            $device = New-SimulatedDevice -Scenario AdapterDisabled
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            foreach ($i in 1..2) {
                [void](Invoke-TestCommand -Worker $worker -Kind ConnectNow)
            }
            $device.Adapter.Status | Should -Be 'Disabled'
            (Invoke-TestCommand -Worker $worker -Kind EnableAdapter).Result | Should -Be 'Done'
            $script:link['Snapshot'].State | Should -Be 'Online'
        }

        It 'refuses what writes while it only observes: <Kind>' -ForEach @(
            @{ Kind = 'DisableSimPin'; Scenario = 'Online' }
            @{ Kind = 'UnlockFcc'; Scenario = 'FccLocked' }
            @{ Kind = 'EnableAdapter'; Scenario = 'AdapterDisabled' }
        ) {
            $device = New-SimulatedDevice -Scenario $Scenario
            $worker = Get-TestWorker -Device $device -Extra @{ ObserveOnly = $true }
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind $Kind -Parameter @{ Pin = ConvertTo-TestSecret '1234' }).Result | Should -Be 'Refused'
            Get-WriteCommand -Modem $device.Modem | Should -BeNullOrEmpty
            if ($Scenario -eq 'AdapterDisabled') {
                $device.Adapter.Status | Should -Be 'Disabled'
            }
        }

        It 'says there is no modem for what needs one' {
            $worker = Get-TestWorker -Device (New-SimulatedDevice -Scenario NoDevice)
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SaveSimPin -Parameter @{ Pin = ConvertTo-TestSecret '1234' }).Result | Should -Be 'NoModem'
        }

        It 'logs a command without its secret' {
            $worker = Get-TestWorker -Device (New-SimulatedDevice -Scenario PinRequired)
            Invoke-ModemWorkerCycle -Worker $worker
            [void](Invoke-TestCommand -Worker $worker -Kind SaveSimPin -Parameter @{ Pin = ConvertTo-TestSecret '1234' })
            $log = @(Get-TestLog)
            $log -match 'Command SaveSimPin: Done' | Should -Not -BeNullOrEmpty
            ($log -join "`n") | Should -Not -Match '1234'
        }
    }

    Context 'what changes under it' {
        It 'runs a failed pass again at the retry, not at its next interval' {
            $worker = Get-TestWorker -Device (New-SimulatedDevice -Scenario Online)
            Mock -ModuleName FibocomFm350 Invoke-ModemConnect { throw 'The pass failed.' }
            { Invoke-ModemWorkerCycle -Worker $worker -ErrorAction Stop } | Should -Throw '*pass failed*'
            $worker.LastPass | Should -BeNullOrEmpty
            $worker.PassForced | Should -BeTrue
            (Resolve-WorkerSchedule -Now $script:now -LastPass $worker.LastPass -PortOpen -State 'Online').Pass | Should -BeTrue
        }

        It 'forgets the signal once the state drops below a ready SIM' {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $script:link['Snapshot'].Radio | Should -Not -BeNullOrEmpty
            # The modem restarted and its SIM now waits for its PIN.
            $device.Modem.SetAnswer('AT+CPIN?', @('+CPIN: SIM PIN', 'OK'))
            [void](Invoke-TestCommand -Worker $worker -Kind ConnectNow)
            $snapshot = $script:link['Snapshot']
            $snapshot.Reason | Should -Be 'NoPin'
            $snapshot.Radio | Should -BeNullOrEmpty
        }

        It 'brings the pass forward when the modem stops answering the status read' {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $script:now += 5000
            $device.Modem.Script('AT+CESQ', @{ NoFinal = $true })
            Invoke-ModemWorkerCycle -Worker $worker
            $script:link['Snapshot'].Radio.Answered | Should -BeFalse
            $worker.PassForced | Should -BeTrue
            $worker.WaitMs | Should -Be 0
            @($device.Modem.Received | Where-Object { $_ -eq 'AT+CLCK="SC",2' }).Count | Should -Be 1 -Because 'nothing more is asked of a modem that doesn''t answer'
        }
    }

    Context 'unsolicited codes' {
        It 'brings the next pass forward when the modem reports a context change' {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $script:now += 5000
            $device.Modem.EmitUnsolicited('+CGEV: ME PDN DEACT 1', 0)
            Invoke-ModemWorkerCycle -Worker $worker
            $worker.LastPass | Should -Be 100000 -Because 'the status read came first'
            $worker.WaitMs | Should -Be 0
            Invoke-ModemWorkerCycle -Worker $worker
            $worker.LastPass | Should -Be 105000
        }
    }
}

Describe 'Health and recovery on the simulated modem' {
    BeforeAll {
        $script:timings = & (Get-Module FibocomFm350) { $script:RecoveryTimings }
    }

    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
        $script:now = 100000
    }

    Context 'the data path (H7)' {
        It 'takes a path that settles for no failure: an address still tentative, then a lost round' {
            $device = New-SimulatedDevice -Scenario Settling
            $worker = Get-TestWorker -Device $device
            $trace = Invoke-TestCycle -Worker $worker -Until { param($s) $s.DataPath.Healthy -eq $true }
            $trace[-1].DataPath | Should -BeTrue
            @($trace | Where-Object State -NE 'Online') | Should -BeNullOrEmpty
            @($trace | Where-Object Recovery -NE 'Healthy') | Should -BeNullOrEmpty
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
            $log = @(Get-TestLog)
            @($log -match 'not usable yet \(Tentative\)').Count | Should -Be 2
            @($log -match 'Data path: no reply').Count | Should -Be 1
            $log -match 'no traffic gets through' | Should -BeNullOrEmpty
        }

        It 'probes from the address the adapter carries, at the interval once proven' {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            [void](Invoke-TestCycle -Worker $worker -Until { param($s) $s.DataPath.Healthy -eq $true })
            $worker.Probe.Address | Should -Be '192.0.2.10'
            $proven = $worker.Probe.LastAt
            [void](Invoke-TestCycle -Worker $worker -Until { $worker.Probe.LastAt -ne $proven })
            $worker.Probe.LastAt - $proven | Should -Be $script:probe.IntervalMs
        }

        It 'restarts the data context when no traffic gets through, and goes no further once it does' {
            $device = New-SimulatedDevice -Scenario DataPathDown
            $worker = Get-TestWorker -Device $device
            $trace = Invoke-TestCycle -Worker $worker -Max 60 -Until { param($s) $s.Recovery.Step -eq 'R2' -and $s.DataPath.Healthy -eq $true }
            $trace[-1].State | Should -Be 'Online'
            $step = [array]::IndexOf($trace, ($trace | Where-Object Reason -EQ 'DataPathFailed' | Select-Object -First 1))
            $trace[$step].Recovery | Should -Be 'Recovering'
            # The rounds that failed before the step don't count for the context it brought up,
            # and the first round after it waits the settle time.
            $trace[$step + 1].State | Should -Be 'Online'
            $trace[$step + 1].DataPath | Should -BeNullOrEmpty
            $firstRound = $trace | Select-Object -Skip ($step + 1) | Where-Object { $null -ne $_.DataPath } | Select-Object -First 1
            $firstRound.Now - $trace[$step].Now | Should -BeGreaterOrEqual $script:probe.SettleMs
            Get-RecoveryCommand -Modem $device.Modem | Should -Be @('AT+CGACT=0,1')
            $writes = Get-WriteCommand -Modem $device.Modem
            $writes[-1] | Should -Be 'AT+CGACT=1,1' -Because 'the pass right after the step activates the context again'
            @(Get-TestLog) -match 'Recovery: H7 fails - step R2: Done' | Should -Not -BeNullOrEmpty
        }

        It 'never takes a path that hasn''t answered once since the app started for a failure: a network that drops ICMP' {
            $device = New-SimulatedDevice -Scenario IcmpDropped
            $worker = Get-TestWorker -Device $device
            $trace = Invoke-TestCycle -Worker $worker -Max 60
            @($trace | Where-Object State -NE 'Online') | Should -BeNullOrEmpty
            @($trace | Where-Object { $_.Recovery -ne 'Healthy' }) | Should -BeNullOrEmpty
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
            $script:link['Snapshot'].DataPath.Result | Should -Be 'Failed'
            $script:link['Snapshot'].DataPath.Proven | Should -BeFalse
            @(Get-TestLog | Where-Object { $_ -match 'may drop ICMP' }).Count | Should -Be 1 -Because 'it is said once'
        }

        It 'carries a path proven once to the worker that replaces this one' {
            $device = New-SimulatedDevice -Scenario DataPathDown
            $first = Get-TestWorker -Device $device
            [void](Invoke-TestCycle -Worker $first -Until { param($s) $s.DataPath.Healthy -eq $true })
            $last = $script:link['Snapshot']
            $last.DataPath.Proven | Should -BeTrue
            Close-ModemWorker -Worker $first
            $second = Get-TestWorker -Device $device -Extra @{ Previous = $last; Generation = 2 }
            $trace = Invoke-TestCycle -Worker $second -Max 40 -Until { param($s) $s.Recovery.Status -eq 'Recovering' }
            $trace[-1].Step | Should -Be 'R2' -Because 'the path failed after it had worked, under either worker'
        }

        It 'takes one lost round for no failure' {
            $device = New-SimulatedDevice -Scenario Online
            $device.LostRounds = 1
            $worker = Get-TestWorker -Device $device
            $trace = Invoke-TestCycle -Worker $worker -Until { param($s) $s.DataPath.Healthy -eq $true }
            @($trace | Where-Object State -NE 'Online') | Should -BeNullOrEmpty
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
        }
    }

    Context 'up the ladder' {
        It 'leaves a lost registration to the pass for its grace time, then re-registers (R3), then turns the radio off and on (R4)' {
            $device = New-SimulatedDevice -Scenario RegistrationLost
            $worker = Get-TestWorker -Device $device
            $trace = Invoke-TestCycle -Worker $worker -Jump -Until { param($s) $s.State -eq 'Online' }
            $trace[-1].State | Should -Be 'Online'
            Get-RecoveryCommand -Modem $device.Modem | Should -Be @('AT+COPS=2', 'AT+CFUN=4')
            $first = $trace | Where-Object Step -EQ 'R3' | Select-Object -First 1
            $first.Now - $trace[0].Now | Should -Be $script:timings.Grace['H4']
            $second = $trace | Where-Object Step -EQ 'R4' | Select-Object -First 1
            $second.Now - $first.Now | Should -Be $script:timings.Settle['R3']
            # The pass took the steps back up: automatic selection after R3, the radio on after R4.
            $writes = Get-WriteCommand -Modem $device.Modem
            $writes | Should -Contain 'AT+COPS=0'
            $writes | Should -Contain 'AT+CFUN=1'
        }

        It 'restarts the USB device of a modem that doesn''t answer (R6), its port closed first' {
            $saved = & (Get-Module FibocomFm350) { $script:AtMinimumTimeoutMs }
            & (Get-Module FibocomFm350) { $script:AtMinimumTimeoutMs = 200 }
            try {
                $device = New-SimulatedDevice -Scenario ModemHung
                $device.AwayMs = 0
                $worker = Get-TestWorker -Device $device
                $trace = Invoke-TestCycle -Worker $worker -Jump -Until { param($s) $s.State -eq 'Online' }
                $trace[0].State | Should -Be 'PortOpen'
                $trace[-1].State | Should -Be 'Online'
                ($trace | Where-Object Step -EQ 'R6' | Select-Object -First 1).Now - $trace[0].Now | Should -Be $script:timings.Grace['H2']
                $log = @(Get-TestLog)
                $closed = [array]::IndexOf($log, @($log -match 'closed to restart the USB device')[0])
                $restarted = [array]::IndexOf($log, @($log -match 'step R6: Done')[0])
                $closed | Should -BeGreaterThan -1
                $restarted | Should -BeGreaterThan $closed
            }
            finally {
                & (Get-Module FibocomFm350) { param($value) $script:AtMinimumTimeoutMs = $value } $saved
            }
        }

        It 'runs its cycles, waits longer after each, then keeps to the slow cadence' {
            $device = New-SimulatedDevice -Scenario Unrecoverable
            $device.AwayMs = 0
            $worker = Get-TestWorker -Device $device
            $cycles = $script:timings.Backoff.Count + 1
            $trace = Invoke-TestCycle -Worker $worker -Jump -Max 200 -Until { param($s) $s.Recovery.Cycles -ge $cycles }
            $trace[-1].Recovery | Should -Be 'SlowCadence'
            @(Get-RecoveryCommand -Modem $device.Modem | Where-Object { $_ -eq 'AT+CFUN=15' }).Count | Should -Be $cycles
            # Each cycle starts with its entry step, R3, the backoff after the one before.
            $starts = @($trace | Where-Object { $_.Step -eq 'R3' -and $_.Recovery -eq 'Recovering' })
            $starts.Count | Should -Be $cycles
            $ends = @($trace | Where-Object { $_.Recovery -in 'Waiting', 'SlowCadence' } | Group-Object { [int]($_.Now) } | ForEach-Object { $_.Group[0] })
            for ($i = 1; $i -lt $cycles; $i++) {
                $backoff = $script:timings.Backoff[[Math]::Min($i, $script:timings.Backoff.Count) - 1]
                $starts[$i].Now - $starts[$i - 1].Now | Should -BeGreaterOrEqual $backoff
            }
            $ends | Should -Not -BeNullOrEmpty
            @(Get-TestLog) -match 'Recovery: \d+ cycles didn''t mend H4' | Should -Not -BeNullOrEmpty
        }
    }

    Context 'what is never escalated' {
        It '<Scenario>: <Reason>, two hours long, no recovery step' -ForEach @(
            @{ Scenario = 'ApnNeeded'; Reason = 'ApnNeeded' }
            @{ Scenario = 'PinRequired'; Reason = 'NoPin' }
            @{ Scenario = 'FccLocked'; Reason = 'FccLocked' }
            @{ Scenario = 'AdapterDisabled'; Reason = 'AdapterDisabled' }
            @{ Scenario = 'NoDevice'; Reason = 'NoDevice' }
        ) {
            $device = New-SimulatedDevice -Scenario $Scenario
            $worker = Get-TestWorker -Device $device
            foreach ($i in 1..13) {
                Invoke-ModemWorkerCycle -Worker $worker
                $script:now += 600000
            }
            $snapshot = $script:link['Snapshot']
            $snapshot.Reason | Should -Be $Reason
            $snapshot.Recovery.Status | Should -Be 'Blocked'
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
            if ($Scenario -eq 'AdapterDisabled') {
                $device.Adapter.Status | Should -Be 'Disabled'
            }
        }

        It 'names the step it would take, and takes none, while it only observes' {
            $device = New-SimulatedDevice -Scenario DataPathDown
            $worker = Get-TestWorker -Device $device -Extra @{ ObserveOnly = $true }
            $trace = Invoke-TestCycle -Worker $worker -Max 40 -Until { param($s) $s.Recovery.Status -eq 'Withheld' }
            $trace[-1].Recovery | Should -Be 'Withheld'
            $trace[-1].Step | Should -Be 'R2'
            Get-WriteCommand -Modem $device.Modem | Should -BeNullOrEmpty
            @(Get-TestLog) -match 'step R2 withheld' | Should -Not -BeNullOrEmpty
        }

        It 'opens a maintenance window for the FCC unlock: the modem restarting is no failure' {
            $device = New-SimulatedDevice -Scenario FccLocked
            $device.AwayMs = 0
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind UnlockFcc).Result | Should -Be 'Restarted'
            # Back from the restart, it doesn't find a network for a while.
            $device.Modem.SetAnswer('AT+CEREG?;+C5GREG?', @('+CEREG: 0,2', '+C5GREG: 0', 'OK'))
            $device.Modem.SetAnswer('AT+CGACT?', @('OK'))
            $window = $script:timings.Settle['R5']
            $trace = Invoke-TestCycle -Worker $worker -Jump -Max 30 -Until { param($s) $s.Recovery.Status -eq 'Recovering' }
            @($trace | Where-Object { $_.Recovery -eq 'Maintenance' }).Count | Should -BeGreaterThan 0
            @($trace | Where-Object { $_.Recovery -eq 'Maintenance' -and $_.Now -ge 100000 + $window }) | Should -BeNullOrEmpty
            ($trace | Where-Object Recovery -EQ 'Recovering' | Select-Object -First 1).Now | Should -BeGreaterOrEqual (100000 + $window + $script:timings.Grace['H4'])
            Get-RecoveryCommand -Modem $device.Modem | Should -Be @('AT+COPS=2')
        }
    }

    Context 'what a step must not do' {
        It 'never escalates a data context it can''t read' {
            $device = New-SimulatedDevice -Scenario Online
            $device.Modem.SetAnswer('AT+CGACT?', @('+CME ERROR: 100'))
            $worker = Get-TestWorker -Device $device
            foreach ($i in 1..7) {
                Invoke-ModemWorkerCycle -Worker $worker
                $script:now += 600000
            }
            $snapshot = $script:link['Snapshot']
            $snapshot.Reason | Should -Be 'ContextUnknown'
            $snapshot.Recovery.Status | Should -Be 'Watching'
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'never resets a modem whose SIM would then wait for a PIN the app doesn''t have' {
            $device = New-SimulatedDevice -Scenario Unrecoverable
            $device.Modem.SetAnswer('AT+CLCK="SC",2', @('+CLCK: 1', 'OK'))
            $worker = Get-TestWorker -Device $device
            $trace = Invoke-TestCycle -Worker $worker -Jump -Max 60 -Until { param($s) $s.Recovery.Cycles -ge 1 }
            $trace[-1].Recovery | Should -Be 'Waiting'
            $worker.PinRequestOn | Should -BeTrue
            Get-RecoveryCommand -Modem $device.Modem | Should -Be @('AT+COPS=2', 'AT+CFUN=4')
        }

        It 'doesn''t count a step that found no modem to act on: the port went since the state was read' {
            $device = New-SimulatedDevice -Scenario DataPathDown
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            InModuleScope FibocomFm350 -Parameters @{ Worker = $worker } {
                param($Worker)
                Close-WorkerChannel -Worker $Worker -Why 'lost'
                $Worker.State = 'DataActive'
                $Worker.Decision = [pscustomobject]@{ State = 'DataActive'; Action = 'None'; Reason = 'DataPathFailed'; Blocked = $false; Dropped = $false; SettingsPending = $false }
                Invoke-WorkerRecovery -Worker $Worker
            }
            $worker.Recovery.Step | Should -BeNullOrEmpty
            $worker.RecoveryView.Status | Should -Be 'Watching'
            @(Get-TestLog) -match 'step R2: NoModem' | Should -Not -BeNullOrEmpty
            # Found again, the path still down: R2 is taken, not R3.
            $script:now += 1000
            $trace = Invoke-TestCycle -Worker $worker -Max 60 -Until { param($s) $s.Recovery.Status -eq 'Recovering' }
            $trace[-1].Step | Should -Be 'R2'
        }

        It 'publishes the step before taking it: a worker that replaces a hung one gives it its settle time' {
            $device = New-SimulatedDevice -Scenario DataPathDown
            $worker = Get-TestWorker -Device $device
            $script:published = $null
            Mock -ModuleName FibocomFm350 Invoke-RecoveryStep {
                $script:published = $script:link['Snapshot'].Recovery
                [pscustomobject]@{ Step = $Step; Result = 'Done'; Commands = [object[]]@() }
            }
            [void](Invoke-TestCycle -Worker $worker -Max 20 -Until { $null -ne $script:published })
            $script:published.Status | Should -Be 'Recovering'
            $script:published.Step | Should -Be 'R2'
            $script:published.History.Step | Should -Be 'R2'
        }
    }

    Context 'continuity' {
        It 'carries on up the ladder in a worker that replaces the one that took the last step' {
            $device = New-SimulatedDevice -Scenario DataPathDown
            $first = Get-TestWorker -Device $device
            [void](Invoke-TestCycle -Worker $first -Until { param($s) $s.Recovery.Step -eq 'R2' })
            # R2 didn't mend it this time.
            $device.Modem.Flags['DataPath'] = 'Down'
            $last = $script:link['Snapshot']
            Close-ModemWorker -Worker $first
            $second = Get-TestWorker -Device $device -Extra @{ Previous = $last; Generation = 2 }
            $trace = Invoke-TestCycle -Worker $second -Jump -Max 40 -Until { param($s) $s.Recovery.Step -eq 'R3' }
            $trace[-1].Step | Should -Be 'R3'
            @(Get-RecoveryCommand -Modem $device.Modem) | Should -Be @('AT+CGACT=0,1', 'AT+COPS=2')
        }

        It 'gives a failing check its grace time again after the computer slept' {
            $device = New-SimulatedDevice -Scenario RegistrationLost
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $script:now += $script:timings.Grace['H4'] - 1000
            $worker.Resumed = $true
            Invoke-ModemWorkerCycle -Worker $worker
            $script:now += 2000
            Invoke-ModemWorkerCycle -Worker $worker
            $script:link['Snapshot'].Recovery.Status | Should -Be 'Watching'
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
            @(Get-TestLog) -match 'Resumed after a pause' | Should -Not -BeNullOrEmpty
        }

        It 'publishes what recovery is doing, with clock times' {
            $device = New-SimulatedDevice -Scenario RegistrationLost
            $worker = Get-TestWorker -Device $device
            [void](Invoke-TestCycle -Worker $worker -Jump -Until { param($s) $s.Recovery.Step -eq 'R3' })
            $recovery = $script:link['Snapshot'].Recovery
            $recovery.Status | Should -BeIn 'Recovering', 'Settling'
            $recovery.Check | Should -Be 'H4'
            $recovery.StepTime | Should -BeOfType [DateTimeOffset]
            $recovery.NextTime | Should -BeOfType [DateTimeOffset]
            ($recovery.NextTime - $recovery.StepTime).TotalMilliseconds | Should -BeGreaterOrEqual ($script:timings.Settle['R3'] - 1000)
            $recovery.History.Step | Should -Be 'R3'
        }
    }
}

Describe 'The network mode on the simulated modem' {
    BeforeAll {
        $script:timings = & (Get-Module FibocomFm350) { $script:RecoveryTimings }
        $script:modeData = (Import-PowerShellDataFile -Path "$PSScriptRoot/../src/FibocomFm350/Data/Simulation.psd1").NetworkMode
        # The writes of AT+GTACT the modem received.
        function Get-ModeWrite {
            param($Modem)
            @($Modem.Received | Where-Object { $_ -match '^AT\+GTACT=[^?]' })
        }
        function Save-TestSetting {
            param([hashtable] $Values)
            Export-AppSetting -Path (Join-Path $script:folder 'settings.json') -Settings $Values -Confirm:$false
        }
        function Get-SavedSetting {
            (Import-AppSetting -Path (Join-Path $script:folder 'settings.json')).Settings
        }
        # What the simulated modem reads in automatic mode once registered: every band, n77 dropped.
        $script:automatic = 'AT+GTACT=20,6,3,' + ((@($script:modeData.Bands.UMTS) + @($script:modeData.Bands.LTE) + @($script:modeData.Bands.NR)) -join ',')
        $script:lteOnly = 'AT+GTACT=2,3,3,' + (@($script:modeData.Supported.LTE) -join ',')
    }

    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
        $script:now = 100000
    }

    Context 'keeping the mode the settings ask' {
        It 'leaves the modem''s mode alone while the settings don''t manage it, and shows it' {
            $device = New-SimulatedDevice -Scenario LteOnlyMode
            $worker = Get-TestWorker -Device $device
            [void](Invoke-TestCycle -Worker $worker -Max 10)
            Get-ModeWrite -Modem $device.Modem | Should -BeNullOrEmpty
            $mode = $script:link['Snapshot'].NetworkMode
            $mode.Current.Mode | Should -Be 'LteOnly'
            $mode.Decision.Managed | Should -BeFalse
            $mode.Support.Modes | Should -Be @('Automatic', 'LteOnly', 'NrOnly')
            @($device.Modem.Received | Where-Object { $_ -eq 'AT+GTACT=?' }).Count | Should -Be 1 -Because 'what the modem supports is read once per channel'
        }

        It 'never writes a mode the modem keeps: automatic, n77 left out by the modem' {
            Save-TestSetting @{ NetworkMode = 'Automatic' }
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            $trace = Invoke-TestCycle -Worker $worker -Max 20
            Get-ModeWrite -Modem $device.Modem | Should -BeNullOrEmpty
            @($trace | Where-Object State -NE 'Online') | Should -BeNullOrEmpty
            $mode = $script:link['Snapshot'].NetworkMode
            $mode.Decision.Satisfied | Should -BeTrue
            $mode.Decision.Missing.Nr | Should -Be @(77)
        }

        It 'writes the mode the settings ask over the modem''s once, in a maintenance window, and comes back online without a recovery step' {
            Save-TestSetting @{ NetworkMode = 'Automatic' }
            $device = New-SimulatedDevice -Scenario LteOnlyMode
            $worker = Get-TestWorker -Device $device
            $trace = Invoke-TestCycle -Worker $worker -Jump -Max 60 -Until { param($s) $s.State -eq 'Online' -and $s.Recovery.Status -eq 'Healthy' -and $s.NetworkMode.Current.Mode -eq 'Automatic' }
            $trace[-1].State | Should -Be 'Online'
            Get-ModeWrite -Modem $device.Modem | Should -Be @('AT+GTACT=20,6,3,' + ((@($script:modeData.Supported.LTE) + @($script:modeData.Supported.NR)) -join ','))
            @($trace | Where-Object { $_.Recovery -notin 'Healthy', 'Maintenance' }) | Should -BeNullOrEmpty
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
            $script:link['Snapshot'].Radio.Technology | Should -Be '5G NSA'
            # n77 is gone from the list once the modem registered: that is no reason to write again.
            [void](Invoke-TestCycle -Worker $worker -Max 10)
            @(Get-ModeWrite -Modem $device.Modem).Count | Should -Be 1
            @(Get-TestLog) -match 'ApplyNetworkMode: Done' | Should -Not -BeNullOrEmpty
        }

        It 'never writes again a mode the modem doesn''t keep' {
            Save-TestSetting @{ NetworkMode = 'LteOnly' }
            $device = New-SimulatedDevice -Scenario Online
            $device.Modem.Script($script:lteOnly, @{ Lines = @('OK'); Keep = $true })
            $worker = Get-TestWorker -Device $device
            [void](Invoke-TestCycle -Worker $worker -Jump -Max 30)
            Get-ModeWrite -Modem $device.Modem | Should -Be @($script:lteOnly)
            $script:link['Snapshot'].NetworkMode.Decision.Problem | Should -Be 'NotKept'
            @(Get-TestLog | Where-Object { $_ -match 'Network mode: not as the settings ask \(NotKept\)' }).Count | Should -Be 1
        }

        It 'remembers a write the modem refused: the context comes up, nothing escalates, the write is not repeated' {
            Save-TestSetting @{ NetworkMode = 'Automatic' }
            $device = New-SimulatedDevice -Scenario LteOnlyMode
            $device.Modem.SetAnswer('AT+CGACT?', @('OK'))
            $write = 'AT+GTACT=20,6,3,' + ((@($script:modeData.Supported.LTE) + @($script:modeData.Supported.NR)) -join ',')
            $device.Modem.Script($write, @{ Lines = @('ERROR'); Keep = $true })
            $worker = Get-TestWorker -Device $device
            $trace = Invoke-TestCycle -Worker $worker -Jump -Max 30
            Get-ModeWrite -Modem $device.Modem | Should -Be @($write)
            $device.Modem.Received | Should -Contain 'AT+CGACT=1,1'
            $trace[-1].State | Should -Be 'Online'
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
            $script:link['Snapshot'].NetworkMode.Decision.Problem | Should -Be 'NotKept'
        }

        It 'takes no recovery step on a narrowed mode while its setting can''t be read' {
            Save-TestSetting @{ NetworkMode = 'NrOnly' }
            $device = New-SimulatedDevice -Scenario Standalone
            $worker = Get-TestWorker -Device $device
            [void](Invoke-TestCycle -Worker $worker -Jump -Max 40 -Until { param($s) $s.State -eq 'Online' -and $s.Recovery.Status -eq 'Healthy' })
            $device.Modem.NetworkMode.Standalone = $false
            $device.Modem.SetAnswer('AT+CEREG?;+C5GREG?', [string[]]$script:modeData.Registration.Searching)
            $device.Modem.SetAnswer('AT+CGACT?', @('OK'))
            $device.Modem.Script('AT+GTACT?', @{ Lines = @('ERROR'); Keep = $true })
            foreach ($i in 1..13) {
                Invoke-ModemWorkerCycle -Worker $worker
                $script:now += 600000
            }
            $script:link['Snapshot'].NetworkMode.Decision.Satisfied | Should -BeNullOrEmpty
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'writes nothing while it only observes' {
            Save-TestSetting @{ NetworkMode = 'Automatic' }
            $device = New-SimulatedDevice -Scenario LteOnlyMode
            $worker = Get-TestWorker -Device $device -Extra @{ ObserveOnly = $true }
            Invoke-ModemWorkerCycle -Worker $worker
            $script:link['Snapshot'].Action | Should -Be 'ApplyNetworkMode'
            Get-ModeWrite -Modem $device.Modem | Should -BeNullOrEmpty
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'LteOnly' }).Result | Should -Be 'Refused'
            Get-ModeWrite -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'takes no recovery step for a network a narrowed mode doesn''t find: 5G SA gone' {
            Save-TestSetting @{ NetworkMode = 'NrOnly' }
            $device = New-SimulatedDevice -Scenario Standalone
            $worker = Get-TestWorker -Device $device
            [void](Invoke-TestCycle -Worker $worker -Jump -Max 40 -Until { param($s) $s.State -eq 'Online' -and $s.Recovery.Status -eq 'Healthy' })
            $script:link['Snapshot'].Radio.Technology | Should -Be '5G SA'
            # The 5G SA network goes away.
            $device.Modem.NetworkMode.Standalone = $false
            $device.Modem.SetAnswer('AT+CEREG?;+C5GREG?', [string[]]$script:modeData.Registration.Searching)
            $device.Modem.SetAnswer('AT+CGACT?', @('OK'))
            foreach ($i in 1..13) {
                Invoke-ModemWorkerCycle -Worker $worker
                $script:now += 600000
            }
            $snapshot = $script:link['Snapshot']
            $snapshot.State | Should -Be 'SimReady'
            $snapshot.Recovery.Check | Should -Be 'H4'
            $snapshot.Recovery.Status | Should -Be 'Watching'
            $snapshot.NetworkMode.Decision.Narrowed | Should -BeTrue
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
        }
    }

    Context 'a mode the user chooses' {
        It 'writes it at once, tries it, and saves it once the modem registers with it' {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $result = Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'LteOnly' }
            $result.Result | Should -Be 'Applied'
            $result.Detail | Should -Be $script:lteOnly
            $script:link['Snapshot'].NetworkMode.Trial.Selection.NetworkMode | Should -Be 'LteOnly'
            (Get-SavedSetting).NetworkMode | Should -Be '' -Because 'it is saved once the modem has found a network with it'
            $trace = Invoke-TestCycle -Worker $worker -Jump -Max 40 -Until { param($s) -not $s.NetworkMode.Trial -and $s.State -eq 'Online' }
            $snapshot = $script:link['Snapshot']
            $snapshot.NetworkMode.Notice.Kind | Should -Be 'Kept'
            (Get-SavedSetting).NetworkMode | Should -Be 'LteOnly'
            $snapshot.Radio.Technology | Should -Not -BeLike '5G*'
            Get-ModeWrite -Modem $device.Modem | Should -Be @($script:lteOnly)
            @($trace | Where-Object { $_.Recovery -notin 'Healthy', 'Maintenance' }) | Should -BeNullOrEmpty
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'undoes a mode that finds no network - 5G only without 5G SA -, writing back what the modem had, each code as read' {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $applied = $script:now
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'NrOnly' }).Result | Should -Be 'Applied'
            $trace = Invoke-TestCycle -Worker $worker -Jump -Max 60 -Until { param($s) $s.NetworkMode.Notice -and $s.State -eq 'Online' }
            $snapshot = $script:link['Snapshot']
            $snapshot.NetworkMode.Notice.Kind | Should -Be 'Reverted'
            $snapshot.NetworkMode.Notice.Mode | Should -Be 'NrOnly'
            $writes = Get-ModeWrite -Modem $device.Modem
            $writes.Count | Should -Be 2
            $writes[0] | Should -BeLike 'AT+GTACT=14,6,6,*'
            $writes[1] | Should -Be $script:automatic -Because 'the setting before goes back as read, UMTS codes and all'
            $reverted = $trace | Where-Object { $_.State -ne 'Online' } | Select-Object -Last 1
            $reverted.Now - $applied | Should -BeGreaterOrEqual $script:timings.Maintenance
            (Get-SavedSetting).NetworkMode | Should -Be ''
            @($trace | Where-Object { $_.Recovery -notin 'Healthy', 'Maintenance' }) | Should -BeNullOrEmpty
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
            @(Get-TestLog) -match 'Network mode NrOnly: no network' | Should -Not -BeNullOrEmpty
        }

        It 'registers on 5G SA where there is one' {
            $device = New-SimulatedDevice -Scenario Standalone
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'NrOnly' }).Result | Should -Be 'Applied'
            [void](Invoke-TestCycle -Worker $worker -Jump -Max 40 -Until { param($s) -not $s.NetworkMode.Trial -and $s.State -eq 'Online' })
            $script:link['Snapshot'].NetworkMode.Notice.Kind | Should -Be 'Kept'
            $script:link['Snapshot'].Radio.Technology | Should -Be '5G SA'
        }

        It 'keeps the mode on trial against the saved one: the pass doesn''t undo it' {
            Save-TestSetting @{ NetworkMode = 'Automatic' }
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'LteOnly' }).Result | Should -Be 'Applied'
            [void](Invoke-TestCycle -Worker $worker -Jump -Max 40 -Until { param($s) -not $s.NetworkMode.Trial -and $s.State -eq 'Online' })
            Get-ModeWrite -Modem $device.Modem | Should -Be @($script:lteOnly)
            (Get-SavedSetting).NetworkMode | Should -Be 'LteOnly'
        }

        It 'goes back to the setting before the first change, after two changes on trial' {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'LteOnly' }).Result | Should -Be 'Applied'
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'NrOnly' }).Result | Should -Be 'Applied'
            [void](Invoke-TestCycle -Worker $worker -Jump -Max 60 -Until { param($s) $s.NetworkMode.Notice -and $s.State -eq 'Online' })
            (Get-ModeWrite -Modem $device.Modem)[-1] | Should -Be $script:automatic
        }

        It 'carries a mode on trial to the worker that replaces this one, which undoes it' {
            $device = New-SimulatedDevice -Scenario Online
            $first = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $first
            (Invoke-TestCommand -Worker $first -Kind SetNetworkMode -Parameter @{ NetworkMode = 'NrOnly' }).Result | Should -Be 'Applied'
            $last = $script:link['Snapshot']
            Close-ModemWorker -Worker $first
            $second = Get-TestWorker -Device $device -Extra @{ Previous = $last; Generation = 2 }
            [void](Invoke-TestCycle -Worker $second -Jump -Max 60 -Until { param($s) $s.NetworkMode.Notice -and $s.State -eq 'Online' })
            $script:link['Snapshot'].NetworkMode.Notice.Kind | Should -Be 'Reverted'
            (Get-ModeWrite -Modem $device.Modem)[-1] | Should -Be $script:automatic
        }

        It 'saves a mode the modem has already, and writes nothing' {
            $device = New-SimulatedDevice -Scenario LteOnlyMode
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'LteOnly' }).Result | Should -Be 'Unchanged'
            (Get-SavedSetting).NetworkMode | Should -Be 'LteOnly'
            Get-ModeWrite -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'restricts the bands, and keeps the setting of what it doesn''t name' {
            Save-TestSetting @{ NetworkMode = 'Automatic'; LteBands = @(3, 20) }
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            [void](Invoke-TestCycle -Worker $worker -Jump -Max 40 -Until { param($s) $s.State -eq 'Online' -and $s.Recovery.Status -eq 'Healthy' -and @(Get-ModeWrite -Modem $device.Modem).Count -gt 0 })
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NrBands = @(78) }).Result | Should -Be 'Applied'
            (Get-ModeWrite -Modem $device.Modem)[-1] | Should -Be 'AT+GTACT=20,6,3,103,120,5078'
            [void](Invoke-TestCycle -Worker $worker -Jump -Max 40 -Until { param($s) -not $s.NetworkMode.Trial })
            $saved = Get-SavedSetting
            $saved.LteBands | Should -Be @(3, 20)
            $saved.NrBands | Should -Be @(78)
        }

        It 'stops managing the mode when asked: the modem keeps what it has' {
            Save-TestSetting @{ NetworkMode = 'LteOnly' }
            $device = New-SimulatedDevice -Scenario LteOnlyMode
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = '' }).Result | Should -Be 'Done'
            (Get-SavedSetting).NetworkMode | Should -Be ''
            Get-ModeWrite -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'saves 4G + 5G on a modem that has it, n77 left out by the modem, without a write' {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'Automatic' }).Result | Should -Be 'Unchanged'
            (Get-SavedSetting).NetworkMode | Should -Be 'Automatic'
            Get-ModeWrite -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'keeps a mode on trial when it is applied again, and still undoes it without a network' {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            # LTE on B5 only: no cell of the network around it.
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'LteOnly'; LteBands = @(5) }).Result | Should -Be 'Applied'
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'LteOnly'; LteBands = @(5) }).Result | Should -Be 'Applied'
            $script:link['Snapshot'].NetworkMode.Trial | Should -Not -BeNullOrEmpty
            (Get-SavedSetting).NetworkMode | Should -Be '' -Because 'only a registration with it saves it'
            [void](Invoke-TestCycle -Worker $worker -Jump -Max 60 -Until { param($s) $s.NetworkMode.Notice -and $s.State -eq 'Online' })
            $script:link['Snapshot'].NetworkMode.Notice.Kind | Should -Be 'Reverted'
            (Get-ModeWrite -Modem $device.Modem)[-1] | Should -Be $script:automatic
            (Get-SavedSetting).NetworkMode | Should -Be ''
        }

        It 'writes the setting before back first when it stops managing a mode on trial' {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'NrOnly' }).Result | Should -Be 'Applied'
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = '' }).Result | Should -Be 'Done'
            (Get-ModeWrite -Modem $device.Modem)[-1] | Should -Be $script:automatic
            $script:link['Snapshot'].NetworkMode.Trial | Should -BeNullOrEmpty
            (Get-SavedSetting).NetworkMode | Should -Be ''
            $trace = Invoke-TestCycle -Worker $worker -Jump -Max 40 -Until { param($s) $s.State -eq 'Online' -and $s.Recovery.Status -eq 'Healthy' }
            $trace[-1].State | Should -Be 'Online'
            Get-RecoveryCommand -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'undoes a mode only once the modem took the setting before back: refused once, written again' {
            $device = New-SimulatedDevice -Scenario Online
            $device.Modem.Script($script:automatic, @{ Lines = @('+CME ERROR: 14') })
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'NrOnly' }).Result | Should -Be 'Applied'
            $trace = Invoke-TestCycle -Worker $worker -Jump -Max 80 -Until { param($s) $s.NetworkMode.Notice -and $s.State -eq 'Online' }
            $script:link['Snapshot'].NetworkMode.Notice.Kind | Should -Be 'Reverted'
            @(Get-ModeWrite -Modem $device.Modem | Where-Object { $_ -eq $script:automatic }).Count | Should -Be 2
            @($trace | Where-Object { $_.Recovery -notin 'Healthy', 'Maintenance' }) | Should -BeNullOrEmpty
            @(Get-TestLog | Where-Object { $_ -match "can't be written back yet" }).Count | Should -Be 1
        }

        It 'waits for the modem, without spinning, when a mode on trial is due to be undone and the modem is gone' {
            $device = New-SimulatedDevice -Scenario Online
            $device.AwayMs = 3600000
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'NrOnly' }).Result | Should -Be 'Applied'
            $device.Modem.Vanish()
            $script:now += $script:timings.Maintenance + 1000
            # The port found lost, then a look for the modem at once.
            foreach ($i in 1..2) {
                Invoke-ModemWorkerCycle -Worker $worker
                $script:now += [Math]::Max(1, $worker.WaitMs)
            }
            $worker.Channel | Should -BeNullOrEmpty
            foreach ($i in 1..3) {
                Invoke-ModemWorkerCycle -Worker $worker
                $worker.WaitMs | Should -BeGreaterThan 0
                $script:now += $worker.WaitMs
            }
            $script:link['Snapshot'].NetworkMode.Trial | Should -Not -BeNullOrEmpty -Because 'it is undone once the modem is back'
        }

        It 'tries a write that got no answer as one that landed' {
            $saved = & (Get-Module FibocomFm350) { $script:AtMinimumTimeoutMs }
            & (Get-Module FibocomFm350) { $script:AtMinimumTimeoutMs = 300 }
            try {
                $device = New-SimulatedDevice -Scenario Online
                $device.Modem.Script($script:lteOnly, @{ NoFinal = $true })
                $worker = Get-TestWorker -Device $device
                Invoke-ModemWorkerCycle -Worker $worker
                $result = Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'LteOnly' }
                $result.Result | Should -Be 'Applied'
                $result.Detail | Should -Match 'Timeout$'
                $script:link['Snapshot'].Recovery.History.MaintenanceUntil | Should -Not -BeNullOrEmpty
                [void](Invoke-TestCycle -Worker $worker -Jump -Max 40 -Until { param($s) -not $s.NetworkMode.Trial -and $s.State -eq 'Online' })
                $script:link['Snapshot'].NetworkMode.Notice.Kind | Should -Be 'Kept'
            }
            finally {
                & (Get-Module FibocomFm350) { param($value) $script:AtMinimumTimeoutMs = $value } $saved
            }
        }

        It 'never saves a mode the modem didn''t keep, though it stays registered' {
            $device = New-SimulatedDevice -Scenario Online
            $device.Modem.Script($script:lteOnly, @{ Lines = @('OK'); Keep = $true })
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'LteOnly' }).Result | Should -Be 'Applied'
            [void](Invoke-TestCycle -Worker $worker -Jump -Max 60 -Until { param($s) $s.NetworkMode.Notice })
            $script:link['Snapshot'].NetworkMode.Notice.Kind | Should -Be 'Reverted'
            (Get-SavedSetting).NetworkMode | Should -Be ''
        }

        It 'publishes a mode on trial and its window at once: a cycle that fails after the command loses neither' {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            Mock -ModuleName FibocomFm350 Invoke-ModemConnect { throw 'the pass failed' }
            [void](Send-ModemCommand -Link $worker.Link -Kind SetNetworkMode -Parameter @{ NetworkMode = 'NrOnly' })
            $worker.PassForced = $true
            { Invoke-ModemWorkerCycle -Worker $worker } | Should -Throw '*the pass failed*'
            $snapshot = $script:link['Snapshot']
            $snapshot.NetworkMode.Trial.Selection.NetworkMode | Should -Be 'NrOnly'
            $snapshot.Recovery.History.MaintenanceUntil | Should -Not -BeNullOrEmpty
            $next = New-ModemWorker -Link (New-ModemWorkerLink) -Simulation $device -DataFolder $script:folder -Clock { $script:now } -Previous $snapshot -Generation 2
            $next.NetworkModeTrial.Selection.NetworkMode | Should -Be 'NrOnly'
            $next.Recovery.MaintenanceUntil | Should -Not -BeNullOrEmpty
        }

        It 'refuses a mode that is not one: <Value>' -ForEach @(@{ Value = 'FiveG' }, @{ Value = 20 }) {
            $device = New-SimulatedDevice -Scenario Online
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            $result = Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = $Value }
            $result.Result | Should -Be 'Failed'
            $result.Detail | Should -Match 'NetworkMode'
            Get-ModeWrite -Modem $device.Modem | Should -BeNullOrEmpty
        }

        It 'says there is no modem, and changes nothing' {
            $device = New-SimulatedDevice -Scenario NoDevice
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SetNetworkMode -Parameter @{ NetworkMode = 'LteOnly' }).Result | Should -Be 'NoModem'
            (Get-SavedSetting).NetworkMode | Should -Be ''
        }

        It 'keeps the saved mode when the other settings are saved' {
            Save-TestSetting @{ NetworkMode = 'LteOnly'; LteBands = @(3) }
            $device = New-SimulatedDevice -Scenario LteOnlyMode
            $worker = Get-TestWorker -Device $device
            Invoke-ModemWorkerCycle -Worker $worker
            (Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = @{ Apn = 'internet'; NetworkMode = '' } }).Result | Should -Be 'Done'
            $saved = Get-SavedSetting
            $saved.Apn | Should -Be 'internet'
            $saved.NetworkMode | Should -Be 'LteOnly'
            $saved.LteBands | Should -Be @(3)
        }
    }
}

Describe 'The worker and the AT port' {
    BeforeAll {
        # The PnP records of one modem, its AT port on -PortName; -Instance tells the device
        # instances apart (a re-enumeration makes new ones).
        function Get-TestRecord {
            param([string] $PortName, [int] $Instance = 1)
            $parent = "USB\VID_0E8D&PID_7127\7&00000000&0&$Instance"
            [pscustomobject]@{ InstanceId = "USB\VID_0E8D&PID_7127&MI_06\8&00000000&$Instance&0006"; Present = $true; ProblemCode = 0; Service = 'usb2ser'; Parent = $parent; PortName = $PortName }
            [pscustomobject]@{ InstanceId = "USB\VID_0E8D&PID_7127&MI_00\8&00000000&$Instance&0000"; Present = $true; ProblemCode = 0; Service = 'usbrndis6'; Parent = $parent; PortName = $null }
        }
        $script:configured = (New-SimulatedDevice -Scenario Online).Adapter.Read()
    }

    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
        $script:now = 100000
        $script:records = @(Get-TestRecord -PortName 'COM14')
        $script:modems = @{ COM14 = (New-SimulatedDevice -Scenario Online -PortName 'COM14').Modem; COM15 = (New-SimulatedDevice -Scenario Online -PortName 'COM15').Modem }
        Mock -ModuleName FibocomFm350 Get-ModemPnpRecord { $script:records }
        Mock -ModuleName FibocomFm350 Open-SerialAtTransport { $script:modems[$PortName] }
        Mock -ModuleName FibocomFm350 Get-ModemAdapterState { $script:configured }
        Mock -ModuleName FibocomFm350 Test-AppElevation { $true }
        $script:link = New-ModemWorkerLink
        $script:worker = New-ModemWorker -Link $script:link -DataFolder $script:folder -Clock { $script:now }
    }

    It 'finds the modem again by PnP after a re-enumeration, under another COM number' {
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].PortName | Should -Be 'COM14'
        $script:link['Snapshot'].State | Should -Be 'Online'

        # Back as a new device instance, its AT port on COM15: the next status read finds the
        # port lost.
        $script:modems['COM14'].Vanish()
        $script:records = @(Get-TestRecord -PortName 'COM15' -Instance 2)
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.PortName | Should -Be 'COM15'
        $snapshot.State | Should -Be 'Online'
        Should -Invoke -ModuleName FibocomFm350 Open-SerialAtTransport -Times 1 -Exactly -ParameterFilter { $PortName -eq 'COM15' }
        Should -Invoke -ModuleName FibocomFm350 Get-ModemAdapterState -ParameterFilter { $InstanceId -eq 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&2&0000' }
        $script:modems['COM14'].Closed | Should -BeTrue -Because 'the lost port is released'
        Get-WriteCommand -Modem $script:modems['COM15'] | Should -BeNullOrEmpty
    }

    It 'says when another program holds the AT port, and tries again at the next scan' {
        Mock -ModuleName FibocomFm350 Open-SerialAtTransport { throw [System.UnauthorizedAccessException]::new("Access to the port '$PortName' is denied.") }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.State | Should -Be 'NoDevice'
        $snapshot.Reason | Should -Be 'PortInUse'
        $snapshot.Blocked | Should -BeFalse
        $script:worker.WaitMs | Should -Be 5000
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        Should -Invoke -ModuleName FibocomFm350 Open-SerialAtTransport -Times 2 -Exactly
        @(Get-TestLog | Where-Object { $_ -match "can't be opened" }).Count | Should -Be 1 -Because 'the same failure is logged once'
    }

    It 'finds the network adapter a PnP read missed, without closing the port' {
        # The network function missed at the look that opened the port.
        $script:records = @(Get-TestRecord -PortName 'COM14' | Where-Object PortName)
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].Reason | Should -Be 'NoAdapter'
        $script:records = @(Get-TestRecord -PortName 'COM14')
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].State | Should -Be 'Online'
        Should -Invoke -ModuleName FibocomFm350 Open-SerialAtTransport -Times 1 -Exactly
        $script:modems['COM14'].Closed | Should -BeFalse
    }

    It 'looks for the modem again only at the scan interval' {
        $script:records = @()
        Invoke-ModemWorkerCycle -Worker $script:worker
        Invoke-ModemWorkerCycle -Worker $script:worker
        Should -Invoke -ModuleName FibocomFm350 Get-ModemPnpRecord -Times 1 -Exactly
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        Should -Invoke -ModuleName FibocomFm350 Get-ModemPnpRecord -Times 2 -Exactly
        $script:link['Snapshot'].Reason | Should -Be 'NoDevice'
    }
}

Describe 'The heartbeat' {
    It 'never lets a wait for the modem''s answer go a second without a beat' {
        InModuleScope FibocomFm350 {
            $modem = New-SimulatedModem
            $modem.SetAnswer('AT+COPS?', @('+COPS: 0', 'OK'))
            $modem.Script('AT+COPS?', @{ DelayMs = 2500 })
            # The modem, recording how long each read was allowed to wait.
            $recorder = [pscustomobject]@{ PortName = 'TEST'; Lost = $false; Waits = [System.Collections.Generic.List[int]]::new(); Modem = $modem }
            $recorder | Add-Member -MemberType ScriptMethod -Name Write -Value { param($text) $this.Modem.Write($text) }
            $recorder | Add-Member -MemberType ScriptMethod -Name Read -Value { param($timeout) $this.Waits.Add($timeout); $this.Modem.Read($timeout) }
            $recorder | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.Modem.Close() }
            $link = New-ModemWorkerLink
            $link['Heartbeat'] = 0
            $channel = New-AtChannel -Transport ([WorkerTransport]::new($recorder, $link, 1000))
            $answer = Invoke-AtCommand -Channel $channel -Command 'AT+COPS?' -TimeoutMs 10000
            $answer.Status | Should -Be 'OK'
            @($recorder.Waits | Where-Object { $_ -gt 1000 }).Count | Should -Be 0
            $recorder.Waits.Count | Should -BeGreaterOrEqual 3
            $link['Heartbeat'] | Should -BeGreaterThan 0
            Close-AtChannel -Channel $channel
        }
    }

    It 'follows the port it wraps when that port is lost' {
        InModuleScope FibocomFm350 {
            $modem = New-SimulatedModem
            $transport = [WorkerTransport]::new($modem, (New-ModemWorkerLink), 1000)
            $modem.Vanish()
            [void]$transport.Read(10)
            $transport.Lost | Should -BeTrue
        }
    }
}

Describe 'Invoke-ModemWorker' {
    It 'stops a failed cycle, logs it, and tries again a second later' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        $device = New-SimulatedDevice -Scenario Online
        $link = New-ModemWorkerLink
        $job = Start-ThreadJob -ScriptBlock {
            Import-Module $using:modulePath
            # PnP busy at the first look: built here, so that its methods run in this runspace.
            $simulated = $using:device
            $flaky = [pscustomobject]@{ Scenario = 'Online'; Adapter = $simulated.Adapter; Device = $simulated; Looks = 0 }
            $flaky | Add-Member -MemberType ScriptMethod -Name Find -Value {
                $this.Looks++
                if ($this.Looks -eq 1) { throw 'PnP is busy.' }
                $this.Device.Find()
            }
            $flaky | Add-Member -MemberType ScriptMethod -Name Open -Value { $this.Device.Open() }
            Invoke-ModemWorker -Link $using:link -Simulation $flaky -DataFolder $using:folder
        }
        try {
            $deadline = [Environment]::TickCount64 + 20000
            while (-not ($link['Snapshot'] -and $link['Snapshot'].State -eq 'Online') -and [Environment]::TickCount64 -lt $deadline) {
                Start-Sleep -Milliseconds 100
            }
            $link['Snapshot'].State | Should -Be 'Online'
            $log = @(Get-ChildItem (Join-Path $folder 'logs') | Get-Content)
            $failed = @($log -match 'ERROR\s+Cycle failed \(1 in a row\): .*PnP is busy')[0]
            $opened = @($log -match 'AT port SIMULATED open')[0]
            $failed | Should -Not -BeNullOrEmpty
            # The look that failed is the one run again, a second later - not at the next scan.
            $at = { param($line) [DateTimeOffset]::Parse($line.Substring(0, 29), [cultureinfo]::InvariantCulture) }
            ((& $at $opened) - (& $at $failed)).TotalMilliseconds | Should -BeLessThan 3000
        }
        finally {
            $link['Stop'] = $true
            [void]$link['Wake'].Set()
            $job | Wait-Job -Timeout 15 | Out-Null
            $job | Remove-Job -Force
            Close-ModemWorkerLink -Link $link
        }
    }

    It 'ends after three failed cycles in a row, with the error' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        $link = New-ModemWorkerLink
        $job = Start-ThreadJob -ScriptBlock {
            Import-Module $using:modulePath
            $broken = [pscustomobject]@{ Scenario = 'Online' }
            $broken | Add-Member -MemberType ScriptMethod -Name Find -Value { throw 'PnP is broken.' }
            Invoke-ModemWorker -Link $using:link -Simulation $broken -DataFolder $using:folder
        }
        try {
            $job | Wait-Job -Timeout 20 | Out-Null
            $job.State | Should -Be 'Failed'
            $failures = $null
            $job | Receive-Job -ErrorAction SilentlyContinue -ErrorVariable failures | Out-Null
            ($failures | ForEach-Object { $_.ToString() }) -join ' ' | Should -Match 'PnP is broken'
            $log = @(Get-ChildItem (Join-Path $folder 'logs') | Get-Content)
            $log -match 'Cycle failed \(3 in a row\)' | Should -Not -BeNullOrEmpty
            $log -match 'Worker 1 stopped' | Should -Not -BeNullOrEmpty
        }
        finally {
            $link['Stop'] = $true
            [void]$link['Wake'].Set()
            $job | Wait-Job -Timeout 15 | Out-Null
            $job | Remove-Job -Force
            Close-ModemWorkerLink -Link $link
        }
    }

    It 'runs in a runspace of its own until asked to stop, wakes for a command, and closes the AT port' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        $device = New-SimulatedDevice -Scenario Online
        $link = New-ModemWorkerLink
        $job = Start-ThreadJob -ScriptBlock {
            Import-Module $using:modulePath
            Invoke-ModemWorker -Link $using:link -Simulation $using:device -DataFolder $using:folder
        }
        try {
            $deadline = [Environment]::TickCount64 + 20000
            while (-not ($link['Snapshot'] -and $link['Snapshot'].State -eq 'Online') -and [Environment]::TickCount64 -lt $deadline) {
                Start-Sleep -Milliseconds 100
            }
            $link['Snapshot'].State | Should -Be 'Online'

            # The worker waits up to 5 s for the next status read: a command must not.
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $id = Send-ModemCommand -Link $link -Kind ConnectNow
            while (-not ($link['Snapshot'].Results | Where-Object Id -EQ $id) -and $clock.ElapsedMilliseconds -lt 4000) {
                Start-Sleep -Milliseconds 50
            }
            $link['Snapshot'].Results.Id | Should -Contain $id
            $clock.ElapsedMilliseconds | Should -BeLessThan 3000

            $link['Stop'] = $true
            [void]$link['Wake'].Set()
            $job | Wait-Job -Timeout 15 | Out-Null
            $job.State | Should -Be 'Completed'
            $device.Modem.Closed | Should -BeTrue
            (Get-ChildItem (Join-Path $folder 'logs') | Get-Content) -match 'Worker 1 stopped' | Should -Not -BeNullOrEmpty
        }
        finally {
            $link['Stop'] = $true
            [void]$link['Wake'].Set()
            $job | Wait-Job -Timeout 15 | Out-Null
            $job | Remove-Job -Force
            Close-ModemWorkerLink -Link $link
        }
    }
}

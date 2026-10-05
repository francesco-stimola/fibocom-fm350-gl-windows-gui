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

    # Commands that change the modem's state; reads and the channel's own setup left out, and the
    # messages' (their mode and notices, which the modem doesn't keep, and their listing).
    function Get-WriteCommand {
        param($Modem)
        @($Modem.Received | Where-Object {
                $_ -match '=' -and $_ -notmatch '=\?$' -and $_ -notin 'AT+CMEE=1', 'AT+CLCK="SC",2', 'AT+CMGF=0', 'AT+CNMI=2,1,0,0,0', 'AT+CMGL=4' -and
                $_ -notmatch '^AT\+(CGCONTRDP|CGPADDR|GTDNS)='
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

    It 'reads data usage: <Name>' -ForEach @(
        # Pass and status read just done: the next of those 5 s away.
        @{ Name = 'the adapter known, never read: now'; Arguments = @{ UsageWanted = $true }; Usage = $true; Wait = 0 }
        @{ Name = 'read 28 s ago: in 2 s'; Arguments = @{ UsageWanted = $true; LastUsage = 72000 }; Usage = $false; Wait = 2000 }
        @{ Name = 'read 30 s ago: now'; Arguments = @{ UsageWanted = $true; LastUsage = 70000 }; Usage = $true; Wait = 0 }
        @{ Name = 'no adapter: never'; Arguments = @{ LastUsage = 0 }; Usage = $false; Wait = 5000 }
    ) {
        $schedule = Resolve-WorkerSchedule -Now 100000 -LastPass 100000 -LastStatus 100000 -State 'Online' -PortOpen @Arguments
        $schedule.Usage | Should -Be $Usage
        $schedule.WaitMs | Should -Be $Wait
    }

    It 'reads data usage with no port open too' {
        $schedule = Resolve-WorkerSchedule -Now 100000 -LastScan 99000 -UsageWanted
        $schedule.Usage | Should -BeTrue
        $schedule.WaitMs | Should -Be 0
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
            [void](Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = $settings; SimToken = $first.SimToken })
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
            $result = Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = $settings; ApnPassword = ConvertTo-TestSecret 'apn-secret'; SimToken = $script:link['Snapshot'].SimToken }
            $result.Result | Should -Be 'Done'
            $snapshot = $script:link['Snapshot']
            $snapshot.Sim.PinStored | Should -BeTrue
            $snapshot.ApnPasswordStored | Should -BeTrue
            $json = $snapshot | ConvertTo-Json -Depth 8
            $json | Should -Not -Match '1234'
            $json | Should -Not -Match 'apn-secret'
            $json | Should -Not -Match '8900100000000000000' -Because 'the ICCID stays in the worker'
            $fingerprint = InModuleScope FibocomFm350 { Get-SimSettingFingerprint -Iccid '8900100000000000000' }
            $json | Should -Not -Match $fingerprint -Because 'its fingerprint too'
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
            $result = Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = $settings; SimToken = $script:link['Snapshot'].SimToken }
            $result.Result | Should -Be 'Done'
            (Import-SimSetting -Path (Join-Path $script:folder 'sim-settings.json')).Sims.Apn | Should -Be 'internet' -Because 'it is the SIM in use''s'
            (Get-Content (Join-Path $script:folder 'settings.json') -Raw | ConvertFrom-Json).Apn | Should -Be ''
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
            $token = $script:link['Snapshot'].SimToken
            [void](Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = $settings; ApnPassword = ConvertTo-TestSecret 'pass'; SimToken = $token })
            $script:link['Snapshot'].ApnPasswordStored | Should -BeTrue
            [void](Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = $settings; ApnPassword = [securestring]::new(); SimToken = $token })
            $script:link['Snapshot'].ApnPasswordStored | Should -BeFalse
        }

        It 'checks the APN password before writing anything' {
            $worker = Get-TestWorker -Device (New-SimulatedDevice -Scenario Online)
            Invoke-ModemWorkerCycle -Worker $worker
            $simsPath = Join-Path $script:folder 'sim-settings.json'
            $before = Get-Content -LiteralPath $simsPath -Raw
            $settings = $script:link['Snapshot'].Settings | Select-Object -Property *
            $settings.Apn = 'internet'
            $result = Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = $settings; ApnPassword = ConvertTo-TestSecret 'a"b'; SimToken = $script:link['Snapshot'].SimToken }
            $result.Result | Should -Be 'Failed'
            $result.Detail | Should -Match 'printable ASCII'
            Get-Content -LiteralPath $simsPath -Raw | Should -Be $before
            $script:link['Snapshot'].Settings.Apn | Should -Be ''
        }

        It 'keeps a SIM''s APN settings when a save fails halfway, the old ones given to it then' {
            Export-AppSetting -Settings @{ Apn = 'old' } -Path (Join-Path $script:folder 'settings.json')
            $worker = Get-TestWorker -Device (New-SimulatedDevice -Scenario Online)
            Invoke-ModemWorkerCycle -Worker $worker
            # As if the first SIM's move had failed: the SIM still on the settings file's.
            Remove-Item -LiteralPath (Join-Path $script:folder 'sim-settings.json')
            Export-AppSetting -Settings @{ Apn = 'old' } -Path (Join-Path $script:folder 'settings.json')
            $worker.SimSettings = [pscustomobject]@{ Exists = $false; Sims = @() }
            Mock -ModuleName FibocomFm350 Save-ApnPassword { throw [System.IO.IOException]::new('The disk is full.') }
            $settings = $script:link['Snapshot'].Settings | Select-Object -Property *
            $settings.Apn = 'internet'
            $result = Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = $settings; ApnPassword = ConvertTo-TestSecret 'pass'; SimToken = $script:link['Snapshot'].SimToken }
            $result.Result | Should -Be 'Failed'
            $worker.PassForced = $true
            Invoke-ModemWorkerCycle -Worker $worker
            @((Import-SimSetting -Path (Join-Path $script:folder 'sim-settings.json')).Sims | ForEach-Object Apn) | Should -Be @('internet') -Because 'what was written is read again, and never moved over'
            $script:link['Snapshot'].Settings.Apn | Should -Be 'internet'
        }

        It 'says once in the log that a ready SIM can''t be identified, and leaves the context as it is' {
            $device = New-SimulatedDevice -Scenario Online
            $device.Modem.SetAnswer('AT+ICCID', @('+CME ERROR: 13'))
            $worker = Get-TestWorker -Device $device
            for ($i = 0; $i -lt 3; $i++) {
                $worker.PassForced = $true
                Invoke-ModemWorkerCycle -Worker $worker
            }
            @(Get-TestLog | Where-Object { $_ -match 'ICCID can''t be read' }).Count | Should -Be 1
            $script:link['Snapshot'].SimToken | Should -BeNullOrEmpty
            $script:link['Snapshot'].Reason | Should -Be 'ContextUnknown'
            Get-WriteCommand -Modem $device.Modem | Should -BeNullOrEmpty
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
            @(Get-TestLog) -match 'AT port \(SIMULATED\) lost' | Should -Not -BeNullOrEmpty
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
            $token = $worker.Link['Snapshot'].SimToken
            (Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = @{ Apn = 'internet'; NetworkMode = '' }; SimToken = $token }).Result | Should -Be 'Done'
            $worker.Link['Snapshot'].Settings.Apn | Should -Be 'internet'
            $saved = Get-SavedSetting
            $saved.NetworkMode | Should -Be 'LteOnly'
            $saved.LteBands | Should -Be @(3)
        }
    }
}

Describe 'Data usage on the simulated modem' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
        $script:now = 100000
    }

    BeforeAll {
        # Cycles until -Reads more readings of the counters were taken, the clock moving on.
        function Invoke-UsageRead {
            param([hashtable] $Worker, [int] $Reads = 1)
            for ($i = 0; $i -lt $Reads; $i++) {
                $script:now += 30000
                Invoke-ModemWorkerCycle -Worker $Worker
            }
        }
    }

    It 'counts the adapter''s traffic from the first reading on: today and the cycle' {
        $worker = Get-TestWorker -Device (New-SimulatedDevice -Scenario Online)
        Invoke-ModemWorkerCycle -Worker $worker
        $first = $script:link['Snapshot'].Usage
        Invoke-UsageRead -Worker $worker

        $first.Today.Total | Should -Be 0 -Because 'the first reading only says where counting starts'
        $usage = $script:link['Snapshot'].Usage
        $usage.Today.Received | Should -Be 2000000
        $usage.Today.Sent | Should -Be 200000
        $usage.Cycle.Total | Should -Be 2200000
        $usage.Quota | Should -BeNullOrEmpty
        $script:link['Snapshot'].UsageNotice | Should -BeNullOrEmpty
    }

    It 'says each quota threshold once, never touching the connection' {
        Export-AppSetting -Settings @{ UsageQuotaGB = 0.01 } -Path (Join-Path $script:folder 'settings.json') -Confirm:$false
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $notices = foreach ($i in 1..6) {
            Invoke-UsageRead -Worker $worker
            $script:link['Snapshot'].UsageNotice
        }

        # 2.2 MB a reading against 10 MB: 80% at the fourth, 100% at the fifth.
        $notices[2] | Should -BeNullOrEmpty
        $notices[3].Threshold | Should -Be 80
        $notices[3].Id | Should -Be 1
        $notices[4].Threshold | Should -Be 100
        $notices[4].Id | Should -Be 2
        $notices[5].Id | Should -Be 2
        $script:link['Snapshot'].State | Should -Be 'Online'
        Get-WriteCommand -Modem $device.Modem | Should -BeNullOrEmpty
        @(Get-TestLog | Where-Object { $_ -match 'Data usage: (80|100)% of the quota reached' }).Count | Should -Be 2
    }

    It 'carries the totals and the thresholds said to the next worker, which says none again' {
        # 5 readings of 2.2 MB against 13.5 MB: 81%; one more, 98%.
        Export-AppSetting -Settings @{ UsageQuotaGB = 0.0135 } -Path (Join-Path $script:folder 'settings.json') -Confirm:$false
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        Invoke-UsageRead -Worker $worker -Reads 5
        $before = $script:link['Snapshot']
        Close-ModemWorker -Worker $worker
        $next = Get-TestWorker -Device $device -Extra @{ Previous = $before; Generation = 2 }
        Invoke-ModemWorkerCycle -Worker $next

        $after = $script:link['Snapshot']
        $before.UsageNotice.Threshold | Should -Be 80
        $after.UsageNotice.Id | Should -Be 1 -Because 'the threshold was said already this cycle'
        $after.Usage.Today.Total | Should -Be (6 * 2200000) -Because 'the next worker counts on from the counters the first one saved'
    }

    It 'counts across a restart of the modem''s USB device, its counters starting over' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        Invoke-UsageRead -Worker $worker -Reads 2
        $device.Adapter.ResetCounters()
        Invoke-UsageRead -Worker $worker

        $script:link['Snapshot'].Usage.Today.Received | Should -Be 6000000
    }

    It 'measures again at once when the cycle or the quota change' {
        $worker = Get-TestWorker -Device (New-SimulatedDevice -Scenario Online)
        Invoke-ModemWorkerCycle -Worker $worker
        $null = Invoke-TestCommand -Worker $worker -Kind SaveSettings -Parameter @{ Settings = @{ UsageQuotaGB = 5; UsageCycleDay = 31 } }

        $script:link['Snapshot'].Usage.Quota | Should -Be 5000000000
    }

    It 'never stops the cycle when the counters can''t be read: said once, tried again' {
        $device = New-SimulatedDevice -Scenario Online
        $device.Adapter | Add-Member -MemberType ScriptMethod -Name ReadCounters -Value { throw 'not readable' } -Force
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        Invoke-UsageRead -Worker $worker -Reads 2

        $script:link['Snapshot'].State | Should -Be 'Online'
        $script:link['Snapshot'].Usage | Should -BeNullOrEmpty
        @(Get-TestLog | Where-Object { $_ -match 'Data usage not counted' }).Count | Should -Be 1
        @(Get-TestLog | Where-Object { $_ -match 'Cycle failed' }).Count | Should -Be 0
    }

    It 'saves what it counted when it ends' {
        $worker = Get-TestWorker -Device (New-SimulatedDevice -Scenario Online)
        Invoke-ModemWorkerCycle -Worker $worker
        Invoke-UsageRead -Worker $worker
        $path = Join-Path $script:folder 'usage.json'
        $saved = Import-DataUsage -Path $path
        Close-ModemWorker -Worker $worker

        $saved.Days.Count | Should -Be 0 -Because 'saved at the first reading, then not again within the interval'
        @((Import-DataUsage -Path $path).Days.Values)[0].Received | Should -Be 2000000
    }
}

Describe 'Messages on the simulated modem' {
    BeforeAll {
        # The simulated SIM holds a read message from 'Operator' (place 1), an unread one from
        # +10000000000 (place 2) and an unread one from 'Info' in two parts (places 3 and 4).
        $script:simulation = Import-PowerShellDataFile -Path "$PSScriptRoot/../src/FibocomFm350/Data/Simulation.psd1"
        $script:arrival = $script:simulation.Messages.Arrivals[0].Pdu
        # From +10000000000, 'hello', a protocol identifier of 0x40: a silent message.
        $script:silent = '07910100000000F0040B910100000000F0400062014021436580' + '05E8329BFD06'

        function Get-TestMessage {
            param([string] $Address)
            @($script:link['Snapshot'].Messages.Items | Where-Object Address -EQ $Address)
        }
    }

    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
        $script:now = 100000
    }

    It 'sets the notices once the SIM is ready, reads the storage, and announces what is new: how many, and from whom' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $snapshot = $script:link['Snapshot']

        @($device.Modem.Received | Where-Object { $_ -in 'AT+CMGF=0', 'AT+CNMI=2,1,0,0,0' }) | Should -Be @('AT+CMGF=0', 'AT+CNMI=2,1,0,0,0')
        @($snapshot.Messages.Items | ForEach-Object Address) | Should -Be @('Info', '+10000000000', 'Operator') -Because 'the newest first'
        $snapshot.Messages.Items.New | Should -Be @($true, $true, $false)
        (Get-TestMessage 'Info').Text | Should -Match '^Your data bundle renews .+ before showing it\.$'
        (Get-TestMessage 'Info').Fingerprints.Count | Should -Be 2
        $snapshot.Messages.New | Should -Be 2
        $snapshot.Messages.Used | Should -Be 4
        $snapshot.Messages.Total | Should -Be 70
        $snapshot.Messages.Full | Should -BeFalse
        $snapshot.MessageNotice.Count | Should -Be 2
        $snapshot.MessageNotice.Sender | Should -Be 'Info'
        $snapshot.MessageNotice.Id | Should -Be 1
        $log = @(Get-TestLog) -join "`n"
        $log | Should -Match 'Messages: 2 new'
        $log | Should -Not -Match '10000000000|Ciao|bundle|Welcome' -Because 'no sender and no text goes to the log'
    }

    It 'keeps what is new for the next worker, though the modem marked it read, and announces nothing again' {
        $device = New-SimulatedDevice -Scenario Online
        $first = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $first
        $last = $script:link['Snapshot']
        Close-ModemWorker -Worker $first

        $second = Get-TestWorker -Device $device -Extra @{ Previous = $last; Generation = 2 }
        Invoke-ModemWorkerCycle -Worker $second
        $snapshot = $script:link['Snapshot']
        @($device.Modem.Messaging.Stored | Where-Object Status -EQ 0).Count | Should -Be 0 -Because 'the first listing marked them read'
        $snapshot.Messages.Items.New | Should -Be @($true, $true, $false)
        $snapshot.MessageNotice.Id | Should -Be 1
        Get-Content -LiteralPath (Join-Path $script:folder 'sms-new.dat') -Raw | Should -Not -Match (Get-TestMessage 'Info').Fingerprints[0] -Because 'the file is encrypted'
    }

    It 'reads a message on its notice, and announces its sender' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $device.Modem.Messaging.Deliver($script:arrival, $device.Modem)
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $worker
        $snapshot = $script:link['Snapshot']

        $snapshot.Messages.Items.Count | Should -Be 4
        $snapshot.Messages.Items[0].Text | Should -Match '^You have used 80%'
        $snapshot.Messages.Items[0].New | Should -BeTrue
        $snapshot.MessageNotice.Id | Should -Be 2
        $snapshot.MessageNotice.Count | Should -Be 1
        $snapshot.MessageNotice.Sender | Should -Be 'Info'
    }

    It 'announces a long message once, its parts coming one after the other' {
        $device = New-SimulatedDevice -Scenario Online
        $device.Modem.Messaging.Stored.Clear()
        $parts = @($script:simulation.Messages.Stored[2].Pdu, $script:simulation.Messages.Stored[3].Pdu)
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $notices = foreach ($part in $parts) {
            $device.Modem.Messaging.Deliver($part, $device.Modem)
            $script:now += 5000
            Invoke-ModemWorkerCycle -Worker $worker
            $script:link['Snapshot'].MessageNotice.Id
        }

        $notices | Should -Be @(1, 1)
        $script:link['Snapshot'].Messages.Items.Count | Should -Be 1
        $script:link['Snapshot'].Messages.Items[0].Complete | Should -BeTrue
    }

    It 'finds a message stored without a notice, once a pass sees the storage grow' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $script:now += 30000
        Invoke-ModemWorkerCycle -Worker $worker
        @($device.Modem.Received | Where-Object { $_ -eq 'AT+CMGL=4' }).Count | Should -Be 1 -Because 'a pass that finds the storage as it was lists nothing'
        [void]$device.Modem.Messaging.Store(0, $script:arrival)
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $worker
        $script:link['Snapshot'].Messages.Items.Count | Should -Be 3 -Because 'no notice came, and no pass ran yet'

        $script:now += 30000
        Invoke-ModemWorkerCycle -Worker $worker
        $script:link['Snapshot'].Messages.Items.Count | Should -Be 4
        $script:link['Snapshot'].MessageNotice.Id | Should -Be 2
    }

    It 'lists a silent message, so it can be deleted, but never as new nor announced' {
        $device = New-SimulatedDevice -Scenario Online
        $place = $device.Modem.Messaging.Store(0, $script:silent)
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker

        $snapshot = $script:link['Snapshot']
        $snapshot.Messages.Items.Count | Should -Be 4
        $snapshot.Messages.Used | Should -Be 5
        $silent = @($snapshot.Messages.Items | Where-Object Silent)
        $silent.Count | Should -Be 1
        $silent[0].New | Should -BeFalse -Because 'the modem had it unread, but it is never to be shown'
        $snapshot.Messages.New | Should -Be 2
        $snapshot.MessageNotice.Count | Should -Be 2
        $worker.SmsUnread | Should -Not -Contain (Get-SmsFingerprint -Pdu $script:silent)

        (Invoke-TestCommand -Worker $worker -Kind DeleteMessage -Parameter @{ Fingerprints = $silent[0].Fingerprints }).Result | Should -Be 'Done'
        $device.Modem.Received | Should -Contain "AT+CMGD=$place"
        @($script:link['Snapshot'].Messages.Items | Where-Object Silent).Count | Should -Be 0
    }

    It 'says when the storage is full' {
        $device = New-SimulatedDevice -Scenario Online
        $device.Modem.Messaging.Capacity = 4
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker

        $script:link['Snapshot'].Messages.Full | Should -BeTrue
    }

    It 'opens a message: new no more, for the next worker too' {
        $device = New-SimulatedDevice -Scenario Online
        $first = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $first
        $result = Invoke-TestCommand -Worker $first -Kind OpenMessage -Parameter @{ Fingerprints = (Get-TestMessage '+10000000000').Fingerprints }
        $result.Result | Should -Be 'Done'
        (Get-TestMessage '+10000000000').New | Should -BeFalse
        $last = $script:link['Snapshot']
        Close-ModemWorker -Worker $first

        $second = Get-TestWorker -Device $device -Extra @{ Previous = $last; Generation = 2 }
        Invoke-ModemWorkerCycle -Worker $second
        $script:link['Snapshot'].Messages.Items.New | Should -Be @($true, $false, $false)
    }

    It 'opens a message the next worker gets before its first listing' {
        $device = New-SimulatedDevice -Scenario Online
        $first = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $first
        $last = $script:link['Snapshot']
        $fingerprints = (Get-TestMessage '+10000000000').Fingerprints
        Close-ModemWorker -Worker $first

        $second = Get-TestWorker -Device $device -Extra @{ Previous = $last; Generation = 2 }
        $result = Invoke-TestCommand -Worker $second -Kind OpenMessage -Parameter @{ Fingerprints = $fingerprints }

        $result.Result | Should -Be 'Done'
        (Get-TestMessage '+10000000000').New | Should -BeFalse -Because 'the record of what is new was read before the message was taken off it'
        (Get-TestMessage 'Info').New | Should -BeTrue
    }

    It 'keeps new the unread parts a listing cut short marked read' {
        $device = New-SimulatedDevice -Scenario Online
        $device.AwayMs = 600000
        $device.Modem.Script('AT+CMGL=4', @{ Lines = @('+CMGL: 2,0,,24', $script:silent.Replace('F04000', 'F00000'), 'OK'); NoFinal = $true; Vanish = $true })
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker

        $expected = Get-SmsFingerprint -Pdu $script:silent.Replace('F04000', 'F00000')
        $worker.SmsUnread | Should -Contain $expected
        @(Import-SmsUnread -Path (Join-Path $script:folder 'sms-new.dat')) | Should -Contain $expected
        @(Get-TestLog | Where-Object { $_ -match 'Messages: AT\+CMGL=4 PortLost' }).Count | Should -Be 1
    }

    It 'goes on with the cycle when reading the messages fails, saying it once by the error''s type' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Mock ConvertFrom-AtMessageList -ModuleName FibocomFm350 { throw [System.FormatException]::new('From +10000000000: bad') }
        Invoke-ModemWorkerCycle -Worker $worker
        $script:now += 30000
        Invoke-ModemWorkerCycle -Worker $worker

        $snapshot = $script:link['Snapshot']
        $snapshot.State | Should -Be 'Online'
        $snapshot.Recovery | Should -Not -BeNullOrEmpty -Because 'the cycle went on to the recovery decision'
        $snapshot.Messages | Should -BeNullOrEmpty
        $log = @(Get-TestLog)
        @($log | Where-Object { $_ -match 'Messages: not read \(FormatException\)' }).Count | Should -Be 1
        ($log -join "`n") | Should -Not -Match '10000000000'
    }

    It 'deletes a message, every part of it, where the storage keeps them now' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $result = Invoke-TestCommand -Worker $worker -Kind DeleteMessage -Parameter @{ Fingerprints = (Get-TestMessage 'Info').Fingerprints }

        $result.Result | Should -Be 'Done'
        @($device.Modem.Received | Where-Object { $_ -like 'AT+CMGD=*' }) | Should -Be @('AT+CMGD=3', 'AT+CMGD=4')
        @($script:link['Snapshot'].Messages.Items | ForEach-Object Address) | Should -Be @('+10000000000', 'Operator')
        $script:link['Snapshot'].Messages.Used | Should -Be 2
    }

    It 'deletes nothing for a message no longer stored' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $result = Invoke-TestCommand -Worker $worker -Kind DeleteMessage -Parameter @{ Fingerprints = @('0' * 64) }

        $result.Result | Should -Be 'NotFound'
        @($device.Modem.Received | Where-Object { $_ -like 'AT+CMGD=*' }).Count | Should -Be 0
    }

    It 'sends a message part by part, logging neither the number nor the text' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $text = 'A message long enough for two parts. ' * 6
        $result = Invoke-TestCommand -Worker $worker -Kind SendMessage -Parameter @{ Number = '+1 000 000-0000'; Text = $text }

        $result.Result | Should -Be 'Sent'
        $result.Parts.Sent | Should -Be 2
        $result.Parts.Count | Should -Be 2
        $device.Modem.Messaging.Sent.Count | Should -Be 2
        (ConvertFrom-SmsPdu -Pdu $device.Modem.Messaging.Sent[0]).Address | Should -Be '+10000000000'
        $script:link['Snapshot'].MessageOperation | Should -BeNullOrEmpty
        $log = @(Get-TestLog) -join "`n"
        $log | Should -Match 'Command SendMessage: Sent'
        $log | Should -Not -Match '10000000000|1 000 000|long enough'
    }

    It 'stops at a part the modem refuses, and sends nothing again by itself' {
        $device = New-SimulatedDevice -Scenario Online
        $device.Modem.Messaging.SendError = '331'
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $result = Invoke-TestCommand -Worker $worker -Kind SendMessage -Parameter @{ Number = '+10000000000'; Text = 'hello ' * 40 }
        Invoke-TestCycle -Worker $worker -Max 5 | Out-Null

        $result.Result | Should -Be 'Failed'
        $result.Detail | Should -Be 'part 1 of 2: CmsError 331'
        $result.Parts.Sent | Should -Be 0
        @($device.Modem.Received | Where-Object { $_ -like 'AT+CMGS=*' }).Count | Should -Be 1
    }

    It 'says the message is going out before its parts are sent' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $script:seen = $null
        Mock Send-AtMessagePdu -ModuleName FibocomFm350 {
            $script:seen = $script:link['Snapshot'].MessageOperation
            [pscustomobject]@{ Command = 'AT+CMGS=18'; Status = 'OK'; Reference = 1; ErrorCode = $null; ElapsedMs = 1 }
        }
        $result = Invoke-TestCommand -Worker $worker -Kind SendMessage -Parameter @{ Number = '+10000000000'; Text = 'hello' }

        $result.Result | Should -Be 'Sent'
        $script:seen | Should -Be 'Sending'
        $script:link['Snapshot'].MessageOperation | Should -BeNullOrEmpty
    }

    It 'gives only the type of an error, which may hold the number or the text' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        Mock ConvertTo-SmsPdu -ModuleName FibocomFm350 { throw [System.FormatException]::new("Not a number: $Number") }
        $result = Invoke-TestCommand -Worker $worker -Kind SendMessage -Parameter @{ Number = '+10000000000'; Text = 'hello' }

        $result.Result | Should -Be 'Failed'
        $result.Detail | Should -Be 'FormatException'
        @(Get-TestLog) -join "`n" | Should -Not -Match '10000000000'
    }

    It 'refuses <Name>, saying nothing of it' -ForEach @(
        @{ Name = 'a number that is not one'; Number = 'Mario'; Text = 'hello' }
        @{ Name = 'an empty text'; Number = '+10000000000'; Text = '' }
        @{ Name = 'a text longer than 255 parts'; Number = '+10000000000'; Text = 'x' * 40000 }
    ) {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $result = Invoke-TestCommand -Worker $worker -Kind SendMessage -Parameter @{ Number = $Number; Text = $Text }

        $result.Result | Should -Be 'Invalid'
        @($device.Modem.Received | Where-Object { $_ -like 'AT+CMGS=*' }).Count | Should -Be 0
        @(Get-TestLog) -join "`n" | Should -Not -Match 'Mario'
    }

    It 'only observing: no notices, no listing, nothing deleted or sent' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device -Extra @{ ObserveOnly = $true }
        Invoke-ModemWorkerCycle -Worker $worker
        $delete = Invoke-TestCommand -Worker $worker -Kind DeleteMessage -Parameter @{ Fingerprints = @('0' * 64) }
        $send = Invoke-TestCommand -Worker $worker -Kind SendMessage -Parameter @{ Number = '+10000000000'; Text = 'hello' }

        $script:link['Snapshot'].Messages | Should -BeNullOrEmpty
        $delete.Result | Should -Be 'Refused'
        $send.Result | Should -Be 'Refused'
        @($device.Modem.Received | Where-Object { $_ -match '^AT\+(CMGF|CNMI|CMGL|CMGD|CMGS)' }) | Should -BeNullOrEmpty
    }

    It 'without a ready SIM: no messages, and nothing deleted or sent' {
        $device = New-SimulatedDevice -Scenario PinRequired
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $send = Invoke-TestCommand -Worker $worker -Kind SendMessage -Parameter @{ Number = '+10000000000'; Text = 'hello' }

        $script:link['Snapshot'].Messages | Should -BeNullOrEmpty
        $send.Result | Should -Be 'NotReady'
        @($device.Modem.Received | Where-Object { $_ -match '^AT\+(CNMI|CMGL|CMGS)' }) | Should -BeNullOrEmpty
    }

    It 'says once that the modem refused the notices, and tries again after the next pass' {
        $device = New-SimulatedDevice -Scenario Online
        $device.Modem.Script('AT+CNMI=2,1,0,0,0', @{ Lines = @('+CMS ERROR: 302') })
        $device.Modem.Script('AT+CNMI=2,1,0,0,0', @{ Lines = @('+CMS ERROR: 302') })
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $worker
        $tries = @($device.Modem.Received | Where-Object { $_ -eq 'AT+CNMI=2,1,0,0,0' }).Count
        $script:link['Snapshot'].Messages | Should -BeNullOrEmpty

        $script:now += 30000
        Invoke-ModemWorkerCycle -Worker $worker
        $script:now += 30000
        Invoke-ModemWorkerCycle -Worker $worker
        $tries | Should -Be 1 -Because 'a refused step waits for the next pass'
        $script:link['Snapshot'].Messages.Items.Count | Should -Be 3
        @(Get-TestLog | Where-Object { $_ -match 'Messages: AT\+CNMI=2,1,0,0,0 CmsError 302' }).Count | Should -Be 1
    }

    It 'forgets the messages with a lost port, and sets the notices again on the next' {
        $device = New-SimulatedDevice -Scenario Online
        $device.AwayMs = 0
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $device.Restart()
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $worker
        $script:link['Snapshot'].Messages | Should -BeNullOrEmpty

        Invoke-TestCycle -Worker $worker -Until { param($snapshot) $snapshot.Messages } -Max 10 | Out-Null
        $script:link['Snapshot'].Messages.Items.Count | Should -Be 3
        $device.Modem.Messaging.Notices[1] | Should -Be '1'
        @($device.Modem.Received | Where-Object { $_ -eq 'AT+CNMI=2,1,0,0,0' }).Count | Should -Be 2
    }

    It 'remembers the SIM in use as the one the unread messages came in on, encrypted; a message read before keeps none' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $snapshot = $script:link['Snapshot']

        $snapshot.Messages.Items.Owner | Should -Be @('Own', 'Own', 'Unknown') -Because 'Operator''s was read before the app saw it'
        $snapshot.Messages.Hidden | Should -Be 0
        $path = Join-Path $script:folder 'sms-sim.dat'
        $owners = @(Import-SmsOwner -Path $path)
        $owners.Count | Should -Be 3 -Because 'one entry per part: Info''s has two'
        @($owners | ForEach-Object Sim | Sort-Object -Unique) | Should -Be (InModuleScope FibocomFm350 { Get-SimSettingFingerprint -Iccid '8900100000000000000' })
        @($owners | ForEach-Object Kind | Sort-Object -Unique) | Should -Be 'Usim'
        Get-Content -LiteralPath $path -Raw | Should -Not -Match $owners[0].Message -Because 'the file is encrypted'
    }

    It 'shows a message that came in on another physical SIM, with the kind of that SIM' {
        New-Item -ItemType Directory -Path $script:folder -Force | Out-Null
        $operator = Get-SmsFingerprint -Pdu $script:simulation.Messages.Stored[0].Pdu
        Export-SmsOwner -Owner @([pscustomobject]@{ Message = $operator; Sim = 'C' * 64; Kind = 'Usim'; Name = '' }) -Path (Join-Path $script:folder 'sms-sim.dat') -Confirm:$false
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $message = Get-TestMessage 'Operator'

        $message.Owner | Should -Be 'Other'
        $message.OwnerKind | Should -Be 'Usim'
        $message.OwnerName | Should -BeNullOrEmpty
        $script:link['Snapshot'].Messages.Items.Count | Should -Be 3 -Because 'only another eSIM profile still on the eUICC hides one'
    }

    It 'reads the messages again when a pass finds another SIM, though its storage holds as many' {
        $device = New-SimulatedDevice -Scenario Online
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $before = @($device.Modem.Received | Where-Object { $_ -eq 'AT+CMGL=4' }).Count
        # Another SIM in the slot, swapped while the port stayed open.
        $device.Modem.SetAnswer('AT+ICCID', @('+ICCID: 8900100000000000001', 'OK'))
        $script:now += 30000
        $worker.PassForced = $true
        Invoke-ModemWorkerCycle -Worker $worker

        @($device.Modem.Received | Where-Object { $_ -eq 'AT+CMGL=4' }).Count | Should -Be ($before + 1) -Because 'the list shown was the other SIM''s'
        $script:link['Snapshot'].Messages.Items.Owner | Should -Be @('Other', 'Other', 'Unknown')
    }

    It 'keeps another SIM''s messages new while the SIM in use can''t be identified, and tells none as another''s' {
        New-Item -ItemType Directory -Path $script:folder -Force | Out-Null
        $operator = Get-SmsFingerprint -Pdu $script:simulation.Messages.Stored[0].Pdu
        $away = Get-SmsFingerprint -Pdu $script:arrival
        Export-SmsOwner -Owner @(
            [pscustomobject]@{ Message = $operator; Sim = 'C' * 64; Kind = 'Esim'; Name = 'Travel' }
            [pscustomobject]@{ Message = $away; Sim = 'C' * 64; Kind = 'Esim'; Name = 'Travel' }
        ) -Path (Join-Path $script:folder 'sms-sim.dat') -Confirm:$false
        Export-SmsUnread -Fingerprint @($away) -Path (Join-Path $script:folder 'sms-new.dat') -Confirm:$false
        $device = New-SimulatedDevice -Scenario Online
        $device.Modem.SetAnswer('AT+ICCID', @('+CME ERROR: 100'))
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker

        $worker.SmsUnread | Should -Contain $away -Because 'it may be in another SIM''s storage, not this one'
        (Get-TestMessage 'Operator').Owner | Should -Be 'Unknown' -Because 'the SIM in use may be the one it came in on'
        $script:link['Snapshot'].Messages.Hidden | Should -Be 0
    }

    It 'reads the messages of a SIM whose ICCID can''t be read, every one shown, none told as its own' {
        $device = New-SimulatedDevice -Scenario Online
        $device.Modem.SetAnswer('AT+ICCID', @('+CME ERROR: 100'))
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $snapshot = $script:link['Snapshot']

        $snapshot.Messages.Items.Owner | Should -Be @('Unknown', 'Unknown', 'Unknown')
        $snapshot.Messages.New | Should -Be 2
        @(Import-SmsOwner -Path (Join-Path $script:folder 'sms-sim.dat')).Count | Should -Be 0
    }

    It 'shows every message when the file of their SIMs can''t be read, and says so once' {
        New-Item -ItemType Directory -Path $script:folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:folder 'sms-sim.dat') -Value 'not encrypted'
        $device = New-SimulatedDevice -Scenario Online
        $device.Modem.Messaging.Stored | ForEach-Object { $_.Status = 1 }
        $worker = Get-TestWorker -Device $device
        Invoke-ModemWorkerCycle -Worker $worker
        $script:now += 30000
        Invoke-ModemWorkerCycle -Worker $worker

        $script:link['Snapshot'].Messages.Items.Owner | Should -Be @('Unknown', 'Unknown', 'Unknown')
        @(Get-TestLog | Where-Object { $_ -match 'Messages: The SIMs the messages came in on can''t be read \(CryptographicException\)' }).Count | Should -Be 1
    }
}

Describe 'The worker and the AT port' {
    BeforeAll {
        $script:guid = '{4FDE9624-2286-4DC0-9D07-601A3922581A}'
        # The PnP records of one modem: its AT port on WinUSB with the app's interface class, or on
        # MediaTek's driver with a COM port (-Unbound); a GNSS function on MediaTek's driver
        # (-Gnss); -Instance tells the device instances apart (a re-enumeration makes new ones).
        function Get-TestRecord {
            param([int] $Instance = 1, [switch] $Unbound, [switch] $Gnss, [switch] $NoNetwork)
            $parent = "USB\VID_0E8D&PID_7127\7&00000000&0&$Instance"
            $vendor = @('USB\Class_ff&SubClass_00&Prot_00')
            [pscustomobject]@{
                InstanceId = "USB\VID_0E8D&PID_7127&MI_06\8&00000000&$Instance&0006"; Present = $true; ProblemCode = 0; Parent = $parent; CompatibleIds = $vendor
                Service = if ($Unbound) { 'usb2ser_tm' } else { 'WINUSB' }; PortName = if ($Unbound) { 'COM14' } else { $null }
                InterfaceGuids = if ($Unbound) { $null } else { @($script:guid) }
            }
            if ($Gnss) {
                [pscustomobject]@{
                    InstanceId = "USB\VID_0E8D&PID_7127&MI_03\8&00000000&$Instance&0003"; Present = $true; ProblemCode = 0; Parent = $parent; CompatibleIds = $vendor
                    Service = 'usb2ser_tm'; PortName = 'COM11'; InterfaceGuids = $null
                }
            }
            if (-not $NoNetwork) {
                [pscustomobject]@{
                    InstanceId = "USB\VID_0E8D&PID_7127&MI_00\8&00000000&$Instance&0000"; Present = $true; ProblemCode = 0; Service = 'usbrndis6'; Parent = $parent
                    CompatibleIds = @('USB\Class_e0&SubClass_01&Prot_03'); PortName = $null; InterfaceGuids = $null
                }
            }
        }
        $script:configured = (New-SimulatedDevice -Scenario Online).Adapter.Read()
    }

    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
        $script:now = 100000
        $script:records = @(Get-TestRecord)
        $script:modems = @{ 1 = (New-SimulatedDevice -Scenario Online -PortName 'WinUSB').Modem; 2 = (New-SimulatedDevice -Scenario Online -PortName 'WinUSB').Modem }
        $script:installs = [System.Collections.Generic.List[object]]::new()
        $script:install = { [pscustomobject]@{ Done = $true; NeedReboot = $false; Step = 'Install'; Error = 0 } }
        $script:free = $true
        Mock -ModuleName FibocomFm350 Get-ModemPnpRecord { $script:records }
        # The interface is there only for a function on WinUSB, as Windows would have it.
        Mock -ModuleName FibocomFm350 Get-WinUsbInterfacePath {
            if (@($script:records | Where-Object { $_.InstanceId -eq $InstanceId -and $_.Service -eq 'WINUSB' }).Count -gt 0) {
                "\\?\usb#vid_0e8d&pid_7127&mi_06#$($InstanceId -replace '^.*\\', '')#{4fde9624-2286-4dc0-9d07-601a3922581a}"
            }
        }
        Mock -ModuleName FibocomFm350 Open-WinUsbAtTransport { $script:modems[[int]($InterfacePath -replace '^.*#8&00000000&(\d)&.*$', '$1')] }
        Mock -ModuleName FibocomFm350 Test-UsbFunctionFree { [pscustomobject]@{ Free = $script:free; Held = $(if ($script:free) { $null } else { 'Port' }); Error = $(if ($script:free) { 0 } else { 5 }) } }
        # Never the real installation: each one recorded, its outcome from $script:install, and the
        # records then as Windows would show them.
        Mock -ModuleName FibocomFm350 Install-WinUsbDriver {
            $script:installs.Add([pscustomobject]@{ InstanceId = $InstanceId; InterfaceGuid = $InterfaceGuid; Beat = [bool]$Beat })
            $result = & $script:install
            if ($result.Done -and -not $result.NeedReboot) {
                foreach ($record in $script:records | Where-Object InstanceId -EQ $InstanceId) {
                    $record.Service = 'WINUSB'
                    $record.PortName = $null
                    if ($InterfaceGuid) { $record.InterfaceGuids = @($InterfaceGuid) }
                }
            }
            $result
        }
        Mock -ModuleName FibocomFm350 Get-ModemAdapterState { $script:configured }
        Mock -ModuleName FibocomFm350 Get-ModemAdapterCounter { }
        Mock -ModuleName FibocomFm350 Test-AppElevation { $true }
        $script:link = New-ModemWorkerLink
        $script:worker = New-ModemWorker -Link $script:link -DataFolder $script:folder -Clock { $script:now }
    }

    It 'opens the AT port on WinUSB, by its interface, and names no COM port' {
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.State | Should -Be 'Online'
        $snapshot.PortName | Should -Be 'WinUSB'
        $snapshot.Usb.Device | Should -Be 'Present'
        Should -Invoke -ModuleName FibocomFm350 Get-WinUsbInterfacePath -Times 1 -Exactly -ParameterFilter { $InstanceId -eq 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&1&0006' }
        $script:installs | Should -BeNullOrEmpty
        @(Get-TestLog | Where-Object { $_ -match 'COM\d' }) | Should -BeNullOrEmpty
    }

    It 'finds the modem again by PnP after a re-enumeration, as a new device instance' {
        Invoke-ModemWorkerCycle -Worker $script:worker
        # Back as a new device instance: the next status read finds the port lost.
        $script:modems[1].Vanish()
        $script:records = @(Get-TestRecord -Instance 2)
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.State | Should -Be 'Online'
        Should -Invoke -ModuleName FibocomFm350 Open-WinUsbAtTransport -Times 1 -Exactly -ParameterFilter { $InterfacePath -like '*#8&00000000&2&0006#*' }
        Should -Invoke -ModuleName FibocomFm350 Get-ModemAdapterState -ParameterFilter { $InstanceId -eq 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&2&0000' }
        $script:modems[1].Closed | Should -BeTrue -Because 'the lost port is released'
        Get-WriteCommand -Modem $script:modems[2] | Should -BeNullOrEmpty
    }

    It 'puts a new instance back on MediaTek''s driver on WinUSB, the AT port first with its interface class, then opens it' {
        $script:records = @(Get-TestRecord -Unbound -Gnss)
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs.InstanceId | Should -Be @('USB\VID_0E8D&PID_7127&MI_06\8&00000000&1&0006', 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&1&0003')
        $script:installs.InterfaceGuid | Should -Be @($script:guid, $null)
        $script:installs.Beat | Should -Be @($true, $true) -Because 'the heartbeat beats while Windows installs'
        Should -Invoke -ModuleName FibocomFm350 Test-UsbFunctionFree -ParameterFilter { $PortName -eq 'COM14' -and $InstanceId -like '*&MI_06\*' }
        $snapshot = $script:link['Snapshot']
        $snapshot.State | Should -Be 'Online'
        $snapshot.Usb.Binding.Functions.Result | Should -Be @('Done', 'Done')
        $snapshot.Recovery.History.MaintenanceUntil | Should -BeGreaterThan $script:now -Because 'a port just started may stay silent: nothing escalates'
        @(Get-TestLog | Where-Object { $_ -match 'USB function MI_06 MdAt: on WinUSB \(OtherDriver\)' }).Count | Should -Be 1
        @(Get-TestLog | Where-Object { $_ -match 'COM\d' }) | Should -BeNullOrEmpty
    }

    It 'leaves the AT port on its driver while another program holds its COM port, and looks again at each scan' {
        $script:records = @(Get-TestRecord -Unbound)
        $script:free = $false
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.State | Should -Be 'NoDevice'
        $snapshot.Reason | Should -Be 'PortInUse'
        $snapshot.Usb.Binding.Functions.Result | Should -Be @('InUse')
        $script:installs | Should -BeNullOrEmpty
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs | Should -BeNullOrEmpty
        $script:free = $true
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs.Count | Should -Be 1
        $script:link['Snapshot'].State | Should -Be 'Online'
        @(Get-TestLog | Where-Object { $_ -match 'another program holds its port' }).Count | Should -Be 1 -Because 'it is logged once'
    }

    It 'tries a failed installation once per instance, out of the app''s reach meanwhile, again when the user checks now' {
        $script:records = @(Get-TestRecord -Unbound)
        $script:install = { [pscustomobject]@{ Done = $false; NeedReboot = $false; Step = 'Install'; Error = [int]0xE0000203 } }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.Reason | Should -Be 'BindFailed'
        $snapshot.Blocked | Should -BeTrue
        $snapshot.Recovery.Status | Should -Be 'Blocked'
        $snapshot.Usb.Binding.Functions[0].Error | Should -Be '0xE0000203'
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs.Count | Should -Be 1
        $script:link['Snapshot'].Reason | Should -Be 'BindFailed'

        $script:install = { [pscustomobject]@{ Done = $true; NeedReboot = $false; Step = 'Install'; Error = 0 } }
        [void](Send-ModemCommand -Link $script:link -Kind ConnectNow)
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs.Count | Should -Be 2
        $script:link['Snapshot'].State | Should -Be 'Online'
    }

    It 'tries again a new instance of a function whose installation failed' {
        $script:records = @(Get-TestRecord -Unbound)
        $script:install = { [pscustomobject]@{ Done = $false; NeedReboot = $false; Step = 'Install'; Error = 5 } }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:records = @(Get-TestRecord -Unbound -Instance 2)
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs.InstanceId | Should -Be @('USB\VID_0E8D&PID_7127&MI_06\8&00000000&1&0006', 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&2&0006')
    }

    It 'says a function goes on WinUSB at the next restart of Windows, and doesn''t try it again' {
        $script:records = @(Get-TestRecord -Unbound)
        $script:install = { [pscustomobject]@{ Done = $true; NeedReboot = $true; Step = 'Install'; Error = 0 } }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].Reason | Should -Be 'BindRestartNeeded'
        # Until Windows restarts, PnP may show the function on WinUSB with a problem.
        $script:records[0].Service = 'WINUSB'
        $script:records[0].ProblemCode = 14
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs.Count | Should -Be 1
        $script:link['Snapshot'].Reason | Should -Be 'BindRestartNeeded'
    }

    It 'carries a failed installation to the worker that replaces it, by a hash of its instance' {
        $script:records = @(Get-TestRecord -Unbound)
        $script:install = { [pscustomobject]@{ Done = $false; NeedReboot = $false; Step = 'Install'; Error = 5 } }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.Reason | Should -Be 'BindFailed'
        @($snapshot.Usb.Failed).Count | Should -Be 1
        $snapshot | ConvertTo-Json -Depth 12 | Should -Not -Match ([regex]::Escape('00000000&1&0006')) -Because 'a snapshot carries no instance ID'
        $script:now += 5000
        $script:worker = New-ModemWorker -Link $script:link -DataFolder $script:folder -Clock { $script:now } -Previous $snapshot
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs.Count | Should -Be 1 -Because 'an instance is tried once, not once per worker'
        $script:link['Snapshot'].Reason | Should -Be 'BindFailed'
        @($script:link['Snapshot'].Usb.Failed).Count | Should -Be 1
    }

    It 'still says, in the worker that replaces it, that Windows finishes an installation at its restart' {
        $script:records = @(Get-TestRecord -Unbound)
        $script:install = { [pscustomobject]@{ Done = $true; NeedReboot = $true; Step = 'Install'; Error = 0 } }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:records[0].Service = 'WINUSB'
        $script:records[0].ProblemCode = 14
        $script:now += 5000
        $script:worker = New-ModemWorker -Link $script:link -DataFolder $script:folder -Clock { $script:now } -Previous $script:link['Snapshot']
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs.Count | Should -Be 1
        $script:link['Snapshot'].Reason | Should -Be 'BindRestartNeeded'
    }

    It 'tries again, when the user checks now, what the worker it replaced saw fail' {
        $script:records = @(Get-TestRecord -Unbound)
        $script:install = { [pscustomobject]@{ Done = $false; NeedReboot = $false; Step = 'Install'; Error = 5 } }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:worker = New-ModemWorker -Link $script:link -DataFolder $script:folder -Clock { $script:now } -Previous $script:link['Snapshot']
        $script:install = { [pscustomobject]@{ Done = $true; NeedReboot = $false; Step = 'Install'; Error = 0 } }
        [void](Send-ModemCommand -Link $script:link -Kind ConnectNow)
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs.Count | Should -Be 2
        $script:link['Snapshot'].State | Should -Be 'Online'
        @($script:link['Snapshot'].Usb.Failed).Count | Should -Be 0
    }

    It 'looks at the ports of a function once per instance when looking fails, and says it once' {
        $script:records = @(Get-TestRecord -Unbound)
        Mock -ModuleName FibocomFm350 Test-UsbFunctionFree { throw [System.IO.IOException]::new('no') }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        Should -Invoke -ModuleName FibocomFm350 Test-UsbFunctionFree -Times 1 -Exactly
        $script:installs | Should -BeNullOrEmpty
        $script:link['Snapshot'].Reason | Should -Be 'BindFailed'
        @(Get-TestLog | Where-Object { $_ -match "can't be looked at" }).Count | Should -Be 1
    }

    It 'closes the AT port it opened when its channel can''t be made' {
        Mock -ModuleName FibocomFm350 New-AtChannel { throw [System.InvalidOperationException]::new('no channel') }
        try {
            Invoke-ModemWorkerCycle -Worker $script:worker
        }
        catch {
            $_.Exception.Message | Should -Be 'no channel'
        }
        $script:modems[1].Closed | Should -BeTrue
        $script:worker.Channel | Should -BeNullOrEmpty
    }

    It 'changes no driver without administrator rights, and says so' {
        Mock -ModuleName FibocomFm350 Test-AppElevation { $false }
        $script:worker = New-ModemWorker -Link $script:link -DataFolder $script:folder -Clock { $script:now }
        $script:records = @(Get-TestRecord -Unbound)
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].Reason | Should -Be 'BindNotElevated'
        $script:link['Snapshot'].Blocked | Should -BeTrue
        $script:installs | Should -BeNullOrEmpty
        Should -Invoke -ModuleName FibocomFm350 Test-UsbFunctionFree -Times 0 -Exactly
    }

    It 'changes no driver while it only observes, and says which step it withholds' {
        $script:worker = New-ModemWorker -Link $script:link -DataFolder $script:folder -Clock { $script:now } -ObserveOnly
        $script:records = @(Get-TestRecord -Unbound)
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.Action | Should -Be 'BindUsb'
        $snapshot.Reason | Should -BeNullOrEmpty
        $snapshot.Recovery.Check | Should -Be 'H1' -Because 'an AT port not on WinUSB yet is no silent port: no step for it'
        $script:installs | Should -BeNullOrEmpty
    }

    It 'puts the modem''s other functions on WinUSB when the user checks now, the port left open' {
        $script:records = @(Get-TestRecord -Gnss)
        $script:install = { [pscustomobject]@{ Done = $false; NeedReboot = $false; Step = 'Install'; Error = 31 } }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].State | Should -Be 'Online' -Because 'a function the app never opens failing is no failure of the connection'
        $script:installs.InstanceId | Should -Be @('USB\VID_0E8D&PID_7127&MI_03\8&00000000&1&0003')
        $script:now += 30000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs.Count | Should -Be 1
        $script:install = { [pscustomobject]@{ Done = $true; NeedReboot = $false; Step = 'Install'; Error = 0 } }
        [void](Send-ModemCommand -Link $script:link -Kind ConnectNow)
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs.Count | Should -Be 2
        $script:modems[1].Closed | Should -BeFalse
        Should -Invoke -ModuleName FibocomFm350 Open-WinUsbAtTransport -Times 1 -Exactly
        $script:link['Snapshot'].Usb.Functions.Driver | Should -Be @('WinUsb', 'WinUsb')
    }

    It 'never gives the port it holds open another driver, whatever a PnP read says of it: <Name>' -ForEach @(
        @{ Name = 'its service unread'; Service = $null; ParametersRead = $true }
        @{ Name = 'its registry parameters unread'; Service = 'WINUSB'; ParametersRead = $false }
        @{ Name = 'read as on another driver'; Service = 'usb2ser_tm'; ParametersRead = $true }
    ) {
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].State | Should -Be 'Online'
        $script:records[0].Service = $Service
        $script:records[0] | Add-Member -NotePropertyName ParametersRead -NotePropertyValue $ParametersRead -Force
        if (-not $ParametersRead) { $script:records[0].InterfaceGuids = $null }
        [void](Send-ModemCommand -Link $script:link -Kind ConnectNow)
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs | Should -BeNullOrEmpty
        $script:modems[1].Closed | Should -BeFalse
        $script:link['Snapshot'].State | Should -Be 'Online'
    }

    It 'never puts on WinUSB a function it couldn''t read at a scan: left to the next look' {
        $script:records = @(Get-TestRecord -Unbound)
        $script:records[0].Service = $null
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs | Should -BeNullOrEmpty
        $script:records = @(Get-TestRecord -Unbound)
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs.Count | Should -Be 1
    }

    It 'leaves the AT port on WinUSB under another program''s class while that program holds its interface' {
        $script:records = @(Get-TestRecord)
        $script:records[0].InterfaceGuids = @('{11111111-2222-3333-4444-555555555555}')
        Mock -ModuleName FibocomFm350 Test-UsbFunctionFree { [pscustomobject]@{ Free = $false; Held = 'Interface'; Error = 32 } }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:installs | Should -BeNullOrEmpty
        $script:link['Snapshot'].Reason | Should -Be 'PortInUse'
        Should -Invoke -ModuleName FibocomFm350 Test-UsbFunctionFree -ParameterFilter { $InterfaceGuid -contains '{11111111-2222-3333-4444-555555555555}' }
    }

    It 'leaves a function whose ports can''t be looked at, the cycle going on, and logs no port' {
        $script:records = @(Get-TestRecord -Gnss)
        Mock -ModuleName FibocomFm350 Test-UsbFunctionFree { throw [System.ArgumentException]::new('COM11 is odd') }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].State | Should -Be 'Online'
        $script:link['Snapshot'].Usb.Binding.Functions[0].Step | Should -Be 'Check'
        $script:installs | Should -BeNullOrEmpty
        @(Get-TestLog | Where-Object { $_ -match 'COM\d' }) | Should -BeNullOrEmpty
    }

    It 'says when another program holds the AT port, and tries again at the next scan' {
        Mock -ModuleName FibocomFm350 Open-WinUsbAtTransport { throw [System.ComponentModel.Win32Exception]::new(5) }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.State | Should -Be 'NoDevice'
        $snapshot.Reason | Should -Be 'PortInUse'
        $snapshot.Blocked | Should -BeFalse
        $script:worker.WaitMs | Should -Be 5000
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        Should -Invoke -ModuleName FibocomFm350 Open-WinUsbAtTransport -Times 2 -Exactly
        @(Get-TestLog | Where-Object { $_ -match "can't be opened" }).Count | Should -Be 1 -Because 'the same failure is logged once'
    }

    It 'reads data usage while another program holds the AT port' {
        Mock -ModuleName FibocomFm350 Open-WinUsbAtTransport { throw [System.ComponentModel.Win32Exception]::new(5) }
        Mock -ModuleName FibocomFm350 Get-ModemAdapterCounter { [pscustomobject]@{ Interface = 'x'; Received = [uint64]10; Sent = [uint64]1; Time = [DateTimeOffset]::Now } }
        Invoke-ModemWorkerCycle -Worker $script:worker

        $script:link['Snapshot'].Reason | Should -Be 'PortInUse'
        $script:link['Snapshot'].Usage | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName FibocomFm350 Get-ModemAdapterCounter -ParameterFilter { $InstanceId -eq 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&1&0000' }
    }

    It 'finds the network adapter a PnP read missed, without closing the port' {
        # The network function missed at the look that opened the port.
        $script:records = @(Get-TestRecord -NoNetwork)
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].Reason | Should -Be 'NoAdapter'
        $script:records = @(Get-TestRecord)
        $script:now += 5000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].State | Should -Be 'Online'
        Should -Invoke -ModuleName FibocomFm350 Open-WinUsbAtTransport -Times 1 -Exactly
        $script:modems[1].Closed | Should -BeFalse
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

Describe 'The worker on the simulated modem not on WinUSB (Unbound)' {
    It 'puts its functions on WinUSB and goes online, as on a real one' {
        $device = New-SimulatedDevice -Scenario Unbound
        $link = New-ModemWorkerLink
        $worker = New-ModemWorker -Link $link -Simulation $device -DataFolder (Join-Path $TestDrive ([guid]::NewGuid()))
        try {
            Invoke-ModemWorkerCycle -Worker $worker
            $device.Binds | Should -Be 7
            $link['Snapshot'].State | Should -Be 'Online'
            $link['Snapshot'].Usb.Device | Should -Be 'Present'
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $link
        }
    }

    It 'puts a modem back from a reset as a new instance on WinUSB again: an intended operation, nothing escalated' {
        $device = New-SimulatedDevice
        $device.NewInstanceOnReturn = $true
        $device.AwayMs = 0
        $link = New-ModemWorkerLink
        $worker = New-ModemWorker -Link $link -Simulation $device -DataFolder (Join-Path $TestDrive ([guid]::NewGuid()))
        try {
            Invoke-ModemWorkerCycle -Worker $worker
            $link['Snapshot'].State | Should -Be 'Online'
            $device.Restart()
            # A pass finds the port lost; the next look finds the modem back, as a new instance.
            [void](Send-ModemCommand -Link $link -Kind ConnectNow)
            Invoke-ModemWorkerCycle -Worker $worker
            Invoke-ModemWorkerCycle -Worker $worker
            $device.Instance | Should -Be 2
            $device.Binds | Should -Be 7
            $link['Snapshot'].State | Should -Be 'Online'
            $link['Snapshot'].Recovery.History.Step | Should -BeNullOrEmpty -Because 'no recovery step was taken'
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $link
        }
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
            $flaky | Add-Member -MemberType ScriptMethod -Name PnpRecords -Value {
                $this.Looks++
                if ($this.Looks -eq 1) { throw 'PnP is busy.' }
                $this.Device.PnpRecords()
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
            $opened = @($log -match 'AT port open \(SIMULATED\)')[0]
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
            $broken | Add-Member -MemberType ScriptMethod -Name PnpRecords -Value { throw 'PnP is broken.' }
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

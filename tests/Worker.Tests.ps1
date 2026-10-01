# The worker: its schedule (pure), its snapshots, and its cycles on the simulated modem - attaching
# without a write, a restarted worker that attaches, the user's commands, a port lost and found
# again by PnP under another COM number, a port held by another program, the heartbeat while the
# modem takes its time; and the whole loop in a runspace of its own.

BeforeAll {
    $script:modulePath = "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1"
    Import-Module $script:modulePath -Force

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
    ) {
        $schedule = Resolve-WorkerSchedule @Arguments
        $schedule.Scan | Should -Be $Scan
        $schedule.Pass | Should -Be $Pass
        $schedule.Status | Should -Be $Status
        $schedule.WaitMs | Should -Be $Wait
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
            $log -match 'ERROR\s+Cycle failed \(1 in a row\): .*PnP is busy' | Should -Not -BeNullOrEmpty
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

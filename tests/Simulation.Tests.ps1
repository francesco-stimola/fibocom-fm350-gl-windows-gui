# Development mode's simulated device: every scenario builds, the scenario names agree everywhere
# they are listed, the simulated adapter behaves as a real one is configured, and the modem leaves
# USB and comes back as a restart makes it.

BeforeDiscovery {
    $script:scenarios = @((Import-PowerShellDataFile -Path "$PSScriptRoot/../src/FibocomFm350/Data/Simulation.psd1").Scenarios.Keys | Sort-Object)
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    $script:data = Import-PowerShellDataFile -Path "$PSScriptRoot/../src/FibocomFm350/Data/Simulation.psd1"

    # The simulated modem as the worker finds it: its PnP records, through the same pure functions.
    function Find-SimulatedModem {
        param([object] $Device)
        Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device @($Device.PnpRecords()))
    }

    # The ValidateSet of a script's -Scenario parameter.
    function Get-ScriptScenario {
        param([string] $Path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Scenario' }
        $set = $parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        @($set.PositionalArguments.Value | Sort-Object)
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'New-SimulatedDevice' {
    It 'lists the scenarios of the data file, and so does the app''s start script' {
        $names = @($script:data.Scenarios.Keys | Sort-Object)
        @((Get-Command New-SimulatedDevice).Parameters['Scenario'].Attributes.ValidValues | Sort-Object) | Should -Be $names
        Get-ScriptScenario -Path "$PSScriptRoot/../src/App/Start-Fm350App.ps1" | Should -Be $names
    }

    It 'builds the <_> scenario' -ForEach $script:scenarios {
        $device = New-SimulatedDevice -Scenario $_
        $device.Scenario | Should -Be $_
        $device.Modem.PortName | Should -Be 'SIMULATED'
        (Find-SimulatedModem $device).Device | Should -BeIn 'Present', 'Absent', 'Unbound'
    }

    It 'answers the commands of a connect pass and of the recovery steps from its base answers' {
        foreach ($command in $script:data.Answers.Keys) {
            # One device per command: a reset takes it off USB.
            $device = New-SimulatedDevice
            $channel = New-AtChannel -Transport $device.Open()
            try {
                $answer = Invoke-AtCommand -Channel $channel -Command $command -TimeoutMs 3000
            }
            finally {
                Close-AtChannel -Channel $channel
            }
            $answer.Status | Should -BeIn 'OK', 'CmeError' -Because "$command has a standing answer"
        }
    }

    It 'holds the messages of the data file on its SIM, and one coming in later' {
        $device = New-SimulatedDevice
        $channel = New-AtChannel -Transport $device.Open()
        try {
            $listing = Invoke-AtCommand -Channel $channel -Command 'AT+CMGL=4' -TimeoutMs 3000
        }
        finally {
            Close-AtChannel -Channel $channel
        }
        $entries = @(ConvertFrom-AtMessageList -Lines $listing.Lines)
        @($entries | ForEach-Object Status) | Should -Be @('Read', 'Unread', 'Unread', 'Unread')
        @($entries | ForEach-Object { (ConvertFrom-SmsPdu -Pdu $_.Pdu).Problem } | Where-Object { $_ }) | Should -BeNullOrEmpty
        $device.Modem.Messaging.Arrivals.Count | Should -Be 1
        $device.Modem.Messaging.Arrivals[0].AtMs | Should -Be 60000
        $empty = (New-SimulatedDevice -Scenario Connect).Modem.Messaging
        $empty.Stored.Count + $empty.Arrivals.Count | Should -Be 0 -Because 'a scenario may hold messages of its own, none here'
    }

    It 'keeps its messages across a restart, its notices off again' {
        $device = New-SimulatedDevice
        $device.AwayMs = 0
        $device.Modem.Messaging.Notices = @('2', '1', '0', '0', '0')
        $device.Restart()
        (Find-SimulatedModem $device).Device | Should -Be 'Present'

        $device.Modem.Messaging.Notices | Should -Be @('0', '0', '0', '0', '0')
        $device.Modem.Messaging.Stored.Count | Should -Be 4
    }
}

Describe 'The simulated adapter' {
    It 'reads as a copy: what the caller holds never changes under it' {
        $adapter = (New-SimulatedDevice -Scenario Connect).Adapter
        $reading = $adapter.Read()
        $adapter.Dhcp = 'Disabled'
        $reading.Dhcp | Should -Be 'Enabled'
    }

    It 'applies a plan as the real adapter is configured, and is then configured' {
        $adapter = (New-SimulatedDevice -Scenario Connect).Adapter
        $settings = (ConvertTo-AppSetting -InputObject $null).Settings
        $context = [pscustomobject]@{ IPv4Address = '192.0.2.10'; IPv4PrefixLength = $null; IPv4Gateway = $null; Dns = @('192.0.2.53') }
        $plan = Resolve-AdapterConfiguration -Context $context -Adapter $adapter.Read() -Settings $settings
        $results = @($adapter.Apply($plan))
        $results.Action | Should -Be @('DisableDhcp', 'SetAddress', 'SetGateway', 'SetDns', 'SetMetric')
        @($results | Where-Object { -not $_.Done }).Count | Should -Be 0
        (Resolve-AdapterConfiguration -Context $context -Adapter $adapter.Read() -Settings $settings).Configured | Should -BeTrue
    }

    It 'is enabled again' {
        $adapter = (New-SimulatedDevice -Scenario AdapterDisabled).Adapter
        $adapter.Status | Should -Be 'Disabled'
        $adapter.Enable()
        $adapter.Status | Should -Be 'Up'
    }

    It 'keeps an address just set tentative for its first checks, as Windows does' {
        $device = New-SimulatedDevice -Scenario Settling
        $device.Adapter.Apply([pscustomobject]@{ Actions = @([pscustomobject]@{ Action = 'SetAddress'; Address = '192.0.2.10'; PrefixLength = 32 }) })
        ($device.Adapter.Read().Addresses | Where-Object Address -EQ '192.0.2.10').State | Should -Be 'Tentative'
        @(1..3 | ForEach-Object { $device.Adapter.AddressState('192.0.2.10') }) | Should -Be @('Tentative', 'Tentative', 'Preferred')
        ($device.Adapter.Read().Addresses | Where-Object Address -EQ '192.0.2.10').State | Should -Be 'Preferred'
        $device.Adapter.AddressState('192.0.2.99') | Should -Be 'Missing'
    }
}

Describe 'The simulated data path' {
    It 'gets through on a configured adapter' {
        $round = (New-SimulatedDevice -Scenario Online).Probe('192.0.2.10')
        $round.Result | Should -Be 'Passed'
        $round.Status | Should -Be 0
    }

    It 'sends nothing from an address the adapter doesn''t have, or one still tentative' {
        $device = New-SimulatedDevice -Scenario Settling
        $device.Probe('192.0.2.10').Result | Should -Be 'NotReady'
    }

    It 'loses the rounds a settling path loses, then gets through' {
        $device = New-SimulatedDevice -Scenario Online
        $device.LostRounds = 1
        @(1..2 | ForEach-Object { $device.Probe('192.0.2.10').Result }) | Should -Be @('Failed', 'Passed')
    }

    It 'never answers on a network that drops ICMP (IcmpDropped)' {
        $device = New-SimulatedDevice -Scenario IcmpDropped
        @(1..3 | ForEach-Object { $device.Probe('192.0.2.10').Result }) | Should -Be @('Failed', 'Failed', 'Failed')
    }

    It 'is proven once, then down until the context is restarted (DataPathDown)' {
        $device = New-SimulatedDevice -Scenario DataPathDown
        $device.Probe('192.0.2.10').Result | Should -Be 'Passed'
        $device.Probe('192.0.2.10').Result | Should -Be 'Failed'
        $channel = New-AtChannel -Transport $device.Open()
        try {
            (Invoke-AtCommand -Channel $channel -Command 'AT+CGACT=0,1' -TimeoutMs 3000).Status | Should -Be 'OK'
            (Invoke-AtCommand -Channel $channel -Command 'AT+CGACT?' -TimeoutMs 3000).Lines | Should -BeNullOrEmpty
        }
        finally {
            Close-AtChannel -Channel $channel
        }
        $device.Probe('192.0.2.10').Result | Should -Be 'Passed'
    }
}

Describe 'The simulated modem and the recovery steps' {
    BeforeEach {
        $script:send = {
            param($device, [string[]] $commands)
            $channel = New-AtChannel -Transport $device.Open()
            try {
                foreach ($command in $commands) { Invoke-AtCommand -Channel $channel -Command $command -TimeoutMs 1000 }
            }
            finally {
                Close-AtChannel -Channel $channel
            }
        }
    }

    It 'changes its answers every time a step runs, not only the first' {
        $device = New-SimulatedDevice -Scenario Online
        foreach ($i in 1..2) {
            $answers = & $script:send $device 'AT+CFUN=4', 'AT+CFUN?', 'AT+CFUN=1', 'AT+CFUN?'
            $answers[1].Lines | Should -Be @('+CFUN: 4')
            $answers[3].Lines | Should -Be @('+CFUN: 1')
        }
    }

    It 'changes nothing for a command it refuses: a locked radio stays off' {
        $device = New-SimulatedDevice -Scenario FccLocked
        $answers = & $script:send $device 'AT+CFUN=1', 'AT+CFUN?'
        $answers[0].ErrorCode | Should -Be 0
        $answers[1].Lines | Should -Be @('+CFUN: 4')
    }

    It 'registers again after the radio off and on, not after re-registering (RegistrationLost)' {
        $device = New-SimulatedDevice -Scenario RegistrationLost
        $answers = & $script:send $device 'AT+COPS=2', 'AT+COPS=0', 'AT+CEREG?;+C5GREG?'
        ($answers[2].Lines | ConvertFrom-AtRegistration -ReadAnswer | Where-Object Domain -EQ 'EPS').Registered | Should -BeFalse
        $answers = & $script:send $device 'AT+CFUN=4', 'AT+CFUN=1', 'AT+CEREG?;+C5GREG?'
        ($answers[2].Lines | ConvertFrom-AtRegistration -ReadAnswer | Where-Object Domain -EQ 'EPS').Registered | Should -BeTrue
    }

    It 'resets: off USB, and back with its base answers' {
        $device = New-SimulatedDevice -Scenario DataPathDown
        $device.AwayMs = 60000
        $answers = & $script:send $device 'AT+CFUN=15', 'AT'
        $answers[0].Status | Should -Be 'OK'
        $answers[1].Status | Should -Be 'PortLost'
        (Find-SimulatedModem $device).Device | Should -Be 'Absent'
        $device.AwayMs = 0
        (Find-SimulatedModem $device).Device | Should -Be 'Present'
        $device.Probe('192.0.2.10').Result | Should -Be 'Passed'
    }

    It 'answers nothing while hung, and again once its USB device restarted (ModemHung)' {
        $device = New-SimulatedDevice -Scenario ModemHung
        $answer = & $script:send $device 'AT'
        $answer.Status | Should -Be 'Timeout'
        $answer.EchoSeen | Should -BeFalse
        $device.AwayMs = 0
        $device.Restart()
        (Find-SimulatedModem $device).Device | Should -Be 'Present'
        (& $script:send $device 'AT').Status | Should -Be 'OK'
    }

    It 'stays refused whatever is done (Unrecoverable)' {
        $device = New-SimulatedDevice -Scenario Unrecoverable
        $device.AwayMs = 0
        $answers = & $script:send $device 'AT+COPS=2', 'AT+COPS=0', 'AT+CFUN=4', 'AT+CFUN=1', 'AT+CFUN=15', 'AT'
        @($answers.Status) | Should -Be @('OK', 'OK', 'OK', 'OK', 'OK', 'PortLost')
        [void](Find-SimulatedModem $device)
        $answer = & $script:send $device 'AT+CEREG?;+C5GREG?'
        ($answer.Lines | ConvertFrom-AtRegistration -ReadAnswer | Where-Object Domain -EQ 'EPS').State | Should -Be 'Denied'
    }

    It 'gives the composite device''s instance ID while present' {
        $device = New-SimulatedDevice
        (Find-SimulatedModem $device).InstanceId | Should -Be 'USB\VID_0E8D&PID_7127\SIMULATED1'
        $device.AwayMs = 60000
        $device.Restart()
        (Find-SimulatedModem $device).InstanceId | Should -BeNullOrEmpty
    }
}

Describe 'The simulated network mode' {
    BeforeAll {
        . "$PSScriptRoot/FixtureAnswer.ps1"
        $script:converse = {
            param($device, [string[]] $commands)
            $channel = New-AtChannel -Transport $device.Open()
            try {
                foreach ($command in $commands) { Invoke-AtCommand -Channel $channel -Command $command -TimeoutMs 1000 }
            }
            finally {
                Close-AtChannel -Channel $channel
            }
        }
        $script:registered = {
            param($answer)
            @($answer.Lines | ConvertFrom-AtRegistration -ReadAnswer | Where-Object Registered).Count -gt 0
        }
    }

    It 'answers as the device does: <Command>' -ForEach @(
        @{ Command = 'AT+GTACT=?'; Fixture = 'gtact.test.txt' }
        @{ Command = 'AT+GTACT?'; Fixture = 'gtact.auto.txt' }
    ) {
        (& $script:converse (New-SimulatedDevice) $Command).Lines | Should -Be (Get-FixtureAnswer -Name $Fixture -Folder device)
    }

    It 'lists the bands of the RATs in its mode only, as the device in LTE-only mode' {
        (& $script:converse (New-SimulatedDevice -Scenario LteOnlyMode) 'AT+GTACT?').Lines | Should -Be (Get-FixtureAnswer -Name 'gtact.lteonly.txt' -Folder device)
    }

    It 'changes the list of each RAT a write names, and keeps the others: <Case>' -ForEach @(
        @{ Case = 'LTE and NR in one write'; Write = 'AT+GTACT=20,6,3,103,120,5078'; Fixture = 'gtact.combined.txt' }
        @{ Case = 'every LTE band, NR left as it was'; Write = 'AT+GTACT=20,6,3,5078'; Then = 'AT+GTACT=20,6,3,101,102,103,104,105,107,108,112,113,114,117,118,119,120,125,126,128,129,130,132,134,138,139,140,141,142,143,146,148,166,171'; Fixture = 'gtact.ltefull-n78.txt' }
    ) {
        $commands = @($Write) + $(if ($Then) { @($Then) } else { @() }) + 'AT+GTACT?'
        $answers = & $script:converse (New-SimulatedDevice) $commands
        @($answers | Select-Object -SkipLast 1).Status | Should -Not -Contain 'Error'
        $answers[-1].Lines | Should -Be (Get-FixtureAnswer -Name $Fixture -Folder device)
    }

    It 'gives every band back for code 0, n77 listed until it has registered' {
        $device = New-SimulatedDevice
        $answers = & $script:converse $device 'AT+GTACT=20,6,3,5078', 'AT+GTACT=20,6,3,0', 'AT+GTACT?', 'AT+CEREG?;+C5GREG?', 'AT+CEREG?;+C5GREG?', 'AT+GTACT?'
        $answers[2].Lines[0] | Should -Match ',5077,'
        & $script:registered $answers[3] | Should -BeFalse -Because 'a write registers it again'
        & $script:registered $answers[4] | Should -BeTrue
        $answers[5].Lines | Should -Be (Get-FixtureAnswer -Name 'gtact.auto.txt' -Folder device)
    }

    It 'drops n77 as the device does: <Case>' -ForEach @(
        @{ Case = 'with n78, once registered'; Write = 'AT+GTACT=20,6,3,5077,5078'; Fixture = 'gtact.n77-n78.txt' }
        @{ Case = 'alone, kept'; Write = 'AT+GTACT=20,6,3,5077'; Fixture = 'gtact.n77-alone.txt' }
        @{ Case = 'in NR-only mode, without a registration'; Write = 'AT+GTACT=14,6,6,0'; Fixture = 'gtact.nronly.txt' }
    ) {
        $answers = & $script:converse (New-SimulatedDevice) $Write, 'AT+CEREG?;+C5GREG?', 'AT+CEREG?;+C5GREG?', 'AT+GTACT?'
        $answers[-1].Lines | Should -Be (Get-FixtureAnswer -Name $Fixture -Folder device)
    }
    It 'refuses a write with a value it doesn''t take, and changes nothing: <Write>' -ForEach @(
        @{ Write = 'AT+GTACT=21,6,3' }
        @{ Write = 'AT+GTACT=20,7,3' }
        @{ Write = 'AT+GTACT=20,6,3,103,199' }
        @{ Write = 'AT+GTACT=20,6,3,x' }
    ) {
        $answers = & $script:converse (New-SimulatedDevice) $Write, 'AT+GTACT?', 'AT+CEREG?;+C5GREG?'
        $answers[0].Status | Should -Be 'Error'
        $answers[1].Lines | Should -Be (Get-FixtureAnswer -Name 'gtact.auto.txt' -Folder device)
        & $script:registered $answers[2] | Should -BeTrue
    }

    It 'finds <Found> in <Case>' -ForEach @(
        @{ Case = 'LTE only'; Scenario = 'Online'; Write = 'AT+GTACT=2,3,3'; Found = 'LTE'; Technology = 'LTE-A' }
        @{ Case = 'automatic, NR on a band the network doesn''t use'; Scenario = 'Online'; Write = 'AT+GTACT=20,6,3,501'; Found = 'LTE'; Technology = 'LTE-A' }
        @{ Case = 'LTE on a band the network doesn''t use'; Scenario = 'Online'; Write = 'AT+GTACT=2,3,3,171'; Found = 'nothing'; Technology = $null }
        @{ Case = 'NR only without 5G SA'; Scenario = 'Online'; Write = 'AT+GTACT=14,6,6'; Found = 'nothing'; Technology = $null }
        @{ Case = 'NR only with 5G SA'; Scenario = 'Standalone'; Write = 'AT+GTACT=14,6,6'; Found = '5G SA'; Technology = '5G SA' }
    ) {
        $answers = & $script:converse (New-SimulatedDevice -Scenario $Scenario) $Write, 'AT+CEREG?;+C5GREG?', 'AT+CEREG?;+C5GREG?', 'AT+CGACT?', 'AT+CESQ', 'AT+GTCCINFO?;+GTCAINFO?'
        $answers[0].Status | Should -Be 'OK'
        & $script:registered $answers[2] | Should -Be ($Found -ne 'nothing')
        $answers[3].Lines | Should -BeNullOrEmpty -Because 'the data context goes with the registration'
        $radio = Resolve-RadioStatus -Signal (ConvertFrom-AtSignalQuality -Lines $answers[4].Lines) -Cell @(ConvertFrom-AtCellInfo -Lines $answers[5].Lines) -Carrier @(ConvertFrom-AtCarrierAggregation -Lines $answers[5].Lines)
        $radio.Technology | Should -Be $Technology
    }

    It 'keeps its mode across a reset, and comes back in it' {
        $device = New-SimulatedDevice
        $device.AwayMs = 0
        $answers = & $script:converse $device 'AT+GTACT=14,6,6', 'AT+CFUN=15', 'AT'
        $answers[1].Status | Should -Be 'OK'
        $answers[2].Status | Should -Be 'PortLost'
        [void](Find-SimulatedModem $device)
        $answers = & $script:converse $device 'AT+GTACT?', 'AT+CEREG?;+C5GREG?', 'AT+GTCCINFO?;+GTCAINFO?'
        $answers[0].Lines[0] | Should -BeLike '+GTACT: 14,6,6,*'
        & $script:registered $answers[1] | Should -BeFalse -Because 'NR alone finds no network here, after a reset too'
        @(ConvertFrom-AtCellInfo -Lines $answers[2].Lines) | Should -BeNullOrEmpty
    }

    It 'starts as the scenario says: NR only, no network' {
        $answers = & $script:converse (New-SimulatedDevice -Scenario NrOnlyMode) 'AT+GTACT?', 'AT+CEREG?;+C5GREG?'
        $answers[0].Lines[0] | Should -BeLike '+GTACT: 14,6,6,501,*'
        & $script:registered $answers[1] | Should -BeFalse
    }
}

Describe 'The simulated modem on USB' {
    It 'is away for a while after it vanished, then back on the same port' {
        $device = New-SimulatedDevice
        $device.AwayMs = 60000
        $device.Modem.Vanish()
        (Find-SimulatedModem $device).Device | Should -Be 'Absent'
        $device.AwayMs = 0
        $presence = (Find-SimulatedModem $device)
        $presence.Device | Should -Be 'Present'
        $presence.AtInstanceId | Should -Be 'USB\VID_0E8D&PID_7127&MI_06\SIMULATED1&0006'
        $device.Modem.Lost | Should -BeFalse
    }

    It 'opens again after a channel closed it, keeping what commands changed' {
        $device = New-SimulatedDevice -Scenario Connect
        $channel = New-AtChannel -Transport $device.Open()
        [void](Invoke-AtCommand -Channel $channel -Command 'AT+CGACT=1,1' -TimeoutMs 3000)
        Close-AtChannel -Channel $channel
        $device.Modem.Closed | Should -BeTrue
        $channel = New-AtChannel -Transport $device.Open()
        try {
            (Invoke-AtCommand -Channel $channel -Command 'AT+CGACT?' -TimeoutMs 3000).Lines | Should -Be @('+CGACT: 1,1')
        }
        finally {
            Close-AtChannel -Channel $channel
        }
    }

    It 'restarts after the FCC unlock, unlocked' {
        $device = New-SimulatedDevice -Scenario FccLocked
        $channel = New-AtChannel -Transport $device.Open()
        try {
            (Invoke-FccUnlock -Channel $channel -Confirm:$false).Result | Should -Be 'Restarted'
            (Invoke-AtCommand -Channel $channel -Command 'AT' -TimeoutMs 1000).Status | Should -Be 'PortLost'
        }
        finally {
            Close-AtChannel -Channel $channel
        }
        $device.AwayMs = 0
        [void](Find-SimulatedModem $device)
        $channel = New-AtChannel -Transport $device.Open()
        try {
            $lock = ConvertFrom-AtFccLock -Lines (Invoke-AtCommand -Channel $channel -Command 'AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?' -TimeoutMs 3000).Lines
            $lock.Unlocked | Should -BeTrue
        }
        finally {
            Close-AtChannel -Channel $channel
        }
    }

    It 'has its vendor functions on WinUSB, the AT port with the app''s interface class' {
        $presence = Find-SimulatedModem (New-SimulatedDevice)
        $presence.Device | Should -Be 'Present'
        ($presence.Functions | Where-Object WinUsb).Interface | Should -Be @(2, 3, 4, 5, 6, 7, 8, 9)
        ($presence.Functions | Where-Object Role -EQ 'Network').Service | Should -Be 'usbrndis6'
        (Resolve-ModemBinding -Function $presence.Functions).Bind | Should -BeNullOrEmpty
    }

    It 'has them on MediaTek''s driver until the app puts them on WinUSB, as Device Manager would (Unbound)' {
        $device = New-SimulatedDevice -Scenario Unbound
        $presence = Find-SimulatedModem $device
        $presence.Device | Should -Be 'Unbound'
        $plan = Resolve-ModemBinding -Function $presence.Functions
        $plan.Bind.Interface | Should -Be @(6, 2, 3, 4, 7, 8, 9)
        $plan.Bind[0].PortName | Should -Be 'COM26'
        $device.TryPort('COM26') | Should -Be 0
        foreach ($function in $plan.Bind) {
            $device.Bind($function.InstanceId).Done | Should -BeTrue
        }
        $device.Binds | Should -Be 7
        (Find-SimulatedModem $device).Device | Should -Be 'Present'
        $device.Restore($plan.Bind[0].InstanceId).Step | Should -Be 'Best'
        (Find-SimulatedModem $device).Device | Should -Be 'Unbound'
    }

    It 'says a port another program holds, and an installation that fails or waits for a restart' {
        $device = New-SimulatedDevice -Scenario Unbound
        [void]$device.HeldPorts.Add(6)
        $device.TryPort('COM26') | Should -Be 170
        $device.TryPort('COM23') | Should -Be 0
        $at = (Find-SimulatedModem $device).AtInstanceId
        $device.BindResult = 'Failed'
        $device.Bind($at).Done | Should -BeFalse
        $device.BindResult = 'RestartNeeded'
        $device.Bind($at).NeedReboot | Should -BeTrue
        (Find-SimulatedModem $device).Device | Should -Be 'Unbound'
    }

    It 'comes back from a reset as a new instance on MediaTek''s driver, when asked to' {
        $device = New-SimulatedDevice
        $device.NewInstanceOnReturn = $true
        $device.AwayMs = 0
        $device.Restart()
        $presence = Find-SimulatedModem $device
        $presence.Device | Should -Be 'Unbound'
        $presence.InstanceId | Should -Be 'USB\VID_0E8D&PID_7127\SIMULATED2'
    }
    It 'has no function without a modem on USB (NoDevice)' {
        $device = New-SimulatedDevice -Scenario NoDevice
        $device.PnpRecords() | Should -BeNullOrEmpty
        $presence = (Find-SimulatedModem $device)
        $presence.Device | Should -Be 'Absent'
        $presence.ProductId | Should -BeNullOrEmpty
    }
}

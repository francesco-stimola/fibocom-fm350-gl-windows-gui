# What the tray and the window show, from a snapshot: the icon's tone, bars and label, the tooltip,
# every reason and command outcome in words, what the user can do about a block - on the snapshots
# the worker publishes for each simulated scenario, and on made-up ones.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    Import-Module "$PSScriptRoot/../src/App/FibocomFm350.App.psd1" -Force

    # The snapshot the worker publishes after one cycle on a simulated scenario.
    function Get-ScenarioSnapshot {
        param([string] $Scenario, [hashtable] $Extra = @{})
        $link = New-ModemWorkerLink
        $worker = New-ModemWorker -Link $link -Simulation (New-SimulatedDevice -Scenario $Scenario) -DataFolder (Join-Path $TestDrive ([guid]::NewGuid())) @Extra
        try {
            Invoke-ModemWorkerCycle -Worker $worker
            $link['Snapshot']
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $link
        }
    }

    # A copy of a snapshot with some properties changed.
    function Copy-Snapshot {
        param([object] $Snapshot, [hashtable] $Change = @{})
        $copy = $Snapshot | Select-Object -Property *
        foreach ($key in $Change.Keys) {
            $copy.$key = $Change[$key]
        }
        $copy
    }

    $script:online = Get-ScenarioSnapshot -Scenario Online
}

BeforeDiscovery {
    # Every reason the state machine and the SIM rules give, and the registration states that
    # are not registered.
    $script:reasons = @(
        'NoDevice', 'NoDriver', 'DeviceProblem', 'PortInUse', 'PortFailed', 'SimUnknown'
        'NoPin', 'PinForOtherSim', 'SimNotIdentified', 'PinUnconfirmed', 'LastAttempt', 'PukRequired', 'NoSim', 'SimFailure', 'SimOther', 'SimBusy'
        'FccLocked', 'NotRegistered', 'NotSearching', 'Searching', 'Denied', 'Unknown', 'EmergencyOnly'
        'ContextUnknown', 'ApnPasswordUnreadable', 'ApnNeeded', 'NoAddress', 'AdapterDisabled', 'NoAdapter', 'NotElevated', 'DataPathFailed'
    )
}

AfterAll {
    Remove-Module FibocomFm350.App, FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Resolve-TrayIcon' {
    It '<Scenario>: <Tone>, <Bars> bars, label <Label>' -ForEach @(
        @{ Scenario = 'Online'; Tone = 'Online'; Bars = 2; Label = '5G' }
        @{ Scenario = 'ApnNeeded'; Tone = 'Attention'; Bars = 2; Label = '5G' }
        @{ Scenario = 'PinRequired'; Tone = 'Attention'; Bars = $null; Label = $null }
        @{ Scenario = 'FccLocked'; Tone = 'Attention'; Bars = $null; Label = $null }
        @{ Scenario = 'NoDriver'; Tone = 'Attention'; Bars = $null; Label = $null }
        @{ Scenario = 'NoDevice'; Tone = 'Offline'; Bars = $null; Label = $null }
    ) {
        $icon = Resolve-TrayIcon -Snapshot (Get-ScenarioSnapshot -Scenario $Scenario)
        $icon.Tone | Should -Be $Tone
        $icon.Bars | Should -Be $Bars
        $icon.Label | Should -Be $Label
    }

    It 'is amber while the connection is on its way' {
        $snapshot = Copy-Snapshot $script:online @{ State = 'Registered'; Action = 'ActivateContext'; Reason = $null; Blocked = $false }
        (Resolve-TrayIcon -Snapshot $snapshot).Tone | Should -Be 'Working'
    }

    It 'says 4G on LTE' {
        $radio = $script:online.Radio | Select-Object -Property *
        $radio.Technology = 'LTE-A'
        (Resolve-TrayIcon -Snapshot (Copy-Snapshot $script:online @{ Radio = $radio })).Label | Should -Be '4G'
    }

    It 'says 4G on an idle anchor cell, where 5G is only available' {
        $radio = $script:online.Radio | Select-Object -Property *
        $radio.Technology = 'LTE'
        $radio.NrAvailable = $true
        $snapshot = Copy-Snapshot $script:online @{ Radio = $radio }
        (Resolve-TrayIcon -Snapshot $snapshot).Label | Should -Be '4G'
        (ConvertTo-WindowView -Snapshot $snapshot).Technology | Should -Be 'LTE, 5G available'
    }

    It 'is grey and empty without a snapshot, or while the worker <Worker>' -ForEach @(
        @{ Worker = 'Restarting' }
        @{ Worker = 'NotResponding' }
    ) {
        (Resolve-TrayIcon -Snapshot $null).Tone | Should -Be 'Stopped'
        $icon = Resolve-TrayIcon -Snapshot $script:online -Worker $Worker
        $icon.Tone | Should -Be 'Stopped'
        $icon.Bars | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-TrayText' {
    It 'says online, the technology, the operator and the RSRP' {
        ConvertTo-TrayText -Snapshot $script:online | Should -Be 'FM350-GL: Online - 5G NSA - 001 01 - RSRP -97 dBm'
    }

    It 'says why when not online' {
        ConvertTo-TrayText -Snapshot (Get-ScenarioSnapshot -Scenario PinRequired) | Should -Be 'FM350-GL: Action needed - The SIM is waiting for its PIN.'
    }

    It 'says when nothing is monitored' {
        ConvertTo-TrayText -Snapshot $script:online -Worker Restarting | Should -Be 'FM350-GL: Not monitoring'
    }

    It 'never goes beyond 127 characters: <_>' -ForEach $script:reasons {
        $text = ConvertTo-TrayText -Snapshot (Copy-Snapshot $script:online @{ State = 'SimReady'; Reason = $_; Blocked = $true })
        $text.Length | Should -BeLessOrEqual 127
    }

    It 'cuts a longer text at 127 characters' {
        $radio = $script:online.Radio | Select-Object -Property *
        $radio.Operator = 'x' * 200
        $text = ConvertTo-TrayText -Snapshot (Copy-Snapshot $script:online @{ Radio = $radio })
        $text.Length | Should -Be 127
        $text[-1] | Should -Be ([char]0x2026) -Because 'an ellipsis says it was cut'
    }
}

Describe 'ConvertTo-WindowView' {
    It 'says every reason in words: <_>' -ForEach $script:reasons {
        $view = ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ State = 'SimReady'; Reason = $_; Blocked = $true })
        $view.Detail | Should -Not -Match '^Not registered \(' -Because 'the reason has its own sentence'
        $view.Detail | Should -Match '\.$'
    }

    It 'says what the next step does while the connection is on its way: <_>' -ForEach @(
        'OpenPort', 'Initialize', 'EnterPin', 'RadioOn', 'AutoRegister', 'DefineContext', 'ActivateContext', 'DeactivateContext', 'ConfigureAdapter'
    ) {
        $view = ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ State = 'SimReady'; Action = $_; Reason = $null; Blocked = $false })
        $view.Detail | Should -Not -Be 'Working on the connection.'
        $view.Title | Should -Be 'Connecting'
    }

    It 'shows the signal, the cells and the carriers' {
        $view = ConvertTo-WindowView -Snapshot $script:online
        $view.Title | Should -Be 'Online'
        $view.Technology | Should -Be '5G NSA'
        $view.Operator | Should -Be '001 01'
        $view.Signal | Should -Be @('LTE: RSRP -97 dBm, RSRQ -13 dB', 'NR: RSRP -108 dBm, RSRQ -23.5 dB, SINR 11 dB')
        $view.Cells.Count | Should -Be 3
        $view.Cells[1].Band | Should -Be 'n78'
        $view.Cells[1].Bandwidth | Should -Be '80 MHz'
        $view.Blocker | Should -BeNullOrEmpty
    }

    It 'writes numbers in the invariant culture, whatever the user''s' {
        $culture = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo('it-IT')
            $view = ConvertTo-WindowView -Snapshot $script:online
        }
        finally {
            [cultureinfo]::CurrentCulture = $culture
        }
        $view.Signal[1] | Should -Match '-23\.5 dB'
        $view.Cells[0].Rsrq | Should -Be '-13.5 dB'
    }

    It 'shows uplink values only for a carrier that carries uplink' {
        $carriers = (ConvertTo-WindowView -Snapshot $script:online).Carriers
        $carriers[0].Bandwidth | Should -Be '80/80 MHz' -Because 'a primary carrier carries uplink'
        $carriers[2].Bandwidth | Should -Be '15/10 MHz' -Because 'SCC1 has uplink CA'
        $carriers[3].Bandwidth | Should -Be '15 MHz' -Because 'SCC2 has none: its uplink fields are placeholders'
        $carriers[3].Mimo | Should -Be '1'
    }

    It 'notes development mode, observe-only, pending settings, settings problems and a second modem' {
        $snapshot = Copy-Snapshot $script:online @{ ObserveOnly = $true; SettingsPending = $true; SettingsProblems = @('Apn must be printable ASCII.'); Modems = 2 }
        $note = (ConvertTo-WindowView -Snapshot $snapshot).Note
        $note | Should -Match 'Development mode'
        $note | Should -Match 'only observes'
        $note | Should -Match 'next connection'
        $note | Should -Match 'Apn must be printable'
        $note | Should -Match '2 modems found'
    }

    It 'says the next step is not taken while the app only observes' {
        $snapshot = Get-ScenarioSnapshot -Scenario Connect -Extra @{ ObserveOnly = $true }
        $view = ConvertTo-WindowView -Snapshot $snapshot
        $view.Title | Should -Be 'Not connected'
        $view.Detail | Should -Be 'The app only observes, so it doesn''t take the next step: setting up the data connection.'
        ConvertTo-TrayText -Snapshot $snapshot | Should -BeLike 'FM350-GL: Not connected - The app only observes*'
        (Resolve-TrayIcon -Snapshot $snapshot).Tone | Should -Be 'Working'
    }

    It 'says the worker is restarting, without a blocker' {
        $view = ConvertTo-WindowView -Snapshot (Get-ScenarioSnapshot -Scenario ApnNeeded) -Worker Restarting
        $view.Title | Should -Be 'Not monitoring'
        $view.Detail | Should -Match 'restarting'
        $view.Blocker | Should -BeNullOrEmpty
    }

    It 'shows the port, the time of the update, and missing administrator rights' {
        $footer = (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Elevated = $false })).Footer
        $footer | Should -Match '^AT port SIMULATED - updated \d\d:\d\d:\d\d - no administrator rights$'
    }

    It 'starts empty, with no snapshot yet' {
        $view = ConvertTo-WindowView -Snapshot $null
        $view.Title | Should -Be 'Not monitoring'
        $view.Sim | Should -BeNullOrEmpty
    }
}

Describe 'What unblocks the connection' {
    It '<Scenario>: <Kind>' -ForEach @(
        @{ Scenario = 'ApnNeeded'; Kind = 'Apn'; Action = 'Save APN'; Enabled = $true }
        @{ Scenario = 'PinRequired'; Kind = 'Pin'; Action = 'Store PIN'; Enabled = $true }
        @{ Scenario = 'FccLocked'; Kind = 'Unlock'; Action = 'Unlock...'; Enabled = $true }
        @{ Scenario = 'AdapterDisabled'; Kind = 'EnableAdapter'; Action = 'Enable adapter'; Enabled = $true }
    ) {
        $blocker = (ConvertTo-WindowView -Snapshot (Get-ScenarioSnapshot -Scenario $Scenario)).Blocker
        $blocker.Kind | Should -Be $Kind
        $blocker.ActionText | Should -Be $Action
        $blocker.Enabled | Should -Be $Enabled
    }

    It 'asks for the APN password again' {
        $blocker = (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ State = 'Registered'; Reason = 'ApnPasswordUnreadable'; Blocked = $true })).Blocker
        $blocker.Kind | Should -Be 'ApnPassword'
    }

    It 'says how many PIN attempts are left' {
        (ConvertTo-WindowView -Snapshot (Get-ScenarioSnapshot -Scenario PinRequired)).Blocker.Message | Should -Match 'Attempts left: 3\.$'
    }

    It 'offers nothing to do for what the app can''t act on: <Reason>' -ForEach @(
        @{ Reason = 'PukRequired' }
        @{ Reason = 'NoSim' }
        @{ Reason = 'LastAttempt' }
        @{ Reason = 'NoDriver' }
        @{ Reason = 'NotElevated' }
    ) {
        $blocker = (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ State = 'Identified'; Reason = $Reason; Blocked = $true })).Blocker
        $blocker.Kind | Should -BeNullOrEmpty
        $blocker.Message | Should -Not -BeNullOrEmpty
    }

    It 'shows no blocker without a modem, or when nothing blocks' {
        (ConvertTo-WindowView -Snapshot (Get-ScenarioSnapshot -Scenario NoDevice)).Blocker | Should -BeNullOrEmpty
        (ConvertTo-WindowView -Snapshot $script:online).Blocker | Should -BeNullOrEmpty
    }

    It 'can''t enable the adapter without administrator rights' {
        $snapshot = Copy-Snapshot (Get-ScenarioSnapshot -Scenario AdapterDisabled) @{ Elevated = $false }
        $blocker = (ConvertTo-WindowView -Snapshot $snapshot).Blocker
        $blocker.Enabled | Should -BeFalse
        $blocker.Message | Should -Match 'administrator rights'
    }

    It 'changes nothing while the app only observes: <Scenario>' -ForEach @(
        @{ Scenario = 'FccLocked' }
        @{ Scenario = 'AdapterDisabled' }
    ) {
        $blocker = (ConvertTo-WindowView -Snapshot (Get-ScenarioSnapshot -Scenario $Scenario -Extra @{ ObserveOnly = $true })).Blocker
        $blocker.Enabled | Should -BeFalse
    }
}

Describe 'The SIM tab' {
    It 'shows a SIM waiting for its PIN, with its attempts' {
        $sim = (ConvertTo-WindowView -Snapshot (Get-ScenarioSnapshot -Scenario PinRequired)).Sim
        $sim.StateText | Should -Be 'SIM: Waiting for its PIN - PIN attempts left: 3'
        $sim.CanStorePin | Should -BeTrue
        $sim.CanForgetPin | Should -BeFalse
        $sim.CanDisablePin | Should -BeFalse
    }

    It 'offers to remove the PIN only from a ready SIM whose PIN request is on' {
        $on = $script:online.Sim | Select-Object -Property *
        $on.PinRequestOn = $true
        (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Sim = $on })).Sim.CanDisablePin | Should -BeTrue
        (ConvertTo-WindowView -Snapshot $script:online).Sim.CanDisablePin | Should -BeFalse -Because 'the request is off'
        (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Sim = $on; ObserveOnly = $true })).Sim.CanDisablePin | Should -BeFalse
        (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Sim = $on; PortName = $null })).Sim.CanDisablePin | Should -BeFalse
    }

    It 'says the stored PIN was rejected' {
        $rejected = $script:online.Sim | Select-Object -Property *
        $rejected.PinRejected = $true
        (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Sim = $rejected })).Sim.Note | Should -Match 'rejected'
    }

    It 'says what is not known' {
        $unknown = $script:online.Sim | Select-Object -Property *
        $unknown.State = $null
        $unknown.PinRequestOn = $null
        $sim = (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Sim = $unknown })).Sim
        $sim.StateText | Should -Be 'SIM: Not known'
        $sim.RequestText | Should -Be 'PIN request at power-on: not known'
    }
}

Describe 'Command outcomes' {
    It 'says <Kind> / <Result> in words' -ForEach @(
        @{ Kind = 'ConnectNow'; Result = 'Done' }
        @{ Kind = 'SaveSettings'; Result = 'Done' }
        @{ Kind = 'SaveSettings'; Result = 'Failed' }
        @{ Kind = 'SaveSimPin'; Result = 'Done' }
        @{ Kind = 'SaveSimPin'; Result = 'SimNotIdentified' }
        @{ Kind = 'SaveSimPin'; Result = 'NoModem' }
        @{ Kind = 'ForgetSimPin'; Result = 'Done' }
        @{ Kind = 'DisableSimPin'; Result = 'Disabled' }
        @{ Kind = 'DisableSimPin'; Result = 'AlreadyOff' }
        @{ Kind = 'DisableSimPin'; Result = 'PinRejected' }
        @{ Kind = 'DisableSimPin'; Result = 'LastAttempt' }
        @{ Kind = 'DisableSimPin'; Result = 'SimNotReady' }
        @{ Kind = 'DisableSimPin'; Result = 'Failed' }
        @{ Kind = 'DisableSimPin'; Result = 'PortLost' }
        @{ Kind = 'DisableSimPin'; Result = 'Refused' }
        @{ Kind = 'UnlockFcc'; Result = 'Restarted' }
        @{ Kind = 'UnlockFcc'; Result = 'NotLocked' }
        @{ Kind = 'UnlockFcc'; Result = 'Unknown' }
        @{ Kind = 'UnlockFcc'; Result = 'Failed' }
        @{ Kind = 'UnlockFcc'; Result = 'PortLost' }
        @{ Kind = 'EnableAdapter'; Result = 'Done' }
        @{ Kind = 'EnableAdapter'; Result = 'Failed' }
    ) {
        $result = [pscustomobject]@{ Id = '1'; Kind = $Kind; Result = $Result; Detail = $null; AttemptsLeft = $null; Time = [DateTimeOffset]::new(2026, 10, 1, 12, 0, 0, [timespan]::Zero) }
        $text = (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Results = @($result) })).Result
        $text | Should -Match '^12:00:00 '
        $text | Should -Not -Match ([regex]::Escape("${Kind}: $Result")) -Because 'every outcome has a sentence'
    }

    It 'adds the attempts left and the reason of a failure' {
        $time = [DateTimeOffset]::new(2026, 10, 1, 12, 0, 0, [timespan]::Zero)
        $rejected = [pscustomobject]@{ Id = '1'; Kind = 'DisableSimPin'; Result = 'PinRejected'; Detail = $null; AttemptsLeft = 2; Time = $time }
        (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Results = @($rejected) })).Result | Should -Match 'Attempts left: 2\.$'
        $failed = [pscustomobject]@{ Id = '2'; Kind = 'SaveSettings'; Result = 'Failed'; Detail = 'Settings not saved: InterfaceMetric must be a whole number.'; AttemptsLeft = $null; Time = $time }
        (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Results = @($failed) })).Result | Should -Match 'InterfaceMetric'
    }
}

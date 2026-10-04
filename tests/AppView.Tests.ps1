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
    It 'says online, the technology, the operator and the RSRP; below, the data used' {
        ConvertTo-TrayText -Snapshot $script:online | Should -Be "FM350-GL: Online - 5G NSA - 001 01 - RSRP -97 dBm`nData today 0 B, this cycle 0 B"
    }

    It 'says why when not online' {
        ConvertTo-TrayText -Snapshot (Get-ScenarioSnapshot -Scenario PinRequired) | Should -Be "FM350-GL: Action needed - The SIM is waiting for its PIN.`nData today 0 B, this cycle 0 B"
    }

    It 'says the data used against the quota' {
        $usage = [pscustomobject]@{
            Today = [pscustomobject]@{ Total = 1234567890 }; Cycle = [pscustomobject]@{ Total = 14300000000 }; Quota = 50000000000
        }
        (ConvertTo-TrayText -Snapshot (Copy-Snapshot $script:online @{ Usage = $usage })) -split "`n" | Select-Object -Last 1 | Should -Be 'Data today 1.2 GB, this cycle 14.3 GB of 50.0 GB'
    }

    It 'says no data usage before the adapter was read' {
        ConvertTo-TrayText -Snapshot (Copy-Snapshot $script:online @{ Usage = $null }) | Should -Be 'FM350-GL: Online - 5G NSA - 001 01 - RSRP -97 dBm'
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
        ($text -split "`n")[0][-1] | Should -Be ([char]0x2026) -Because 'an ellipsis says the first line was cut'
        ($text -split "`n")[1] | Should -Be 'Data today 0 B, this cycle 0 B' -Because 'the data used keeps its line'
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
        $issue = [pscustomobject]@{ Setting = 'Apn'; Rule = 'Text'; Values = [object[]]@() }
        $snapshot = Copy-Snapshot $script:online @{ ObserveOnly = $true; SettingsPending = $true; SettingsIssues = @($issue); Modems = 2 }
        $note = (ConvertTo-WindowView -Snapshot $snapshot).Note
        $note | Should -Match 'Development mode'
        $note | Should -Match 'only observes'
        $note | Should -Match 'next connection'
        $note | Should -Match 'Settings file: Apn must be printable ASCII without double quotes or surrounding blanks; the default is used\.'
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

    It 'shows the port, the time of the update, missing administrator rights and the app''s version' {
        $footer = (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Elevated = $false; AppVersion = '1.2.3' })).Footer
        $footer | Should -Match '^AT port SIMULATED - updated \d\d:\d\d:\d\d - no administrator rights - version 1\.2\.3$'
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
        @{ Scenario = 'NoDriver'; Kind = 'Driver'; Action = 'Install the driver...'; Enabled = $true }
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
        @{ Kind = 'SetNetworkMode'; Result = 'Applied' }
        @{ Kind = 'SetNetworkMode'; Result = 'Unchanged' }
        @{ Kind = 'SetNetworkMode'; Result = 'Done' }
        @{ Kind = 'SetNetworkMode'; Result = 'ModeUnsupported' }
        @{ Kind = 'SetNetworkMode'; Result = 'NoSupportedBand' }
        @{ Kind = 'SetNetworkMode'; Result = 'Unknown' }
        @{ Kind = 'SetNetworkMode'; Result = 'NoModem' }
        @{ Kind = 'SetNetworkMode'; Result = 'Refused' }
        @{ Kind = 'SetNetworkMode'; Result = 'Failed' }
        @{ Kind = 'CheckDriverPackage'; Result = 'Verified' }
        @{ Kind = 'CheckDriverPackage'; Result = 'Signed' }
        @{ Kind = 'CheckDriverPackage'; Result = 'Refused' }
        @{ Kind = 'CheckDriverPackage'; Result = 'NoPackage' }
        @{ Kind = 'CheckDriverPackage'; Result = 'Failed' }
        @{ Kind = 'CheckDriverPackage'; Result = 'NotElevated' }
        @{ Kind = 'InstallDriver'; Result = 'Done' }
        @{ Kind = 'InstallDriver'; Result = 'RestartNeeded' }
        @{ Kind = 'InstallDriver'; Result = 'NoDevice' }
        @{ Kind = 'InstallDriver'; Result = 'Unconfirmed' }
        @{ Kind = 'InstallDriver'; Result = 'NoPackage' }
        @{ Kind = 'InstallDriver'; Result = 'DriverWorking' }
        @{ Kind = 'InstallDriver'; Result = 'TimedOut' }
        @{ Kind = 'InstallDriver'; Result = 'Failed' }
        @{ Kind = 'InstallDriver'; Result = 'Refused' }
        @{ Kind = 'UninstallDriver'; Result = 'Done' }
        @{ Kind = 'UninstallDriver'; Result = 'RestartNeeded' }
        @{ Kind = 'UninstallDriver'; Result = 'NoDriver' }
        @{ Kind = 'UninstallDriver'; Result = 'TrialOn' }
        @{ Kind = 'UninstallDriver'; Result = 'TimedOut' }
        @{ Kind = 'UninstallDriver'; Result = 'Failed' }
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

Describe 'Get-DriverView' {
    BeforeAll {
        $script:known = @(Get-KnownDriverPackage)
        # A snapshot whose Driver part is changed.
        function Get-DriverSnapshot {
            param([object] $Snapshot, [hashtable] $Change = @{}, [hashtable] $Top = @{})
            $driver = $Snapshot.Driver | Select-Object -Property *
            foreach ($key in $Change.Keys) { $driver.$key = $Change[$key] }
            $Top['Driver'] = $driver
            Copy-Snapshot $Snapshot $Top
        }
        # The package the user chose, as the check left it.
        function Get-TestPackage {
            param([string] $Verdict = 'Verified', [string[]] $Problems = @())
            [pscustomobject]@{
                Name    = 'acer_v3.22.43.1.zip'
                Verdict = [pscustomobject]@{
                    Verdict = $Verdict; Problems = $Problems; Path = 'usb2ser_tm.inf'; Provider = 'MediaTek'; Version = '3.22.43.1'
                    Known = if ($Verdict -eq 'Verified') { [pscustomobject]@{ Name = 'MediaTek usb2ser_tm'; Version = '3.22.43.1' } } else { $null }
                }
                Time    = [DateTimeOffset]::Now
            }
        }
        $script:noDriver = Get-ScenarioSnapshot -Scenario NoDriver
    }

    It 'says the AT port has no driver, where a copy is published and by whom, and lets the user choose a package' {
        $view = Get-DriverView -Snapshot $script:noDriver -Known $script:known
        $view.StateText | Should -BeLike '*has no driver*'
        $copy = $script:known[0].Copy
        $view.PageUrl | Should -Be $copy.Page
        $view.SourceText | Should -BeLike "*doesn't come with the modem's driver*"
        $view.SourceText | Should -BeLike "*third party, $($copy.Publisher), as $($copy.File)*"
        $view.SourceText | Should -BeLike '*never runs a program from it*'
        $view.CanChoose | Should -BeTrue
        $view.CanInstall | Should -BeFalse
        $view.CanUninstall | Should -BeFalse
        $view.PackageText | Should -BeNullOrEmpty
    }

    It 'names the driver an AT port has, and lets the user uninstall it' {
        $view = Get-DriverView -Snapshot $script:online -Known $script:known
        $view.StateText | Should -Be 'The modem''s AT port has its driver: MediaTek 3.22.43.1 (oem0.inf).'
        $view.CanUninstall | Should -BeTrue
        $view.CanInstall | Should -BeFalse
    }

    It 'offers to install a package that may be installed, and asks first for one it doesn''t know: <Verdict>' -ForEach @(
        @{ Verdict = 'Verified'; Confirm = $false; Text = 'acer_v3.22.43.1.zip: MediaTek usb2ser_tm 3.22.43.1, a version the app knows, signed by Microsoft (WHQL) for this modem.' }
        @{ Verdict = 'Signed'; Confirm = $true; Text = 'acer_v3.22.43.1.zip: MediaTek 3.22.43.1, signed by Microsoft (WHQL) for this modem, but not a version the app knows: it asks before installing it.' }
    ) {
        $view = Get-DriverView -Snapshot (Get-DriverSnapshot -Snapshot $script:noDriver -Change @{ Package = (Get-TestPackage -Verdict $Verdict) }) -Known $script:known
        $view.PackageText | Should -Be $Text
        $view.CanInstall | Should -BeTrue
        $view.ConfirmInstall | Should -Be $Confirm
    }

    It 'says why a package is refused, and offers nothing to install' {
        $package = Get-TestPackage -Verdict 'Refused' -Problems 'NotWhql', 'NotInCatalog'
        $view = Get-DriverView -Snapshot (Get-DriverSnapshot -Snapshot $script:noDriver -Change @{ Package = $package }) -Known $script:known
        $view.PackageText | Should -Be 'acer_v3.22.43.1.zip can''t be installed: its catalog is not signed by Microsoft (WHQL); its INF file is not the one its catalog vouches for: it was changed, or is damaged.'
        $view.CanInstall | Should -BeFalse
    }

    It 'has a sentence for every reason a package is refused: <_>' -ForEach @('NoInf', 'NotForModem', 'NoCatalog', 'NotWhql', 'NotInCatalog', 'NotTrusted') {
        $view = Get-DriverView -Snapshot (Get-DriverSnapshot -Snapshot $script:noDriver -Change @{ Package = (Get-TestPackage -Verdict 'Refused' -Problems $_) }) -Known $script:known
        $view.PackageText | Should -Not -BeLike "*$_*"
    }

    It 'never installs over an AT port that works' {
        $view = Get-DriverView -Snapshot (Get-DriverSnapshot -Snapshot $script:online -Change @{ Package = (Get-TestPackage) }) -Known $script:known
        $view.CanInstall | Should -BeFalse
    }

    It 'keeps the driver while a network mode is on trial, and says why' {
        $mode = $script:online.NetworkMode | Select-Object -Property *
        $mode.Trial = [pscustomobject]@{ Selection = [pscustomobject]@{ NetworkMode = 'LteOnly' }; Until = [DateTimeOffset]::Now.AddMinutes(3) }
        $view = Get-DriverView -Snapshot (Copy-Snapshot $script:online @{ NetworkMode = $mode }) -Known $script:known
        $view.CanUninstall | Should -BeFalse
        $view.Note | Should -Be 'A network mode is on trial: the driver can be uninstalled once the trial ends.'
    }

    It 'says what is under way, and offers nothing meanwhile: <Operation>' -ForEach @(
        @{ Operation = 'CheckDriverPackage'; Text = 'Checking the driver package...' }
        @{ Operation = 'InstallDriver'; Text = 'Installing the driver: Windows may take a minute.' }
        @{ Operation = 'UninstallDriver'; Text = 'Uninstalling the driver...' }
    ) {
        $view = Get-DriverView -Snapshot (Get-DriverSnapshot -Snapshot $script:online -Change @{ Operation = $Operation; Package = (Get-TestPackage) }) -Known $script:known
        $view.PackageText | Should -Be $Text
        $view.CanChoose, $view.CanInstall, $view.CanUninstall | Should -Be @($false, $false, $false)
    }

    It 'offers nothing <Name>, and says why' -ForEach @(
        @{ Name = 'while the app only observes'; Top = @{ ObserveOnly = $true }; Note = 'The app only observes: it changes nothing.' }
        @{ Name = 'without administrator rights'; Top = @{ Elevated = $false }; Note = 'Installing or uninstalling a driver needs administrator rights: start the app as administrator.' }
    ) {
        $view = Get-DriverView -Snapshot (Get-DriverSnapshot -Snapshot $script:noDriver -Change @{ Package = (Get-TestPackage) } -Top $Top) -Known $script:known
        $view.Note | Should -Be $Note
        $view.CanChoose, $view.CanInstall, $view.CanUninstall | Should -Be @($false, $false, $false)
    }

    It 'offers nothing while the worker restarts' {
        $view = Get-DriverView -Snapshot $script:noDriver -Worker Restarting -Known $script:known
        $view.CanChoose | Should -BeFalse
    }

    It 'says where no modem is, and that a driver installed now is used once it is plugged in' {
        (Get-DriverView -Snapshot (Get-ScenarioSnapshot -Scenario NoDevice) -Known $script:known).StateText | Should -BeLike 'No modem on USB.*plugged in.'
    }

    It 'shows a page without a snapshot, and without known packages' {
        $view = Get-DriverView -Snapshot $null -Known @()
        $view.PageUrl | Should -BeNullOrEmpty
        $view.SourceText | Should -BeLike '*Download a copy*'
        $view.CanChoose | Should -BeFalse
    }

    It 'is the window''s Driver tab' {
        (ConvertTo-WindowView -Snapshot $script:noDriver).Driver.StateText | Should -BeLike '*has no driver*'
    }
}

Describe 'Recovery in the tray and the window' {
    BeforeAll {
        # A snapshot not online whose recovery is in the given state.
        function Get-RecoverySnapshot {
            param([string] $Status, [string] $Check = 'H7', [string] $Step = 'R2', [int] $Cycles = 0, [string] $State = 'DataActive', [string] $Reason = 'DataPathFailed')
            $time = [DateTimeOffset]::new(2026, 10, 2, 14, 0, 0, [timespan]::Zero)
            $recovery = [pscustomobject]@{ Status = $Status; Check = $Check; Step = $Step; Cycles = $Cycles; StepTime = $time; NextTime = $time.AddMinutes(5); History = $null }
            Copy-Snapshot $script:online @{ State = $State; Reason = $Reason; Blocked = $false; Recovery = $recovery }
        }
    }

    It '<Status>: tone <Tone>, headline <Title>' -ForEach @(
        @{ Status = 'Recovering'; Tone = 'Recovering'; Title = 'Recovering' }
        @{ Status = 'Settling'; Tone = 'Recovering'; Title = 'Recovering' }
        @{ Status = 'Waiting'; Tone = 'Recovering'; Title = 'Recovering' }
        @{ Status = 'SlowCadence'; Tone = 'Attention'; Title = 'Connection lost' }
        @{ Status = 'Watching'; Tone = 'Working'; Title = 'Connecting' }
        @{ Status = 'Withheld'; Tone = 'Working'; Title = 'Not connected' }
        @{ Status = 'Maintenance'; Tone = 'Working'; Title = 'Connecting' }
    ) {
        $snapshot = Get-RecoverySnapshot -Status $Status -Cycles 3
        (Resolve-TrayIcon -Snapshot $snapshot).Tone | Should -Be $Tone
        $view = ConvertTo-WindowView -Snapshot $snapshot
        $view.Tone | Should -Be $Tone
        $view.Title | Should -Be $Title
        $view.Detail | Should -Match '\.$'
        (ConvertTo-TrayText -Snapshot $snapshot).Length | Should -BeLessOrEqual 127
    }

    It 'says the step being taken: <Step>' -ForEach @(
        @{ Step = 'R1'; Text = 'network adapter' }
        @{ Step = 'R2'; Text = 'data connection' }
        @{ Step = 'R3'; Text = 'Registering' }
        @{ Step = 'R4'; Text = 'radio' }
        @{ Step = 'R5'; Text = 'Restarting the modem' }
        @{ Step = 'R6'; Text = 'USB device' }
    ) {
        (ConvertTo-WindowView -Snapshot (Get-RecoverySnapshot -Status 'Settling' -Step $Step)).Detail | Should -Match $Text
        ConvertTo-TrayText -Snapshot (Get-RecoverySnapshot -Status 'Recovering' -Step $Step) | Should -Match "^FM350-GL: Recovering - .*$Text"
    }

    It 'says what fails and when recovery tries again: <Check>' -ForEach @(
        @{ Check = 'H2' }, @{ Check = 'H3' }, @{ Check = 'H4' }, @{ Check = 'H5' }, @{ Check = 'H6' }, @{ Check = 'H7' }
    ) {
        $waiting = (ConvertTo-WindowView -Snapshot (Get-RecoverySnapshot -Status 'Waiting' -Check $Check -Cycles 1)).Detail
        $waiting | Should -Match '14:05'
        $waiting | Should -Not -Match '^The connection is down' -Because 'every check has its sentence'
        (ConvertTo-WindowView -Snapshot (Get-RecoverySnapshot -Status 'SlowCadence' -Check $Check -Cycles 3)).Detail | Should -Match 'failed 3 times.*14:05'
    }

    It 'shows a modem off USB while it restarts as recovering, not as missing' {
        $snapshot = Get-RecoverySnapshot -Status 'Settling' -Check 'H1' -Step 'R5' -State 'NoDevice' -Reason 'NoDevice'
        (Resolve-TrayIcon -Snapshot $snapshot).Tone | Should -Be 'Recovering'
        (ConvertTo-WindowView -Snapshot $snapshot).Detail | Should -Be 'Restarting the modem.'
    }

    It 'says the step it withholds while it only observes' {
        $view = ConvertTo-WindowView -Snapshot (Get-RecoverySnapshot -Status 'Withheld' -Step 'R2')
        $view.Detail | Should -Be 'No traffic gets through. The app only observes, so it doesn''t take the recovery step: restarting the data connection.'
    }

    It 'notes the step that brought the connection back, until health has held' {
        $recovery = [pscustomobject]@{ Status = 'Healthy'; Check = $null; Step = 'R2'; Cycles = 0; StepTime = [DateTimeOffset]::new(2026, 10, 2, 14, 2, 0, [timespan]::Zero); NextTime = $null; History = $null }
        $view = ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Recovery = $recovery })
        $view.Tone | Should -Be 'Online'
        $view.Note | Should -Match 'Recovered at 14:02: restarting the data connection\.'
        $recovery.Step = $null
        (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Recovery = $recovery })).Note | Should -Not -Match 'Recovered'
    }

    It 'shows when the data path was last checked' {
        $time = [DateTimeOffset]::new(2026, 10, 2, 14, 3, 4, [timespan]::Zero)
        foreach ($case in @(@('Passed', 'checked'), @('Failed', 'failed'), @('NotReady', 'not checked yet'))) {
            $snapshot = Copy-Snapshot $script:online @{ DataPath = [pscustomobject]@{ Healthy = $null; Result = $case[0]; Time = $time } }
            (ConvertTo-WindowView -Snapshot $snapshot).Footer | Should -Match "data path $($case[1]) at 14:03:04"
        }
    }

    It 'reads the recovery state of a scenario the worker publishes' {
        $snapshot = Get-ScenarioSnapshot -Scenario PinRequired
        $snapshot.Recovery.Status | Should -Be 'Blocked'
        (ConvertTo-WindowView -Snapshot $snapshot).Title | Should -Be 'Action needed'
    }
}

Describe 'The network mode in the window and the tray' {
    BeforeAll {
        $script:time = [DateTimeOffset]::new(2026, 10, 3, 14, 0, 0, [timespan]::Zero)
        $script:mode = $script:online.NetworkMode
        # A copy of the online snapshot with its network mode changed.
        function Copy-ModeSnapshot {
            param([hashtable] $Mode = @{}, [hashtable] $Change = @{})
            $copy = $script:online.NetworkMode | Select-Object -Property *
            foreach ($key in $Mode.Keys) { $copy.$key = $Mode[$key] }
            $Change['NetworkMode'] = $copy
            Copy-Snapshot $script:online $Change
        }
    }

    It 'shows the modem''s mode and bands as read, n77 left out' {
        $view = Get-NetworkModeView -Snapshot $script:online
        $view.CurrentText | Should -Be 'The modem now: 4G + 5G. LTE: every band. NR: every band but n77.'
        $view.Modes.Text | Should -Be @('As the modem has it', '4G + 5G', '4G only', '5G only (SA)')
        $view.Modes.Name | Should -Be @('', 'Automatic', 'LteOnly', 'NrOnly')
        $view.Lte.Count | Should -Be 31
        $view.Nr | Should -Contain 77
        $view.Selection.NetworkMode | Should -Be ''
        $view.CanApply | Should -BeTrue
        $view.Note | Should -BeNullOrEmpty
    }

    It 'shows LTE-only mode, and the bands of a restriction' {
        $view = Get-NetworkModeView -Snapshot (Get-ScenarioSnapshot -Scenario LteOnlyMode)
        $view.CurrentText | Should -Be 'The modem now: 4G only. LTE: every band.'
        $current = ConvertFrom-AtNetworkMode -Lines @('+GTACT: 20,6,3,1,2,4,5,8,103,120,5078')
        (Get-NetworkModeView -Snapshot (Copy-ModeSnapshot -Mode @{ Current = $current })).CurrentText | Should -Be 'The modem now: 4G + 5G. LTE: B3, B20. NR: n78.'
    }

    It 'says the mode is not read yet, and offers no change without the modem' {
        $view = Get-NetworkModeView -Snapshot (Get-ScenarioSnapshot -Scenario NoDevice)
        $view.CurrentText | Should -Be 'The modem''s network mode is not read yet.'
        $view.CanApply | Should -BeFalse
        (Get-NetworkModeView -Snapshot $null).CanApply | Should -BeFalse
    }

    It 'offers no change while the app only observes' {
        (Get-NetworkModeView -Snapshot (Copy-Snapshot $script:online @{ ObserveOnly = $true })).CanApply | Should -BeFalse
    }

    It 'says a mode is on trial, and until when, with the choice on trial in the form' {
        $trial = [pscustomobject]@{ Selection = [pscustomobject]@{ NetworkMode = 'NrOnly'; LteBands = [int[]]@(); NrBands = [int[]]@(78) }; Since = 5; Until = $script:time.AddMinutes(3) }
        $view = Get-NetworkModeView -Snapshot (Copy-ModeSnapshot -Mode @{ Trial = $trial })
        $view.Note | Should -Be 'Trying 5G only (SA): if the modem finds no network with it by 14:03, it goes back to what it had.'
        $view.Selection.NetworkMode | Should -Be 'NrOnly'
        $view.Selection.NrBands | Should -Be @(78)
        $view.Revision | Should -Not -Be (Get-NetworkModeView -Snapshot $script:online).Revision
    }

    It 'says how the last trial ended: <Kind>' -ForEach @(
        @{ Kind = 'Reverted'; Text = 'At 14:00 the modem had found no network with 5G only \(SA\): it went back to what it had\.' }
        @{ Kind = 'Kept'; Text = 'At 14:00 the modem registered with 5G only \(SA\): it is kept\.' }
    ) {
        $notice = [pscustomobject]@{ Kind = $Kind; Mode = 'NrOnly'; Time = $script:time }
        (Get-NetworkModeView -Snapshot (Copy-ModeSnapshot -Mode @{ Notice = $notice })).Note | Should -Match $Text
    }

    It 'says what the modem leaves out, and a mode it doesn''t keep' {
        $decision = [pscustomobject]@{ Managed = $true; Satisfied = $false; Command = $null; Problem = 'NotKept'; Narrowed = $false; Missing = [pscustomobject]@{ Lte = [int[]]@(); Nr = [int[]]@(77) } }
        $note = (Get-NetworkModeView -Snapshot (Copy-ModeSnapshot -Mode @{ Decision = $decision })).Note
        $note | Should -Match 'doesn''t keep the network mode'
        $note | Should -Match 'leaves out n77'
    }

    It 'lists the modes in the tray, the modem''s checked and not to choose again' {
        $menu = Get-TrayModeMenu -Snapshot $script:online
        $menu.Text | Should -Be 'Network mode: 4G + 5G'
        $menu.Items.Name | Should -Be @('Automatic', 'LteOnly', 'NrOnly')
        $menu.Items.Checked | Should -Be @($true, $false, $false)
        $menu.Items.Enabled | Should -Be @($false, $true, $true)
    }

    It 'offers no mode in the tray while <Case>' -ForEach @(
        @{ Case = 'the worker restarts'; Worker = 'Restarting'; Snapshot = 'online' }
        @{ Case = 'there is no modem'; Worker = 'Running'; Snapshot = 'none' }
    ) {
        $snapshot = if ($Snapshot -eq 'online') { $script:online } else { Get-ScenarioSnapshot -Scenario NoDevice }
        $menu = Get-TrayModeMenu -Snapshot $snapshot -Worker $Worker
        @($menu.Items | Where-Object Enabled) | Should -BeNullOrEmpty
    }

    It 'says when a narrowed mode finds no network, and offers a wider one' {
        $decision = [pscustomobject]@{ Managed = $true; Satisfied = $true; Command = $null; Problem = $null; Narrowed = $true; Missing = [pscustomobject]@{ Lte = [int[]]@(); Nr = [int[]]@() } }
        $current = ConvertFrom-AtNetworkMode -Lines @('+GTACT: 14,6,6,5078')
        $recovery = [pscustomobject]@{ Status = 'Watching'; Check = 'H4'; Step = $null; Cycles = 0; StepTime = $null; NextTime = $null; History = $null }
        $snapshot = Copy-ModeSnapshot -Mode @{ Decision = $decision; Current = $current } -Change @{ State = 'SimReady'; Reason = 'Searching'; Recovery = $recovery }
        $view = ConvertTo-WindowView -Snapshot $snapshot
        $view.Tone | Should -Be 'Attention'
        $view.Title | Should -Be 'No network'
        $view.Detail | Should -Be 'No network found with 5G only (SA). No reset finds one: choose a wider network mode.'
        $view.Blocker.Kind | Should -Be 'NetworkMode'
        $view.Blocker.ActionText | Should -Be 'Use 4G + 5G, every band'
        (Resolve-TrayIcon -Snapshot $snapshot).Tone | Should -Be 'Attention'
        # The same while its setting can't be read.
        $decision.Satisfied = $null
        (ConvertTo-WindowView -Snapshot $snapshot).Title | Should -Be 'No network'
        # During its grace time it is only searching.
        $recovery.NextTime = $script:time
        (ConvertTo-WindowView -Snapshot $snapshot).Tone | Should -Be 'Working'
    }
}

Describe 'The Messages tab' {
    BeforeAll {
        # A message as the worker's snapshot gives it.
        function Get-TestMessage {
            param([hashtable] $Change = @{})
            $message = [ordered]@{
                Fingerprints = [string[]]@('AA'); New = $false; Address = '+10000000000'; AddressType = 'International'
                Time = [DateTimeOffset]::new(2026, 10, 4, 9, 30, 0, [timespan]::FromHours(2)); Text = 'hello'; Content = 'Text'; Class = $null
                Waiting = $null; NationalLanguage = $false; Problem = $null; Count = 1; Missing = [int[]]@(); Complete = $true
            }
            foreach ($key in $Change.Keys) {
                $message[$key] = $Change[$key]
            }
            [pscustomobject]$message
        }

        function Get-TestMessageList {
            param([object[]] $Item, [int] $Used = 1, [int] $Total = 70)
            [pscustomobject]@{ Items = [object[]]$Item; New = @($Item | Where-Object New).Count; Used = $Used; Total = $Total; Full = $Used -ge $Total }
        }
    }

    It 'lists the messages newest first, the new ones marked, and says how full the SIM is' {
        $view = Get-MessagesView -Snapshot $script:online
        $view.StateText | Should -Be '4 of 70 places used on the SIM.'
        $view.TabText | Should -Be 'Messages (2)'
        @($view.Items | ForEach-Object From) | Should -Be @('Info', '+10000000000', 'Operator')
        @($view.Items | ForEach-Object Marker) | Should -Be @([string][char]0x25CF, [string][char]0x25CF, '')
        $first = $view.Items[0]
        $first.Time | Should -Be ([DateTimeOffset]::new(2026, 10, 4, 11, 51, 0, [timespan]::FromHours(2)).ToLocalTime().ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture))
        $first.Header | Should -Be "From Info, $($first.Time)"
        $first.Text | Should -Match '^Your data bundle renews .+ before showing it\.$'
        $first.Preview.Length | Should -Be 60
        $first.Preview[-1] | Should -Be ([char]0x2026) -Because 'a long text is cut in the list'
        $first.Fingerprints.Count | Should -Be 2
        $first.Key | Should -Be ($first.Fingerprints -join ',')
        $view.CanDelete | Should -BeTrue
        $view.CanSend | Should -BeTrue
        $view.SendingText | Should -BeNullOrEmpty
    }

    It 'says why there are none: <Name>' -ForEach @(
        @{ Name = 'observe-only'; Change = @{ Messages = $null; ObserveOnly = $true }; Text = 'Messages are not read while the app only observes*' }
        @{ Name = 'no modem'; Change = @{ Messages = $null; PortName = $null }; Text = 'The modem is not connected.' }
        @{ Name = 'the SIM not ready'; Change = @{ Messages = $null }; Text = 'Messages are read once the SIM is ready.' }
    ) {
        $view = Get-MessagesView -Snapshot (Copy-Snapshot $script:online $Change)
        $view.StateText | Should -BeLike $Text
        $view.Items.Count | Should -Be 0
        $view.TabText | Should -Be 'Messages'
        $view.CanSend | Should -BeFalse
        $view.CanDelete | Should -BeFalse
    }

    It 'says an empty SIM, and a full one' {
        (Get-MessagesView -Snapshot (Copy-Snapshot $script:online @{ Messages = (Get-TestMessageList -Item @() -Used 0) })).StateText | Should -Be '0 of 70 places used on the SIM. No messages on the SIM.'
        $full = Get-MessagesView -Snapshot (Copy-Snapshot $script:online @{ Messages = (Get-TestMessageList -Item @(Get-TestMessage) -Used 70) })
        $full.StateText | Should -Be '70 of 70 places used on the SIM. The SIM is full: new messages can''t be stored until some are deleted.'
    }

    It 'says what a message shows instead of text, and what it lacks: <Name>' -ForEach @(
        @{ Name = '8-bit data'; Change = @{ Text = $null; Content = 'Binary' }; Text = 'This message carries data, not text.'; Note = $null }
        @{ Name = 'compressed'; Change = @{ Text = $null; Content = 'Compressed' }; Text = 'This message is compressed: the app can''t show it.'; Note = $null }
        @{ Name = 'malformed'; Change = @{ Text = $null; Content = $null; Problem = 'Malformed' }; Text = 'This message can''t be read.'; Note = $null }
        @{ Name = 'malformed in its first part, the others read'; Change = @{ Text = 'the rest'; Problem = 'Malformed' }; Text = 'This message can''t be read.'; Note = $null }
        @{ Name = 'parts missing'; Change = @{ Text = "one $([char]0x2026)"; Count = 3; Missing = [int[]]@(2, 3); Complete = $false }; Text = "one $([char]0x2026)"; Note = 'Parts not received (yet): 2, 3.' }
        @{ Name = 'a national language table'; Change = @{ NationalLanguage = $true }; Text = 'hello'; Note = 'It uses a national language table the app doesn''t have: some characters may be wrong.' }
    ) {
        $view = Get-MessagesView -Snapshot (Copy-Snapshot $script:online @{ Messages = (Get-TestMessageList -Item @(Get-TestMessage -Change $Change)) })
        $view.Items[0].Text | Should -Be $Text
        $view.Items[0].Note | Should -Be $Note
    }

    It 'shows the time where the user is, whatever zone the centre stamped' {
        $stamped = [DateTimeOffset]::new(2026, 10, 4, 9, 30, 0, [timespan]::FromHours(-7))
        $view = Get-MessagesView -Snapshot (Copy-Snapshot $script:online @{ Messages = (Get-TestMessageList -Item @(Get-TestMessage -Change @{ Time = $stamped })) })
        $view.Items[0].Time | Should -Be $stamped.ToLocalTime().ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture)
        if ([TimeZoneInfo]::Local.GetUtcOffset($stamped) -ne $stamped.Offset) {
            $view.Items[0].Time | Should -Not -Be '2026-10-04 09:30'
        }
    }

    It 'shows a text over several lines on one line in the list' {
        $view = Get-MessagesView -Snapshot (Copy-Snapshot $script:online @{ Messages = (Get-TestMessageList -Item @(Get-TestMessage -Change @{ Text = "first`r`nsecond" })) })
        $view.Items[0].Preview | Should -Be 'first second'
        $view.Items[0].Text | Should -Be "first`r`nsecond"
    }

    It 'says a message is going out, and offers nothing meanwhile' {
        $view = Get-MessagesView -Snapshot (Copy-Snapshot $script:online @{ MessageOperation = 'Sending' })
        $view.SendingText | Should -Be 'Sending the message...'
        $view.CanSend | Should -BeFalse
        $view.CanDelete | Should -BeFalse
    }

    It 'names the newest message sent' {
        $time = [DateTimeOffset]::Now
        $results = @(
            [pscustomobject]@{ Id = '1'; Kind = 'SendMessage'; Result = 'Sent'; Time = $time }
            [pscustomobject]@{ Id = '2'; Kind = 'SendMessage'; Result = 'Failed'; Time = $time }
            [pscustomobject]@{ Id = '3'; Kind = 'OpenMessage'; Result = 'Done'; Time = $time }
        )
        (Get-MessagesView -Snapshot (Copy-Snapshot $script:online @{ Results = $results })).SentId | Should -Be '1'
        (Get-MessagesView -Snapshot $script:online).SentId | Should -BeNullOrEmpty
    }

    It 'shows nothing without a snapshot' {
        $view = Get-MessagesView -Snapshot $null
        $view.StateText | Should -BeNullOrEmpty
        $view.Items.Count | Should -Be 0
        $view.CanSend | Should -BeFalse
    }

    It 'is the window''s Messages tab' {
        (ConvertTo-WindowView -Snapshot $script:online).Messages.TabText | Should -Be 'Messages (2)'
    }
}

Describe 'The count of a message being written' {
    It '<Name>' -ForEach @(
        @{ Name = 'nothing for no text'; Text = ''; Expected = $null }
        @{ Name = 'GSM 7-bit, one part'; Text = 'hello'; Expected = 'Characters: 5 - parts: 1' }
        @{ Name = 'an escaped character counting two'; Text = "$([char]0x20AC)"; Expected = 'Characters: 2 - parts: 1' }
        @{ Name = 'two parts past 160'; Text = ('x' * 161); Expected = 'Characters: 161 - parts: 2' }
        @{ Name = 'UCS2 for a character the alphabet lacks'; Text = "$([char]0x0416)abc"; Expected = 'Characters: 4 - parts: 1 (with special characters, 70 per part)' }
        @{ Name = 'too long'; Text = ('x' * 40000); Expected = 'Too long: a message has at most 255 parts.' }
    ) {
        & (Get-Module FibocomFm350.App) { param($text) Get-MessageCountText -Text $text } $Text | Should -Be $Expected
    }
}

Describe 'The Data tab' {
    BeforeAll {
        function Get-TestUsage {
            param([uint64[]] $Today, [uint64[]] $Cycle, $Quota = $null, $Percent = $null, $Threshold = $null)
            [pscustomobject]@{
                Today      = [pscustomobject]@{ Received = $Today[0]; Sent = $Today[1]; Total = $Today[0] + $Today[1] }
                Cycle      = [pscustomobject]@{ Received = $Cycle[0]; Sent = $Cycle[1]; Total = $Cycle[0] + $Cycle[1] }
                CycleStart = [datetime]::new(2026, 10, 1)
                CycleEnd   = [datetime]::new(2026, 11, 1)
                Quota      = $Quota
                Percent    = $Percent
                Threshold  = $Threshold
            }
        }
    }

    It 'says today and the cycle, with its first and last day, and no quota' {
        $usage = Get-TestUsage -Today 1000000, 200000 -Cycle 14000000000, 300000000
        $view = Get-UsageView -Snapshot (Copy-Snapshot $script:online @{ Usage = $usage })
        $view.TodayText | Should -Be 'Today: 1.2 MB (received 1.0 MB, sent 200.0 kB)'
        $view.CycleText | Should -Be 'This cycle, from 2026-10-01 to 2026-10-31: 14.3 GB (received 14.0 GB, sent 300.0 MB)'
        $view.QuotaText | Should -Be 'No quota set.'
        $view.Percent | Should -BeNullOrEmpty
        $view.Warning | Should -BeFalse
    }

    It 'says the quota and the share used, at most a full bar, and a threshold reached' {
        $usage = Get-TestUsage -Today 0, 0 -Cycle 14000000000, 300000000 -Quota ([uint64]10000000000) -Percent 143.0 -Threshold 100
        $view = Get-UsageView -Snapshot (Copy-Snapshot $script:online @{ Usage = $usage })
        $view.QuotaText | Should -Be 'Quota: 14.3 GB of 10.0 GB used (143%)'
        $view.Percent | Should -Be 100
        $view.Warning | Should -BeTrue
        $below = Get-UsageView -Snapshot (Copy-Snapshot $script:online @{ Usage = (Get-TestUsage -Today 0, 0 -Cycle 500000000, 0 -Quota ([uint64]10000000000) -Percent 5.0) })
        $below.Percent | Should -Be 5
        $below.Warning | Should -BeFalse
    }

    It 'says nothing is counted before the adapter was read' {
        $view = Get-UsageView -Snapshot (Copy-Snapshot $script:online @{ Usage = $null })
        $view.TodayText | Should -Be 'Nothing counted yet: the modem''s network adapter has not been read.'
        $view.CycleText | Should -BeNullOrEmpty
    }

    It 'writes <Bytes> bytes as <Text>, whatever the culture' -ForEach @(
        @{ Bytes = 0; Text = '0 B' }
        @{ Bytes = 999; Text = '999 B' }
        @{ Bytes = 1000; Text = '1.0 kB' }
        @{ Bytes = 999949; Text = '999.9 kB' }
        @{ Bytes = 999950; Text = '1.0 MB' }
        @{ Bytes = 1234567890; Text = '1.2 GB' }
        @{ Bytes = 12000000000000; Text = '12.0 TB' }
    ) {
        $culture = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = 'it-IT'
            & (Get-Module FibocomFm350.App) { param($bytes) Format-DataSize -Bytes $bytes } $Bytes | Should -Be $Text
        }
        finally {
            [cultureinfo]::CurrentCulture = $culture
        }
    }

    It 'is the window''s Data tab' {
        (ConvertTo-WindowView -Snapshot $script:online).Usage.TodayText | Should -Be 'Today: 0 B (received 0 B, sent 0 B)'
    }
}

Describe 'Tray notices' {
    It 'announces new messages once, by their newest sender only' {
        $snapshot = Copy-Snapshot $script:online @{ UsageNotice = $null }
        $first = Get-TrayNotice -Snapshot $snapshot
        $first.Notice.Kind | Should -Be 'Messages'
        $first.Notice.Title | Should -Be '2 new messages'
        $first.Notice.Text | Should -Be 'From Info'
        $again = Get-TrayNotice -Snapshot $snapshot -Shown @{ MessageId = $first.MessageId; UsageId = $first.UsageId }
        $again.Notice | Should -BeNullOrEmpty -Because 'a notice is shown once'
    }

    It 'says one new message in the singular' {
        $notice = (Get-TrayNotice -Snapshot (Copy-Snapshot $script:online @{ MessageNotice = [pscustomobject]@{ Sender = 'Operator'; Count = 1; Id = 7; Time = [DateTimeOffset]::Now } })).Notice
        $notice.Title | Should -Be 'New message'
        $notice.Text | Should -Be 'From Operator'
    }

    It 'says a quota threshold, after the messages, and that the connection stays on' {
        $quota = [pscustomobject]@{ Threshold = 80; Id = 1; Time = [DateTimeOffset]::Now }
        $snapshot = Copy-Snapshot $script:online @{ UsageNotice = $quota }
        $first = Get-TrayNotice -Snapshot $snapshot
        $first.Notice.Kind | Should -Be 'Messages'
        $second = Get-TrayNotice -Snapshot $snapshot -Shown @{ MessageId = $first.MessageId; UsageId = $first.UsageId }
        $second.Notice.Kind | Should -Be 'Quota'
        $second.Notice.Title | Should -Be 'Data quota'
        $second.Notice.Text | Should -Be '80% of the quota used in this cycle. The connection stays on.'
        (Get-TrayNotice -Snapshot $snapshot -Shown @{ MessageId = $second.MessageId; UsageId = $second.UsageId }).Notice | Should -BeNullOrEmpty
    }

    It 'says nothing without a notice, or without a snapshot' {
        (Get-TrayNotice -Snapshot (Copy-Snapshot $script:online @{ MessageNotice = $null; UsageNotice = $null })).Notice | Should -BeNullOrEmpty
        (Get-TrayNotice -Snapshot $null).Notice | Should -BeNullOrEmpty
    }
}

Describe 'Message command outcomes' {
    BeforeAll {
        $script:time = [DateTimeOffset]::new(2026, 10, 1, 12, 0, 0, [timespan]::Zero)
    }

    It 'says <Kind> / <Result> in words' -ForEach @(
        @{ Kind = 'SendMessage'; Result = 'Sent'; Text = 'Message sent.' }
        @{ Kind = 'SendMessage'; Result = 'Invalid'; Text = 'Enter a phone number and a text.' }
        @{ Kind = 'SendMessage'; Result = 'NotReady'; Text = 'The SIM is not ready.' }
        @{ Kind = 'SendMessage'; Result = 'Refused'; Text = 'Not available while the app only observes.' }
        @{ Kind = 'DeleteMessage'; Result = 'Done'; Text = 'Message deleted from the SIM.' }
        @{ Kind = 'DeleteMessage'; Result = 'NotFound'; Text = 'The message is no longer on the SIM.' }
        @{ Kind = 'DeleteMessage'; Result = 'NoModem'; Text = 'The modem is not connected.' }
    ) {
        $result = [pscustomobject]@{ Id = '1'; Kind = $Kind; Result = $Result; Detail = $null; AttemptsLeft = $null; Parts = $null; Time = $script:time }
        (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Results = @($result) })).Result | Should -Be "12:00:00 $Text"
    }

    It 'says how many parts of a message went out, and why it stopped' {
        $result = [pscustomobject]@{ Id = '1'; Kind = 'SendMessage'; Result = 'Failed'; Detail = 'part 2 of 3: CmsError 331'; AttemptsLeft = $null; Parts = [pscustomobject]@{ Sent = 1; Count = 3 }; Time = $script:time }
        (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Results = @($result) })).Result | Should -Be '12:00:00 The message was not sent completely: 1 of 3 parts went out. part 2 of 3: CmsError 331'
        $broken = [pscustomobject]@{ Id = '2'; Kind = 'SendMessage'; Result = 'Failed'; Detail = 'FormatException'; AttemptsLeft = $null; Parts = $null; Time = $script:time }
        (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Results = @($broken) })).Result | Should -Be '12:00:00 It didn''t work. FormatException'
    }

    It 'says nothing of a message opened: the outcome before it stays' {
        $sent = [pscustomobject]@{ Id = '1'; Kind = 'SendMessage'; Result = 'Sent'; Detail = $null; AttemptsLeft = $null; Parts = $null; Time = $script:time }
        $opened = [pscustomobject]@{ Id = '2'; Kind = 'OpenMessage'; Result = 'Done'; Detail = $null; AttemptsLeft = $null; Parts = $null; Time = $script:time.AddMinutes(1) }
        (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Results = @($sent, $opened) })).Result | Should -Be '12:00:00 Message sent.'
        (ConvertTo-WindowView -Snapshot (Copy-Snapshot $script:online @{ Results = @($opened) })).Result | Should -BeNullOrEmpty
    }
}

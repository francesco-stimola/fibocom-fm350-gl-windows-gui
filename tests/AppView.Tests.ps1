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
# What the tray and the window show, from the worker's latest snapshot: pure functions, so every
# text and every icon state is decided here and proven by tests. Design: docs/ARCHITECTURE.md ->
# Tray icon. Texts and icon states: the maintainer's decision (ROADMAP M3).

# Every text the tray and the window show is the app's, in its language (Texts.ps1, Get-AppText):
# Reason.<reason>, Action.<step>, Mode.<mode>, Result.<command>.<result>, Tone.<tone>,
# Check.<check>, Step.<step>... The codes come from the snapshot.

# The network modes the window and the tray menu offer, in their order (ROADMAP M5).
$script:NetworkModeNames = @('Automatic', 'LteOnly', 'NrOnly')

# The longest message text: 255 parts of 153 GSM 7-bit characters (23.040). The window's box takes
# no more, and a text beyond it is too long without being measured on the UI thread.
$script:MessageMaxCharacters = 255 * 153

# The eSIM tab's commands: one at a time, the tab waiting for each one's outcome.
$script:EsimCommands = @('ReadEsim', 'SelectSimSlot', 'EnableProfile', 'DisableProfile', 'SetProfileNickname', 'DeleteProfile', 'DownloadProfile')

# The SIM slots as the worker counts them, from 0: the physical SIM's and the eUICC's on the
# FM350-GL (AT-COMMANDS section 8).
$script:PhysicalSlot = 0
$script:EuiccSlot = 1

function Get-SnapshotRecovery {
    # The snapshot's recovery state, or $null.
    param([object] $Snapshot)

    if ($Snapshot -and $Snapshot.PSObject.Properties['Recovery']) { $Snapshot.Recovery } else { $null }
}

function Get-SnapshotNetworkMode {
    # The snapshot's network mode, or $null.
    param([object] $Snapshot)

    if ($Snapshot -and $Snapshot.PSObject.Properties['NetworkMode']) { $Snapshot.NetworkMode } else { $null }
}

function Get-NetworkModeText {
    # '4G + 5G', ... for a mode's name; the RAT value for a mode the app doesn't offer.
    param([string] $Name, [object] $Rat)

    if ($Name -and $Name -in $script:NetworkModeNames) { Get-AppText "Mode.$Name" } else { Get-AppText 'Mode.Other' "$Rat" }
}

function Test-NoNetworkForMode {
    # Whether the connection waits for a network the network mode the user narrowed doesn't find:
    # no registration past its grace time, and no step for it (ARCHITECTURE -> Modes and bands).
    param([object] $Snapshot)

    $mode = Get-SnapshotNetworkMode -Snapshot $Snapshot
    $recovery = Get-SnapshotRecovery -Snapshot $Snapshot
    [bool]($mode -and $mode.Decision -and $mode.Decision.Narrowed -and $mode.Decision.Satisfied -ne $false -and -not $mode.Trial -and
        $recovery -and $recovery.Check -eq 'H4' -and $recovery.Status -eq 'Watching' -and -not $recovery.NextTime)
}

function Resolve-AppTone {
    # The tone of the tray icon and the window: Online, Working (on its way), Recovering (a
    # recovery step taken, or the next one awaited), Attention (the user must act, or recovery
    # ran out of steps), Offline (no modem), Stopped (no worker, or one that doesn't answer).
    param([object] $Snapshot, [string] $Worker)

    if (-not $Snapshot -or $Worker -ne 'Running' -or -not $Snapshot.State) {
        return 'Stopped'
    }
    $recovery = Get-SnapshotRecovery -Snapshot $Snapshot
    if (($recovery -and $recovery.Status -eq 'SlowCadence') -or (Test-NoNetworkForMode -Snapshot $Snapshot)) {
        return 'Attention'
    }
    if ($Snapshot.State -eq 'Online') {
        return 'Online'
    }
    if ($recovery -and $recovery.Status -in 'Recovering', 'Settling', 'Waiting') {
        return 'Recovering'
    }
    if ($Snapshot.Reason -eq 'NoDevice') {
        return 'Offline'
    }
    if ($Snapshot.Blocked) {
        return 'Attention'
    }
    'Working'
}

function Format-ClockTime {
    # 'HH:mm', or '' without a time.
    param([object] $Time)

    if ($Time) { $Time.ToString('HH:mm', [cultureinfo]::InvariantCulture) } else { '' }
}

function Get-RecoveryText {
    # What recovery is doing, in a sentence or two; $null when it says nothing beyond the reason.
    param([object] $Snapshot)

    $recovery = Get-SnapshotRecovery -Snapshot $Snapshot
    if (-not $recovery) {
        return $null
    }
    $check = if ($recovery.Check -and (Test-AppText "Check.$($recovery.Check)")) { Get-AppText "Check.$($recovery.Check)" } else { Get-AppText 'Check.Other' }
    $step = if ($recovery.Step -and (Test-AppText "Step.$($recovery.Step)")) { $recovery.Step } else { $null }
    switch ($recovery.Status) {
        { $_ -in 'Recovering', 'Settling' } { if ($step) { Get-AppText "Step.$step" } }
        'Waiting' { Get-AppText 'Recovery.Waiting' $check (Format-ClockTime -Time $recovery.NextTime) }
        'SlowCadence' { Get-AppText 'Recovery.Slow' $check $recovery.Cycles (Format-ClockTime -Time $recovery.NextTime) }
        'Withheld' { if ($step) { Get-AppText 'Recovery.Withheld' $check (Get-AppText "StepInline.$step") } }
    }
}

function Get-ReasonText {
    # The sentence that says why the connection is where it is.
    param([object] $Snapshot)

    if ($Snapshot.State -eq 'Online') {
        return Get-AppText 'Reason.Connected'
    }
    if (Test-NoNetworkForMode -Snapshot $Snapshot) {
        $mode = (Get-SnapshotNetworkMode -Snapshot $Snapshot).Current
        $key = if ($Snapshot.Settings -and @($Snapshot.Settings.LteBands).Count -gt 0) { 'Reason.NoNetworkForModeBands' } else { 'Reason.NoNetworkForMode' }
        return Get-AppText $key (Get-NetworkModeText -Name $mode.Mode -Rat $mode.Rat)
    }
    $recovering = Get-RecoveryText -Snapshot $Snapshot
    if ($recovering) {
        return $recovering
    }
    $reason = $Snapshot.Reason
    if ($reason -and (Test-AppText "Reason.$reason")) {
        return Get-AppText "Reason.$reason"
    }
    if ($reason) {
        # A registration state the texts don't name (roaming SMS only, ...).
        return Get-AppText 'Reason.Other' $reason
    }
    $step = if ($Snapshot.Action -and (Test-AppText "Action.$($Snapshot.Action)")) { $Snapshot.Action } else { $null }
    if ($step -and $Snapshot.ObserveOnly) {
        return Get-AppText 'Reason.Withheld' (Get-AppText "ActionInline.$step")
    }
    if ($step) {
        return Get-AppText "Action.$step"
    }
    Get-AppText 'Reason.Working'
}

function Test-StepWithheld {
    # Whether the connection waits on a step the app doesn't take because it only observes.
    param([object] $Snapshot)

    $Snapshot.ObserveOnly -and $Snapshot.State -ne 'Online' -and -not $Snapshot.Reason -and $Snapshot.Action -and $Snapshot.Action -ne 'None'
}

function Get-AppTitle {
    # The headline: the tone's, except 'Not connected' while a step waits that the app, only
    # observing, never takes, and 'Connection lost' once recovery has run out of steps.
    param([object] $Snapshot, [string] $Tone)

    $recovery = Get-SnapshotRecovery -Snapshot $Snapshot
    if ($Tone -eq 'Attention' -and $recovery -and $recovery.Status -eq 'SlowCadence') {
        return Get-AppText 'Title.ConnectionLost'
    }
    if ($Tone -eq 'Attention' -and (Test-NoNetworkForMode -Snapshot $Snapshot)) {
        return Get-AppText 'Title.NoNetwork'
    }
    if ($Tone -eq 'Working' -and ((Test-StepWithheld -Snapshot $Snapshot) -or ($recovery -and $recovery.Status -eq 'Withheld'))) {
        return Get-AppText 'Title.NotConnected'
    }
    Get-AppText "Tone.$Tone"
}

function Format-Measurement {
    # '-97 dBm', '<-140 dBm', '>=-44 dBm', or $null.
    param([object] $Measurement)

    if ($null -eq $Measurement) {
        return $null
    }
    $value = $Measurement.Value.ToString('0.#', [cultureinfo]::InvariantCulture)
    $prefix = switch ($Measurement.Bound) { 'Below' { '<' } 'Above' { '>=' } default { '' } }
    "$prefix$value $($Measurement.Unit)"
}

function Format-Operator {
    # '001 01' for a numeric operator (MCC and MNC), as reported otherwise.
    param([string] $Operator)

    if ($Operator -match '^(\d{3})(\d{2,3})$') { "$($Matches[1]) $($Matches[2])" } else { $Operator }
}

function Resolve-TrayIcon {
    <#
    .SYNOPSIS
        Decides what the tray icon shows: its tone, its signal bars and its technology label.
    .DESCRIPTION
        A pure function of the snapshot and of the worker's state ('Running', 'Restarting' or
        'NotResponding'). Tone: 'Online', 'Working', 'Attention', 'Offline' or 'Stopped'. Bars:
        0 to 4 from the serving RSRP, $null when nothing is measured (all bars drawn empty).
        Label: '5G' or '4G' while the radio is on one, else $null. The icon is redrawn only when
        one of the three changes.
    .EXAMPLE
        Resolve-TrayIcon -Snapshot $snapshot -Worker Running
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Snapshot,

        [ValidateSet('Running', 'Restarting', 'NotResponding')]
        [string] $Worker = 'Running'
    )

    $tone = Resolve-AppTone -Snapshot $Snapshot -Worker $Worker
    $radio = if ($tone -ne 'Stopped' -and $Snapshot.Radio) { $Snapshot.Radio } else { $null }
    $label = if ($radio) {
        switch -Wildcard ($radio.Technology) {
            '5G*' { '5G' }
            'LTE*' { '4G' }
        }
    }
    [pscustomobject]@{
        Tone  = $tone
        Bars  = if ($radio) { $radio.Bars } else { $null }
        Label = $label
    }
}

function ConvertTo-TrayText {
    <#
    .SYNOPSIS
        The tray icon's tooltip, from the snapshot.
    .DESCRIPTION
        'FM350-GL: Online' and, when online, the technology, the operator and the RSRP; else the
        reason in a few words. On a second line, the data used today and in this cycle, against
        the quota when there is one. At most 127 characters - Windows cuts a longer tooltip, and
        the framework refuses it: the first line is cut to make room.
    .EXAMPLE
        ConvertTo-TrayText -Snapshot $snapshot
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Snapshot,

        [ValidateSet('Running', 'Restarting', 'NotResponding')]
        [string] $Worker = 'Running'
    )

    $tone = Resolve-AppTone -Snapshot $Snapshot -Worker $Worker
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((Get-AppText 'Tray.Tooltip' (Get-AppTitle -Snapshot $Snapshot -Tone $tone)))
    if ($tone -eq 'Online' -and $Snapshot.Radio) {
        $radio = $Snapshot.Radio
        foreach ($part in @($radio.Technology, (Format-Operator -Operator $radio.Operator))) {
            if ($part) { $parts.Add($part) }
        }
        if ($null -ne $radio.Rsrp) {
            $parts.Add("RSRP $($radio.Rsrp.ToString('0', [cultureinfo]::InvariantCulture)) dBm")
        }
    }
    elseif ($tone -ne 'Stopped') {
        $parts.Add((Get-ReasonText -Snapshot $Snapshot))
    }
    $text = $parts -join ' - '
    $usage = Get-SnapshotValue -Snapshot $Snapshot -Name 'Usage'
    $line = if ($usage -and $tone -ne 'Stopped') {
        if ($usage.Quota) {
            Get-AppText 'Tray.UsageQuota' (Format-DataSize $usage.Today.Total) (Format-DataSize $usage.Cycle.Total) (Format-DataSize $usage.Quota)
        }
        else {
            Get-AppText 'Tray.Usage' (Format-DataSize $usage.Today.Total) (Format-DataSize $usage.Cycle.Total)
        }
    }
    $room = if ($line) { 127 - $line.Length - 1 } else { 127 }
    if ($text.Length -gt $room) {
        $text = $text.Substring(0, $room - 1) + [char]0x2026
    }
    if ($line) { "$text`n$line" } else { $text }
}

function Resolve-AppBlocker {
    # What the user can do about what blocks the connection, if anything: Kind - 'Apn',
    # 'ApnPassword', 'Pin', 'EnableAdapter', 'Unlock', 'Esim' (the eSIM
    # tab), 'Settings' (the Connection tab) or $null for a message alone - Message, ActionText,
    # and Enabled ($false when the app can't do it now).
    param([object] $Snapshot)

    if (Test-NoNetworkForMode -Snapshot $Snapshot) {
        return [pscustomobject]@{
            Kind       = 'NetworkMode'
            Message    = Get-ReasonText -Snapshot $Snapshot
            ActionText = Get-AppText 'Blocker.UseAutomatic' (Get-AppText 'Mode.Automatic')
            Enabled    = -not $Snapshot.ObserveOnly
        }
    }
    if (-not $Snapshot.Blocked -or $Snapshot.Reason -eq 'NoDevice') {
        return $null
    }
    $kind, $action = switch ($Snapshot.Reason) {
        'ApnNeeded' { 'Apn', 'Blocker.SaveApn' }
        'ApnPasswordUnreadable' { 'ApnPassword', 'Blocker.SavePassword' }
        { $_ -in 'NoPin', 'PinForOtherSim', 'PinUnconfirmed' } { 'Pin', 'Blocker.StorePin' }
        'AdapterDisabled' { 'EnableAdapter', 'Blocker.EnableAdapter' }
        'FccLocked' { 'Unlock', 'Blocker.Unlock' }
        'NoProfile' { 'Esim', 'Blocker.OpenEsim' }
        { $_ -like 'Doh*' } { 'Settings', 'Blocker.OpenSettings' }
        default { $null, $null }
    }
    $enabled = $true
    $sentences = [System.Collections.Generic.List[string]]::new()
    $sentences.Add((Get-ReasonText -Snapshot $Snapshot))
    if ($Snapshot.ObserveOnly -and $kind -in 'EnableAdapter', 'Unlock') {
        $enabled = $false
        $sentences.Add((Get-AppText 'Blocker.ObserveOnly'))
    }
    elseif ($kind -eq 'EnableAdapter' -and -not $Snapshot.Elevated) {
        $enabled = $false
        $sentences.Add((Get-AppText 'Blocker.NeedsAdmin'))
    }
    elseif ($kind -eq 'Unlock') {
        $sentences.Add((Get-AppText 'Blocker.UnlockNote'))
    }
    if ($kind -eq 'Pin' -and $null -ne $Snapshot.Sim.AttemptsLeft) {
        $sentences.Add((Get-AppText 'Blocker.AttemptsLeft' $Snapshot.Sim.AttemptsLeft))
    }
    [pscustomobject]@{ Kind = $kind; Message = $sentences -join ' '; ActionText = $(if ($action) { Get-AppText $action }); Enabled = $enabled }
}

function Get-SimView {
    # The SIM tab: its state, the stored PIN, what can be done.
    param([object] $Snapshot)

    $sim = $Snapshot.Sim
    $known = 'Ready', 'PinRequired', 'PukRequired', 'NoProfile', 'Absent', 'Busy', 'Failure', 'Other'
    $state = Get-AppText $(if ($sim.State -in $known) { "Sim.$($sim.State)" } else { 'Sim.Unknown' })
    $request = if ($sim.PinRequestOn -eq $true) { 'Sim.RequestOn' } elseif ($sim.PinRequestOn -eq $false) { 'Sim.RequestOff' } else { 'Sim.RequestUnknown' }
    $connected = [bool]$Snapshot.PortName
    [pscustomobject]@{
        StateText     = if ($null -ne $sim.AttemptsLeft) { Get-AppText 'Sim.StateAttempts' $state $sim.AttemptsLeft } else { Get-AppText 'Sim.State' $state }
        RequestText   = Get-AppText $request
        StoredText    = Get-AppText $(if ($sim.PinStored) { 'Sim.Stored' } else { 'Sim.NotStored' })
        Note          = if ($sim.PinRejected) { Get-AppText 'Sim.Rejected' } else { $null }
        CanStorePin   = $connected
        CanForgetPin  = [bool]$sim.PinStored
        CanDisablePin = $connected -and -not $Snapshot.ObserveOnly -and $sim.State -eq 'Ready' -and $sim.PinRequestOn -eq $true
    }
}

function Get-ResultText {
    # The newest command outcome, in a sentence with its time. Opening a message says nothing: it
    # would hide the outcome before it.
    param([object] $Snapshot)

    $last = @($Snapshot.Results | Where-Object { $_ -and $_.Kind -ne 'OpenMessage' }) | Select-Object -Last 1
    if (-not $last) {
        return $null
    }
    $parts = if ($last.PSObject.Properties['Parts']) { $last.Parts } else { $null }
    # An outcome whose detail is a code of its own (an activation code's problem...): its text.
    $detailed = if ($last.Detail -is [string] -and $last.Detail -match '^[A-Za-z]+$') { "Result.$($last.Kind).$($last.Result).$($last.Detail)" } else { $null }
    $text = if ($last.Kind -eq 'SendMessage' -and $last.Result -eq 'Failed') {
        # How many parts went out, when the worker got as far as sending.
        if ($parts) { Get-AppText 'Result.SendMessage.Failed' $parts.Sent $parts.Count } else { Get-AppText 'Result.Failed' }
    }
    elseif ($detailed -and (Test-AppText $detailed)) {
        Get-AppText $detailed
    }
    elseif (Test-AppText "Result.$($last.Kind).$($last.Result)") {
        Get-AppText "Result.$($last.Kind).$($last.Result)"
    }
    elseif (Test-AppText "Result.$($last.Result)") {
        Get-AppText "Result.$($last.Result)"
    }
    else {
        Get-AppText 'Result.Other' $last.Kind $last.Result
    }
    if ($last.Kind -eq 'DisableSimPin' -and $null -ne $last.AttemptsLeft) {
        $text += ' ' + (Get-AppText 'Result.AttemptsLeft' $last.AttemptsLeft)
    }
    if ($last.Result -eq 'Failed' -and $last.Detail) {
        $text += " $($last.Detail)"
    }
    "$($last.Time.ToString('HH:mm:ss', [cultureinfo]::InvariantCulture)) $text"
}

function Format-BandList {
    # 'every band', 'every band but n77', or 'B3, B20' - the bands of one RAT, as -Prefix ('B' for
    # LTE, 'n' for NR) names them, against those supported (none known: listed).
    param([int[]] $Band, [int[]] $Supported, [string] $Prefix)

    $bands = @($Band | Where-Object { $null -ne $_ })
    $known = @($Supported | Where-Object { $null -ne $_ })
    $left = @($known | Where-Object { $_ -notin $bands })
    if ($known.Count -gt 0 -and $left.Count -eq 0) {
        return Get-AppText 'Bands.Every'
    }
    if ($known.Count -gt 0 -and $left.Count -le 3 -and $bands.Count -gt $left.Count) {
        return Get-AppText 'Bands.EveryBut' (@($left | ForEach-Object { "$Prefix$_" }) -join ', ')
    }
    if ($bands.Count -eq 0) {
        return Get-AppText 'Bands.None'
    }
    @($bands | ForEach-Object { "$Prefix$_" }) -join ', '
}

function Get-NetworkModeView {
    <#
    .SYNOPSIS
        The window's network tab, from the snapshot: the modem's mode and bands, what can be
        chosen, and how the last choice went.
    .DESCRIPTION
        A pure function. Returns CurrentText (the modem's mode and bands as read), Modes (Name
        and Text of each choice: not managed, then the modes the modem supports), Lte and Nr
        (the band numbers that can be chosen), Selection (NetworkMode, LteBands and NrBands in
        force: on trial, else saved), Revision (changes when the choice in force does), Note (a
        mode on trial, how the last one ended, bands asked that the modem leaves out, a mode
        not kept), and CanApply (the modem is there, its supported values known, and the app
        doesn't only observe).
    .EXAMPLE
        Get-NetworkModeView -Snapshot $snapshot
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Snapshot
    )

    $mode = Get-SnapshotNetworkMode -Snapshot $Snapshot
    $current = if ($mode) { $mode.Current } else { $null }
    $support = if ($mode) { $mode.Support } else { $null }
    $decision = if ($mode) { $mode.Decision } else { $null }
    $lte = [int[]]@(if ($support) { $support.Lte })
    $nr = [int[]]@(if ($support) { $support.Nr })

    $currentText = if ($current) {
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add((Get-AppText 'Network.Current' (Get-NetworkModeText -Name $current.Mode -Rat $current.Rat)))
        if (@($current.LteCodes).Count -gt 0 -or $current.AllBands) {
            $parts.Add((Get-AppText 'Network.Lte' $(if ($current.AllBands) { Get-AppText 'Bands.Every' } else { Format-BandList -Band $current.Lte -Supported $lte -Prefix 'B' })))
        }
        if (@($current.NrCodes).Count -gt 0 -or ($current.AllBands -and $current.Mode -ne 'LteOnly')) {
            $parts.Add((Get-AppText 'Network.Nr' $(if ($current.AllBands) { Get-AppText 'Bands.Every' } else { Format-BandList -Band $current.Nr -Supported $nr -Prefix 'n' })))
        }
        $parts -join ' '
    }
    else {
        Get-AppText 'Network.NotRead'
    }

    $offered = if ($support) { @($support.Modes) } else { $script:NetworkModeNames }
    $modes = @([pscustomobject]@{ Name = ''; Text = Get-AppText 'Mode.NotManaged' }) + @(foreach ($name in $script:NetworkModeNames) {
            if ($name -in $offered) { [pscustomobject]@{ Name = $name; Text = Get-AppText "Mode.$name" } }
        })

    $notes = [System.Collections.Generic.List[string]]::new()
    $trial = if ($mode) { $mode.Trial } else { $null }
    if ($trial) {
        $notes.Add((Get-AppText 'Network.Trial' (Get-NetworkModeText -Name $trial.Selection.NetworkMode) (Format-ClockTime -Time $trial.Until)))
    }
    $notice = if ($mode) { $mode.Notice } else { $null }
    if ($notice -and -not $trial) {
        $text = Get-NetworkModeText -Name $notice.Mode
        $notes.Add((Get-AppText $(if ($notice.Kind -eq 'Reverted') { 'Network.Reverted' } else { 'Network.Kept' }) (Format-ClockTime -Time $notice.Time) $text))
    }
    if ($decision -and $decision.Problem -and (Test-AppText "ModeProblem.$($decision.Problem)")) {
        $notes.Add((Get-AppText "ModeProblem.$($decision.Problem)"))
    }
    if ($decision -and $decision.Missing) {
        $left = @(@($decision.Missing.Lte | ForEach-Object { "B$_" }) + @($decision.Missing.Nr | ForEach-Object { "n$_" }))
        if ($left.Count -gt 0) {
            $notes.Add((Get-AppText 'Network.Missing' ($left -join ', ')))
        }
    }

    # The choice in force: the one on trial, else the saved one.
    $settings = if ($trial) { $trial.Selection } elseif ($Snapshot) { $Snapshot.Settings } else { $null }
    [pscustomobject]@{
        CurrentText = $currentText
        Modes       = [object[]]$modes
        Lte         = $lte
        Nr          = $nr
        Selection   = if ($settings -and $settings.PSObject.Properties['NetworkMode']) {
            [pscustomobject]@{ NetworkMode = $settings.NetworkMode; LteBands = [int[]]@($settings.LteBands); NrBands = [int[]]@($settings.NrBands) }
        }
        else {
            $null
        }
        # Changes when the choice in force does: a trial starts or ends.
        Revision    = "$(if ($trial) { "trial $($trial.Since)" } else { 'saved' }) $(if ($notice) { $notice.Time.UtcTicks })"
        Note        = if ($notes.Count) { $notes -join ' ' } else { $null }
        CanApply    = [bool]($Snapshot -and $Snapshot.PortName -and -not $Snapshot.ObserveOnly -and $support)
    }
}

function Get-TrayModeMenu {
    <#
    .SYNOPSIS
        The tray menu's network modes, from the snapshot.
    .DESCRIPTION
        A pure function. Returns Text (the submenu's: 'Network mode', with the modem's mode when
        known) and Items: Name, Text, Checked (the modem's mode now) and Enabled (it can be
        chosen now: not the modem's, the modem there, and the app not only observing).
    .EXAMPLE
        Get-TrayModeMenu -Snapshot $snapshot -Worker Running
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Snapshot,

        [ValidateSet('Running', 'Restarting', 'NotResponding')]
        [string] $Worker = 'Running'
    )

    $view = Get-NetworkModeView -Snapshot $Snapshot
    $mode = Get-SnapshotNetworkMode -Snapshot $Snapshot
    $current = if ($mode -and $mode.Current) { $mode.Current.Mode } else { $null }
    $usable = $view.CanApply -and $Worker -eq 'Running'
    [pscustomobject]@{
        Text  = if ($mode -and $mode.Current) { Get-AppText 'Tray.NetworkModeNow' (Get-NetworkModeText -Name $current -Rat $mode.Current.Rat) } else { Get-AppText 'Tray.NetworkMode' }
        Items = [object[]]@(foreach ($choice in $view.Modes | Where-Object Name) {
                [pscustomobject]@{
                    Name    = $choice.Name
                    Text    = $choice.Text
                    Checked = $choice.Name -eq $current
                    Enabled = $usable -and $choice.Name -ne $current
                }
            })
    }
}

function Get-TrayUpdateItem {
    <#
    .SYNOPSIS
        The tray menu's update notice, from the snapshot.
    .DESCRIPTION
        A pure function. Returns Visible - a newer release was found, and the settings still ask
        for the notice -, Text and Url, the release's page.
    .EXAMPLE
        Get-TrayUpdateItem -Snapshot $snapshot
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Snapshot
    )

    $update = if ($Snapshot -and $Snapshot.PSObject.Properties['Update']) { $Snapshot.Update } else { $null }
    $wanted = -not ($Snapshot -and $Snapshot.Settings -and $Snapshot.Settings.PSObject.Properties['CheckForUpdates'] -and -not $Snapshot.Settings.CheckForUpdates)
    if ($wanted -and $update -and $update.Result -eq 'Newer' -and $update.Url) {
        return [pscustomobject]@{ Visible = $true; Text = Get-AppText 'Tray.Update' $update.Version; Url = $update.Url }
    }
    [pscustomobject]@{ Visible = $false; Text = $null; Url = $null }
}

function Get-DnsView {
    # The connection tab's encrypted DNS: Text, what the adapter has now; CanEnable, $false on a
    # Windows without the per-interface API; Known, the servers Windows has a template for.
    param([object] $Snapshot)

    $dns = if ($Snapshot -and $Snapshot.PSObject.Properties['Dns']) { $Snapshot.Dns } else { $null }
    $supported = if ($dns) { $dns.Supported } else { $null }
    $encrypted = @(if ($dns) { $dns.Encrypted | Where-Object { $_ } })
    $name = if ($dns -and $dns.PSObject.Properties['Name']) { $dns.Name } else { $null }
    # A DoH server named by its template: when it was looked up, and when it will be again.
    # Why a lookup failed is the log's to say, in English.
    $lookup = if ($name -and $name.Failure) {
        Get-AppText 'Dns.LookupFailed' $name.Host
    }
    elseif ($name -and @($name.Addresses).Count -gt 0) {
        $key = if ($name.PSObject.Properties['Via'] -and $name.Via -eq 'Operator') { 'Dns.LookedUpOperator' } else { 'Dns.LookedUp' }
        if ($name.Next) {
            Get-AppText "${key}Next" $name.Host (Format-ClockTime -Time $name.LookedUp) (Format-ClockTime -Time $name.Next)
        }
        else {
            Get-AppText $key $name.Host (Format-ClockTime -Time $name.LookedUp)
        }
    }
    elseif ($name) {
        Get-AppText 'Dns.LookingUp' $name.Host
    }
    # IPv6 DNS servers the network gives beside encrypted DNS, which Windows may query in the clear.
    $advertised = @(if ($dns -and $dns.PSObject.Properties['Advertised']) { $dns.Advertised | Where-Object { $_ } })
    $given = if ($advertised.Count -gt 0) { Get-AppText 'Dns.Advertised' ($advertised -join ', ') }
    $text = if ($supported -eq $false) {
        Get-AppText 'Dns.Unavailable'
    }
    elseif ($encrypted.Count -gt 0) {
        @((Get-AppText 'Dns.On' ($encrypted -join ', ')), $lookup, $given | Where-Object { $_ }) -join ' '
    }
    elseif ($name) {
        @((Get-AppText 'Dns.Waiting'), $lookup, $given | Where-Object { $_ }) -join ' '
    }
    elseif ($null -ne $supported) {
        Get-AppText 'Dns.Off'
    }
    else {
        $null
    }
    [pscustomobject]@{
        Text      = $text
        CanEnable = $supported -ne $false
        Known     = [string[]]@(if ($dns) { $dns.Known | Where-Object { $_ } })
    }
}

function Get-StartupView {
    # The connection tab's start at sign-in: Checked (the installer's logon task is on), CanChange,
    # and Note - why it can't be changed.
    param([object] $Snapshot, [string] $Worker)

    $state = if ($Snapshot -and $Snapshot.PSObject.Properties['StartAtLogon']) { $Snapshot.StartAtLogon } else { $null }
    $note = if (-not $Snapshot) {
        $null
    }
    elseif ($null -eq $state) {
        Get-AppText 'Startup.NotInstalled'
    }
    elseif ($Snapshot.ObserveOnly) {
        Get-AppText 'Startup.ObserveOnly'
    }
    elseif (-not $Snapshot.Elevated) {
        Get-AppText 'Startup.NeedsAdmin'
    }
    [pscustomobject]@{
        Checked   = $state -eq $true
        CanChange = [bool]($Snapshot -and $null -ne $state -and -not $Snapshot.ObserveOnly -and $Snapshot.Elevated -and $Worker -eq 'Running')
        Note      = $note
    }
}

function Get-SnapshotSettingIssue {
    # The settings file's issues the snapshot carries (ConvertTo-AppSetting's Issues).
    param([object] $Snapshot)

    if ($Snapshot -and $Snapshot.PSObject.Properties['SettingsIssues']) { @($Snapshot.SettingsIssues | Where-Object { $_ }) }
}

function ConvertTo-SettingIssueText {
    # One issue of the settings - Setting, Rule, Values (ConvertTo-AppSetting's) - in the app's
    # language; in English, the problem the log says (but an unreadable file's reason).
    param([object] $Issue)

    $values = [object[]]@($Issue.Values)
    switch ($Issue.Rule) {
        'Unknown' { return Get-AppText 'Setting.Unknown' $Issue.Setting }
        'Unreadable' { return Get-AppText 'Setting.Unreadable' }
        'DohNeedsServers' { return Get-AppText 'Setting.DohNeedsServers' }
        'TemplateAddress' { return Get-AppText 'Setting.TemplateAddress' $values[0] }
    }
    Get-AppText 'Setting.Rejected' $Issue.Setting (Get-AppText "Rule.$($Issue.Rule)" -Arguments $values)
}

function Get-UsbFunctionText {
    # A function of the modem as the USB tab names it: what it is, and its interface - 'AT port
    # (MI_06)'.
    param([object] $Function)

    $name = if ($Function.Name -and (Test-AppText "Usb.Function.$($Function.Name)")) { Get-AppText "Usb.Function.$($Function.Name)" } else { Get-AppText 'Usb.Function.Other' }
    Get-AppText 'Usb.FunctionName' $name ([int]$Function.Interface).ToString('X2', [cultureinfo]::InvariantCulture)
}

function Get-UsbView {
    <#
    .SYNOPSIS
        The window's USB tab, from the snapshot.
    .DESCRIPTION
        A pure function of the snapshot (decided 2026-10-04: the state, no buttons - the app puts
        the functions on WinUSB by itself, and Check now tries again). Returns StateText (where the
        modem's vendor functions are: on Windows' WinUSB, not yet, a problem, no modem), Functions
        (a line per vendor function: what it is, its interface and its driver), BindingText (the
        last time the app put functions on WinUSB: when, and how it went for each) and Note (the
        app only observes, or has no administrator rights: it puts none there).
    .EXAMPLE
        Get-UsbView -Snapshot $snapshot
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Snapshot
    )

    $usb = Get-SnapshotValue -Snapshot $Snapshot -Name 'Usb'
    $device = if ($usb) { $usb.Device } else { $null }
    $stateText = switch ($device) {
        'Present' { Get-AppText 'Usb.Present' }
        'Unbound' { Get-AppText 'Usb.Unbound' }
        'Problem' { Get-AppText 'Reason.DeviceProblem' }
        'Absent' { Get-AppText 'Reason.NoDevice' }
        default { Get-AppText 'Usb.NotLooked' }
    }
    $functions = @(if ($usb) { $usb.Functions | Where-Object { $_ } })
    $lines = foreach ($function in $functions) {
        $driver = switch ($function.Driver) {
            'WinUsb' { Get-AppText 'Usb.OnWinUsb' }
            'None' { Get-AppText 'Usb.NoDriver' }
            default { Get-AppText 'Usb.OtherDriver' }
        }
        if ($function.ProblemCode) {
            $driver = Get-AppText 'Usb.ProblemCode' $driver $function.ProblemCode
        }
        Get-AppText 'Usb.FunctionLine' (Get-UsbFunctionText -Function $function) $driver
    }
    $binding = if ($usb) { $usb.Binding } else { $null }
    $bindingText = if ($binding -and @($binding.Functions).Count -gt 0) {
        $said = [System.Collections.Generic.List[string]]::new()
        $said.Add((Get-AppText 'Usb.LastChange' (Format-ClockTime -Time $binding.Time)))
        foreach ($outcome in @($binding.Functions)) {
            $name = Get-UsbFunctionText -Function $outcome
            $said.Add($(switch ($outcome.Result) {
                        'Done' { Get-AppText 'Usb.Bound' $name }
                        'InUse' { Get-AppText 'Usb.Held' $name }
                        'RestartNeeded' { Get-AppText 'Usb.RestartNeeded' $name }
                        default { Get-AppText 'Usb.Failed' $name (@($outcome.Step, $outcome.Error | Where-Object { $_ }) -join ', ') }
                    }))
        }
        $said -join [Environment]::NewLine
    }
    $offWinUsb = @($functions | Where-Object Driver -NE 'WinUsb').Count -gt 0 -or $device -eq 'Unbound'
    $note = if ($Snapshot -and $Snapshot.ObserveOnly) {
        Get-AppText 'Usb.ObserveOnly'
    }
    elseif ($Snapshot -and -not $Snapshot.Elevated -and $offWinUsb) {
        Get-AppText 'Usb.NeedsAdmin'
    }
    [pscustomobject]@{
        StateText   = $stateText
        Functions   = [string[]]@($lines)
        BindingText = $bindingText
        Note        = $note
    }
}

function Format-DataSize {
    # Bytes in decimal units - a gigabyte is 10^9 bytes, as the quota counts it -, one decimal, in
    # the invariant culture: '0 B', '950 B', '1.2 kB', '14.3 GB'.
    param([double] $Bytes)

    $units = 'B', 'kB', 'MB', 'GB', 'TB'
    $value = [Math]::Max([double]0, $Bytes)
    $unit = 0
    while ([Math]::Round($value, 1) -ge 1000 -and $unit -lt $units.Count - 1) {
        $value /= 1000
        $unit++
    }
    if ($unit -eq 0) { "$([long]$value) B" } else { "$($value.ToString('0.0', [cultureinfo]::InvariantCulture)) $($units[$unit])" }
}

function Get-SnapshotValue {
    # A snapshot's property, or $null: a snapshot from before M8 has no messages and no usage.
    param([object] $Snapshot, [string] $Name)

    if ($Snapshot -and $Snapshot.PSObject.Properties[$Name]) { $Snapshot.$Name } else { $null }
}

function Get-MessageBody {
    # A message's text as the window shows it; for one without text, a sentence that says why. A
    # silent message's text is never shown (23.040: a short message type 0).
    param([object] $Message)

    if ($Message.Silent) {
        return Get-AppText 'Messages.Silent'
    }
    if ($Message.Problem) {
        return Get-AppText 'Messages.Malformed'
    }
    if ($null -ne $Message.Text) {
        return $Message.Text
    }
    switch ($Message.Content) {
        'Binary' { Get-AppText 'Messages.Binary' }
        'Compressed' { Get-AppText 'Messages.Compressed' }
        default { Get-AppText 'Messages.Malformed' }
    }
}

function Get-MessagesView {
    <#
    .SYNOPSIS
        The Messages tab, from the snapshot.
    .DESCRIPTION
        A pure function. Returns StateText (the SIM in use - the messages listed are its slot's -,
        how full it is and how many messages of another eSIM profile are not shown, or why there
        are no messages: no modem, the SIM not ready, observe-only), TabText (the tab's header,
        with the number of new messages), Items - a row per message, newest first: Key,
        Fingerprints, New, Marker, From, Time, Preview, Header, Text, Note - the SIM it came in on,
        when not the one in use, first -, SentId (the newest message sent's command), SendIds (the commands of the
        messages the worker sent or tried), Generation (that worker's), SendingText, FromText
        (which SIM a message goes out from: the one in use - the modem uses one at a time,
        decided 2026-10-04), CanDelete and CanSend.
    .EXAMPLE
        Get-MessagesView -Snapshot $snapshot
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Snapshot
    )

    $messages = Get-SnapshotValue -Snapshot $Snapshot -Name 'Messages'
    $sending = (Get-SnapshotValue -Snapshot $Snapshot -Name 'MessageOperation') -eq 'Sending'
    $simInUse = Get-SimInUseText -Snapshot $Snapshot
    $state = if ($messages) {
        $sentences = [System.Collections.Generic.List[string]]::new()
        if ($simInUse) {
            $sentences.Add($simInUse)
        }
        if ($null -ne $messages.Used -and $null -ne $messages.Total) {
            $sentences.Add((Get-AppText 'Messages.Storage' $messages.Used $messages.Total))
        }
        if ($messages.Full) {
            $sentences.Add((Get-AppText 'Messages.Full'))
        }
        $hidden = if ($messages.PSObject.Properties['Hidden']) { [int]$messages.Hidden } else { 0 }
        if ($hidden -gt 0) {
            $sentences.Add((Get-AppText 'Messages.Hidden' $hidden))
        }
        elseif (@($messages.Items).Count -eq 0) {
            $sentences.Add((Get-AppText 'Messages.Empty'))
        }
        $sentences -join ' '
    }
    elseif (-not $Snapshot) {
        $null
    }
    elseif ($Snapshot.ObserveOnly) {
        Get-AppText 'Messages.ObserveOnly'
    }
    elseif (-not $Snapshot.PortName) {
        Get-AppText 'Messages.NoModem'
    }
    else {
        Get-AppText 'Messages.NotReady'
    }
    $rows = foreach ($item in @(if ($messages) { $messages.Items })) {
        $time = if ($item.Time) { $item.Time.ToLocalTime().ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture) } else { '' }
        $body = Get-MessageBody -Message $item
        $line = ($body -replace '\s+', ' ').Trim()
        $notes = [System.Collections.Generic.List[string]]::new()
        if ($item.PSObject.Properties['Owner'] -and $item.Owner -eq 'Other') {
            $cameIn = if ($item.OwnerKind -eq 'Esim' -and $item.OwnerName) {
                Get-AppText 'Messages.FromGoneProfile' $item.OwnerName
            }
            elseif ($item.OwnerKind -eq 'Esim') {
                Get-AppText 'Messages.FromOtherProfile'
            }
            else {
                Get-AppText 'Messages.FromOtherSim'
            }
            $notes.Add($cameIn)
        }
        if (-not $item.Complete -and @($item.Missing).Count -gt 0) {
            $notes.Add((Get-AppText 'Messages.Missing' (@($item.Missing) -join ', ')))
        }
        if ($item.Silent) {
            $notes.Add((Get-AppText 'Messages.SilentNote'))
        }
        elseif ($item.NationalLanguage) {
            $notes.Add((Get-AppText 'Messages.NationalLanguage'))
        }
        [pscustomobject]@{
            Key          = @($item.Fingerprints) -join ','
            Fingerprints = [string[]]@($item.Fingerprints)
            New          = [bool]$item.New
            Marker       = if ($item.New) { [string][char]0x25CF } else { '' }
            From         = [string]$item.Address
            Time         = $time
            Preview      = if ($line.Length -gt 60) { $line.Substring(0, 59) + [char]0x2026 } else { $line }
            Header       = Get-AppText 'Messages.Header' $item.Address $time
            Text         = $body
            Note         = if ($notes.Count) { $notes -join ' ' } else { $null }
        }
    }
    $new = if ($messages) { [int]$messages.New } else { 0 }
    $sends = @(Get-SnapshotValue -Snapshot $Snapshot -Name 'Results' | Where-Object { $_ -and $_.Kind -eq 'SendMessage' })
    $sent = @($sends | Where-Object Result -EQ 'Sent') | Select-Object -Last 1
    [pscustomobject]@{
        StateText   = $state
        TabText     = if ($new -gt 0) { Get-AppText 'Messages.TabNew' $new } else { Get-AppText 'Xaml.MessagesTab' }
        Items       = [object[]]@($rows)
        SentId      = if ($sent) { $sent.Id } else { $null }
        SendIds     = [string[]]@($sends | ForEach-Object Id)
        Generation  = Get-SnapshotValue -Snapshot $Snapshot -Name 'Generation'
        SendingText = if ($sending) { Get-AppText 'Messages.Sending' } else { $null }
        FromText    = if ($messages) { Get-AppText 'Messages.From' } else { $null }
        CanDelete   = [bool]$messages -and -not $sending
        CanSend     = [bool]$messages -and -not $sending
    }
}

function Get-MessageCountText {
    # What a message being written takes (Measure-SmsText): its characters and its parts, and the
    # characters a part holds when one of them needs UCS2; $null while it is empty.
    param([string] $Text)

    if (-not $Text) {
        return $null
    }
    # Longer than 255 parts of the most a part holds: too long, without measuring it.
    if ($Text.Length -gt $script:MessageMaxCharacters) {
        return Get-AppText 'Messages.TooLong'
    }
    $measure = Measure-SmsText -Text $Text
    if ($measure.TooLong) {
        Get-AppText 'Messages.TooLong'
    }
    elseif ($measure.Alphabet -eq 'Ucs2') {
        Get-AppText 'Messages.CountUnicode' $measure.Length $measure.Parts $measure.PerPart
    }
    else {
        Get-AppText 'Messages.Count' $measure.Length $measure.Parts
    }
}

function Get-UsageView {
    <#
    .SYNOPSIS
        The Data tab, from the snapshot's data usage (Measure-DataUsage's).
    .DESCRIPTION
        A pure function. Returns TodayText, CycleText (with the cycle's first and last day),
        QuotaText, Percent (the quota's share used, at most 100, or $null without a quota) and
        Warning (a quota threshold reached).
    .EXAMPLE
        Get-UsageView -Snapshot $snapshot
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Snapshot
    )

    $usage = Get-SnapshotValue -Snapshot $Snapshot -Name 'Usage'
    if (-not $usage) {
        return [pscustomobject]@{ TodayText = Get-AppText 'Usage.NotCounted'; CycleText = $null; QuotaText = $null; Percent = $null; Warning = $false }
    }
    $day = { param($date) $date.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
    $today = $usage.Today
    $cycle = $usage.Cycle
    $percent = if ($usage.Quota) { [Math]::Min(100.0, [double]$usage.Percent) } else { $null }
    [pscustomobject]@{
        TodayText = Get-AppText 'Usage.Today' (Format-DataSize $today.Total) (Format-DataSize $today.Received) (Format-DataSize $today.Sent)
        CycleText = Get-AppText 'Usage.Cycle' (& $day $usage.CycleStart) (& $day $usage.CycleEnd.AddDays(-1)) (Format-DataSize $cycle.Total) (Format-DataSize $cycle.Received) (Format-DataSize $cycle.Sent)
        QuotaText = if ($usage.Quota) { Get-AppText 'Usage.Quota' (Format-DataSize $cycle.Total) (Format-DataSize $usage.Quota) ([Math]::Floor([double]$usage.Percent)) } else { Get-AppText 'Usage.NoQuota' }
        Percent   = $percent
        Warning   = [bool]$usage.Threshold
    }
}

function Get-EsimProfileName {
    # A profile as the user knows it: its nickname, its name, or its provider's.
    param([object] $Entry)

    foreach ($name in @($Entry.Nickname, $Entry.Name, $Entry.Provider)) {
        if ($name) {
            return [string]$name
        }
    }
    Get-AppText 'Esim.Unnamed'
}

function Get-SimInUseText {
    # The SIM slot in use and its SIM - the eSIM's profile enabled -, as a sentence, from the
    # snapshot; $null while the slot is unknown. Slots are counted from 1, as the modem names
    # them (SUB1, SUB2).
    param([AllowNull()] [object] $Snapshot)

    $esim = Get-SnapshotValue -Snapshot $Snapshot -Name 'Esim'
    $slot = if ($esim) { $esim.Slot } else { $null }
    if ($null -eq $slot) {
        return $null
    }
    $inUse = $esim.SimType -eq 'Esim' -or ($null -eq $esim.SimType -and $slot -eq 1)
    # Not an if expression: it would unroll an eUICC's empty list into none read.
    $profiles = $esim.Profiles
    $enabled = @($profiles | Where-Object { $_ -and $_.State -eq 'Enabled' }) | Select-Object -First 1
    if ($esim.SimType -eq 'Usim') {
        Get-AppText 'SimInUse.Physical' ($slot + 1)
    }
    elseif ($inUse -and $enabled) {
        Get-AppText 'SimInUse.Esim' ($slot + 1) (Get-EsimProfileName -Entry $enabled)
    }
    elseif ($inUse -and $null -ne $profiles) {
        Get-AppText 'SimInUse.EsimEmpty' ($slot + 1)
    }
    elseif ($inUse) {
        Get-AppText 'SimInUse.EsimUnread' ($slot + 1)
    }
    else {
        Get-AppText 'SimInUse.Slot' ($slot + 1)
    }
}

function Get-EsimView {
    <#
    .SYNOPSIS
        The eSIM tab, and the SIM in use for the window's top panel, from the snapshot.
    .DESCRIPTION
        A pure function. Slots are counted from 1, as the modem names them (SUB1, SUB2). Returns
        SimInUse (the slot in use and its SIM - the eSIM's profile enabled -, or $null while the
        slot is unknown), StateText (why the profiles can't be managed, the command under way,
        the last read's failure, or that there are none), Eid (shown with Copy, decided
        2026-10-04), ChipText, NotificationText, Profiles - a row each: Aid, Name, Provider, Kind,
        State, Enabled, Nickname -, the two SIMs' buttons - on the SIM tab and the eSIM tab,
        each saying when its SIM is in use: PhysicalText and EsimText, CanUsePhysical and
        CanUseEsim - with SlotNote, which says the modem uses one at a time, CanRead, CanManage
        (enable, disable, rename, delete), CanDownload, CanReadQr, QrNote, ResultIds (the
        outcomes of the tab's commands) and Generation (the worker's).
    .EXAMPLE
        Get-EsimView -Snapshot $snapshot
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Snapshot
    )

    $esim = Get-SnapshotValue -Snapshot $Snapshot -Name 'Esim'
    $slot = if ($esim) { $esim.Slot } else { $null }
    $inUse = [bool]($esim -and ($esim.SimType -eq 'Esim' -or ($null -eq $esim.SimType -and $slot -eq 1)))
    # Not an if expression: it would unroll an eUICC's empty list into none read.
    $profiles = $null
    if ($esim) {
        $profiles = $esim.Profiles
    }
    $simInUse = Get-SimInUseText -Snapshot $Snapshot

    $connected = [bool]($Snapshot -and $Snapshot.PortName)
    $operation = if ($esim) { $esim.Operation } else { $null }
    $lpac = [bool]($esim -and $esim.LpacAvailable)
    $sentences = [System.Collections.Generic.List[string]]::new()
    if ($operation -and (Test-AppText "Esim.Operation.$operation")) {
        $sentences.Add((Get-AppText "Esim.Operation.$operation"))
    }
    elseif (-not $connected) {
        if ($Snapshot) { $sentences.Add((Get-AppText 'Esim.NoModem')) }
    }
    elseif ($null -eq $slot) {
        $sentences.Add((Get-AppText 'Esim.NoSlot'))
    }
    elseif (-not $inUse) {
        $sentences.Add((Get-AppText 'Esim.NotInUse'))
    }
    elseif (-not $lpac) {
        $sentences.Add((Get-AppText 'Esim.NoLpac'))
    }
    elseif ($esim.Failure) {
        $sentences.Add((Get-AppText 'Esim.ReadFailed' $esim.Failure))
    }
    elseif ($null -eq $profiles) {
        $sentences.Add((Get-AppText 'Esim.NotRead'))
    }
    elseif (@($profiles).Count -eq 0) {
        $sentences.Add((Get-AppText 'Esim.NoProfiles'))
    }
    if ($Snapshot -and $Snapshot.ObserveOnly) {
        $sentences.Add((Get-AppText 'Esim.ObserveOnly'))
    }

    $rows = foreach ($item in @($profiles | Where-Object { $_ })) {
        $state = if ($item.State -in 'Enabled', 'Disabled') { $item.State } else { 'Unknown' }
        $class = if ($item.Class -in 'Operational', 'Test', 'Provisioning') { $item.Class } else { 'Unknown' }
        [pscustomobject]@{
            Aid      = [string]$item.Aid
            Name     = Get-EsimProfileName -Entry $item
            Provider = [string]$item.Provider
            Kind     = Get-AppText "Esim.Class.$class"
            State    = Get-AppText "Esim.State.$state"
            Enabled  = $state -eq 'Enabled'
            Nickname = [string]$item.Nickname
        }
    }
    $chip = if ($inUse -and $esim.Specification) {
        $free = if ($null -ne $esim.FreeMemory) { Format-DataSize $esim.FreeMemory } else { '?' }
        Get-AppText 'Esim.Chip' $esim.Specification $(if ($esim.Firmware) { $esim.Firmware } else { '?' }) $free
    }
    $waiting = if ($inUse -and $esim.Notifications -gt 0) { Get-AppText 'Esim.Notifications' $esim.Notifications } else { $null }
    $eid = if ($inUse -and $esim.PSObject.Properties['Eid'] -and $esim.Eid) { [string]$esim.Eid } else { $null }
    $qr = [bool]($esim -and $esim.PSObject.Properties['QrAvailable'] -and $esim.QrAvailable)
    $writable = $connected -and -not $Snapshot.ObserveOnly -and -not $operation
    # A button for each SIM, which exclude each other: the one in use says so (decided
    # 2026-10-04). The physical SIM in slot 1, the eUICC in slot 2, as on the FM350-GL
    # (AT-COMMANDS section 8).
    $physicalInUse = $null -ne $slot -and $slot -eq $script:PhysicalSlot
    $euiccInUse = $null -ne $slot -and $slot -eq $script:EuiccSlot
    [pscustomobject]@{
        SimInUse         = $simInUse
        StateText        = if ($sentences.Count) { $sentences -join ' ' } else { $null }
        Eid              = $eid
        ChipText         = $chip
        NotificationText = $waiting
        Profiles         = [object[]]@($rows)
        PhysicalText     = if ($physicalInUse) { Get-AppText 'Sim.PhysicalInUse' ($script:PhysicalSlot + 1) } else { Get-AppText 'Sim.UsePhysical' ($script:PhysicalSlot + 1) }
        EsimText         = if ($euiccInUse) { Get-AppText 'Esim.EsimInUse' ($script:EuiccSlot + 1) } else { Get-AppText 'Esim.UseEsim' ($script:EuiccSlot + 1) }
        CanUsePhysical   = [bool]($writable -and $null -ne $slot -and -not $physicalInUse)
        CanUseEsim       = [bool]($writable -and $null -ne $slot -and -not $euiccInUse)
        SlotNote         = Get-AppText 'Sim.OneAtATime' ($script:PhysicalSlot + 1) ($script:EuiccSlot + 1)
        CanRead          = [bool]($connected -and -not $operation -and $inUse -and $lpac)
        CanManage        = [bool]($writable -and $inUse -and $lpac -and $null -ne $profiles)
        CanDownload      = [bool]($writable -and $inUse -and $lpac)
        CanReadQr        = [bool]($writable -and $inUse -and $lpac -and $qr)
        QrNote           = if ($esim -and -not $qr) { Get-AppText 'Esim.QrMissing' } else { $null }
        ResultIds        = [string[]]@(Get-SnapshotValue -Snapshot $Snapshot -Name 'Results' | Where-Object { $_ -and $_.Kind -in $script:EsimCommands } | ForEach-Object Id)
        Generation       = Get-SnapshotValue -Snapshot $Snapshot -Name 'Generation'
    }
}

function Get-TrayNotice {
    <#
    .SYNOPSIS
        Decides the tray notification to show, if any: new messages, or a quota threshold.
    .DESCRIPTION
        A pure function. -Shown holds the Ids of the last notices shown (MessageId, UsageId;
        none yet at the start). A notice whose Id differs is shown once; a worker that replaces
        another carries its Ids on, so nothing is said twice. New messages name their newest
        sender only, the text stays in the window; the quota says the threshold, and that the
        connection stays on (decided 2026-10-04). One notice at a time, messages first.
        Returns Notice (Kind 'Messages' or 'Quota', Title, Text; or $null), MessageId and
        UsageId: what is shown now.
    .EXAMPLE
        $decision = Get-TrayNotice -Snapshot $snapshot -Shown $shown
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Snapshot,

        [hashtable] $Shown = @{}
    )

    $messageId = $Shown['MessageId']
    $usageId = $Shown['UsageId']
    $message = Get-SnapshotValue -Snapshot $Snapshot -Name 'MessageNotice'
    $quota = Get-SnapshotValue -Snapshot $Snapshot -Name 'UsageNotice'
    $notice = $null
    if ($message -and $message.Id -ne $messageId) {
        $title = if ($message.Count -gt 1) { Get-AppText 'Tray.NewMessages' $message.Count } else { Get-AppText 'Tray.NewMessage' }
        $notice = [pscustomobject]@{ Kind = 'Messages'; Title = $title; Text = Get-AppText 'Tray.MessageFrom' $message.Sender }
        $messageId = $message.Id
    }
    elseif ($quota -and $quota.Id -ne $usageId) {
        $notice = [pscustomobject]@{ Kind = 'Quota'; Title = Get-AppText 'Tray.QuotaTitle'; Text = Get-AppText 'Tray.Quota' $quota.Threshold }
        $usageId = $quota.Id
    }
    [pscustomobject]@{ Notice = $notice; MessageId = $messageId; UsageId = $usageId }
}

function ConvertTo-WindowView {
    <#
    .SYNOPSIS
        Everything the main window shows, from the snapshot, as text.
    .DESCRIPTION
        A pure function of the snapshot and of the worker's state ('Running', 'Restarting' or
        'NotResponding'). Returns Tone, Title, Detail, Note, SimInUse, Technology, Operator,
        Signal (lines), Cells and Carriers (rows of text), Blocker (Resolve-AppBlocker's), Sim (the
        SIM tab), Esim (the eSIM tab, Get-EsimView's), NetworkMode (the network tab,
        Get-NetworkModeView's), Usb (the USB tab, Get-UsbView's), Messages (the Messages
        tab, Get-MessagesView's), Usage (the Data tab, Get-UsageView's), Settings,
        ApnPasswordStored, SimToken, ApnSimText and ApnEditable (whose APN settings these are:
        the SIM in use's, changed only while one is identified), Dns and Startup (the
        connection tab: its encrypted DNS, the start at sign-in), Result (the newest command's
        outcome, as a sentence) and LastResult (its Id, Kind and Result), and Footer.
    .EXAMPLE
        ConvertTo-WindowView -Snapshot $snapshot -Worker Running
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Snapshot,

        [ValidateSet('Running', 'Restarting', 'NotResponding')]
        [string] $Worker = 'Running'
    )

    $tone = Resolve-AppTone -Snapshot $Snapshot -Worker $Worker
    $detail = switch ($Worker) {
        'Restarting' { Get-AppText 'Window.Restarting' }
        'NotResponding' { Get-AppText 'Window.NotResponding' }
        default { if ($Snapshot -and $Snapshot.State) { Get-ReasonText -Snapshot $Snapshot } else { Get-AppText 'Window.Starting' } }
    }
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($Snapshot) {
        if ($Snapshot.Simulated) { $notes.Add((Get-AppText 'Window.Simulated' $Snapshot.Scenario)) }
        if ($Snapshot.ObserveOnly) { $notes.Add((Get-AppText 'Window.ObserveOnly')) }
        if ($Snapshot.SettingsPending) { $notes.Add((Get-AppText 'Window.SettingsPending')) }
        $issues = @(Get-SnapshotSettingIssue -Snapshot $Snapshot)
        if ($issues.Count -gt 0) { $notes.Add((Get-AppText 'Window.SettingsFile' (@($issues | ForEach-Object { ConvertTo-SettingIssueText -Issue $_ }) -join ' '))) }
        if ($Snapshot.Modems -gt 1) { $notes.Add((Get-AppText 'Window.Modems' $Snapshot.Modems)) }
        # The step that brought the connection back, until health has held long enough.
        $recovery = Get-SnapshotRecovery -Snapshot $Snapshot
        if ($recovery -and $recovery.Status -eq 'Healthy' -and $recovery.Step -and $recovery.StepTime -and (Test-AppText "StepInline.$($recovery.Step)")) {
            $notes.Add((Get-AppText 'Window.Recovered' (Format-ClockTime -Time $recovery.StepTime) (Get-AppText "StepInline.$($recovery.Step)")))
        }
    }

    $radio = if ($Snapshot) { $Snapshot.Radio } else { $null }
    $signal = [System.Collections.Generic.List[string]]::new()
    $cells = @()
    $carriers = @()
    if ($radio) {
        $quality = $radio.Signal
        if ($quality) {
            $lte = @(foreach ($pair in @(@('RSRP', $quality.LteRsrp), @('RSRQ', $quality.LteRsrq))) { if ($pair[1]) { "$($pair[0]) $(Format-Measurement -Measurement $pair[1])" } })
            if ($lte) { $signal.Add("LTE: $($lte -join ', ')") }
            $nr = @(foreach ($pair in @(@('RSRP', $quality.NrRsrp), @('RSRQ', $quality.NrRsrq), @('SINR', $quality.NrSinr))) { if ($pair[1]) { "$($pair[0]) $(Format-Measurement -Measurement $pair[1])" } })
            if ($nr) { $signal.Add("NR: $($nr -join ', ')") }
        }
        $cells = @(foreach ($cell in @($radio.Cells)) {
                [pscustomobject]@{
                    Role      = Get-AppText $(if ($cell.Serving) { 'Cell.Serving' } else { 'Cell.Neighbour' })
                    Rat       = $cell.Technology
                    Band      = $cell.Band
                    Channel   = $cell.Arfcn
                    Pci       = $cell.Pci
                    Bandwidth = if ($cell.BandwidthMHz) { "$($cell.BandwidthMHz.ToString('0.#', [cultureinfo]::InvariantCulture)) MHz" } else { $null }
                    Rsrp      = Format-Measurement -Measurement $cell.Rsrp
                    Rsrq      = Format-Measurement -Measurement $cell.Rsrq
                    Sinr      = Format-Measurement -Measurement $cell.Sinr
                }
            })
        $carriers = @(foreach ($carrier in @($radio.Carriers)) {
                # Uplink values only for a carrier that carries uplink: a secondary one without
                # uplink CA reports placeholders there.
                $uplink = $carrier.Primary -or $carrier.UplinkCa
                $pick = { param($down, $up) @($down, $(if ($uplink) { $up }) | Where-Object { $null -ne $_ }) }
                $bandwidth = @(& $pick $carrier.DlBandwidthMHz $carrier.UlBandwidthMHz | ForEach-Object { $_.ToString('0.#', [cultureinfo]::InvariantCulture) }) -join '/'
                [pscustomobject]@{
                    Carrier    = $carrier.Carrier
                    State      = Get-AppText $(if ($carrier.Primary) { 'Carrier.Primary' } elseif ($carrier.Active) { 'Carrier.Active' } else { 'Carrier.Inactive' })
                    Band       = $carrier.Band
                    Channel    = $carrier.Arfcn
                    Pci        = $carrier.Pci
                    Bandwidth  = if ($bandwidth) { "$bandwidth MHz" } else { $null }
                    Mimo       = @(& $pick $carrier.DlMimoLayers $carrier.UlMimoLayers) -join '/'
                    Modulation = @(& $pick $carrier.DlModulation $carrier.UlModulation) -join '/'
                }
            })
    }

    $footer = [System.Collections.Generic.List[string]]::new()
    if ($Snapshot) {
        $footer.Add($(if ($Snapshot.PortName) { Get-AppText 'Footer.Port' $Snapshot.PortName } else { Get-AppText 'Footer.PortClosed' }))
        $footer.Add((Get-AppText 'Footer.Updated' $Snapshot.Time.ToString('HH:mm:ss', [cultureinfo]::InvariantCulture)))
        if ($Snapshot.PSObject.Properties['DataPath'] -and $Snapshot.DataPath -and $Snapshot.DataPath.Time) {
            $key = switch ($Snapshot.DataPath.Result) { 'Passed' { 'Footer.PathChecked' } 'Failed' { 'Footer.PathFailed' } default { 'Footer.PathPending' } }
            $footer.Add((Get-AppText $key $Snapshot.DataPath.Time.ToString('HH:mm:ss', [cultureinfo]::InvariantCulture)))
        }
        if (-not $Snapshot.Elevated) { $footer.Add((Get-AppText 'Footer.NotElevated')) }
        if ($Snapshot.PSObject.Properties['AppVersion'] -and $Snapshot.AppVersion) { $footer.Add((Get-AppText 'Footer.Version' $Snapshot.AppVersion)) }
    }

    $esim = Get-EsimView -Snapshot $Snapshot
    # Each SIM keeps its own APN settings (decided 2026-10-04): the form shows the SIM in use's.
    $simToken = if ($Worker -eq 'Running') { Get-SnapshotValue -Snapshot $Snapshot -Name 'SimToken' } else { $null }
    $apnSim = if (-not $Snapshot) {
        $null
    }
    elseif ($simToken) {
        @($esim.SimInUse, (Get-AppText 'Window.ApnPerSim') | Where-Object { $_ }) -join ' '
    }
    else {
        Get-AppText 'Window.ApnNoSim'
    }
    [pscustomobject]@{
        Tone              = $tone
        Title             = Get-AppTitle -Snapshot $Snapshot -Tone $tone
        Detail            = $detail
        Note              = if ($notes.Count) { $notes -join ' ' } else { $null }
        SimInUse          = if ($Worker -eq 'Running') { $esim.SimInUse } else { $null }
        Technology        = if ($radio -and $radio.NrAvailable) { Get-AppText 'Window.NrAvailable' $radio.Technology } elseif ($radio) { $radio.Technology } else { $null }
        Operator          = if ($radio) { Format-Operator -Operator $radio.Operator } else { $null }
        Bars              = if ($radio) { $radio.Bars } else { $null }
        Signal            = [string[]]$signal.ToArray()
        Cells             = [object[]]$cells
        Carriers          = [object[]]$carriers
        Blocker           = if ($Snapshot -and $Worker -eq 'Running') { Resolve-AppBlocker -Snapshot $Snapshot } else { $null }
        Sim               = if ($Snapshot) { Get-SimView -Snapshot $Snapshot } else { $null }
        Esim              = $esim
        NetworkMode       = Get-NetworkModeView -Snapshot $Snapshot
        Usb               = Get-UsbView -Snapshot $Snapshot
        Messages          = Get-MessagesView -Snapshot $Snapshot
        Usage             = Get-UsageView -Snapshot $Snapshot
        Settings          = if ($Snapshot) { $Snapshot.Settings } else { $null }
        ApnPasswordStored = $Snapshot -and $Snapshot.ApnPasswordStored
        SimToken          = $simToken
        ApnSimText        = $apnSim
        ApnEditable       = [bool]$simToken
        Dns               = Get-DnsView -Snapshot $Snapshot
        Startup           = Get-StartupView -Snapshot $Snapshot -Worker $Worker
        Result            = if ($Snapshot) { Get-ResultText -Snapshot $Snapshot } else { $null }
        LastResult        = if ($Snapshot) { @($Snapshot.Results) | Select-Object -Last 1 -Property Id, Kind, Result } else { $null }
        Footer            = $footer -join ' - '
    }
}

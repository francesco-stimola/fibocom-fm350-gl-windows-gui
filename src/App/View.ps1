# What the tray and the window show, from the worker's latest snapshot: pure functions, so every
# text and every icon state is decided here and proven by tests. Design: docs/ARCHITECTURE.md ->
# Tray icon. Texts and icon states: the maintainer's decision (ROADMAP M3).

# Every text the tray and the window show is the app's, in its language (Texts.ps1, Get-AppText):
# Reason.<reason>, Action.<step>, Mode.<mode>, Result.<command>.<result>, Tone.<tone>,
# Check.<check>, Step.<step>... The codes come from the snapshot.

# The network modes the window and the tray menu offer, in their order (ROADMAP M5).
$script:NetworkModeNames = @('Automatic', 'LteOnly', 'NrOnly')

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
        reason in a few words. At most 127 characters: Windows cuts a longer tooltip, and .NET
        refuses it.
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
    if ($text.Length -gt 127) { $text.Substring(0, 126) + [char]0x2026 } else { $text }
}

function Resolve-AppBlocker {
    # What the user can do about what blocks the connection, if anything: Kind - 'Apn',
    # 'ApnPassword', 'Pin', 'EnableAdapter', 'Unlock', 'Driver' (the Driver tab), 'Settings' (the
    # Connection tab) or $null for a message alone - Message, ActionText, and Enabled ($false
    # when the app can't do it now).
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
        'NoDriver' { 'Driver', 'Blocker.InstallDriver' }
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
    $known = 'Ready', 'PinRequired', 'PukRequired', 'Absent', 'Busy', 'Failure', 'Other'
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
    # The newest command outcome, in a sentence with its time.
    param([object] $Snapshot)

    $last = @($Snapshot.Results) | Select-Object -Last 1
    if (-not $last) {
        return $null
    }
    $text = if (Test-AppText "Result.$($last.Kind).$($last.Result)") {
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

function Get-DriverView {
    <#
    .SYNOPSIS
        The window's Driver tab, from the snapshot.
    .DESCRIPTION
        A pure function of the snapshot, the worker's state and -Known (Get-KnownDriverPackage's
        packages). Returns StateText (the AT port and its driver), SourceText and PageUrl (that
        the app doesn't come with the driver, and where a third party publishes a copy of a
        version it knows), PackageText (the package the user chose and what its check found, or
        the driver command under way), Note (why the buttons are off), CanChoose, CanInstall,
        ConfirmInstall (the package is no version the app knows: the user must accept it first)
        and CanUninstall.
    .EXAMPLE
        Get-DriverView -Snapshot $snapshot -Known (Get-KnownDriverPackage)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Snapshot,

        [ValidateSet('Running', 'Restarting', 'NotResponding')]
        [string] $Worker = 'Running',

        [AllowEmptyCollection()]
        [object[]] $Known = @()
    )

    $driver = if ($Snapshot -and $Snapshot.PSObject.Properties['Driver']) { $Snapshot.Driver } else { $null }
    $device = if ($driver) { $driver.Device } else { $null }
    $stateText = switch ($device) {
        'Present' {
            $what = @($driver.Provider, $driver.Version, $(if ($driver.Inf) { "($($driver.Inf))" }) | Where-Object { $_ }) -join ' '
            if ($what) { Get-AppText 'Driver.PresentWhat' $what } else { Get-AppText 'Driver.Present' }
        }
        'NoDriver' { Get-AppText 'Driver.NoDriver' }
        'Problem' { Get-AppText 'Driver.Problem' }
        'Absent' { Get-AppText 'Driver.Absent' }
        default { Get-AppText 'Driver.NotLooked' }
    }

    $copy = @($Known | Where-Object { $_.Copy }) | Select-Object -First 1
    $sourceText = if ($copy) {
        Get-AppText 'Driver.SourceCopy' "$($copy.Name) $($copy.Version)" $copy.Copy.Publisher $copy.Copy.File
    }
    else {
        Get-AppText 'Driver.Source'
    }

    $package = if ($driver) { $driver.Package } else { $null }
    $verdict = if ($package) { $package.Verdict } else { $null }
    $operation = if ($driver) { $driver.Operation } else { $null }
    $packageText = switch ($operation) {
        'CheckDriverPackage' { Get-AppText 'Driver.Checking' }
        'InstallDriver' { Get-AppText 'Driver.Installing' }
        'UninstallDriver' { Get-AppText 'Driver.Uninstalling' }
        default {
            if ($verdict) {
                $what = if ($verdict.Known) { "$($verdict.Known.Name) $($verdict.Known.Version)" } else { @($verdict.Provider, $verdict.Version | Where-Object { $_ }) -join ' ' }
                switch ($verdict.Verdict) {
                    'Verified' { Get-AppText 'Driver.Verified' $package.Name $what }
                    'Signed' { Get-AppText 'Driver.Signed' $package.Name $what }
                    default {
                        $why = @($verdict.Problems | ForEach-Object { if (Test-AppText "DriverProblem.$_") { Get-AppText "DriverProblem.$_" } else { $_ } })
                        Get-AppText 'Driver.Refused' $package.Name ($why -join '; ')
                    }
                }
            }
            else {
                $null
            }
        }
    }

    $note = $null
    $usable = [bool]($Snapshot -and $Worker -eq 'Running' -and -not $operation)
    if ($Snapshot -and $Snapshot.ObserveOnly) {
        $usable = $false
        $note = Get-AppText 'Driver.ObserveOnly'
    }
    elseif ($Snapshot -and -not $Snapshot.Elevated) {
        $usable = $false
        $note = Get-AppText 'Driver.NeedsAdmin'
    }
    $installable = $verdict -and $verdict.Verdict -in 'Verified', 'Signed'
    # A mode on trial is written back through the AT port: the driver stays until it ends.
    $mode = Get-SnapshotNetworkMode -Snapshot $Snapshot
    $trial = [bool]($mode -and $mode.Trial)
    if ($usable -and $trial -and $device -eq 'Present') {
        $note = Get-AppText 'Driver.Trial'
    }
    [pscustomobject]@{
        StateText      = $stateText
        SourceText     = $sourceText
        PageUrl        = if ($copy) { $copy.Copy.Page } else { $null }
        PackageText    = $packageText
        Note           = $note
        CanChoose      = $usable
        CanInstall     = [bool]($usable -and $installable -and $device -ne 'Present')
        ConfirmInstall = [bool]($verdict -and $verdict.Verdict -eq 'Signed')
        CanUninstall   = [bool]($usable -and -not $trial -and $device -eq 'Present' -and $driver.Inf -match '^oem\d+\.inf$')
    }
}

function ConvertTo-WindowView {
    <#
    .SYNOPSIS
        Everything the main window shows, from the snapshot, as text.
    .DESCRIPTION
        A pure function of the snapshot and of the worker's state ('Running', 'Restarting' or
        'NotResponding'). Returns Tone, Title, Detail, Note, Technology, Operator, Signal (lines),
        Cells and Carriers (rows of text), Blocker (Resolve-AppBlocker's), Sim (the SIM tab),
        NetworkMode (the network tab, Get-NetworkModeView's), Driver (the Driver tab,
        Get-DriverView's), Settings, ApnPasswordStored, Dns and Startup (the connection tab: its
        encrypted DNS, the start at sign-in), Result (the newest command's
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
        if ($Snapshot.Modems -gt 1) { $notes.Add((Get-AppText 'Window.Modems' $Snapshot.Modems $Snapshot.PortName)) }
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

    [pscustomobject]@{
        Tone              = $tone
        Title             = Get-AppTitle -Snapshot $Snapshot -Tone $tone
        Detail            = $detail
        Note              = if ($notes.Count) { $notes -join ' ' } else { $null }
        Technology        = if ($radio -and $radio.NrAvailable) { Get-AppText 'Window.NrAvailable' $radio.Technology } elseif ($radio) { $radio.Technology } else { $null }
        Operator          = if ($radio) { Format-Operator -Operator $radio.Operator } else { $null }
        Bars              = if ($radio) { $radio.Bars } else { $null }
        Signal            = [string[]]$signal.ToArray()
        Cells             = [object[]]$cells
        Carriers          = [object[]]$carriers
        Blocker           = if ($Snapshot -and $Worker -eq 'Running') { Resolve-AppBlocker -Snapshot $Snapshot } else { $null }
        Sim               = if ($Snapshot) { Get-SimView -Snapshot $Snapshot } else { $null }
        NetworkMode       = Get-NetworkModeView -Snapshot $Snapshot
        Driver            = Get-DriverView -Snapshot $Snapshot -Worker $Worker -Known @(Get-KnownDriverPackage)
        Settings          = if ($Snapshot) { $Snapshot.Settings } else { $null }
        ApnPasswordStored = $Snapshot -and $Snapshot.ApnPasswordStored
        Dns               = Get-DnsView -Snapshot $Snapshot
        Startup           = Get-StartupView -Snapshot $Snapshot -Worker $Worker
        Result            = if ($Snapshot) { Get-ResultText -Snapshot $Snapshot } else { $null }
        LastResult        = if ($Snapshot) { @($Snapshot.Results) | Select-Object -Last 1 -Property Id, Kind, Result } else { $null }
        Footer            = $footer -join ' - '
    }
}

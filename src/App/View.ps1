# What the tray and the window show, from the worker's latest snapshot: pure functions, so every
# text and every icon state is decided here and proven by tests. Design: docs/ARCHITECTURE.md ->
# Tray icon. Texts and icon states: the maintainer's decision (ROADMAP M3).

# Why the connection is where it is, in the user's words: one sentence per reason.
$script:ReasonTexts = @{
    NoDevice              = 'No modem found on USB.'
    NoDriver              = 'The modem''s AT port has no driver: install the MediaTek USB serial driver.'
    DeviceProblem         = 'Windows reports a problem with the modem''s AT port.'
    PortInUse             = 'Another program is using the modem''s AT port.'
    PortFailed            = 'The modem''s AT port can''t be opened.'
    SimUnknown            = 'Reading the SIM.'
    NoPin                 = 'The SIM is waiting for its PIN.'
    PinForOtherSim        = 'The stored PIN belongs to another SIM: enter this SIM''s PIN.'
    SimNotIdentified      = 'The SIM can''t be identified, so the stored PIN is not sent to it.'
    PinUnconfirmed        = 'The last PIN entry got no answer, and the app never tries twice: enter the PIN again.'
    LastAttempt           = 'Only one PIN attempt is left, and the app won''t use it: unlock the SIM in a phone.'
    PukRequired           = 'The SIM is blocked and needs its PUK: unblock it in a phone. The app never enters a PUK.'
    NoSim                 = 'No SIM in the modem.'
    SimFailure            = 'The SIM is not working.'
    SimOther              = 'The SIM is waiting for a code the app doesn''t handle.'
    SimBusy               = 'The SIM is busy; waiting for it.'
    FccLocked             = 'The modem is locked by its laptop''s maker (FCC lock): its radio stays off.'
    NotRegistered         = 'Not registered on a network.'
    NotSearching          = 'Not registered, and not searching for a network.'
    Searching             = 'Searching for a network.'
    Denied                = 'The network refused the registration.'
    Unknown               = 'Not registered; the reason is not known.'
    EmergencyOnly         = 'Emergency calls only.'
    ContextUnknown        = 'Reading the data connection.'
    ApnPasswordUnreadable = 'The stored APN password can''t be read: enter it again.'
    ApnNeeded             = 'The network gave no internet access to an empty APN: enter your operator''s APN.'
    NoAddress             = 'The data connection has no IPv4 address.'
    AdapterDisabled       = 'The modem''s network adapter is disabled.'
    NoAdapter             = 'The modem''s network adapter is missing.'
    NotElevated           = 'The network adapter can only be configured with administrator rights: start the app as administrator.'
    DataPathFailed        = 'The connection is up, but no traffic gets through.'
}

# What the next step does, while the connection is on its way.
$script:ActionTexts = @{
    OpenPort          = 'Opening the modem''s AT port.'
    Initialize        = 'Waiting for the modem to answer.'
    EnterPin          = 'Entering the stored PIN.'
    RadioOn           = 'Turning the radio on.'
    AutoRegister      = 'Selecting the network automatically.'
    DefineContext     = 'Setting up the data connection.'
    ActivateContext   = 'Setting up the data connection.'
    DeactivateContext = 'Setting up the data connection.'
    ConfigureAdapter  = 'Configuring the network adapter.'
    ApplyNetworkMode  = 'Setting the network mode.'
}

# The network modes, as the window and the tray menu name them (ROADMAP M5).
$script:NetworkModeTexts = [ordered]@{
    Automatic = '4G + 5G'
    LteOnly   = '4G only'
    NrOnly    = '5G only (SA)'
}
$script:NotManagedText = 'As the modem has it'

# Why the modem's network mode is not as the settings ask, when nothing is written.
$script:NetworkModeProblemTexts = @{
    NotKept         = 'The modem doesn''t keep the network mode as written; the app doesn''t write it again.'
    NoSupportedBand = 'The modem supports none of the bands chosen for one of its RATs.'
    ModeUnsupported = 'The modem doesn''t support this network mode.'
}

# The outcome of the user's commands: Kind/Result, or Result alone for any kind.
$script:ResultTexts = @{
    'ConnectNow/Done'          = 'Checking the connection now.'
    'SaveSettings/Done'        = 'Settings saved.'
    'SaveSimPin/Done'          = 'PIN stored: the app enters it once when the SIM asks for it.'
    'SaveSimPin/SimNotIdentified' = 'The SIM can''t be identified: the PIN was not stored.'
    'ForgetSimPin/Done'        = 'The stored PIN is deleted.'
    'DisableSimPin/Disabled'   = 'The SIM no longer asks for its PIN.'
    'DisableSimPin/AlreadyOff' = 'The SIM''s PIN request was already off.'
    'DisableSimPin/PinRejected' = 'Wrong PIN: the SIM still asks for it.'
    'DisableSimPin/LastAttempt' = 'Only one PIN attempt is left: nothing was sent.'
    'DisableSimPin/SimNotReady' = 'The SIM is not ready: nothing was sent.'
    'DisableSimPin/Failed'     = 'The SIM''s PIN request could not be changed.'
    'UnlockFcc/Restarted'      = 'Unlock sent: the modem is restarting.'
    'UnlockFcc/NotLocked'      = 'The modem is not locked: nothing was written.'
    'UnlockFcc/Unknown'        = 'The lock can''t be read: nothing was written.'
    'UnlockFcc/Failed'         = 'The unlock stopped before the restart.'
    'UnlockFcc/PortLost'       = 'The modem left USB during the unlock.'
    'EnableAdapter/Done'       = 'Network adapter enabled.'
    'SetNetworkMode/Applied'   = 'Network mode sent: the modem is registering again. It is kept once the modem finds a network with it.'
    'SetNetworkMode/Unchanged' = 'The modem already has this network mode: it is kept.'
    'SetNetworkMode/Done'      = 'The app no longer manages the network mode: the modem keeps the one it has.'
    'SetNetworkMode/ModeUnsupported' = 'The modem doesn''t support this network mode: nothing was written.'
    'SetNetworkMode/NoSupportedBand' = 'The modem supports none of the bands chosen for one of its RATs: nothing was written.'
    'SetNetworkMode/Unknown'   = 'The modem''s network mode can''t be read: nothing was written.'
    'Refused'                  = 'Not available while the app only observes.'
    'NoModem'                  = 'The modem is not connected.'
    'PortLost'                 = 'The modem left USB during the command.'
    'Failed'                   = 'It didn''t work.'
}

# The headline for each tone.
$script:ToneTitles = @{
    Online     = 'Online'
    Working    = 'Connecting'
    Recovering = 'Recovering'
    Attention  = 'Action needed'
    Offline    = 'No modem'
    Stopped    = 'Not monitoring'
}

# Recovery (ARCHITECTURE -> Health checks and the recovery ladder): what fails, in the user's
# words, and what each step does.
$script:CheckTexts = @{
    H1 = 'The modem is not on USB.'
    H2 = 'The modem doesn''t answer.'
    H3 = 'The SIM is not ready.'
    H4 = 'Not registered on a network.'
    H5 = 'The data connection is down.'
    H6 = 'The network adapter is not configured.'
    H7 = 'No traffic gets through.'
}
$script:StepTexts = @{
    R1 = 'Configuring the network adapter again.'
    R2 = 'Restarting the data connection.'
    R3 = 'Registering on the network again.'
    R4 = 'Turning the radio off and on.'
    R5 = 'Restarting the modem.'
    R6 = 'Restarting the modem''s USB device.'
}

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

    if ($Name -and $script:NetworkModeTexts.Contains($Name)) { $script:NetworkModeTexts[$Name] } else { "mode $Rat" }
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
    $check = if ($recovery.Check -and $script:CheckTexts.ContainsKey($recovery.Check)) { $script:CheckTexts[$recovery.Check] } else { 'The connection is down.' }
    $step = if ($recovery.Step -and $script:StepTexts.ContainsKey($recovery.Step)) { $script:StepTexts[$recovery.Step] } else { $null }
    switch ($recovery.Status) {
        { $_ -in 'Recovering', 'Settling' } { if ($step) { $step } }
        'Waiting' { "$check The recovery steps didn't help: they start again at $(Format-ClockTime -Time $recovery.NextTime)." }
        'SlowCadence' { "$check Recovery failed $($recovery.Cycles) times: the app tries again at $(Format-ClockTime -Time $recovery.NextTime)." }
        'Withheld' { if ($step) { "$check The app only observes, so it doesn't take the recovery step: $($step.Substring(0, 1).ToLowerInvariant())$($step.Substring(1))" } }
    }
}

function Get-ReasonText {
    # The sentence that says why the connection is where it is.
    param([object] $Snapshot)

    if ($Snapshot.State -eq 'Online') {
        return 'Connected.'
    }
    if (Test-NoNetworkForMode -Snapshot $Snapshot) {
        $mode = (Get-SnapshotNetworkMode -Snapshot $Snapshot).Current
        $bands = if ($Snapshot.Settings -and @($Snapshot.Settings.LteBands).Count -gt 0) { ' on the LTE bands chosen' } else { '' }
        return "No network found with $(Get-NetworkModeText -Name $mode.Mode -Rat $mode.Rat)$bands. No reset finds one: choose a wider network mode."
    }
    $recovering = Get-RecoveryText -Snapshot $Snapshot
    if ($recovering) {
        return $recovering
    }
    $reason = $Snapshot.Reason
    if ($reason -and $script:ReasonTexts.ContainsKey($reason)) {
        return $script:ReasonTexts[$reason]
    }
    if ($reason) {
        # A registration state the table doesn't name (roaming SMS only, ...).
        return "Not registered ($reason)."
    }
    $step = if ($Snapshot.Action -and $script:ActionTexts.ContainsKey($Snapshot.Action)) { $script:ActionTexts[$Snapshot.Action] } else { $null }
    if ($step -and $Snapshot.ObserveOnly) {
        return "The app only observes, so it doesn't take the next step: $($step.Substring(0, 1).ToLowerInvariant())$($step.Substring(1))"
    }
    if ($step) {
        return $step
    }
    'Working on the connection.'
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
        return 'Connection lost'
    }
    if ($Tone -eq 'Attention' -and (Test-NoNetworkForMode -Snapshot $Snapshot)) {
        return 'No network'
    }
    if ($Tone -eq 'Working' -and ((Test-StepWithheld -Snapshot $Snapshot) -or ($recovery -and $recovery.Status -eq 'Withheld'))) {
        return 'Not connected'
    }
    $script:ToneTitles[$Tone]
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
    $parts.Add("FM350-GL: $(Get-AppTitle -Snapshot $Snapshot -Tone $tone)")
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
    # 'ApnPassword', 'Pin', 'EnableAdapter', 'Unlock' or $null for a message alone - Message,
    # ActionText, and Enabled ($false when the app can't do it now).
    param([object] $Snapshot)

    if (Test-NoNetworkForMode -Snapshot $Snapshot) {
        return [pscustomobject]@{
            Kind       = 'NetworkMode'
            Message    = Get-ReasonText -Snapshot $Snapshot
            ActionText = "Use $($script:NetworkModeTexts['Automatic']), every band"
            Enabled    = -not $Snapshot.ObserveOnly
        }
    }
    if (-not $Snapshot.Blocked -or $Snapshot.Reason -eq 'NoDevice') {
        return $null
    }
    $kind, $action = switch ($Snapshot.Reason) {
        'ApnNeeded' { 'Apn', 'Save APN' }
        'ApnPasswordUnreadable' { 'ApnPassword', 'Save password' }
        { $_ -in 'NoPin', 'PinForOtherSim', 'PinUnconfirmed' } { 'Pin', 'Store PIN' }
        'AdapterDisabled' { 'EnableAdapter', 'Enable adapter' }
        'FccLocked' { 'Unlock', 'Unlock...' }
        default { $null, $null }
    }
    $enabled = $true
    $note = $null
    if ($Snapshot.ObserveOnly -and $kind -in 'EnableAdapter', 'Unlock') {
        $enabled = $false
        $note = ' The app only observes: it changes nothing.'
    }
    elseif ($kind -eq 'EnableAdapter' -and -not $Snapshot.Elevated) {
        $enabled = $false
        $note = ' Enabling it needs administrator rights.'
    }
    elseif ($kind -eq 'Unlock') {
        $note = ' Unlocking writes the modem''s non-volatile memory: the app asks before it does.'
    }
    $message = (Get-ReasonText -Snapshot $Snapshot) + $note
    if ($kind -eq 'Pin' -and $null -ne $Snapshot.Sim.AttemptsLeft) {
        $message += " Attempts left: $($Snapshot.Sim.AttemptsLeft)."
    }
    [pscustomobject]@{ Kind = $kind; Message = $message; ActionText = $action; Enabled = $enabled }
}

function Get-SimView {
    # The SIM tab: its state, the stored PIN, what can be done.
    param([object] $Snapshot)

    $sim = $Snapshot.Sim
    $states = @{
        Ready = 'Ready'; PinRequired = 'Waiting for its PIN'; PukRequired = 'Blocked: needs its PUK'; Absent = 'No SIM'
        Busy = 'Busy'; Failure = 'Not working'; Other = 'Waiting for another code'
    }
    $state = if ($sim.State -and $states.ContainsKey($sim.State)) { $states[$sim.State] } else { 'Not known' }
    if ($null -ne $sim.AttemptsLeft) {
        $state += " - PIN attempts left: $($sim.AttemptsLeft)"
    }
    $request = if ($sim.PinRequestOn -eq $true) { 'on' } elseif ($sim.PinRequestOn -eq $false) { 'off' } else { 'not known' }
    $connected = [bool]$Snapshot.PortName
    [pscustomobject]@{
        StateText     = "SIM: $state"
        RequestText   = "PIN request at power-on: $request"
        StoredText    = if ($sim.PinStored) { 'A PIN is stored for this SIM.' } else { 'No PIN is stored.' }
        Note          = if ($sim.PinRejected) { 'The stored PIN was rejected and deleted: the app never tries it again.' } else { $null }
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
    $key = "$($last.Kind)/$($last.Result)"
    $text = if ($script:ResultTexts.ContainsKey($key)) {
        $script:ResultTexts[$key]
    }
    elseif ($script:ResultTexts.ContainsKey($last.Result)) {
        $script:ResultTexts[$last.Result]
    }
    else {
        "$($last.Kind): $($last.Result)."
    }
    if ($last.Kind -eq 'DisableSimPin' -and $null -ne $last.AttemptsLeft) {
        $text += " Attempts left: $($last.AttemptsLeft)."
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
        return 'every band'
    }
    if ($known.Count -gt 0 -and $left.Count -le 3 -and $bands.Count -gt $left.Count) {
        return "every band but $(@($left | ForEach-Object { "$Prefix$_" }) -join ', ')"
    }
    if ($bands.Count -eq 0) {
        return 'none'
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
        $parts.Add("The modem now: $(Get-NetworkModeText -Name $current.Mode -Rat $current.Rat).")
        if (@($current.LteCodes).Count -gt 0 -or $current.AllBands) {
            $parts.Add("LTE: $(if ($current.AllBands) { 'every band' } else { Format-BandList -Band $current.Lte -Supported $lte -Prefix 'B' }).")
        }
        if (@($current.NrCodes).Count -gt 0 -or ($current.AllBands -and $current.Mode -ne 'LteOnly')) {
            $parts.Add("NR: $(if ($current.AllBands) { 'every band' } else { Format-BandList -Band $current.Nr -Supported $nr -Prefix 'n' }).")
        }
        $parts -join ' '
    }
    else {
        'The modem''s network mode is not read yet.'
    }

    $offered = if ($support) { @($support.Modes) } else { @($script:NetworkModeTexts.Keys) }
    $modes = @([pscustomobject]@{ Name = ''; Text = $script:NotManagedText }) + @(foreach ($name in $script:NetworkModeTexts.Keys) {
            if ($name -in $offered) { [pscustomobject]@{ Name = $name; Text = $script:NetworkModeTexts[$name] } }
        })

    $notes = [System.Collections.Generic.List[string]]::new()
    $trial = if ($mode) { $mode.Trial } else { $null }
    if ($trial) {
        $notes.Add("Trying $(Get-NetworkModeText -Name $trial.Selection.NetworkMode): if the modem finds no network with it by $(Format-ClockTime -Time $trial.Until), it goes back to what it had.")
    }
    $notice = if ($mode) { $mode.Notice } else { $null }
    if ($notice -and -not $trial) {
        $text = Get-NetworkModeText -Name $notice.Mode
        $notes.Add($(switch ($notice.Kind) {
                    'Reverted' { "At $(Format-ClockTime -Time $notice.Time) the modem had found no network with ${text}: it went back to what it had." }
                    default { "At $(Format-ClockTime -Time $notice.Time) the modem registered with ${text}: it is kept." }
                }))
    }
    if ($decision -and $decision.Problem -and $script:NetworkModeProblemTexts.ContainsKey($decision.Problem)) {
        $notes.Add($script:NetworkModeProblemTexts[$decision.Problem])
    }
    if ($decision -and $decision.Missing) {
        $left = @(@($decision.Missing.Lte | ForEach-Object { "B$_" }) + @($decision.Missing.Nr | ForEach-Object { "n$_" }))
        if ($left.Count -gt 0) {
            $notes.Add("The modem leaves out $($left -join ', '), though asked: it uses the other bands chosen.")
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
        Text  = if ($mode -and $mode.Current) { "Network mode: $(Get-NetworkModeText -Name $current -Rat $mode.Current.Rat)" } else { 'Network mode' }
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

function ConvertTo-WindowView {
    <#
    .SYNOPSIS
        Everything the main window shows, from the snapshot, as text.
    .DESCRIPTION
        A pure function of the snapshot and of the worker's state ('Running', 'Restarting' or
        'NotResponding'). Returns Tone, Title, Detail, Note, Technology, Operator, Signal (lines),
        Cells and Carriers (rows of text), Blocker (Resolve-AppBlocker's), Sim (the SIM tab),
        NetworkMode (the network tab, Get-NetworkModeView's), Settings and ApnPasswordStored
        (the connection tab), Result (the newest command's
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
        'Restarting' { 'The monitor stopped and is restarting. The connection is not touched.' }
        'NotResponding' { 'The monitor is not responding. The connection is not touched.' }
        default { if ($Snapshot -and $Snapshot.State) { Get-ReasonText -Snapshot $Snapshot } else { 'Starting.' } }
    }
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($Snapshot) {
        if ($Snapshot.Simulated) { $notes.Add("Development mode: a simulated modem (scenario $($Snapshot.Scenario)).") }
        if ($Snapshot.ObserveOnly) { $notes.Add('The app only observes: it changes nothing on the modem or the system.') }
        if ($Snapshot.SettingsPending) { $notes.Add('The data connection is up with other settings: the new ones apply at the next connection.') }
        if (@($Snapshot.SettingsProblems).Count -gt 0) { $notes.Add("Settings file: $(@($Snapshot.SettingsProblems) -join ' ')") }
        if ($Snapshot.Modems -gt 1) { $notes.Add("$($Snapshot.Modems) modems found: the app uses the one on $($Snapshot.PortName).") }
        # The step that brought the connection back, until health has held long enough.
        $recovery = Get-SnapshotRecovery -Snapshot $Snapshot
        if ($recovery -and $recovery.Status -eq 'Healthy' -and $recovery.Step -and $recovery.StepTime -and $script:StepTexts.ContainsKey($recovery.Step)) {
            $step = $script:StepTexts[$recovery.Step]
            $notes.Add("Recovered at $(Format-ClockTime -Time $recovery.StepTime): $($step.Substring(0, 1).ToLowerInvariant())$($step.Substring(1))")
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
                    Role      = if ($cell.Serving) { 'Serving' } else { 'Neighbour' }
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
                    State      = if ($carrier.Primary) { 'Primary' } elseif ($carrier.Active) { 'Active' } else { 'Inactive' }
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
        $footer.Add($(if ($Snapshot.PortName) { "AT port $($Snapshot.PortName)" } else { 'AT port closed' }))
        $footer.Add("updated $($Snapshot.Time.ToString('HH:mm:ss', [cultureinfo]::InvariantCulture))")
        if ($Snapshot.PSObject.Properties['DataPath'] -and $Snapshot.DataPath -and $Snapshot.DataPath.Time) {
            $word = switch ($Snapshot.DataPath.Result) { 'Passed' { 'checked' } 'Failed' { 'failed' } default { 'not checked yet' } }
            $footer.Add("data path $word at $($Snapshot.DataPath.Time.ToString('HH:mm:ss', [cultureinfo]::InvariantCulture))")
        }
        if (-not $Snapshot.Elevated) { $footer.Add('no administrator rights') }
    }

    [pscustomobject]@{
        Tone              = $tone
        Title             = Get-AppTitle -Snapshot $Snapshot -Tone $tone
        Detail            = $detail
        Note              = if ($notes.Count) { $notes -join ' ' } else { $null }
        Technology        = if ($radio -and $radio.NrAvailable) { "$($radio.Technology), 5G available" } elseif ($radio) { $radio.Technology } else { $null }
        Operator          = if ($radio) { Format-Operator -Operator $radio.Operator } else { $null }
        Bars              = if ($radio) { $radio.Bars } else { $null }
        Signal            = [string[]]$signal.ToArray()
        Cells             = [object[]]$cells
        Carriers          = [object[]]$carriers
        Blocker           = if ($Snapshot -and $Worker -eq 'Running') { Resolve-AppBlocker -Snapshot $Snapshot } else { $null }
        Sim               = if ($Snapshot) { Get-SimView -Snapshot $Snapshot } else { $null }
        NetworkMode       = Get-NetworkModeView -Snapshot $Snapshot
        Settings          = if ($Snapshot) { $Snapshot.Settings } else { $null }
        ApnPasswordStored = $Snapshot -and $Snapshot.ApnPasswordStored
        Result            = if ($Snapshot) { Get-ResultText -Snapshot $Snapshot } else { $null }
        LastResult        = if ($Snapshot) { @($Snapshot.Results) | Select-Object -Last 1 -Property Id, Kind, Result } else { $null }
        Footer            = $footer -join ' - '
    }
}

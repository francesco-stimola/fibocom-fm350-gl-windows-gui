# The worker: in a runspace of its own, it owns the modem's AT port, runs the connect passes, reads
# the radio for display, carries out the user's commands, and publishes an immutable snapshot of
# it all for the UI. Design: docs/ARCHITECTURE.md -> Process model.
#
# The UI and a worker share one link (New-ModemWorkerLink): a synchronized hashtable holding the
# command queue, the latest snapshot, the heartbeat and the stop request. The UI only enqueues and
# reads; it never waits on the worker.

# How often the worker does what, in ms. Thresholds: the maintainer's decision (ROADMAP M3).
$script:WorkerIntervals = @{
    # A connect pass on a connection that is online: it reads, and changes nothing.
    PassOnline  = 30000
    # A pass while the connection is on its way: the next step, or a wait (searching, SIM busy).
    PassWorking = 10000
    # A pass while the user must act: nothing changes until they do, and their command runs a
    # pass at once.
    PassBlocked = 30000
    # Signal, operator, cells and carriers, for display.
    Status      = 5000
    # Looking for the modem by PnP, while there is none or its port can't be opened.
    Scan        = 5000
}

# The longest the worker goes without a sign of life, a wait for the modem's answer included
# (WorkerTransport): the supervisor's hang timeout is far above it.
$script:WorkerBeatMs = 1000

# A wait that ends this much past its deadline was a pause: the computer slept (as the UI's).
$script:WorkerPauseMs = 5000

# The results of the user's commands a snapshot keeps, the newest last.
$script:WorkerResultsKept = 10

# A cycle that fails is stopped where it failed and tried again this much later; after this many
# failures in a row the worker ends, and the supervisor starts a new one after its own wait.
$script:WorkerRetryMs = 1000
$script:WorkerFailedCyclesAllowed = 3

# Unsolicited codes that say the registration or a context changed: a pass is due at once. The
# modem doesn't send every report (AT-COMMANDS section 2), so the passes never depend on them.
$script:WorkerPassUrcPattern = '^\s*\+(CREG|CGREG|CEREG|C5GREG|CGEV)\s*:'

# The commands the UI can send (Send-ModemCommand).
$script:WorkerCommandKinds = @('ConnectNow', 'SaveSettings', 'SaveSimPin', 'ForgetSimPin', 'DisableSimPin', 'UnlockFcc', 'EnableAdapter')

# A transport around the real one (the shape is in Transport.ps1) that keeps the worker's heartbeat
# fresh while a command waits for its answer: a read waits at most SliceMs at a time, and the
# channel reads again until the command's own timeout. A command that legitimately takes minutes
# (AT+COPS) never looks like a hung worker.
[NoRunspaceAffinity()]
class WorkerTransport {
    [string] $PortName
    [bool] $Lost = $false
    [string] $LostReason
    hidden [object] $Inner
    hidden [hashtable] $Link
    hidden [int] $SliceMs

    WorkerTransport([object] $inner, [hashtable] $link, [int] $sliceMs) {
        $this.Inner = $inner
        $this.Link = $link
        $this.SliceMs = $sliceMs
        $this.PortName = $inner.PortName
    }

    [void] Write([string] $text) {
        $this.Link['Heartbeat'] = [Environment]::TickCount64
        $this.Inner.Write($text)
        $this.Follow()
    }

    [string] Read([int] $timeoutMs) {
        $this.Link['Heartbeat'] = [Environment]::TickCount64
        $text = $this.Inner.Read([Math]::Min($timeoutMs, $this.SliceMs))
        $this.Follow()
        return $text
    }

    [void] Close() {
        $this.Inner.Close()
    }

    hidden [void] Follow() {
        if ($this.Inner.Lost -and -not $this.Lost) {
            $this.Lost = $true
            if ($this.Inner.PSObject.Properties['LostReason']) {
                $this.LostReason = $this.Inner.LostReason
            }
        }
    }
}

function New-ModemWorkerLink {
    <#
    .SYNOPSIS
        Creates what the UI and one worker share.
    .DESCRIPTION
        A synchronized hashtable, the only object both threads touch:
        - Commands: a ConcurrentQueue of commands for the worker (Send-ModemCommand).
        - Wake: an AutoResetEvent that ends the worker's wait at once.
        - Snapshot: the latest snapshot (New-ModemSnapshot), replaced whole and never changed
          once published; -Snapshot until the worker publishes its first.
        - Heartbeat: when the worker last showed a sign of life ([Environment]::TickCount64).
        - Stop: $true asks the worker to finish.
        Each worker gets a link of its own, so a worker that hung and comes back to life later
        writes only to its own. The owner disposes it once the worker has ended
        (Close-ModemWorkerLink).
    .EXAMPLE
        $link = New-ModemWorkerLink -Snapshot $previous.Link['Snapshot']
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object; changes no system state.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # The snapshot shown until the worker publishes one: the last of the worker it replaces.
        [object] $Snapshot
    )

    [hashtable]::Synchronized(@{
            Commands  = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
            Wake      = [System.Threading.AutoResetEvent]::new($false)
            Snapshot  = $Snapshot
            Heartbeat = [Environment]::TickCount64
            Stop      = $false
        })
}

function Close-ModemWorkerLink {
    <#
    .SYNOPSIS
        Releases a link once its worker has ended.
    .EXAMPLE
        Close-ModemWorkerLink -Link $link
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Link
    )

    $Link['Stop'] = $true
    $Link['Wake'].Dispose()
}

function Send-ModemCommand {
    <#
    .SYNOPSIS
        Queues a command for the worker and wakes it.
    .DESCRIPTION
        Never waits: safe on the UI thread. Returns the command's Id; the snapshot's Results say
        how it went. Kinds, with what -Parameter carries:
        - ConnectNow: a connect pass now.
        - SaveSettings: Settings (validated by the worker, which refuses an invalid value);
          ApnPassword, a SecureString - an empty one removes the stored password - or left out
          to keep it.
        - SaveSimPin: Pin, a SecureString; stored for the SIM in the modem.
        - ForgetSimPin: deletes the stored PIN.
        - DisableSimPin: Pin; turns the SIM's PIN request off (Disable-SimPin). Only after the
          user confirmed it.
        - UnlockFcc: lifts the FCC lock (Invoke-FccUnlock). Only after the user confirmed it.
        - EnableAdapter: enables the modem's network adapter (Enable-ModemAdapter).
        Secrets travel as SecureStrings, stay in the process, and never come back in a snapshot.
    .EXAMPLE
        Send-ModemCommand -Link $link -Kind SaveSimPin -Parameter @{ Pin = $passwordBox.SecurePassword }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Link,

        [Parameter(Mandatory)]
        [ValidateSet('ConnectNow', 'SaveSettings', 'SaveSimPin', 'ForgetSimPin', 'DisableSimPin', 'UnlockFcc', 'EnableAdapter')]
        [string] $Kind,

        [hashtable] $Parameter = @{}
    )

    $id = [guid]::NewGuid().ToString()
    $Link['Commands'].Enqueue([pscustomobject]@{ Id = $id; Kind = $Kind; Parameter = $Parameter })
    [void]$Link['Wake'].Set()
    $id
}

function Get-WorkerDueTime {
    # Milliseconds until a thing that last ran at -Last is due again: 0 when it never ran.
    param([long] $Now, [Nullable[long]] $Last, [long] $Interval)

    if ($null -eq $Last) { 0 } else { [Math]::Max(0, $Last + $Interval - $Now) }
}

function Resolve-WorkerSchedule {
    <#
    .SYNOPSIS
        Decides what the worker does now, and how long it may wait before the next thing.
    .DESCRIPTION
        A pure decision from the worker's clock (-Now, and when it last looked for the modem,
        ran a pass and read the status - $null for never, in the same milliseconds) and the
        connection: its State, whether it is Blocked, whether the AT port is open, and whether a
        pass was asked for (a command, a new port, a code from the modem).
        - Scan: no port open, and the last look for the modem is older than the scan interval.
        - Pass: a port open, and a pass asked for, or the last one older than the interval for
          the state: online, on its way, or waiting for the user.
        - Status: a port open, the SIM ready, and the last status read older than its interval.
        - AdapterLook: a port open, the last pass found no network adapter (-AdapterMissing),
          and the last look for it by PnP older than the scan interval.
        - Probe: a port open, the adapter carrying the context's address (-ProbeWanted), the
          last data-path round older than the probe interval - the retry interval after a round
          that failed or could not be sent (-ProbeFailed) - and -ProbeNotBefore reached: the
          settle time after the address was set.
        - WaitMs: until the next of those falls due, or -RecoveryAt (when the recovery decision
          may change); 0 when one is due now.
    .EXAMPLE
        Resolve-WorkerSchedule -Now 60000 -LastPass 25000 -State Online -PortOpen
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [long] $Now,

        [Nullable[long]] $LastScan,

        [Nullable[long]] $LastPass,

        [Nullable[long]] $LastStatus,

        [Nullable[long]] $LastAdapterLook,

        [string] $State,

        [switch] $Blocked,

        [switch] $PortOpen,

        [switch] $PassForced,

        [switch] $AdapterMissing,

        [switch] $ProbeWanted,

        [Nullable[long]] $LastProbe,

        [switch] $ProbeFailed,

        [Nullable[long]] $ProbeNotBefore,

        [Nullable[long]] $RecoveryAt
    )

    $intervals = $script:WorkerIntervals
    $passInterval = if ($State -eq 'Online') { $intervals.PassOnline } elseif ($Blocked) { $intervals.PassBlocked } else { $intervals.PassWorking }
    $simReady = $State -and $script:ConnectionStates.IndexOf($State) -ge $script:ConnectionStates.IndexOf('SimReady')

    $waits = [System.Collections.Generic.List[long]]::new()
    $scan = $false
    $pass = $false
    $status = $false
    $adapterLook = $false
    $probe = $false
    if (-not $PortOpen) {
        $wait = Get-WorkerDueTime -Now $Now -Last $LastScan -Interval $intervals.Scan
        $scan = $wait -eq 0
        $waits.Add($wait)
    }
    else {
        $wait = if ($PassForced) { 0 } else { Get-WorkerDueTime -Now $Now -Last $LastPass -Interval $passInterval }
        $pass = $wait -eq 0
        $waits.Add($wait)
        if ($simReady) {
            $wait = Get-WorkerDueTime -Now $Now -Last $LastStatus -Interval $intervals.Status
            $status = $wait -eq 0
            $waits.Add($wait)
        }
        if ($AdapterMissing) {
            $wait = Get-WorkerDueTime -Now $Now -Last $LastAdapterLook -Interval $intervals.Scan
            $adapterLook = $wait -eq 0
            $waits.Add($wait)
        }
        if ($ProbeWanted) {
            $wait = Get-WorkerDueTime -Now $Now -Last $LastProbe -Interval $(if ($ProbeFailed) { $script:DataProbe.RetryMs } else { $script:DataProbe.IntervalMs })
            if ($null -ne $ProbeNotBefore) {
                $wait = [Math]::Max($wait, $ProbeNotBefore - $Now)
            }
            $probe = $wait -eq 0
            $waits.Add($wait)
        }
    }
    if ($null -ne $RecoveryAt) {
        $waits.Add([Math]::Max(0, $RecoveryAt - $Now))
    }
    [pscustomobject]@{
        Scan        = $scan
        Pass        = $pass
        Status      = $status
        AdapterLook = $adapterLook
        Probe       = $probe
        WaitMs      = [int]($waits | Measure-Object -Minimum).Minimum
    }
}

function New-ModemSnapshot {
    <#
    .SYNOPSIS
        Builds the snapshot the worker publishes for the UI, from the worker's state.
    .DESCRIPTION
        A pure function: a new object every time, which nobody changes afterwards - the UI reads
        whichever snapshot is the latest without a lock. It carries no secret (the stored PIN and
        APN password only as "stored or not") and no identifier (no ICCID, no cell location).

        Version (grows with every snapshot, across worker restarts), Time, Generation (the
        worker's), WorkerStarted, Simulated and Scenario (development mode), ObserveOnly,
        Elevated, PortName (of the open AT port), Modems; the connection: State, StateSince,
        Action, Reason, Blocked, Dropped, SettingsPending; Sim (State, Reason - the PIN rules' -,
        AttemptsLeft, PinStored, PinRequestOn, PinRejected); Fcc (Diagnosis, PowerUpUnlock);
        Radio (Resolve-RadioStatus); DataPath (the probes: Healthy - $true, $false or $null -,
        the last round's Result and Time, Proven: a reply since the app started); Recovery (Resolve-RecoveryAction's Status, Check,
        Step, Cycles, with StepTime and NextTime as clock times, and History, which a worker
        that replaces this one carries on); Settings, ApnPasswordStored, SettingsProblems;
        Results (the last commands' outcomes: Id, Kind, Result, Detail, AttemptsLeft, Time).
    .EXAMPLE
        $Link['Snapshot'] = New-ModemSnapshot -Worker $worker -Time ([DateTimeOffset]::Now)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object; changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Worker,

        [Parameter(Mandatory)]
        [DateTimeOffset] $Time
    )

    $facts = $Worker.Facts
    $fact = { param($name) if ($facts -and $facts.PSObject.Properties[$name]) { $facts.$name } }
    $decision = $Worker.Decision
    $field = { param($name) if ($decision) { $decision.$name } }
    $pin = & $fact 'Sim'
    $presence = $Worker.Presence

    [pscustomobject]@{
        Version           = $Worker.Version
        Time              = $Time
        Generation        = $Worker.Generation
        WorkerStarted     = $Worker.Started
        Simulated         = [bool]$Worker.Simulation
        Scenario          = if ($Worker.Simulation) { $Worker.Simulation.Scenario } else { $null }
        ObserveOnly       = $Worker.ObserveOnly
        Elevated          = $Worker.Elevated
        PortName          = if ($Worker.Channel) { $Worker.PortName } else { $null }
        Modems            = if ($presence) { $presence.Modems } else { $null }
        State             = $Worker.State
        StateSince        = $Worker.StateSince
        Action            = & $field 'Action'
        Reason            = & $field 'Reason'
        Blocked           = [bool](& $field 'Blocked')
        Dropped           = [bool](& $field 'Dropped')
        SettingsPending   = [bool](& $field 'SettingsPending')
        Sim               = [pscustomobject]@{
            State        = & $fact 'SimState'
            Reason       = if ($pin) { $pin.Reason } else { $null }
            AttemptsLeft = & $fact 'PinAttemptsLeft'
            PinStored    = $Worker.PinStored
            PinRequestOn = $Worker.PinRequestOn
            PinRejected  = $Worker.PinRejected
        }
        Fcc               = & $fact 'Fcc'
        Radio             = $Worker.Radio
        DataPath          = [pscustomobject]@{
            Healthy = & $fact 'DataPath'
            Result  = $Worker.Probe.LastResult
            Time    = $Worker.Probe.LastTime
            Proven  = $Worker.Probe.Proven
        }
        Recovery          = $Worker.RecoveryView
        Settings          = if ($Worker.Settings) { $Worker.Settings | Select-Object -Property * } else { $null }
        ApnPasswordStored = $Worker.ApnPasswordStored
        SettingsProblems  = [string[]]@($Worker.SettingsProblems)
        Results           = [object[]]$Worker.Results.ToArray()
    }
}

function New-ModemWorker {
    <#
    .SYNOPSIS
        Prepares a worker: what it keeps between its cycles.
    .DESCRIPTION
        Invoke-ModemWorker runs one; tests drive the cycles one by one with
        Invoke-ModemWorkerCycle. A worker that replaces another one (-Previous, the last snapshot
        of the one before) starts from its state: its first pass attaches, it never re-dials, and
        its recovery carries on where the other's was - a restart never starts the ladder over.

        -DataFolder keeps the settings, the secrets and the log in one folder (development mode,
        tests); by default they are the app's (ARCHITECTURE -> Settings and logs). -Simulation is
        New-SimulatedDevice's device, driven instead of a real modem. -ObserveOnly reads and
        never writes: no step, no command that changes the modem or the system. -Clock returns
        the time in milliseconds; [Environment]::TickCount64 by default.
    .EXAMPLE
        $worker = New-ModemWorker -Link $link -Simulation (New-SimulatedDevice)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object; changes no system state.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Link,

        [object] $Simulation,

        [string] $DataFolder,

        [switch] $ObserveOnly,

        [int] $Generation = 1,

        [object] $Previous,

        [scriptblock] $Clock = { [Environment]::TickCount64 }
    )

    $paths = if ($DataFolder) {
        @{
            Settings  = Join-Path -Path $DataFolder -ChildPath 'settings.json'
            SimPin    = Join-Path -Path $DataFolder -ChildPath 'sim-pin.json'
            ApnSecret = Join-Path -Path $DataFolder -ChildPath 'apn-password.dat'
            Log       = Join-Path -Path $DataFolder -ChildPath 'logs'
        }
    }
    else {
        @{
            Settings  = Get-AppDataPath -Name 'settings.json'
            SimPin    = Get-AppDataPath -Name 'sim-pin.json'
            ApnSecret = Get-AppDataPath -Name 'apn-password.dat'
            Log       = Get-AppDataPath -Name 'logs' -Local
        }
    }
    @{
        Link              = $Link
        Simulation        = $Simulation
        Paths             = $paths
        ObserveOnly       = [bool]$ObserveOnly
        Generation        = $Generation
        Clock             = $Clock
        Started           = [DateTimeOffset]::Now
        # The simulated adapter needs no rights.
        Elevated          = [bool]$Simulation -or (Test-AppElevation)
        Settings          = $null
        SettingsProblems  = [string[]]@()
        Presence          = $null
        PortError         = $null
        Channel           = $null
        PortName          = $null
        AdapterInstanceId = $null
        Decision          = $null
        Facts             = $null
        State             = if ($Previous) { $Previous.State } else { $null }
        StateSince        = if ($Previous) { $Previous.StateSince } else { [DateTimeOffset]::Now }
        Radio             = $null
        PinStored         = $false
        PinRequestOn      = $null
        PinRejected       = if ($Previous) { [bool]$Previous.Sim.PinRejected } else { $false }
        ApnPasswordStored = $false
        Results           = [System.Collections.Generic.List[object]]::new()
        LastScan          = $null
        LastPass          = $null
        LastStatus        = $null
        LastAdapterLook   = $null
        PassForced        = $true
        Version           = if ($Previous) { [long]$Previous.Version } else { [long]0 }
        WaitMs            = 0
        # The data-path probes, for the address the adapter carries (none: nothing to probe).
        Probe             = @{
            Address    = $null
            Rounds     = [System.Collections.Generic.List[string]]::new()
            LastAt     = $null
            NotBefore  = $null
            LastResult = $null
            LastTime   = $null
            # A reply since the app started: until then, failed rounds prove nothing (a network that
            # drops ICMP). Carried over from the worker this one replaces.
            Proven     = [bool]($Previous -and $Previous.PSObject.Properties['DataPath'] -and $Previous.DataPath -and $Previous.DataPath.Proven)
            Quiet      = $false
        }
        # Resolve-RecoveryAction's history, and what it last decided.
        Recovery          = if ($Previous -and $Previous.PSObject.Properties['Recovery'] -and $Previous.Recovery) { $Previous.Recovery.History } else { $null }
        RecoveryView      = if ($Previous -and $Previous.PSObject.Properties['Recovery']) { $Previous.Recovery } else { $null }
        RecoveryAt        = $null
        RecoveryLogged    = $null
        # The computer slept: Invoke-ModemWorker sets it, the next cycle takes it into account.
        Resumed           = $false
    }
}

function Write-WorkerLog {
    # A line in the worker's log, redacted on its way in. A log that can't be written (a full
    # disk) never stops the worker: monitoring matters more than its record.
    param([hashtable] $Worker, [string] $Level, [string] $Message)

    try {
        Write-AppLog -Folder $Worker.Paths.Log -Level $Level -Message $Message -ErrorAction Stop
    }
    catch {
        Write-Verbose "The log can't be written: $($_.Exception.Message)"
    }
}

function Register-WorkerDecision {
    # Takes a decision of the state machine as the worker's state; a change of state is logged
    # unless the pass logged it already.
    param([hashtable] $Worker, [object] $Decision, [switch] $Logged)

    if ($Decision.State -ne $Worker.State) {
        if (-not $Logged) {
            $from = if ($Worker.State) { $Worker.State } else { '(start)' }
            $why = if ($Decision.Reason) { " ($($Decision.Reason))" } else { '' }
            Write-WorkerLog -Worker $Worker -Level $(if ($Decision.Dropped) { 'Warning' } else { 'Info' }) -Message "State $from -> $($Decision.State)$why"
        }
        $Worker.StateSince = [DateTimeOffset]::Now
    }
    $Worker.State = $Decision.State
    $Worker.Decision = $Decision
}

function Close-WorkerChannel {
    # Closes the worker's channel - lost, or at the end - and forgets what was read through it.
    param([hashtable] $Worker, [string] $Why)

    if (-not $Worker.Channel) {
        return
    }
    $reason = $Worker.Channel.Transport.LostReason
    Close-AtChannel -Channel $Worker.Channel
    $Worker.Channel = $null
    $Worker.Facts = $null
    $Worker.Radio = $null
    $Worker.PinRequestOn = $null
    $Worker.LastScan = $null
    $Worker.LastAdapterLook = $null
    Set-WorkerProbeAddress -Worker $Worker -Address $null
    if ($Why) {
        Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "AT port $($Worker.PortName) $Why$(if ($reason) { ": $reason" })"
    }
}

function Get-WorkerPresence {
    # The modem as PnP reports it now - or as the simulated device does.
    param([hashtable] $Worker)

    if ($Worker.Simulation) {
        $Worker.Simulation.Find()
    }
    else {
        Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device @(Get-ModemPnpRecord))
    }
}

function Find-WorkerModem {
    # Looks for the modem and opens its AT port when it is there. Every look starts from nothing:
    # the COM number may have changed.
    param([hashtable] $Worker)

    $presence = Get-WorkerPresence -Worker $Worker
    $before = if ($Worker.Presence) { $Worker.Presence.Device } else { $null }
    if ($presence.Device -ne $before) {
        Write-WorkerLog -Worker $Worker -Level 'Info' -Message "Modem: $($presence.Device)$(if ($presence.PortName) { ", AT port $($presence.PortName)" })"
    }
    $Worker.Presence = $presence
    if ($presence.Device -ne 'Present') {
        $Worker.PortError = $null
        return
    }

    $portError = $null
    try {
        $inner = if ($Worker.Simulation) { $Worker.Simulation.Open() } else { Open-SerialAtTransport -PortName $presence.PortName }
    }
    catch {
        # Another program holding the port is told apart: the user can do something about it.
        $exception = $_.Exception
        $inUse = $false
        while ($exception) {
            if ($exception -is [System.UnauthorizedAccessException]) { $inUse = $true }
            $exception = $exception.InnerException
        }
        $portError = if ($inUse) { 'InUse' } else { 'Failed' }
        if ($portError -ne $Worker.PortError) {
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "AT port $($presence.PortName) can't be opened: $($_.Exception.Message)"
        }
    }
    $Worker.PortError = $portError
    if ($portError) {
        return
    }
    $Worker.Channel = New-AtChannel -Transport ([WorkerTransport]::new($inner, $Worker.Link, $script:WorkerBeatMs))
    $Worker.PortName = $presence.PortName
    $Worker.AdapterInstanceId = $presence.AdapterInstanceId
    $Worker.PassForced = $true
    Write-WorkerLog -Worker $Worker -Level 'Info' -Message "AT port $($presence.PortName) open"
}

function Set-WorkerProbeAddress {
    # Points the data-path probes at the address the adapter carries ($null: none, nothing to
    # probe). A new address - or the same one set again (-Again: configured anew, or a recovery
    # step taken) - starts with no rounds, and its first round waits the settle time.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the worker''s in-memory state only.')]
    param([hashtable] $Worker, [string] $Address, [switch] $Again)

    $probe = $Worker.Probe
    if ($Address -eq [string]$probe.Address -and -not $Again) {
        return
    }
    $probe.Address = if ($Address) { $Address } else { $null }
    $probe.Rounds.Clear()
    $probe.LastAt = $null
    $probe.NotBefore = (& $Worker.Clock) + $script:DataProbe.SettleMs
}

function Get-WorkerDataPath {
    # The probes' verdict as the connect pass takes it: it counts only for the address the
    # rounds were sent from.
    param([hashtable] $Worker)

    $probe = $Worker.Probe
    if (-not $probe.Address) {
        return $null
    }
    [pscustomobject]@{ Address = $probe.Address; Healthy = (Resolve-DataPathHealth -Rounds $probe.Rounds.ToArray() -Unproven:(-not $probe.Proven)) }
}

function Invoke-WorkerProbe {
    # One data-path round from the adapter's address. The state follows the verdict at once, from
    # the last pass's facts: no need to wait for the next pass to say that no traffic gets
    # through. Addresses are never logged.
    param([hashtable] $Worker)

    $probe = $Worker.Probe
    $started = & $Worker.Clock
    $before = Resolve-DataPathHealth -Rounds $probe.Rounds.ToArray() -Unproven:(-not $probe.Proven)
    $round = if ($Worker.Simulation) { $Worker.Simulation.Probe($probe.Address) } else { Test-ModemDataPath -SourceAddress $probe.Address }
    $probe.LastAt = $started
    $probe.LastResult = $round.Result
    $probe.LastTime = [DateTimeOffset]::Now
    if ($round.Result -eq 'Passed') {
        $probe.Proven = $true
    }
    if ($round.Result -in 'Passed', 'Failed') {
        $probe.Rounds.Add($round.Result)
        while ($probe.Rounds.Count -gt $script:DataProbe.RoundsKept) {
            $probe.Rounds.RemoveAt(0)
        }
    }
    if ($round.Result -eq 'Failed') {
        Write-WorkerLog -Worker $Worker -Level 'Info' -Message "Data path: no reply to $($round.Sent) request(s), status $($round.Status)"
    }
    elseif ($round.Result -eq 'NotReady') {
        Write-WorkerLog -Worker $Worker -Level 'Info' -Message "Data path: the adapter's address is not usable yet ($($round.AddressState))"
    }
    $healthy = Resolve-DataPathHealth -Rounds $probe.Rounds.ToArray() -Unproven:(-not $probe.Proven)
    if (-not $probe.Proven -and -not $probe.Quiet -and $null -eq $healthy -and $null -ne (Resolve-DataPathHealth -Rounds $probe.Rounds.ToArray())) {
        $probe.Quiet = $true
        Write-WorkerLog -Worker $Worker -Level 'Warning' -Message 'Data path: no reply since the app started - the network may drop ICMP; not taken for a failure'
    }
    if ($healthy -ne $before -and $null -ne $healthy) {
        $level, $text = if ($healthy) { 'Info', 'traffic gets through' } else { 'Warning', "no traffic gets through ($($script:DataProbe.FailedRounds) rounds failed in a row)" }
        Write-WorkerLog -Worker $Worker -Level $level -Message "Data path: $text"
    }
    if ($Worker.Facts -and $Worker.Facts.ContextAddress -eq $probe.Address -and $Worker.Facts.DataPath -ne $healthy) {
        $facts = $Worker.Facts | Select-Object -Property *
        $facts.DataPath = $healthy
        $Worker.Facts = $facts
        $previous = if ($Worker.State) { @{ Previous = $Worker.State } } else { @{} }
        Register-WorkerDecision -Worker $Worker -Decision (Resolve-ConnectionState -Observation $facts @previous)
    }
}

function Invoke-WorkerRecovery {
    # The recovery decision on the worker's latest state, and the step it calls for. Logs what it
    # decides when that changes; a step is logged with its commands.
    param([hashtable] $Worker, [switch] $Resumed)

    $now = & $Worker.Clock
    $decision = $Worker.Decision
    $health = Resolve-HealthCheck -State $Worker.State -Reason $(if ($decision) { $decision.Reason }) -Action $(if ($decision) { $decision.Action }) `
        -Blocked:([bool]($decision -and $decision.Blocked))
    $failing = @{}
    if ($health.Check) {
        $failing['Check'] = $health.Check
    }
    $before = $Worker.Recovery
    # After a reset a SIM whose PIN request is on asks for its PIN: without a stored one, the
    # reset would leave the connection waiting for the user.
    $noReset = $Worker.PinRequestOn -eq $true -and -not $Worker.PinStored
    $recovery = Resolve-RecoveryAction -Now $now @failing -Blocked:$health.Blocked -Unknown:$health.Unknown -History $before `
        -Elevated:$Worker.Elevated -Withhold:$Worker.ObserveOnly -Resumed:$Resumed -NoReset:$noReset
    $Worker.Recovery = $recovery.History
    $Worker.RecoveryAt = if ($null -ne $recovery.WaitMs) { $now + $recovery.WaitMs } else { $null }
    $setView = {
        param($status)
        $clock = [DateTimeOffset]::Now
        $history = $Worker.Recovery
        $step = if ($status -eq 'Withheld') { $recovery.Step } elseif ($history) { $history.Step } else { $null }
        $Worker.RecoveryView = [pscustomobject]@{
            Status   = $status
            Check    = $recovery.Check
            Step     = $step
            Cycles   = if ($history) { $history.Cycles } else { 0 }
            StepTime = if ($history -and $null -ne $history.StepAt) { $clock.AddMilliseconds($history.StepAt - $now) } else { $null }
            NextTime = if ($null -ne $Worker.RecoveryAt) { $clock.AddMilliseconds($Worker.RecoveryAt - $now) } else { $null }
            History  = $history
        }
    }

    $key = "$($recovery.Status) $($recovery.Check) $($recovery.Step)"
    if ($key -ne $Worker.RecoveryLogged -and $recovery.Status -notin 'Recovering', 'Settling') {
        $minutes = if ($null -ne $recovery.WaitMs) { [Math]::Ceiling($recovery.WaitMs / 60000) } else { $null }
        $reason = if ($decision -and $decision.Reason) { " ($($decision.Reason))" } else { '' }
        $level, $message = switch ($recovery.Status) {
            'Healthy' { if ($Worker.RecoveryLogged) { 'Info', 'every check passes again' } }
            'Watching' { 'Info', "$($recovery.Check) fails$reason; the connect pass has it for now" }
            'Blocked' { 'Info', "$($recovery.Check) fails$reason, out of the app's reach: nothing is escalated" }
            'Maintenance' { 'Info', "$($recovery.Check) fails during a maintenance window: nothing is escalated" }
            'Waiting' { 'Warning', "cycle $($recovery.Cycles) didn't mend $($recovery.Check); the next one in $minutes min" }
            'SlowCadence' { 'Warning', "$($recovery.Cycles) cycles didn't mend $($recovery.Check); trying again in $minutes min" }
            'Withheld' { 'Info', "$($recovery.Check) fails$reason; step $($recovery.Step) withheld: the app only observes" }
        }
        if ($message) {
            Write-WorkerLog -Worker $Worker -Level $level -Message "Recovery: $message"
        }
        $Worker.RecoveryLogged = $key
    }

    $status = $recovery.Status
    if ($status -eq 'Recovering') {
        $Worker.RecoveryLogged = $key
        # Published before the step runs: should the step hang, the worker that replaces this one
        # knows it was taken, and gives it its settle time instead of taking it again.
        & $setView $status
        $Worker.Version++
        $Worker.Link['Snapshot'] = New-ModemSnapshot -Worker $Worker -Time ([DateTimeOffset]::Now)
        $step = $recovery.Action
        $options = @{ Step = $step; Simulation = $Worker.Simulation; Confirm = $false }
        if ($step -eq 'R6') {
            # Windows can't restart a device whose port is held open.
            Close-WorkerChannel -Worker $Worker -Why 'closed to restart the USB device'
            # H1 passing: the modem is still on USB. Found again, never remembered.
            $presence = Get-WorkerPresence -Worker $Worker
            if ($presence.Device -eq 'Present') {
                $options['DeviceInstanceId'] = $presence.InstanceId
            }
            else {
                $options['Simulation'] = $null
            }
        }
        else {
            $options['Channel'] = $Worker.Channel
            $options['AdapterInstanceId'] = $Worker.AdapterInstanceId
        }
        $outcome = Invoke-RecoveryStep @options
        $commands = ($outcome.Commands | ForEach-Object { "$($_.Command) $($_.Status)" }) -join '; '
        Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Recovery: $($recovery.Check) fails - step $step$(if ($Worker.Recovery.Cycles) { " (after $($Worker.Recovery.Cycles) cycle(s))" }): $($outcome.Result)$(if ($commands) { " - $commands" })"
        if ($outcome.Result -eq 'NoModem') {
            # Nothing to act on - the port went with the modem since the state was read: the
            # step is not counted, and the next cycle decides on what the next look finds.
            $Worker.Recovery = $before
            $Worker.RecoveryAt = $null
            $status = 'Watching'
        }
        else {
            # Whatever the step changed, the data path is proven again from scratch.
            Set-WorkerProbeAddress -Worker $Worker -Address $Worker.Probe.Address -Again
            if ($step -in 'R1', 'R2', 'R3', 'R4') {
                # The pass takes the steps back up: configures, activates, registers, radio on.
                $Worker.PassForced = $true
            }
        }
    }
    & $setView $status
}

function Invoke-WorkerCommand {
    # Carries out one of the user's commands; returns its outcome for the snapshot. Never logs or
    # returns a secret.
    param([hashtable] $Worker, [object] $Command)

    $parameter = if ($Command.Parameter) { $Command.Parameter } else { @{} }
    $result = 'Done'
    $detail = $null
    $attemptsLeft = $null
    $channelOpen = $Worker.Channel -and $Worker.Channel.State -eq 'Open'
    $writes = $Command.Kind -in 'DisableSimPin', 'UnlockFcc', 'EnableAdapter'
    try {
        if ($writes -and $Worker.ObserveOnly) {
            $result = 'Refused'
        }
        elseif ($Command.Kind -in 'SaveSimPin', 'DisableSimPin', 'UnlockFcc' -and -not $channelOpen) {
            $result = 'NoModem'
        }
        else {
            switch ($Command.Kind) {
                'ConnectNow' { }
                'SaveSettings' {
                    Export-AppSetting -Settings $parameter['Settings'] -Path $Worker.Paths.Settings -Confirm:$false
                    if ($parameter.ContainsKey('ApnPassword')) {
                        $password = $parameter['ApnPassword']
                        if ($password -and $password.Length -gt 0) {
                            Save-ApnPassword -Password $password -Path $Worker.Paths.ApnSecret -Confirm:$false
                        }
                        else {
                            Remove-ApnPassword -Path $Worker.Paths.ApnSecret -Confirm:$false
                        }
                    }
                    $Worker.Settings = $null
                }
                'SaveSimPin' {
                    # The PIN goes with the SIM it belongs to (ARCHITECTURE -> SIM PIN).
                    $iccid = ConvertFrom-AtIccid -Lines (Invoke-AtCommand -Channel $Worker.Channel -Command 'AT+ICCID').Lines
                    if ($iccid) {
                        Save-SimPin -Pin $parameter['Pin'] -Iccid $iccid -Path $Worker.Paths.SimPin -Confirm:$false
                        $Worker.PinRejected = $false
                    }
                    else {
                        $result = 'SimNotIdentified'
                    }
                }
                'ForgetSimPin' {
                    Remove-SimPin -Path $Worker.Paths.SimPin -Confirm:$false
                }
                'DisableSimPin' {
                    $outcome = Disable-SimPin -Channel $Worker.Channel -Pin $parameter['Pin'] -Confirm:$false
                    $result = $outcome.Result
                    $attemptsLeft = $outcome.AttemptsLeft
                    $Worker.PinRequestOn = $null
                }
                'UnlockFcc' {
                    $outcome = Invoke-FccUnlock -Channel $Worker.Channel -Confirm:$false
                    $result = $outcome.Result
                    $detail = ($outcome.Steps | ForEach-Object { "$($_.Command) $($_.Status)" }) -join '; '
                    if ($result -eq 'Restarted') {
                        # The modem restarts as at a reset (R5): an intentional operation, which
                        # nothing escalates over.
                        $Worker.Recovery = Open-MaintenanceWindow -History $Worker.Recovery -Now (& $Worker.Clock) -DurationMs $script:RecoveryTimings.Settle['R5']
                    }
                }
                'EnableAdapter' {
                    if ($Worker.Simulation) {
                        $Worker.Simulation.Adapter.Enable()
                    }
                    elseif ($Worker.AdapterInstanceId) {
                        Enable-ModemAdapter -InstanceId $Worker.AdapterInstanceId -Confirm:$false
                    }
                    else {
                        $result = 'NoModem'
                    }
                }
                default {
                    $result = 'Unknown'
                }
            }
        }
    }
    catch {
        $result = 'Failed'
        $detail = $_.Exception.Message
    }
    $outcome = [pscustomobject]@{
        Id           = $Command.Id
        Kind         = $Command.Kind
        Result       = $result
        Detail       = $detail
        AttemptsLeft = $attemptsLeft
        Time         = [DateTimeOffset]::Now
    }
    $level = if ($result -in 'Done', 'Disabled', 'AlreadyOff', 'Restarted', 'NotLocked') { 'Info' } else { 'Warning' }
    Write-WorkerLog -Worker $Worker -Level $level -Message "Command $($Command.Kind): $result$(if ($detail) { " - $detail" })"
    $outcome
}

function Invoke-ModemWorkerCycle {
    <#
    .SYNOPSIS
        Runs one cycle of the worker: the user's commands, the modem's port, a pass, a data-path
        probe and a status read when due, the recovery decision, and a new snapshot.
    .DESCRIPTION
        In order: carries out the queued commands; closes a port that was lost; looks for the
        modem by PnP when no port is open, and opens its AT port; runs a connect pass when one is
        due (Invoke-ModemConnect: on a connection that is up it changes nothing); sends a
        data-path round from the adapter's address when due (H7); reads the radio for display
        when due; decides on recovery (Resolve-HealthCheck, Resolve-RecoveryAction) and takes
        the step it calls for. Publishes a new snapshot in the link when anything was done, and
        sets the worker's WaitMs: how long it may wait before the next cycle
        (Resolve-WorkerSchedule).
    .EXAMPLE
        Invoke-ModemWorkerCycle -Worker $worker
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Worker
    )

    $link = $Worker.Link
    $link['Heartbeat'] = [Environment]::TickCount64
    $published = $false
    $publish = {
        $Worker.Version++
        $link['Snapshot'] = New-ModemSnapshot -Worker $Worker -Time ([DateTimeOffset]::Now)
    }
    $due = {
        $decision = $Worker.Decision
        $probe = $Worker.Probe
        Resolve-WorkerSchedule -Now (& $Worker.Clock) -LastScan $Worker.LastScan -LastPass $Worker.LastPass -LastStatus $Worker.LastStatus `
            -LastAdapterLook $Worker.LastAdapterLook -State $Worker.State -Blocked:($decision -and $decision.Blocked) `
            -PortOpen:([bool]$Worker.Channel) -PassForced:$Worker.PassForced -AdapterMissing:($decision -and $decision.Reason -eq 'NoAdapter') `
            -ProbeWanted:([bool]$probe.Address) -LastProbe $probe.LastAt -ProbeFailed:($probe.LastResult -in 'Failed', 'NotReady') `
            -ProbeNotBefore $probe.NotBefore -RecoveryAt $Worker.RecoveryAt
    }
    $resumed = $Worker.Resumed
    if ($resumed) {
        # The computer slept: the modem and the network had time to change. Everything is read
        # again, the data path proven again, and a failing check gets its grace time again.
        $Worker.Resumed = $false
        $Worker.PassForced = $true
        Set-WorkerProbeAddress -Worker $Worker -Address $Worker.Probe.Address -Again
        Write-WorkerLog -Worker $Worker -Level 'Info' -Message 'Resumed after a pause (the computer slept?)'
    }
    $lost = {
        if ($Worker.Channel -and $Worker.Channel.State -ne 'Open') {
            Close-WorkerChannel -Worker $Worker -Why 'lost'
        }
    }

    if ($null -eq $Worker.Settings) {
        $read = Import-AppSetting -Path $Worker.Paths.Settings
        $Worker.Settings = $read.Settings
        $Worker.SettingsProblems = [string[]]@($read.Problems)
        foreach ($problem in $read.Problems) {
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Settings: $problem"
        }
        $Worker.ApnPasswordStored = Test-Path -LiteralPath $Worker.Paths.ApnSecret -PathType Leaf
        $Worker.PinStored = [bool](Get-SimPin -Path $Worker.Paths.SimPin)
    }

    # The user's commands.
    $command = $null
    while ($link['Commands'].TryDequeue([ref]$command)) {
        $Worker.Results.Add((Invoke-WorkerCommand -Worker $Worker -Command $command))
        while ($Worker.Results.Count -gt $script:WorkerResultsKept) {
            $Worker.Results.RemoveAt(0)
        }
        $Worker.PassForced = $true
        $published = $true
        & $lost
        if ($null -eq $Worker.Settings) {
            $read = Import-AppSetting -Path $Worker.Paths.Settings
            $Worker.Settings = $read.Settings
            $Worker.SettingsProblems = [string[]]@($read.Problems)
        }
        $Worker.ApnPasswordStored = Test-Path -LiteralPath $Worker.Paths.ApnSecret -PathType Leaf
        $Worker.PinStored = [bool](Get-SimPin -Path $Worker.Paths.SimPin)
    }

    # The modem's port. What is due is marked done only once it has run: a part that fails is due
    # again at the retry, and fails the next cycle too.
    & $lost
    if ((& $due).Scan) {
        $started = & $Worker.Clock
        Find-WorkerModem -Worker $Worker
        $Worker.LastScan = $started
        if (-not $Worker.Channel) {
            $observation = @{ Device = $Worker.Presence.Device; PortOpen = $false; PortError = $Worker.PortError }
            $previous = if ($Worker.State) { @{ Previous = $Worker.State } } else { @{} }
            Register-WorkerDecision -Worker $Worker -Decision (Resolve-ConnectionState -Observation $observation @previous)
        }
        $published = $true
    }

    # The modem's network adapter, looked for again while a pass finds none: a PnP read can miss
    # it, and the port stays open meanwhile.
    if ((& $due).AdapterLook) {
        $started = & $Worker.Clock
        $presence = Get-WorkerPresence -Worker $Worker
        $Worker.LastAdapterLook = $started
        if ($presence.Device -eq 'Present' -and $presence.PortName -eq $Worker.PortName -and $presence.AdapterInstanceId -and $presence.AdapterInstanceId -ne $Worker.AdapterInstanceId) {
            $Worker.AdapterInstanceId = $presence.AdapterInstanceId
            $Worker.PassForced = $true
            Write-WorkerLog -Worker $Worker -Level 'Info' -Message 'The modem''s network adapter is found'
        }
    }

    # A connect pass.
    if ((& $due).Pass) {
        $started = & $Worker.Clock
        $options = @{}
        if ($Worker.State) {
            $options['Previous'] = $Worker.State
        }
        if ($Worker.Simulation) {
            $options['SimulatedAdapter'] = $Worker.Simulation.Adapter
        }
        $pass = Invoke-ModemConnect -Channel $Worker.Channel -Settings $Worker.Settings -AdapterInstanceId $Worker.AdapterInstanceId `
            -SimPinPath $Worker.Paths.SimPin -ApnSecretPath $Worker.Paths.ApnSecret -LogFolder $Worker.Paths.Log `
            -DataPath (Get-WorkerDataPath -Worker $Worker) -WhatIf:$Worker.ObserveOnly -Confirm:$false @options
        $Worker.LastPass = $started
        $Worker.PassForced = $false
        Register-WorkerDecision -Worker $Worker -Decision $pass -Logged
        $Worker.Facts = $pass.Observation
        # The probes follow the address the adapter carries; one set anew is proven anew.
        $facts = $Worker.Facts
        $configured = @($pass.Steps | Where-Object { $_.Action -eq 'ConfigureAdapter' -and $_.Result -eq 'Done' }).Count -gt 0
        $address = if ($facts -and $facts.AdapterConfigured -eq $true -and $facts.ContextAddress) { [string]$facts.ContextAddress } else { $null }
        Set-WorkerProbeAddress -Worker $Worker -Address $address -Again:$configured
        if (@($pass.Steps | Where-Object Result -EQ 'PinRejected').Count -gt 0) {
            $Worker.PinRejected = $true
        }
        $Worker.PinStored = [bool](Get-SimPin -Path $Worker.Paths.SimPin)
        if ($Worker.Facts.SimState -ne 'Ready') {
            $Worker.PinRequestOn = $null
        }
        # Below a ready SIM the radio is not read: what was read before is no longer shown.
        if ($script:ConnectionStates.IndexOf($Worker.State) -lt $script:ConnectionStates.IndexOf('SimReady')) {
            $Worker.Radio = $null
        }
        $published = $true
        & $lost
    }

    # The data path (H7), from the adapter's address.
    if ((& $due).Probe) {
        Invoke-WorkerProbe -Worker $Worker
        $published = $true
    }

    # The radio, for display.
    if ((& $due).Status) {
        $started = & $Worker.Clock
        $Worker.Radio = Get-ModemRadioStatus -Channel $Worker.Channel
        $Worker.LastStatus = $started
        if (-not $Worker.Radio.Answered) {
            # The modem stopped answering: the pass says what that means, now.
            $Worker.PassForced = $true
        }
        elseif ($Worker.Channel.State -eq 'Open') {
            if ($null -eq $Worker.PinRequestOn -and $Worker.Facts -and $Worker.Facts.SimState -eq 'Ready') {
                $Worker.PinRequestOn = ConvertFrom-AtFacilityLock -Lines (Invoke-AtCommand -Channel $Worker.Channel -Command 'AT+CLCK="SC",2').Lines
            }
            foreach ($code in @(Receive-AtUrc -Channel $Worker.Channel)) {
                if ($code -match $script:WorkerPassUrcPattern) {
                    $Worker.PassForced = $true
                }
            }
        }
        $published = $true
        & $lost
    }

    # Health and recovery: decided on every cycle - it is cheap - and published when it changes.
    if ($Worker.State) {
        $before = $Worker.RecoveryView
        Invoke-WorkerRecovery -Worker $Worker -Resumed:$resumed
        $after = $Worker.RecoveryView
        if (-not $before -or $before.Status -ne $after.Status -or $before.Check -ne $after.Check -or $before.Step -ne $after.Step -or $before.Cycles -ne $after.Cycles) {
            $published = $true
        }
        & $lost
    }

    if ($published) {
        & $publish
    }
    $Worker.WaitMs = (& $due).WaitMs
}

function Close-ModemWorker {
    <#
    .SYNOPSIS
        Ends a worker: closes its AT port. The connection stays as it is.
    .EXAMPLE
        Close-ModemWorker -Worker $worker
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Worker
    )

    Close-WorkerChannel -Worker $Worker
}

function Invoke-ModemWorker {
    <#
    .SYNOPSIS
        Runs the worker until it is asked to stop: the body of the worker runspace.
    .DESCRIPTION
        Cycles (Invoke-ModemWorkerCycle) and waits in between - at most a second at a time,
        beating the heartbeat, and no longer than the next thing due - until the link's Stop is
        set. A command or a stop request ends the wait at once. Closes the AT port on the way
        out, whatever ends it: closing the app stops monitoring only; the connection stays up.

        Any error stops the cycle where it happened - never half a cycle carried on - and is
        logged; the cycle is tried again a second later. After three failed cycles in a row the
        worker ends with the last error, and the supervisor starts a new one, which attaches.
        Parameters as New-ModemWorker.
    .EXAMPLE
        Invoke-ModemWorker -Link $link -Simulation (New-SimulatedDevice -Scenario Connect)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Link,

        [object] $Simulation,

        [string] $DataFolder,

        [switch] $ObserveOnly,

        [int] $Generation = 1,

        [object] $Previous
    )

    # Every error stops the cycle: the functions it calls see this preference. Reads that may fail
    # say so with -ErrorAction of their own.
    $ErrorActionPreference = 'Stop'
    $worker = New-ModemWorker @PSBoundParameters
    $mode = if ($Simulation) { " - simulated, scenario $($Simulation.Scenario)" } else { '' }
    Write-WorkerLog -Worker $worker -Level 'Info' -Message "Worker $Generation started$mode$(if ($ObserveOnly) { ' - observe only' })"
    $failures = 0
    try {
        while (-not $Link['Stop']) {
            try {
                Invoke-ModemWorkerCycle -Worker $worker
                $failures = 0
            }
            catch {
                $failures++
                Write-WorkerLog -Worker $worker -Level 'Error' -Message "Cycle failed ($failures in a row): $($_.Exception.Message)"
                if ($failures -ge $script:WorkerFailedCyclesAllowed) {
                    throw
                }
                $worker.WaitMs = $script:WorkerRetryMs
            }
            $deadline = [Environment]::TickCount64 + $worker.WaitMs
            while (-not $Link['Stop']) {
                $Link['Heartbeat'] = [Environment]::TickCount64
                $left = $deadline - [Environment]::TickCount64
                if ($left -le 0 -or $Link['Wake'].WaitOne([int][Math]::Min($left, $script:WorkerBeatMs))) {
                    break
                }
            }
            # A wait of a second at most that ends far past its deadline: the computer slept,
            # and the clock ran on meanwhile.
            if ([Environment]::TickCount64 - $deadline -gt $script:WorkerPauseMs) {
                $worker.Resumed = $true
            }
        }
    }
    finally {
        Close-ModemWorker -Worker $worker
        Write-WorkerLog -Worker $worker -Level 'Info' -Message "Worker $Generation stopped"
    }
}

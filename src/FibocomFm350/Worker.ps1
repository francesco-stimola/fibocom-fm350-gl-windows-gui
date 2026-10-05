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
    # The modem adapter's byte counters, for data usage.
    Usage       = 30000
}

# The data usage totals are saved at most this often, at once when a quota threshold is said, and
# when the worker ends. Nothing is lost between two saves: the next sample counts from the
# counters last saved, unless they restarted meanwhile.
$script:WorkerUsageSaveMs = 300000

# The modem's new-message notices (AT-COMMANDS section 9): each message stored, then announced on
# the AT port with +CMTI. The modem starts with them off, so they are set on every port opened.
$script:WorkerMessageNotices = 'AT+CNMI=2,1,0,0,0'

# A new message stored: the storage is read again.
$script:WorkerMessageUrcPattern = '^\s*\+CMTI\s*:'

# The commands about messages: what they carry - a number, a text - is never logged.
$script:MessageCommandKinds = @('OpenMessage', 'DeleteMessage', 'SendMessage')

# How long the interface of a function just put on WinUSB is waited for, in ms: it was there within
# seconds on the device (AT-COMMANDS section 1.2).
$script:WorkerInterfaceWaitMs = 5000

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
$script:WorkerCommandKinds = @('ConnectNow', 'SaveSettings', 'SetNetworkMode', 'SaveSimPin', 'ForgetSimPin', 'DisableSimPin', 'UnlockFcc', 'EnableAdapter',
    'OpenMessage', 'DeleteMessage', 'SendMessage', 'ReadEsim', 'SelectSimSlot', 'EnableProfile',
    'DisableProfile', 'SetProfileNickname', 'DeleteProfile', 'DownloadProfile')

# The commands about the SIM slots and the eUICC (ARCHITECTURE -> eSIM): lpac runs for each, so
# they may take a while; an activation code is never logged.
$script:EsimCommandKinds = @('ReadEsim', 'SelectSimSlot', 'EnableProfile', 'DisableProfile', 'SetProfileNickname', 'DeleteProfile', 'DownloadProfile')

# How long one run of lpac may take, in ms: a download talks to the operator's server, the rest
# to the eUICC alone. On the device a download took 16.5 s, the rest under 3 s (decided
# 2026-10-04).
$script:EsimTimeoutMs = @{ Download = 300000; Other = 60000 }

# A DoH server named by its template: how long its first lookup is waited for before a pass (most
# end at once), and how long a lookup may take before it counts as failed.
$script:DohLookupWaitMs = 2000
$script:DohLookupTimeoutMs = 15000

# The settings that make the network mode, set by the SetNetworkMode command only.
$script:NetworkModeSettings = @('NetworkMode', 'LteBands', 'NrBands')

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
          to keep it. The network mode in them is left as it is: SetNetworkMode sets it. The
          APN settings and password are the SIM in use's: saved with SimToken, the snapshot's
          when the window showed them - 'SimChanged' when the SIM changed since, 'NoSim' with
          none identified, and then nothing is saved.
        - SetNetworkMode: NetworkMode, LteBands, NrBands - each left out keeps its setting. A
          mode is written at once, in a maintenance window, and tried: saved once the modem
          registers with it, undone when it finds no network. '' stops managing it.
        - SaveSimPin: Pin, a SecureString; stored for the SIM in the modem.
        - ForgetSimPin: deletes the stored PIN.
        - DisableSimPin: Pin; turns the SIM's PIN request off (Disable-SimPin). Only after the
          user confirmed it.
        - UnlockFcc: lifts the FCC lock (Invoke-FccUnlock). Only after the user confirmed it.
        - EnableAdapter: enables the modem's network adapter (Enable-ModemAdapter).
        - SetStartAtLogon: turns the installer's logon task on or off (Set-AppLogonTask); Enabled.
          'NoTask' when the app is not installed.
        - OpenMessage: Fingerprints, a message's as the snapshot gives them; it is new no more.
        - DeleteMessage: Fingerprints; deletes those messages from the modem's storage, every
          part.
        - SendMessage: Number and Text; sent part by part, never sent again by itself. Neither
          is logged, nor comes back in a snapshot.
        - ReadEsim: the eUICC read again through lpac - its facts, its profiles, its pending
          notifications, sent when there are any.
        - SelectSimSlot: Slot, 0 or 1; AT+GTDUALSIM, a persistent setting of the modem's, in a
          maintenance window. Only after the user confirmed it.
        - EnableProfile, DisableProfile: Aid, a profile's ISD-P AID as the snapshot gives it;
          the SIM resets with it, in a maintenance window. DeleteProfile: Aid, a profile not
          enabled; only after the user confirmed it. SetProfileNickname: Aid and Nickname (''
          clears it). The eUICC's slot must be the one in use.
        - DownloadProfile: ActivationCode and, when the code asks for one, ConfirmationCode -
          SecureStrings; never logged.
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
        [ValidateSet('ConnectNow', 'SaveSettings', 'SetNetworkMode', 'SaveSimPin', 'ForgetSimPin', 'DisableSimPin', 'UnlockFcc', 'EnableAdapter',
            'SetStartAtLogon', 'OpenMessage', 'DeleteMessage', 'SendMessage', 'ReadEsim',
            'SelectSimSlot', 'EnableProfile', 'DisableProfile', 'SetProfileNickname', 'DeleteProfile', 'DownloadProfile')]
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
        - Usage: the modem's network adapter known (-UsageWanted), port open or not, and the
          last reading of its byte counters (-LastUsage) older than the usage interval.
        - WaitMs: until the next of those falls due, or -RecoveryAt (when the recovery decision
          may change), or -TrialAt (when a network mode on trial is undone); 0 when one is due
          now.
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

        [Nullable[long]] $RecoveryAt,

        [Nullable[long]] $TrialAt,

        [switch] $UsageWanted,

        [Nullable[long]] $LastUsage
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
    $usage = $false
    if ($UsageWanted) {
        $wait = Get-WorkerDueTime -Now $Now -Last $LastUsage -Interval $intervals.Usage
        $usage = $wait -eq 0
        $waits.Add($wait)
    }
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
    foreach ($at in @($RecoveryAt, $TrialAt)) {
        if ($null -ne $at) {
            $waits.Add([Math]::Max(0, $at - $Now))
        }
    }
    [pscustomobject]@{
        Scan        = $scan
        Pass        = $pass
        Status      = $status
        AdapterLook = $adapterLook
        Probe       = $probe
        Usage       = $usage
        WaitMs      = [int]($waits | Measure-Object -Minimum).Minimum
    }
}

function Get-WorkerMessageView {
    # The messages as a snapshot shows them, newest first: what Join-SmsPart gives, each with New
    # (a part of it still new) and the SIM it came in on, but not where the storage keeps them;
    # and how full the storage is. $null while they were not read: no port, the SIM not ready, or
    # observe only.
    # The SIM a message came in on is the one remembered for its parts (Update-WorkerSmsOwner).
    # On the eUICC's slot the storage holds other profiles' messages too (AT-COMMANDS section 9):
    # one that came in on another profile still on the eUICC is left out - counted in Hidden,
    # shown when that profile is in use -; one that came in on a SIM not there now, or not known
    # to be there, shows with Owner 'Other', the kind of that SIM and its name (OwnerKind,
    # OwnerName). The others show as they are: Owner 'Own', or 'Unknown' - its SIM not known, or
    # the SIM in use not identified.
    param([hashtable] $Worker)

    if ($null -eq $Worker.Messages) {
        return $null
    }
    $unread = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Worker.SmsUnread), [System.StringComparer]::OrdinalIgnoreCase)
    $owners = @{}
    foreach ($entry in @($Worker.SmsOwners | Where-Object { $_ })) {
        $owners[[string]$entry.Message] = $entry
    }
    $current = if ($Worker.Sim) { [string]$Worker.Sim.Fingerprint } else { '' }
    $present = $null
    if ($null -ne $Worker.EsimProfiles) {
        $present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($each in @($Worker.EsimProfiles | Where-Object { $_ -and $_.Iccid })) {
            [void]$present.Add((Get-SimSettingFingerprint -Iccid $each.Iccid))
        }
    }
    $hidden = 0
    $items = foreach ($message in $Worker.Messages) {
        $owner = @($message.Fingerprints | ForEach-Object { $owners[[string]$_] } | Where-Object { $_ }) | Select-Object -First 1
        $from = if (-not $owner -or -not $current) { 'Unknown' } elseif ($owner.Sim -eq $current) { 'Own' } elseif ($null -ne $present -and $present.Contains($owner.Sim)) { 'Hidden' } else { 'Other' }
        if ($from -eq 'Hidden') {
            $hidden++
            continue
        }
        [pscustomobject]@{
            Fingerprints     = [string[]]$message.Fingerprints
            New              = @($message.Fingerprints | Where-Object { $unread.Contains($_) }).Count -gt 0
            Owner            = $from
            OwnerKind        = if ($from -eq 'Other') { [string]$owner.Kind } else { $null }
            OwnerName        = if ($from -eq 'Other' -and $owner.Name) { [string]$owner.Name } else { $null }
            Address          = $message.Address
            AddressType      = $message.AddressType
            Time             = $message.Time
            Text             = $message.Text
            Content          = $message.Content
            Class            = $message.Class
            Silent           = [bool]$message.Silent
            Waiting          = $message.Waiting
            NationalLanguage = $message.NationalLanguage
            Problem          = $message.Problem
            Count            = $message.Count
            Missing          = [int[]]$message.Missing
            Complete         = $message.Complete
        }
    }
    $items = @($items)
    $storage = $Worker.MessageStorage
    [pscustomobject]@{
        Items  = [object[]]$items
        New    = @($items | Where-Object New).Count
        Hidden = $hidden
        Used   = if ($storage) { $storage.Receive.Used } else { $null }
        Total  = if ($storage) { $storage.Receive.Total } else { $null }
        Full   = [bool]($storage -and $storage.Receive.Used -ge $storage.Receive.Total)
    }
}

function Get-UsbInstanceHash {
    # An instance ID as a snapshot may carry it: the SHA-256 of the ID upper-cased - Windows
    # compares them without case -, in hexadecimal. Pure.
    param([string] $InstanceId)

    [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($InstanceId.ToUpperInvariant())))
}

function Get-WorkerUsbView {
    # The modem's vendor functions with the driver of each - 'WinUsb', 'Other', 'None' -, and the
    # last outcome of putting them on WinUSB: what the window's USB tab shows. Interfaces and
    # names, never an instance ID. Failed and AtFailure carry the installations that failed - as
    # hashes of their instances - and the AT port's failure to a worker that replaces this one.
    param([hashtable] $Worker)

    $presence = $Worker.Presence
    $functions = @(if ($presence -and $presence.PSObject.Properties['Functions'] -and $presence.Functions) { $presence.Functions | Where-Object { $_ -and $_.Vendor } })
    [pscustomobject]@{
        Device    = if ($presence) { $presence.Device } else { $null }
        Functions = [object[]]@(foreach ($function in $functions) {
                [pscustomobject]@{
                    Interface   = $function.Interface
                    Name        = $function.Name
                    Role        = $function.Role
                    Driver      = if ($function.WinUsb) { 'WinUsb' } elseif ($function.State -eq 'NoDriver') { 'None' } else { 'Other' }
                    ProblemCode = $function.ProblemCode
                }
            })
        Binding   = $Worker.Binding
        Failed    = [string[]]@(@($Worker.BindFailed | ForEach-Object { Get-UsbInstanceHash -InstanceId $_ }) + @($Worker.BindFailedCarried) | Sort-Object -Unique)
        AtFailure = $Worker.BindAtFailure
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
        that replaces this one carries on); NetworkMode (Current: the modem's setting as read;
        Support: what it supports; Decision: Resolve-NetworkMode's; Trial: a mode the user chose,
        being tried - Selection, Until, and what a worker that replaces this one carries on -;
        Notice: how the last trial ended, or a mode the modem didn't keep); Usb (the modem's
        vendor functions, Get-WorkerUsbView: Device - Resolve-ModemPresence's -, Functions with the
        driver of each, Binding - the last outcome of putting them on WinUSB); Update (the update
        notice: Status - 'Pending', 'Running', 'Done' -, Result, Version and Url of a newer
        release, Detail, Time); Dns (the adapter's
        encrypted DNS: Supported, Encrypted - the servers encrypted now -, Known - the servers
        Windows has a DoH template for -, Name - a DoH server named by its template: Host,
        Addresses, LookedUp, Via, Next, Failure); Usage (Measure-DataUsage's: today, the cycle,
        the quota) and UsageNotice (the last quota threshold said: Threshold, Id - one more for
        each, across worker restarts -, Time); Messages (Get-WorkerMessageView: the messages on
        the modem, newest first, with the SIM each came in on - another eSIM profile's left out
        and counted -, and how full its storage is; $null while not read),
        MessageNotice (the last new messages announced: Sender - the newest one's -, Count, Id -
        one more each time, across worker restarts -, Time) and MessageOperation ('Sending'
        while a message goes out); Esim (Get-WorkerEsimView: the SIM slot in use and its kind,
        whether lpac and ZXing.Net are there, the eUICC's EID - shown with Copy, never logged - and
        its facts and profiles - no ICCID -, the notifications waiting, the eSIM command under way,
        the last read's failure); AppVersion; Settings - with the SIM in use's own APN settings -,
        ApnPasswordStored (the SIM in use's), SimToken (a random token for the SIM in use, $null
        with none identified: the APN settings shown are that SIM's), SettingsProblems and
        SettingsIssues (ConvertTo-AppSetting's Problems and Issues); Results
        (the last commands' outcomes: Id, Kind, Result, Detail, AttemptsLeft, Parts - of a
        message sent: Sent, Count -, Time).
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
        NetworkMode       = [pscustomobject]@{
            Current  = & $fact 'NetworkModeRead'
            Support  = if ($Worker.NetworkModeSupport) { $Worker.NetworkModeSupport } else { & $fact 'NetworkModeSupport' }
            Decision = & $fact 'NetworkMode'
            # A copy: the worker's trial changes as it goes on.
            Trial    = if ($Worker.NetworkModeTrial) { $Worker.NetworkModeTrial | Select-Object -Property * } else { $null }
            Notice   = $Worker.NetworkModeNotice
        }
        Usb               = Get-WorkerUsbView -Worker $Worker
        Dns               = [pscustomobject]@{
            Supported = & $fact 'DohSupported'
            Encrypted = [string[]]@(& $fact 'DohServers')
            Known     = [string[]]@(& $fact 'DohKnown')
            # IPv6 DNS servers the network gives, which Windows may query in the clear.
            Advertised = [string[]]@(& $fact 'DnsAdvertised')
            Name      = if ($Worker.DohName -and $Worker.DohName.Name) {
                $state = $Worker.DohName
                [pscustomobject]@{
                    Host      = $state.Name
                    Addresses = [string[]]@($state.Addresses)
                    LookedUp  = $state.At
                    Via       = $state.Via
                    Next      = if ($null -ne $state.Next) { [DateTimeOffset]::Now.AddMilliseconds([Math]::Max(0, $state.Next - (& $Worker.Clock))) } else { $null }
                    Failure   = $state.Failure
                }
            }
            else {
                $null
            }
        }
        Update            = $Worker.Update
        Usage             = $Worker.UsageView
        UsageNotice       = $Worker.UsageNotice
        Messages          = Get-WorkerMessageView -Worker $Worker
        MessageNotice     = $Worker.MessageNotice
        MessageOperation  = $Worker.MessageOperation
        Esim              = Get-WorkerEsimView -Worker $Worker
        AppVersion        = if ($Worker.AppVersion) { $Worker.AppVersion.ToString() } else { $null }
        StartAtLogon      = $Worker.StartAtLogon
        Settings          = if ($Worker.Settings) { (Get-WorkerSimSetting -Worker $Worker).Settings } else { $null }
        ApnPasswordStored = $Worker.ApnPasswordStored
        SimToken          = $Worker.SimToken
        SettingsProblems  = [string[]]@($Worker.SettingsProblems)
        SettingsIssues    = [object[]]@($Worker.SettingsIssues)
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
        never writes: no step, no command that changes the modem or the system.
        -CheckForUpdates reads the latest release once the connection is first online, unless
        the settings turn it off (the app's real worker; never in development mode, and mocked in
        the tests). -Clock returns the time in milliseconds; [Environment]::TickCount64 by
        default.
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

        [switch] $CheckForUpdates,

        [scriptblock] $Clock = { [Environment]::TickCount64 }
    )

    $paths = if ($DataFolder) {
        @{
            Settings         = Join-Path -Path $DataFolder -ChildPath 'settings.json'
            SimPin           = Join-Path -Path $DataFolder -ChildPath 'sim-pin.json'
            SimSettings      = Join-Path -Path $DataFolder -ChildPath 'sim-settings.json'
            ApnSecret        = Join-Path -Path $DataFolder -ChildPath 'apn-password.dat'
            Log              = Join-Path -Path $DataFolder -ChildPath 'logs'
            Usage            = Join-Path -Path $DataFolder -ChildPath 'usage.json'
            SmsNew           = Join-Path -Path $DataFolder -ChildPath 'sms-new.dat'
            SmsSim           = Join-Path -Path $DataFolder -ChildPath 'sms-sim.dat'
        }
    }
    else {
        @{
            Settings         = Get-AppDataPath -Name 'settings.json'
            SimPin           = Get-AppDataPath -Name 'sim-pin.json'
            SimSettings      = Get-AppDataPath -Name 'sim-settings.json'
            ApnSecret        = Get-AppDataPath -Name 'apn-password.dat'
            Log              = Get-AppDataPath -Name 'logs' -Local
            Usage            = Get-AppDataPath -Name 'usage.json' -Local
            SmsNew           = Get-AppDataPath -Name 'sms-new.dat' -Local
            SmsSim           = Get-AppDataPath -Name 'sms-sim.dat' -Local
        }
    }
    # The USB section of the snapshot of the worker this one replaces, if any.
    $usbBefore = if ($Previous -and $Previous.PSObject.Properties['Usb']) { $Previous.Usb } else { $null }
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
        SettingsIssues    = [object[]]@()
        # The settings kept for each SIM (Import-SimSetting's, read with the settings); the SIM in
        # use, as the last pass identified it - its fingerprint never in a snapshot -, and a
        # random token that changes with it, which the window sends back with the APN settings
        # it shows; a failure to give the old APN settings to the SIM, and a ready SIM that can't
        # be identified, each logged once.
        SimSettings       = $null
        Sim               = $null
        SimToken          = $null
        SimMoveFailure    = $null
        SimUnreadLogged   = $false
        Presence          = $null
        PortError         = $null
        Channel           = $null
        PortName          = $null
        # The AT port's function, as it was when its port was opened.
        AtInstanceId      = $null
        # Putting the modem's functions on WinUSB (Update-WorkerBinding): the instances whose
        # installation failed - tried once each -, those whose held port was logged, why the AT
        # port isn't on WinUSB (BindState, for the connection's state; BindAtFailure, its failure
        # kept), the last outcome for the window, a look asked for while the port is open (the
        # user's check now), the AT port just put there, and no rights, logged once. A worker that
        # replaces another carries its failed installations, as its snapshot holds them - hashes of
        # their instances, matched as the functions are found -, and the AT port's failure: tried
        # once per instance, not once per worker (decided 2026-10-04).
        BindFailed        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        BindFailedCarried = [System.Collections.Generic.HashSet[string]]::new([string[]]@(if ($usbBefore -and $usbBefore.PSObject.Properties['Failed']) { @($usbBefore.Failed) | Where-Object { $_ } }), [System.StringComparer]::OrdinalIgnoreCase)
        BindHeldLogged    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        BindState         = $null
        BindAtFailure     = if ($usbBefore -and $usbBefore.PSObject.Properties['AtFailure']) { $usbBefore.AtFailure } else { $null }
        Binding           = $null
        BindDue           = $false
        BindJustDone      = $false
        BindNotElevatedLogged = $false
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
        # The network mode: what the modem supports (read once per channel), the app's last
        # write of it (never repeated over the same setting), a mode the user chose on trial and
        # how the last one ended - those two carried over from the worker this one replaces.
        NetworkModeSupport = $null
        NetworkModeWrite   = $null
        NetworkModeLogged  = $null
        # What Windows last wouldn't read about DNS (Resolve-AdapterConfiguration's Unread), logged.
        DnsUnreadLogged    = $null
        # The IPv6 DNS servers the network gave beside encrypted DNS, last logged.
        DnsAdvertisedLogged = ''
        NetworkModeTrial   = if ($Previous -and $Previous.PSObject.Properties['NetworkMode'] -and $Previous.NetworkMode) { $Previous.NetworkMode.Trial } else { $null }
        NetworkModeNotice  = if ($Previous -and $Previous.PSObject.Properties['NetworkMode'] -and $Previous.NetworkMode) { $Previous.NetworkMode.Notice } else { $null }
        # The update notice: one request per app start, carried over from the worker this one
        # replaces - one that was under way then counts as done (Get-WorkerUpdateState).
        CheckForUpdates   = [bool]$CheckForUpdates
        AppVersion        = $MyInvocation.MyCommand.Module.Version
        Update            = Get-WorkerUpdateState -Previous $Previous
        UpdateCheck       = $null
        # A DoH server named by its template: the name, the addresses it was last looked up to -
        # carried over from the worker this one replaces, and looked up again at once -, when the
        # next lookup is due, the lookup under way.
        DohName           = Get-WorkerDohNameState -Previous $Previous
        # Whether the app starts at sign-in (Get-AppLogonTask): $true, $false, or $null - not
        # installed -; read once, and again after the user changes it.
        StartAtLogon      = $null
        StartAtLogonRead  = $false
        # Data usage: the totals (read from their file at the first sample), the quota thresholds
        # said this cycle, what the snapshot shows, the last threshold said - carried over from
        # the worker this one replaces -, when the counters were read and the totals saved last,
        # whether they changed since, and the last failure, logged once.
        Usage             = $null
        UsageLoaded       = $false
        UsageWarned       = $null
        UsageView         = $null
        UsageNotice       = if ($Previous -and $Previous.PSObject.Properties['UsageNotice']) { $Previous.UsageNotice } else { $null }
        LastUsage         = $null
        UsageSavedAt      = $null
        UsageDirty        = $false
        UsageFailure      = $null
        # Messages - none in observe-only mode: listing them marks them read on the modem -:
        # whether the notices are set on this port, whether the storage is to be read whole, the
        # messages read (Join-SmsPart's) and how full the storage is, the fingerprints of the
        # parts still new and the SIMs the parts came in on (each read from its file at the first
        # reading), the last new messages announced - carried over from the worker this one
        # replaces -, the message going out, and the last failure, logged once.
        MessagesReady     = $false
        MessagesDue       = $true
        Messages          = $null
        MessageStorage    = $null
        SmsUnread         = [string[]]@()
        SmsUnreadLoaded   = $false
        SmsOwners         = [object[]]@()
        SmsOwnersLoaded   = $false
        MessageNotice     = if ($Previous -and $Previous.PSObject.Properties['MessageNotice']) { $Previous.MessageNotice } else { $null }
        MessageOperation  = $null
        MessagesFailure   = $null
        # The eSIM (ARCHITECTURE -> eSIM): the SIM slot in use and the kind of SIM in it, read once
        # per port and after a switch; the eUICC as lpac read it last - its facts, its profiles
        # and its pending notifications, the ICCIDs kept here, never in a snapshot -,
        # whether it is to be read again, the eSIM command under way, the last read that failed,
        # logged once.
        SimSlot           = $null
        SimType           = $null
        SimSlotRead       = $false
        EsimInfo          = $null
        EsimProfiles      = $null
        EsimNotifications = $null
        EsimDue           = $true
        EsimReadAt        = $null
        EsimOperation     = $null
        EsimFailure       = $null
        # The computer slept: Invoke-ModemWorker sets it, the next cycle takes it into account.
        Resumed           = $false
    }
}

function Save-WorkerUsage {
    # Writes the usage totals and the thresholds said to their file.
    param([hashtable] $Worker)

    Export-DataUsage -State $Worker.Usage -Warned $Worker.UsageWarned -Path $Worker.Paths.Usage -Confirm:$false
    $Worker.UsageSavedAt = & $Worker.Clock
    $Worker.UsageDirty = $false
}

function Update-WorkerUsage {
    # Reads the modem adapter's byte counters into the usage totals (Update-DataUsage), measures
    # today and the cycle against the quota, says a threshold reached once per cycle, and saves
    # the totals now and then. It never stops the cycle - data usage is no reason to touch the
    # connection -: a failure is logged once, by its type (its text may name the user's folder),
    # and the next sample tries again. The quota never disconnects.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the worker''s in-memory state and its own data file only.')]
    param([hashtable] $Worker)

    try {
        if (-not $Worker.UsageLoaded) {
            $unreadable = $null
            $loaded = Import-DataUsage -Path $Worker.Paths.Usage -WarningVariable unreadable -WarningAction SilentlyContinue
            if ($unreadable) {
                Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Data usage: $unreadable"
            }
            $Worker.Usage = $loaded
            $Worker.UsageWarned = if ($loaded) { $loaded.Warned } else { $null }
            $Worker.UsageLoaded = $true
        }
        $sample = if ($Worker.Simulation) {
            $Worker.Simulation.Adapter.ReadCounters()
        }
        elseif ($Worker.AdapterInstanceId) {
            Get-ModemAdapterCounter -InstanceId $Worker.AdapterInstanceId
        }
        if (-not $sample) {
            return
        }
        $Worker.Usage = Update-DataUsage -State $Worker.Usage -Sample $sample
        $settings = Get-WorkerSetting -Worker $Worker
        $cycleDay = if ($settings) { $settings.UsageCycleDay } else { 1 }
        $quota = if ($settings) { $settings.UsageQuotaGB } else { 0 }
        $view = Measure-DataUsage -State $Worker.Usage -Now $sample.Time -CycleDay $cycleDay -QuotaGB $quota
        $warning = Resolve-UsageWarning -Usage $view -Said $Worker.UsageWarned
        $Worker.UsageView = $view
        $Worker.UsageWarned = $warning.Said
        if ($warning.Warn) {
            $id = if ($Worker.UsageNotice) { [int]$Worker.UsageNotice.Id + 1 } else { 1 }
            $Worker.UsageNotice = [pscustomobject]@{ Threshold = $warning.Warn; Id = $id; Time = [DateTimeOffset]::Now }
            Write-WorkerLog -Worker $Worker -Level 'Info' -Message "Data usage: $($warning.Warn)% of the quota reached"
        }
        $Worker.UsageDirty = $true
        if ($warning.Warn -or $null -eq $Worker.UsageSavedAt -or (& $Worker.Clock) - $Worker.UsageSavedAt -ge $script:WorkerUsageSaveMs) {
            Save-WorkerUsage -Worker $Worker
        }
        $Worker.UsageFailure = $null
    }
    catch {
        $failure = $_.Exception.GetType().Name
        if ($failure -ne $Worker.UsageFailure) {
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Data usage not counted ($failure); tried again at the next sample"
        }
        $Worker.UsageFailure = $failure
    }
}

function Test-WorkerSimReady {
    # Whether the connection has come as far as a ready SIM.
    param([hashtable] $Worker)

    [bool]($Worker.State -and $script:ConnectionStates.IndexOf($Worker.State) -ge $script:ConnectionStates.IndexOf('SimReady'))
}

function Register-WorkerMessagesFailure {
    # A step of the messages the modem refused: logged once per cause - the command and the
    # modem's answer, never a number or a text -, and tried again after the next pass.
    param([hashtable] $Worker, [string] $Failure)

    if ($Failure -ne $Worker.MessagesFailure) {
        Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Messages: $Failure; tried again after the next pass"
    }
    $Worker.MessagesFailure = $Failure
}

function Save-WorkerSmsUnread {
    # Writes the fingerprints of the parts still new to their file. A file that can't be written
    # stops nothing: what is new is still shown, and the file is written again at the next change.
    param([hashtable] $Worker)

    try {
        Export-SmsUnread -Fingerprint $Worker.SmsUnread -Path $Worker.Paths.SmsNew -Confirm:$false
    }
    catch {
        Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Messages: the list of new messages not saved ($($_.Exception.GetType().Name))"
    }
}

function Import-WorkerSmsUnread {
    # Reads the fingerprints of the parts still new from their file, once per worker - before the
    # first reading of the storage, or the first message opened.
    param([hashtable] $Worker)

    if ($Worker.SmsUnreadLoaded) {
        return
    }
    $unreadable = $null
    $Worker.SmsUnread = [string[]]@(Import-SmsUnread -Path $Worker.Paths.SmsNew -WarningVariable unreadable -WarningAction SilentlyContinue)
    if ($unreadable) {
        Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Messages: $unreadable"
    }
    $Worker.SmsUnreadLoaded = $true
}

function Import-WorkerSmsOwner {
    # Reads which SIM the parts came in on from their file, once per worker, before the first
    # reading of the storage. A file that can't be read is said in the log: every message shows.
    param([hashtable] $Worker)

    if ($Worker.SmsOwnersLoaded) {
        return
    }
    $unreadable = $null
    $Worker.SmsOwners = [object[]]@(Import-SmsOwner -Path $Worker.Paths.SmsSim -WarningVariable unreadable -WarningAction SilentlyContinue)
    if ($unreadable) {
        Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Messages: $unreadable"
    }
    $Worker.SmsOwnersLoaded = $true
}

function Update-WorkerSmsOwner {
    # Remembers which SIM the parts came in on (Update-SmsOwner) and writes the file when that
    # changed; a file that can't be written stops nothing - it is written again at the next
    # change. The parts listed unread are the SIM in use's, with its kind and - an eSIM profile's
    # - its name as the user knows it; without the SIM in use identified, they keep no SIM and
    # show with every SIM. -Sim and -Name, with no entries: a SIM's parts take that name.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the worker''s in-memory state and the app''s own file.')]
    param([hashtable] $Worker, [object[]] $Entry = @(), [string] $Sim, [string] $Name)

    Import-WorkerSmsOwner -Worker $Worker
    $options = @{}
    if ($Sim) {
        $options['Sim'] = $Sim
        $options['Name'] = $Name
    }
    elseif ($Worker.Sim -and $Worker.Sim.Fingerprint) {
        $kind = if (Test-WorkerEuiccInUse -Worker $Worker) { 'Esim' } elseif ($Worker.SimType -eq 'Usim') { 'Usim' } else { '' }
        $enabled = @($Worker.EsimProfiles | Where-Object { $_ -and $_.State -eq 'Enabled' -and $_.Iccid }) | Select-Object -First 1
        $options['Sim'] = $Worker.Sim.Fingerprint
        $options['Kind'] = $kind
        $options['Name'] = if ($kind -eq 'Esim' -and $enabled -and (Get-SimSettingFingerprint -Iccid $enabled.Iccid) -eq $Worker.Sim.Fingerprint) {
            Get-WorkerEsimProfileName -Entry $enabled
        }
        else {
            ''
        }
    }
    $before = ConvertTo-Json -InputObject ([object[]]@($Worker.SmsOwners)) -Compress -Depth 3
    $Worker.SmsOwners = [object[]]@(Update-SmsOwner -Owner $Worker.SmsOwners -Entry $Entry @options)
    if ((ConvertTo-Json -InputObject ([object[]]@($Worker.SmsOwners)) -Compress -Depth 3) -ne $before) {
        try {
            Export-SmsOwner -Owner $Worker.SmsOwners -Path $Worker.Paths.SmsSim -Confirm:$false
        }
        catch {
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Messages: the SIMs they came in on not saved ($($_.Exception.GetType().Name))"
        }
    }
}

function Get-WorkerEsimProfileName {
    # A profile's name as the user knows it - its nickname, its name or its provider's -, or ''.
    param([object] $Entry)

    [string](@($Entry.Nickname, $Entry.Name, $Entry.Provider | Where-Object { $_ }) | Select-Object -First 1)
}

function Read-WorkerInbox {
    # Reads the modem's whole storage - AT+CMGL=4, which marks every message read there - and how
    # full it is, keeps which parts are new (Update-SmsUnread, and its file when that changed),
    # and announces the messages new since the last reading: how many, and the newest one's
    # sender. A silent message (23.040: never shown) is listed - it takes a place in the storage,
    # which only deleting it frees -, but never new nor announced. The parts listed unread came in
    # on the SIM in use: that is remembered (Update-WorkerSmsOwner). A listing cut short still
    # marked what it listed read: its unread parts are kept new and told as the SIM in use's, the
    # messages shown left as they were. Returns the listing's status.
    param([hashtable] $Worker)

    $listing = Invoke-AtCommand -Channel $Worker.Channel -Command 'AT+CMGL=4'
    Import-WorkerSmsUnread -Worker $Worker
    if ($listing.Status -ne 'OK') {
        Update-WorkerSmsOwner -Worker $Worker -Entry @(ConvertFrom-AtMessageList -Lines $listing.Lines)
        $listed = @(ConvertFrom-AtMessageList -Lines $listing.Lines | Where-Object Status -EQ 'Unread' | ForEach-Object { Get-SmsFingerprint -Pdu $_.Pdu })
        $kept = [string[]]@(@($Worker.SmsUnread) + $listed | Sort-Object -Unique)
        if ($kept.Count -ne @($Worker.SmsUnread).Count) {
            $Worker.SmsUnread = $kept
            Save-WorkerSmsUnread -Worker $Worker
        }
        Register-WorkerMessagesFailure -Worker $Worker -Failure "AT+CMGL=4 $($listing.Status)$(if ($null -ne $listing.ErrorCode) { " $($listing.ErrorCode)" })"
        return $listing.Status
    }
    $entries = @(ConvertFrom-AtMessageList -Lines $listing.Lines | ForEach-Object {
            $_ | Add-Member -NotePropertyName Sms -NotePropertyValue (ConvertFrom-SmsPdu -Pdu $_.Pdu) -PassThru
        })
    Update-WorkerSmsOwner -Worker $Worker -Entry $entries
    $storage = ConvertFrom-AtMessageStorage -Lines (Invoke-AtCommand -Channel $Worker.Channel -Command 'AT+CPMS?').Lines
    $before = [string[]]@($Worker.SmsUnread)
    # What came in on another SIM is in a storage not listed now: still new. With the SIM in use not
    # identified, every part whose SIM is known may be another's.
    $current = if ($Worker.Sim) { [string]$Worker.Sim.Fingerprint } else { '' }
    $elsewhere = [string[]]@($Worker.SmsOwners | Where-Object { $_ -and (-not $current -or $_.Sim -ne $current) } | ForEach-Object Message)
    $unread = [string[]]@(Update-SmsUnread -Unread $before -Entry @($entries | Where-Object { -not $_.Sms.Silent }) -Elsewhere $elsewhere)
    $messages = @(Join-SmsPart -Entry $entries)
    # New since the last reading: a part new now, and none of it new before - a long message's
    # second part, coming after the first, is not announced again.
    $fresh = @($messages | Where-Object {
            $prints = @($_.Fingerprints)
            @($prints | Where-Object { $_ -in $unread }).Count -gt 0 -and @($prints | Where-Object { $_ -in $before }).Count -eq 0
        })
    if ($fresh.Count -gt 0) {
        $id = if ($Worker.MessageNotice) { [int]$Worker.MessageNotice.Id + 1 } else { 1 }
        $Worker.MessageNotice = [pscustomobject]@{ Sender = $fresh[0].Address; Count = $fresh.Count; Id = $id; Time = [DateTimeOffset]::Now }
        Write-WorkerLog -Worker $Worker -Level 'Info' -Message "Messages: $($fresh.Count) new"
    }
    $Worker.SmsUnread = $unread
    if (($unread -join ',') -ne ($before -join ',')) {
        Save-WorkerSmsUnread -Worker $Worker
    }
    $Worker.Messages = $messages
    $Worker.MessageStorage = $storage
    $Worker.MessagesDue = $false
    $Worker.MessagesFailure = $null
    'OK'
}

function Update-WorkerInbox {
    # The messages' part of a cycle: the notices set once per port - with PDU mode, which the
    # codec reads -, then the storage read whole when due, or else how full it is checked, so a
    # message stored without a notice is read too. It never stops the cycle: messages are no
    # reason to leave the connection unwatched. A failure is logged once, by the error's type -
    # its text may hold a number or a text -, and tried again after the next pass. Returns
    # whether the storage was read.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets the modem''s new-message notices, a setting that is not kept; the worker''s state otherwise.')]
    param([hashtable] $Worker)

    try {
        if (-not $Worker.MessagesReady) {
            foreach ($command in 'AT+CMGF=0', $script:WorkerMessageNotices) {
                $answer = Invoke-AtCommand -Channel $Worker.Channel -Command $command
                if ($answer.Status -ne 'OK') {
                    Register-WorkerMessagesFailure -Worker $Worker -Failure "$command $($answer.Status)$(if ($null -ne $answer.ErrorCode) { " $($answer.ErrorCode)" })"
                    return $false
                }
            }
            $Worker.MessagesReady = $true
            $Worker.MessagesDue = $true
        }
        if (-not $Worker.MessagesDue) {
            $storage = ConvertFrom-AtMessageStorage -Lines (Invoke-AtCommand -Channel $Worker.Channel -Command 'AT+CPMS?').Lines
            if ($storage -and $Worker.MessageStorage -and $storage.Read.Used -eq $Worker.MessageStorage.Read.Used) {
                return $false
            }
        }
        (Read-WorkerInbox -Worker $Worker) -eq 'OK'
    }
    catch {
        Register-WorkerMessagesFailure -Worker $Worker -Failure "not read ($($_.Exception.GetType().Name))"
        $false
    }
}

function Remove-WorkerMessage {
    # Deletes the messages that have a part with one of these fingerprints, every part: the
    # storage is read again first, so the places deleted are where the parts are now. Result:
    # 'Done', 'NotFound', or 'Failed' with the command and the modem's answer in Detail.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The user''s command, carried out by the worker as asked.')]
    param([hashtable] $Worker, [string[]] $Fingerprint)

    $status = Read-WorkerInbox -Worker $Worker
    if ($status -ne 'OK') {
        return [pscustomobject]@{ Result = 'Failed'; Detail = "AT+CMGL=4 $status" }
    }
    $doomed = @($Worker.Messages | Where-Object { @($_.Fingerprints | Where-Object { $_ -in $Fingerprint }).Count -gt 0 })
    if ($doomed.Count -eq 0) {
        return [pscustomobject]@{ Result = 'NotFound'; Detail = $null }
    }
    foreach ($index in @($doomed | ForEach-Object { $_.Indexes })) {
        $answer = Invoke-AtCommand -Channel $Worker.Channel -Command "AT+CMGD=$index"
        if ($answer.Status -ne 'OK') {
            return [pscustomobject]@{ Result = 'Failed'; Detail = "AT+CMGD=$index $($answer.Status)$(if ($null -ne $answer.ErrorCode) { " $($answer.ErrorCode)" })" }
        }
    }
    [pscustomobject]@{ Result = 'Done'; Detail = $null }
}

function Send-WorkerMessage {
    # Sends a message part by part (Send-AtMessagePdu). A part refused or unanswered ends it there,
    # and nothing is sent again by itself: an unanswered part may have gone out, and each part
    # costs (ARCHITECTURE -> SMS). Blanks, dashes, dots and brackets in the number are left out.
    # The number and the text are never logged nor returned. Result: 'Sent'; 'Invalid' - no
    # number, no text, or more parts than a message may have -; 'Failed', with the part and the
    # modem's answer in Detail. Sent and Parts: how many parts went out, of how many.
    param([hashtable] $Worker, [string] $Number, [string] $Text)

    $digits = $Number -replace '[\s\-\.\(\)]', ''
    if ($digits -notmatch '^\+?[0-9]{1,20}$' -or -not $Text -or (Measure-SmsText -Text $Text).TooLong) {
        return [pscustomobject]@{ Result = 'Invalid'; Detail = $null; Sent = 0; Parts = 0 }
    }
    $parts = @(ConvertTo-SmsPdu -Number $digits -Text $Text -Reference (Get-Random -Minimum 0 -Maximum 256))
    $sent = 0
    foreach ($part in $parts) {
        $answer = Send-AtMessagePdu -Channel $Worker.Channel -Length $part.Length -Pdu $part.Pdu
        if ($answer.Status -ne 'OK') {
            $code = if ($null -ne $answer.ErrorCode) { " $($answer.ErrorCode)" } else { '' }
            return [pscustomobject]@{ Result = 'Failed'; Detail = "part $($sent + 1) of $($parts.Count): $($answer.Status)$code"; Sent = $sent; Parts = $parts.Count }
        }
        $sent++
    }
    [pscustomobject]@{ Result = 'Sent'; Detail = $null; Sent = $sent; Parts = $parts.Count }
}

function Get-WorkerDohNameState {
    # The DoH server name a new worker starts from: the last worker's name and addresses, looked up
    # again at once; or none.
    param([object] $Previous)

    $dns = if ($Previous -and $Previous.PSObject.Properties['Dns']) { $Previous.Dns } else { $null }
    $name = if ($dns -and $dns.PSObject.Properties['Name'] -and $dns.Name) { $dns.Name } else { $null }
    @{
        Name      = if ($name) { [string]$name.Host } else { $null }
        Addresses = if ($name) { [string[]]@($name.Addresses) } else { [string[]]@() }
        At        = if ($name) { $name.LookedUp } else { $null }
        # 'Windows', or 'Operator' for a lookup through the operator's DNS.
        Via       = if ($name) { $name.Via } else { $null }
        Next      = $null
        Failure   = $null
        Logged    = $null
        Lookup    = $null
    }
}

function Update-WorkerDohName {
    # A DoH server named by its template (Resolve-DohServer): its name looked up when the worker
    # starts, then every DohRefreshMinutes, and again at the pass cadence while a lookup fails -
    # the last addresses kept meanwhile. Looked up through Windows; when Windows can't - its DNS
    # is that server, at an address it left, and the modem alone carries traffic -, through the
    # operator's DNS, in the clear, from the modem's address: the one exception to encrypted DNS
    # (ARCHITECTURE -> Encrypted DNS). Never waited on beyond DohLookupWaitMs at a time. Returns
    # $true when the addresses changed: the pass sets them at once.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the worker''s in-memory state; a lookup changes nothing.')]
    param([hashtable] $Worker)

    $state = $Worker.DohName
    $settings = $Worker.Settings
    $name = if ($settings) { (Resolve-DohServer -Settings $settings -Resolved $state.Addresses).Name } else { $null }
    if ($name -ne $state.Name) {
        # Another name, or none any more: looked up from scratch.
        Stop-WorkerDohLookup -Worker $Worker
        $state.Name = $name
        $state.Addresses = [string[]]@()
        $state.At = $null
        $state.Via = $null
        $state.Next = $null
        $state.Failure = $null
        $state.Logged = $null
    }
    if (-not $name) {
        return $false
    }
    $now = & $Worker.Clock
    if (-not $state.Lookup) {
        if ($null -ne $state.Next -and $now -lt $state.Next) {
            return $false
        }
        Start-WorkerDohLookup -Worker $Worker
    }
    $result = Receive-WorkerDohLookup -Worker $Worker
    if ($result -and $result.Failure -and $state.Lookup.Via -eq 'Windows') {
        $operator = Get-WorkerOperatorServer -Worker $Worker
        if ($operator) {
            Start-WorkerDohLookup -Worker $Worker -Operator $operator
            $result = Receive-WorkerDohLookup -Worker $Worker
        }
    }
    if (-not $result) {
        return $false
    }
    $via = $state.Lookup.Via
    $state.Lookup = $null
    $state.At = [DateTimeOffset]::Now
    if (@($result.Addresses).Count -gt 0) {
        $changed = (@($result.Addresses) -join ',') -ne (@($state.Addresses) -join ',')
        $state.Addresses = [string[]]@($result.Addresses)
        $state.Via = $via
        $state.Failure = $null
        $state.Logged = $null
        $state.Next = $now + [long]$settings.DohRefreshMinutes * 60000
        $through = if ($via -eq 'Operator') { ' through the operator''s DNS, in the clear' } else { '' }
        Write-WorkerLog -Worker $Worker -Level 'Info' -Message "DoH server's name looked up$($through): $($state.Addresses.Count) address(es)$(if ($changed) { ', new' } else { ', as before' })"
        return $changed
    }
    # Tried again at the pass cadence; the last addresses stay meanwhile. Logged once per cause.
    $state.Failure = $result.Failure
    $state.Next = $now + $script:WorkerIntervals.PassOnline
    if ($state.Logged -ne $result.Failure) {
        $state.Logged = $result.Failure
        Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "DoH server's name can't be looked up ($($result.Failure)); trying again every $($script:WorkerIntervals.PassOnline / 1000) s"
    }
    $false
}

function Get-WorkerOperatorServer {
    # The operator's DNS servers for the context, and the modem's address to ask them from - as
    # the last pass read them -, or nothing.
    param([hashtable] $Worker)

    $facts = $Worker.Facts
    $source = if ($facts -and $facts.PSObject.Properties['ContextAddress']) { [string]$facts.ContextAddress } else { '' }
    $servers = [string[]]@(if ($facts -and $facts.PSObject.Properties['ContextDns']) { $facts.ContextDns | Where-Object { $_ -and $_ -notmatch ':' } })
    if (-not $source -or $servers.Count -eq 0) {
        return
    }
    [pscustomobject]@{ Source = $source; Servers = $servers }
}

function Start-WorkerDohLookup {
    # Starts a lookup of the DoH server's name - through Windows, or with -Operator through the
    # operator's DNS - and waits for it DohLookupWaitMs at most. The simulated adapter answers at
    # once.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the worker''s in-memory state; a lookup changes nothing.')]
    param([hashtable] $Worker, [object] $Operator)

    $state = $Worker.DohName
    $lookup = @{ Via = if ($Operator) { 'Operator' } else { 'Windows' }; Started = & $Worker.Clock; Pending = $null; Result = $null }
    if ($Worker.Simulation) {
        $lookup.Result = $Worker.Simulation.Adapter.Lookup($state.Name, $(if ($Operator) { $Operator.Source } else { '' }))
    }
    else {
        $lookup.Pending = if ($Operator) { Start-DohNameLookup -Name $state.Name -Servers $Operator.Servers -Source $Operator.Source } else { Start-DohNameLookup -Name $state.Name }
        [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($lookup.Pending.Task), $script:DohLookupWaitMs)
    }
    $state.Lookup = $lookup
}

function Receive-WorkerDohLookup {
    # The lookup under way, once it has ended - or failed for want of an answer in
    # DohLookupTimeoutMs; nothing while it runs.
    param([hashtable] $Worker)

    $lookup = $Worker.DohName.Lookup
    if ($lookup.Result) {
        return $lookup.Result
    }
    $result = Receive-DohNameLookup -Lookup $lookup.Pending
    if (-not $result) {
        if ((& $Worker.Clock) - $lookup.Started -lt $script:DohLookupTimeoutMs) {
            return
        }
        Stop-DohNameLookup -Lookup $lookup.Pending
        $result = [pscustomobject]@{ Addresses = [string[]]@(); Failure = 'No answer in time.' }
    }
    $result
}

function Stop-WorkerDohLookup {
    # Drops the lookup under way, if any: its socket closed.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the worker''s in-memory state; closes a socket of its own.')]
    param([hashtable] $Worker)

    $lookup = $Worker.DohName.Lookup
    if ($lookup -and $lookup.Pending) {
        Stop-DohNameLookup -Lookup $lookup.Pending
    }
    $Worker.DohName.Lookup = $null
}

function Get-WorkerUpdateState {
    # The update notice a new worker starts from: the last worker's, or none yet. A request that
    # was under way when that worker ended is never sent again: one attempt per app start.
    param([object] $Previous)

    $update = if ($Previous -and $Previous.PSObject.Properties['Update']) { $Previous.Update } else { $null }
    if (-not $update) {
        return [pscustomobject]@{ Status = 'Pending'; Result = $null; Version = $null; Url = $null; Detail = $null; Time = $null }
    }
    if ($update.Status -eq 'Running') {
        return [pscustomobject]@{ Status = 'Done'; Result = 'Failed'; Version = $null; Url = $null; Detail = 'The monitor restarted during the check.'; Time = [DateTimeOffset]::Now }
    }
    $update
}

function Update-WorkerUpdateCheck {
    # The update notice, at every cycle: sends the one request once the connection is first online
    # and the settings allow it, and takes its answer once it has come - asking the latest
    # release's page once instead when the API refused. Returns $true when the notice changed. A
    # request that can't even be sent counts as the one attempt.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the worker''s in-memory state; the request reads and changes nothing.')]
    param([hashtable] $Worker)

    $done = {
        param($notice)
        $Worker.UpdateCheck = $null
        $Worker.Update = [pscustomobject]@{ Status = 'Done'; Result = $notice.Result; Version = $notice.Version; Url = $notice.Url; Detail = $notice.Detail; Time = [DateTimeOffset]::Now }
        $text = switch ($notice.Result) {
            'Newer' { "version $($notice.Version) is available" }
            'Current' { 'this is the latest release' }
            'NoRelease' { 'no release is published yet' }
            default { "no answer ($($notice.Detail))" }
        }
        Write-WorkerLog -Worker $Worker -Level $(if ($notice.Result -eq 'Failed') { 'Warning' } else { 'Info' }) -Message "Update check: $text"
        $true
    }
    try {
        if ($Worker.UpdateCheck) {
            $notice = Receive-UpdateCheck -Check $Worker.UpdateCheck -Current $Worker.AppVersion
            if (-not $notice) {
                return $false
            }
            if ($notice.Result -ne 'Refused') {
                return & $done $notice
            }
            # Received, so released. The API's limit is per public address, shared with every other
            # client behind it. The page's answer is never 'Refused': it is asked once.
            $Worker.UpdateCheck = $null
            Write-WorkerLog -Worker $Worker -Level Info -Message "Update check: the API refused ($($notice.Detail)); asking the latest release's page"
            $Worker.UpdateCheck = Start-UpdateCheck -Page -Refusal $notice.Detail -Confirm:$false
            return $false
        }
        $settings = $Worker.Settings
        if ($Worker.Update.Status -ne 'Pending' -or -not $Worker.CheckForUpdates -or $Worker.State -ne 'Online' -or -not $settings -or -not $settings.CheckForUpdates) {
            return $false
        }
        $Worker.UpdateCheck = Start-UpdateCheck -Confirm:$false
        $Worker.Update = [pscustomobject]@{ Status = 'Running'; Result = $null; Version = $null; Url = $null; Detail = $null; Time = [DateTimeOffset]::Now }
        $true
    }
    catch {
        if ($Worker.UpdateCheck) {
            Stop-UpdateCheck -Check $Worker.UpdateCheck -Confirm:$false
        }
        & $done ([pscustomobject]@{ Result = 'Failed'; Version = $null; Url = $null; Detail = $_.Exception.Message })
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
    # Another modem may come back on the port, or this one after a reset: what it supports is
    # read again, and a write it refused or didn't keep is tried once more.
    $Worker.NetworkModeSupport = $null
    $Worker.NetworkModeWrite = $null
    # The notices are set again on the next port, and the storage read again through it.
    $Worker.MessagesReady = $false
    $Worker.MessagesDue = $true
    $Worker.Messages = $null
    $Worker.MessageStorage = $null
    $Worker.MessagesFailure = $null
    # The slot, the SIM in use and the eUICC are read again through the next port; until then,
    # nothing is shown.
    Clear-WorkerSim -Worker $Worker
    $Worker.SimSlotRead = $false
    $Worker.SimSlot = $null
    $Worker.SimType = $null
    $Worker.EsimInfo = $null
    $Worker.EsimProfiles = $null
    $Worker.EsimNotifications = $null
    $Worker.EsimDue = $true
    $Worker.LastScan = $null
    $Worker.LastAdapterLook = $null
    Set-WorkerProbeAddress -Worker $Worker -Address $null
    if ($Why) {
        Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "AT port ($($Worker.PortName)) $Why$(if ($reason) { ": $reason" })"
    }
}

function Get-WorkerPresence {
    # The modem as PnP reports it now - or as the simulated device does -, decided by the same
    # pure functions.
    param([hashtable] $Worker)

    $records = if ($Worker.Simulation) { $Worker.Simulation.PnpRecords() } else { Get-ModemPnpRecord }
    Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device @($records))
}

function Get-UsbFunctionLabel {
    # A function as the log names it: its interface, and what it is when known ('MI_06 MdAt').
    param([object] $Function)

    "MI_$(([int]$Function.Interface).ToString('X2', [cultureinfo]::InvariantCulture))$(if ($Function.Name) { " $($Function.Name)" })"
}

function Update-WorkerBinding {
    # Puts the chosen modem's vendor functions on WinUSB (ARCHITECTURE -> USB functions), the AT
    # port first: those Resolve-ModemBinding names, each once per instance. A function whose COM
    # port or device interface another program holds is left on its driver, and looked at again
    # next time (decided 2026-10-04); so is the function whose port the worker holds open, whatever
    # a PnP read says of it. After an installation that timed out, the others of this look aren't
    # started. Nothing in observe-only mode, nothing without administrator rights. Sets the
    # worker's BindState - why the AT port isn't on WinUSB, for the connection's state - and
    # Binding, the last outcome, for the window. Returns $true when a function was put on
    # WinUSB: PnP is read again.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A step of the worker''s cycle: observe-only mode withholds it, and Install-WinUsbDriver, which changes the driver, supports ShouldProcess.')]
    param([hashtable] $Worker, [object] $Presence)

    # The installations a worker this one replaced saw fail, matched now that their functions are found.
    if ($Worker.BindFailedCarried.Count -gt 0) {
        foreach ($function in @($Presence.Functions | Where-Object { $_ })) {
            if ($Worker.BindFailedCarried.Remove((Get-UsbInstanceHash -InstanceId $function.InstanceId))) {
                [void]$Worker.BindFailed.Add($function.InstanceId)
            }
        }
    }
    # The port the worker holds is never given another driver: it is on WinUSB, whatever a read said.
    $open = if ($Worker.Channel) { $Worker.AtInstanceId } else { $null }
    $plan = Resolve-ModemBinding -Function @($Presence.Functions | Where-Object { $_ -and -not ($open -and [string]::Equals([string]$_.InstanceId, $open, 'OrdinalIgnoreCase')) }) -Failed @($Worker.BindFailed)
    $atLeft = @($plan.Left | Where-Object Role -EQ 'AtPort') | Select-Object -First 1
    # The AT port's failure stays said while its instance is the one that failed - whatever PnP shows
    # of it meanwhile (a restart awaited can show as a problem on WinUSB).
    $Worker.BindState = if ($atLeft -and $Worker.BindFailed.Contains($atLeft.InstanceId)) { $Worker.BindAtFailure } else { $null }
    if ($plan.Bind.Count -eq 0) {
        return $false
    }
    if ($Worker.ObserveOnly) {
        # The step the app withholds: the window says so.
        return $false
    }
    if (-not $Worker.Elevated) {
        if (@($plan.Bind | Where-Object Role -EQ 'AtPort').Count -gt 0) {
            $Worker.BindState = 'NotElevated'
        }
        if (-not $Worker.BindNotElevatedLogged) {
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message 'The modem''s functions can''t be put on WinUSB without administrator rights'
            $Worker.BindNotElevatedLogged = $true
        }
        return $false
    }

    $beat = Get-WorkerBeat -Worker $Worker
    $outcomes = [System.Collections.Generic.List[object]]::new()
    $bound = $false
    $timedOut = $false
    foreach ($function in $plan.Bind) {
        $label = Get-UsbFunctionLabel -Function $function
        try {
            $held = if ($Worker.Simulation) {
                $function.PortName -and (Test-Win32Held -Code $Worker.Simulation.TryPort($function.PortName))
            }
            else {
                -not (Test-UsbFunctionFree -InstanceId $function.InstanceId -PortName $function.PortName -InterfaceGuid @($function.InterfaceGuids | Where-Object { $_ })).Free
            }
        }
        catch {
            # Told by its type alone: the text may name the port or the device. Tried once per
            # instance, as an installation that failed: not looked at every few seconds.
            $outcomes.Add([pscustomobject]@{ Interface = $function.Interface; Name = $function.Name; Role = $function.Role; Result = 'Failed'; Step = 'Check'; Error = $null })
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "USB function ${label}: its ports can't be looked at ($($_.Exception.GetType().Name)) - left on its driver"
            [void]$Worker.BindFailed.Add($function.InstanceId)
            if ($function.Role -eq 'AtPort') {
                $Worker.BindAtFailure = 'Failed'
                $Worker.BindState = 'Failed'
            }
            continue
        }
        if ($held) {
            # Never a driver changed under another program: its port stays as it is.
            $outcomes.Add([pscustomobject]@{ Interface = $function.Interface; Name = $function.Name; Role = $function.Role; Result = 'InUse'; Step = $null; Error = $null })
            if ($function.Role -eq 'AtPort') {
                $Worker.BindState = 'InUse'
            }
            if ($Worker.BindHeldLogged.Add($function.InstanceId)) {
                Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "USB function ${label}: another program holds its port - left on its driver"
            }
            continue
        }
        $options = @{ InstanceId = $function.InstanceId; Beat = $beat; Confirm = $false }
        if ($function.Role -eq 'AtPort') {
            $options['InterfaceGuid'] = $script:AppInterfaceGuid
        }
        $result = if ($timedOut) {
            # An installation that hangs holds Windows' others: this one would wait as long, and the
            # worker with it. Not started - counted as failed, tried again as one.
            [pscustomobject]@{ Done = $false; NeedReboot = $false; Step = 'TimedOut'; Error = 0 }
        }
        else {
            try {
                if ($Worker.Simulation) { $Worker.Simulation.Bind($function.InstanceId) } else { Install-WinUsbDriver @options }
            }
            catch {
                [pscustomobject]@{ Done = $false; NeedReboot = $false; Step = $_.Exception.GetType().Name; Error = 0 }
            }
        }
        $timedOut = $timedOut -or $result.Step -eq 'TimedOut'
        # Windows' code as it writes it: a negative one is its 0xE... form.
        $code = if ($result.Error) { '0x' + ([int]$result.Error).ToString('X8', [cultureinfo]::InvariantCulture) } else { $null }
        $outcome = if ($result.Done -and $result.NeedReboot) { 'RestartNeeded' } elseif ($result.Done) { 'Done' } else { 'Failed' }
        $outcomes.Add([pscustomobject]@{ Interface = $function.Interface; Name = $function.Name; Role = $function.Role; Result = $outcome; Step = $result.Step; Error = $code })
        if ($outcome -eq 'Done') {
            $bound = $true
            [void]$Worker.BindHeldLogged.Remove($function.InstanceId)
            Write-WorkerLog -Worker $Worker -Level 'Info' -Message "USB function ${label}: on WinUSB ($($function.Why))"
            if ($function.Role -eq 'AtPort') {
                # A port just started may stay silent for minutes (AT-COMMANDS section 2): an
                # intentional operation, which nothing escalates over - as long as a USB restart's
                # settle time.
                $Worker.Recovery = Open-MaintenanceWindow -History $Worker.Recovery -Now (& $Worker.Clock) -DurationMs $script:RecoveryTimings.Settle['R6']
                $Worker.BindState = $null
                $Worker.BindJustDone = $true
            }
        }
        else {
            # Tried once per instance: again at the next start, at a new instance, when the user
            # asks to check now (decided 2026-10-04), or when the modem comes back (2026-10-05).
            [void]$Worker.BindFailed.Add($function.InstanceId)
            $why = if ($outcome -eq 'RestartNeeded') { 'Windows finishes it at the next restart' } else { "failed at $($result.Step)$(if ($code) { ", error $code" })" }
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "USB function ${label}: not put on WinUSB - $why"
            if ($function.Role -eq 'AtPort') {
                $Worker.BindAtFailure = $outcome
                $Worker.BindState = $outcome
            }
        }
    }
    $Worker.Binding = [pscustomobject]@{ Time = [DateTimeOffset]::Now; Functions = [object[]]$outcomes.ToArray() }
    $bound
}

function Find-WorkerModem {
    # Looks for the modem, puts its vendor functions on WinUSB when they aren't, and opens its AT
    # port when it is there. Every look starts from nothing: the device instance may have changed.
    param([hashtable] $Worker)

    $presence = Get-WorkerPresence -Worker $Worker
    if ($presence.Device -eq 'Absent') {
        # The modem gone - unplugged, reset, its SIM taken out: an installation that failed is tried
        # again when it comes back, whichever of its instances it comes back as (decided 2026-10-05).
        $Worker.BindFailed.Clear()
        $Worker.BindFailedCarried.Clear()
        $Worker.BindAtFailure = $null
    }
    elseif (Update-WorkerBinding -Worker $Worker -Presence $presence) {
        $presence = Get-WorkerPresence -Worker $Worker
    }
    $before = if ($Worker.Presence) { $Worker.Presence.Device } else { $null }
    if ($presence.Device -ne $before) {
        Write-WorkerLog -Worker $Worker -Level 'Info' -Message "Modem: $($presence.Device)"
    }
    $Worker.Presence = $presence
    # The modem's network adapter, whatever its AT port does: data usage is read from it while
    # another program holds the port, or the port isn't on WinUSB.
    $Worker.AdapterInstanceId = $presence.AdapterInstanceId
    if ($presence.Device -ne 'Present') {
        $Worker.PortError = $null
        return
    }

    $portError = $null
    $justBound = $Worker.BindJustDone
    $Worker.BindJustDone = $false
    try {
        $inner = if ($Worker.Simulation) {
            $Worker.Simulation.Open()
        }
        else {
            # The interface of a function just put on WinUSB is there within seconds
            # (AT-COMMANDS section 1.2): waited for, the heartbeat beating.
            $path = $null
            $deadline = [Environment]::TickCount64 + $(if ($justBound) { $script:WorkerInterfaceWaitMs } else { 0 })
            while ($true) {
                $path = @(Get-WinUsbInterfacePath -InstanceId $presence.AtInstanceId) | Select-Object -First 1
                if ($path -or [Environment]::TickCount64 -ge $deadline) {
                    break
                }
                $Worker.Link['Heartbeat'] = [Environment]::TickCount64
                [System.Threading.Thread]::Sleep(250)
            }
            if (-not $path) {
                throw [System.InvalidOperationException]::new('The AT port has no WinUSB interface yet.')
            }
            Open-WinUsbAtTransport -InterfacePath $path
        }
    }
    catch {
        # Another program holding the port is told apart: the user can do something about it.
        $exception = $_.Exception
        $inUse = $false
        while ($exception) {
            if ($exception -is [System.ComponentModel.Win32Exception] -and $exception.NativeErrorCode -in $script:Win32Errors['AccessDenied'], $script:Win32Errors['SharingViolation']) {
                $inUse = $true
            }
            $exception = $exception.InnerException
        }
        $portError = if ($inUse) { 'InUse' } else { 'Failed' }
        if ($portError -ne $Worker.PortError) {
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "AT port can't be opened: $($_.Exception.Message)"
        }
    }
    $Worker.PortError = $portError
    if ($portError) {
        return
    }
    try {
        $Worker.Channel = New-AtChannel -Transport ([WorkerTransport]::new($inner, $Worker.Link, $script:WorkerBeatMs))
    }
    catch {
        # Never a port left open with no channel to close it.
        $inner.Close()
        throw
    }
    $Worker.PortName = $inner.PortName
    $Worker.AtInstanceId = $presence.AtInstanceId
    $Worker.PassForced = $true
    Write-WorkerLog -Worker $Worker -Level 'Info' -Message "AT port open ($($inner.PortName))"
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
    # A network mode the user narrowed, in force on the modem: no network found with it is the
    # mode's doing, which no step mends.
    $mode = if ($Worker.Facts -and $Worker.Facts.PSObject.Properties['NetworkMode']) { $Worker.Facts.NetworkMode } else { $null }
    # Narrowed counts unless the modem is known to have another mode: one read that failed
    # escalates nothing.
    $narrowed = [bool]($mode -and $mode.Narrowed -and $mode.Satisfied -ne $false)
    $recovery = Resolve-RecoveryAction -Now $now @failing -Blocked:$health.Blocked -Unknown:$health.Unknown -History $before `
        -Elevated:$Worker.Elevated -Withhold:$Worker.ObserveOnly -Resumed:$Resumed -NoReset:$noReset -Narrowed:$narrowed
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

function ConvertTo-WorkerSettingTable {
    # Settings - an object or a dictionary - as a hashtable of their values, to change some.
    param([object] $Settings)

    $values = @{}
    if ($Settings -is [System.Collections.IDictionary]) {
        foreach ($key in $Settings.Keys) {
            $values[[string]$key] = $Settings[$key]
        }
    }
    elseif ($null -ne $Settings) {
        foreach ($property in $Settings.PSObject.Properties) {
            $values[$property.Name] = $property.Value
        }
    }
    $values
}

function Get-WorkerSetting {
    # The settings a pass works with: the saved ones, with the network mode on trial in place of
    # the saved one - the pass keeps the modem as the user just chose until the trial ends -, and
    # the DoH template's server as the DNS servers when the settings name none.
    param([hashtable] $Worker)

    $saved = $Worker.Settings
    if (-not $saved) {
        return $saved
    }
    $trial = $Worker.NetworkModeTrial
    # Encrypted DNS without servers of its own: the DoH template's server, as looked up.
    $doh = Resolve-DohServer -Settings $saved -Resolved $Worker.DohName.Addresses
    $named = @($saved.DnsServers).Count -eq 0 -and @($doh.Servers).Count -gt 0
    if (-not $trial -and -not $named) {
        return $saved
    }
    $settings = $saved | Select-Object -Property *
    if ($trial) {
        foreach ($name in $script:NetworkModeSettings) {
            $settings.$name = $trial.Selection.$name
        }
    }
    if ($named) {
        $settings.DnsServers = [string[]]$doh.Servers
    }
    $settings
}

function Get-WorkerSimSetting {
    # The settings of the SIM in use, as the last pass identified it (Resolve-SimSetting's), from
    # the saved ones: what the window shows and saves.
    param([hashtable] $Worker)

    $fingerprint = if ($Worker.Sim) { $Worker.Sim.Fingerprint } else { $null }
    Resolve-SimSetting -Settings $Worker.Settings -SimSettings $Worker.SimSettings -Fingerprint $fingerprint
}

function Test-WorkerApnPassword {
    # Whether an APN password is stored for the SIM in use: its own, or the one saved before the
    # settings were kept for each SIM, which the first SIM identified takes.
    param([hashtable] $Worker)

    if (-not $Worker.Settings) {
        return $false
    }
    $sim = Get-WorkerSimSetting -Worker $Worker
    $sim.Source -in 'Sim', 'Legacy', 'Unknown' -and (Test-Path -LiteralPath (Get-SimApnSecretPath -ApnSecretPath $Worker.Paths.ApnSecret -Id $sim.Id) -PathType Leaf)
}

function Update-WorkerSim {
    # The SIM in use as a pass identified it (Invoke-ModemConnect's Sim): one not read is unknown,
    # never "none". Another SIM gets a new token: the window fills its APN settings again; its
    # messages are read again, whatever changed the SIM - a SIM swapped, a profile switched by
    # another program -: the list shown was the other SIM's. The
    # first SIM identified takes the APN settings saved before they were kept for each SIM
    # (Move-ApnSettingToSim); should that fail, it is tried again at the next pass.
    # A ready SIM whose ICCID can't be read is said in the log, once: its settings are unknown, and
    # the data context is left as it is.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the worker''s in-memory state, and once the app''s own settings files, as decided.')]
    param([hashtable] $Worker, [object] $Sim, [object] $Facts)

    $unread = -not $Sim -and $Facts -and $Facts.SimState -eq 'Ready' -and $Facts.PortOpen -eq $true -and $Facts.Responsive -eq $true
    if ($unread -and -not $Worker.SimUnreadLogged) {
        Write-WorkerLog -Worker $Worker -Level 'Warning' -Message 'SIM in use: its ICCID can''t be read, so its APN settings are not known; the data context is left as it is until it can'
    }
    $Worker.SimUnreadLogged = $unread
    if (-not $Sim) {
        return
    }
    $before = if ($Worker.Sim) { $Worker.Sim.Fingerprint } else { $null }
    $Worker.Sim = $Sim
    if ($Sim.Fingerprint -ne $before) {
        $Worker.SimToken = if ($Sim.Fingerprint) { [guid]::NewGuid().ToString('N') } else { $null }
        Clear-WorkerMessageList -Worker $Worker
        if ($Sim.Fingerprint) {
            $what = switch ($Sim.Source) {
                'Sim' { 'its own APN settings' }
                'New' { 'no APN settings of its own yet: the subscription''s APN' }
                default { 'the APN settings saved before each SIM had its own' }
            }
            Write-WorkerLog -Worker $Worker -Level 'Info' -Message "SIM in use identified: $what"
        }
    }
    if ($Sim.Fingerprint -and $Sim.Source -eq 'Legacy' -and -not $Worker.ObserveOnly) {
        try {
            [void](Move-ApnSettingToSim -Fingerprint $Sim.Fingerprint -SettingsPath $Worker.Paths.Settings -Path $Worker.Paths.SimSettings `
                    -ApnSecretPath $Worker.Paths.ApnSecret -Confirm:$false)
            Write-WorkerLog -Worker $Worker -Level 'Info' -Message 'Settings: the APN settings saved are now the SIM in use''s; each SIM keeps its own'
            $Worker.SimMoveFailure = $null
        }
        catch {
            $failure = $_.Exception.GetType().Name
            if ($failure -ne $Worker.SimMoveFailure) {
                Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Settings: the APN settings saved couldn't be given to the SIM in use ($failure); tried again at the next pass"
            }
            $Worker.SimMoveFailure = $failure
        }
        $read = Import-AppSetting -Path $Worker.Paths.Settings
        $Worker.Settings = $read.Settings
        $Worker.SimSettings = Import-SimSetting -Path $Worker.Paths.SimSettings
        $own = Get-WorkerSimSetting -Worker $Worker
        $Worker.Sim = [pscustomobject]@{ Fingerprint = $Sim.Fingerprint; Id = $own.Id; Source = $own.Source }
    }
    $Worker.ApnPasswordStored = Test-WorkerApnPassword -Worker $Worker
}

function Clear-WorkerSim {
    # The SIM in use is about to change - a slot switched, a profile enabled or disabled -, or the
    # port is gone: none is known until a pass identifies it. The messages shown were the other
    # SIM's: the storage is read again once it is.
    param([hashtable] $Worker)

    $Worker.Sim = $null
    $Worker.SimToken = $null
    Clear-WorkerMessageList -Worker $Worker
}

function Clear-WorkerMessageList {
    # The messages shown were another SIM's: none until the storage is read again, whole.
    param([hashtable] $Worker)

    $Worker.Messages = $null
    $Worker.MessageStorage = $null
    $Worker.MessagesDue = $true
}

function Update-WorkerInboxBeforeSwitch {
    # Before the SIM in use changes - a slot switched, a profile enabled or disabled -, how full
    # the storage is is checked, and the storage read if it changed: a message that came in on the
    # SIM in use is told as its own, not as the next one's.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Reads the storage, as a cycle does.')]
    param([hashtable] $Worker)

    if ($Worker.Sim -and $Worker.Sim.Fingerprint -and $Worker.MessagesReady -and -not $Worker.ObserveOnly -and $Worker.Channel -and $Worker.Channel.State -eq 'Open') {
        [void](Update-WorkerInbox -Worker $Worker)
    }
}

function Save-WorkerNetworkMode {
    # Saves a network mode in the settings file, the other settings as they are saved, and reads
    # them back for the worker.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called only for what the user asked, through the worker''s command or its trial.')]
    param([hashtable] $Worker, [object] $Selection)

    $settings = ConvertTo-WorkerSettingTable -Settings (Import-AppSetting -Path $Worker.Paths.Settings).Settings
    foreach ($name in $script:NetworkModeSettings) {
        $settings[$name] = $Selection.$name
    }
    Export-AppSetting -Settings $settings -Path $Worker.Paths.Settings -Confirm:$false
    $read = Import-AppSetting -Path $Worker.Paths.Settings
    $Worker.Settings = $read.Settings
    $Worker.SettingsProblems = [string[]]@($read.Problems)
    $Worker.SettingsIssues = [object[]]@($read.Issues)
}

function Open-WorkerMaintenanceWindow {
    # A maintenance window - a network mode written, a SIM slot or a profile switched -, in the
    # worker's recovery history and in the view a snapshot carries: published before the cycle
    # ends, it reaches a worker that replaces this one.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the worker''s in-memory state only.')]
    param([hashtable] $Worker, [long] $Now)

    $Worker.Recovery = Open-MaintenanceWindow -History $Worker.Recovery -Now $Now
    $view = if ($Worker.RecoveryView) { $Worker.RecoveryView | Select-Object -Property * } else { [pscustomobject]@{ Status = $null; Check = $null; Step = $null; Cycles = 0; StepTime = $null; NextTime = $null; History = $null } }
    $view.History = $Worker.Recovery
    $Worker.RecoveryView = $view
}

function Undo-WorkerNetworkMode {
    # Writes back the setting the modem had before the first change on trial, each code as read
    # (invariant 9). Returns the modem's answer.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Undoes what the user''s own command wrote.')]
    param([hashtable] $Worker)

    $before = $Worker.NetworkModeTrial.Before
    $command = ConvertTo-AtNetworkModeCommand -Rat $before.Rat -Preferences $before.Preferences -Code $before.Codes
    $answer = Invoke-AtCommand -Channel $Worker.Channel -Command $command
    [pscustomobject]@{ Command = $command; Status = $answer.Status; ErrorCode = $answer.ErrorCode }
}

function Set-WorkerNetworkMode {
    # The SetNetworkMode command: writes the mode the user chose at once and tries it (ARCHITECTURE
    # -> Modes and bands). Returns Result and Detail.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The user''s command, carried out by the worker.')]
    param([hashtable] $Worker, [hashtable] $Parameter)

    $values = ConvertTo-WorkerSettingTable -Settings (Import-AppSetting -Path $Worker.Paths.Settings).Settings
    foreach ($name in $script:NetworkModeSettings) {
        if ($Parameter.ContainsKey($name)) {
            $values[$name] = $Parameter[$name]
        }
    }
    $checked = ConvertTo-AppSetting -InputObject $values
    if ($checked.Problems.Count -gt 0) {
        return [pscustomobject]@{ Result = 'Failed'; Detail = $checked.Problems -join ' ' }
    }
    $selection = $checked.Settings
    $open = $Worker.Channel -and $Worker.Channel.State -eq 'Open'
    $trial = $Worker.NetworkModeTrial
    if (-not $selection.NetworkMode) {
        # The app stops managing it: the modem keeps what it has - but never a mode on trial,
        # which goes back first to the setting known to find a network.
        if ($trial) {
            if ($Worker.ObserveOnly) {
                return [pscustomobject]@{ Result = 'Refused'; Detail = $null }
            }
            if (-not $open) {
                return [pscustomobject]@{ Result = 'NoModem'; Detail = $null }
            }
            $undo = Undo-WorkerNetworkMode -Worker $Worker
            if ($undo.Status -ne 'OK') {
                return [pscustomobject]@{ Result = 'Failed'; Detail = "$($undo.Command) $($undo.Status)" }
            }
            $Worker.NetworkModeNotice = [pscustomobject]@{ Kind = 'Reverted'; Mode = $trial.Selection.NetworkMode; Time = [DateTimeOffset]::Now }
            $Worker.NetworkModeTrial = $null
            Open-WorkerMaintenanceWindow -Worker $Worker -Now (& $Worker.Clock)
            $Worker.PassForced = $true
        }
        Save-WorkerNetworkMode -Worker $Worker -Selection $selection
        return [pscustomobject]@{ Result = 'Done'; Detail = $null }
    }
    if ($Worker.ObserveOnly) {
        return [pscustomobject]@{ Result = 'Refused'; Detail = $null }
    }
    if (-not $open) {
        return [pscustomobject]@{ Result = 'NoModem'; Detail = $null }
    }

    if (-not $Worker.NetworkModeSupport) {
        $test = Invoke-AtCommand -Channel $Worker.Channel -Command 'AT+GTACT=?'
        if ($test.Status -eq 'OK') {
            $Worker.NetworkModeSupport = ConvertFrom-AtNetworkModeSupport -Lines $test.Lines
        }
    }
    $read = Invoke-AtCommand -Channel $Worker.Channel -Command 'AT+GTACT?'
    $current = if ($read.Status -eq 'OK') { ConvertFrom-AtNetworkMode -Lines $read.Lines } else { $null }
    $decision = Resolve-NetworkMode -Settings $selection -Current $current -Support $Worker.NetworkModeSupport -Exact
    if ($decision.Problem) {
        return [pscustomobject]@{ Result = $decision.Problem; Detail = $null }
    }
    if ($null -eq $decision.Satisfied) {
        return [pscustomobject]@{ Result = 'Unknown'; Detail = $null }
    }
    $chosen = [pscustomobject]@{ NetworkMode = $selection.NetworkMode; LteBands = $selection.LteBands; NrBands = $selection.NrBands }
    if ($decision.Satisfied) {
        if ($trial) {
            # The modem has it already, on trial: it is saved once it has found a network.
            $trial.Selection = $chosen
            return [pscustomobject]@{ Result = 'Applied'; Detail = $null }
        }
        Save-WorkerNetworkMode -Worker $Worker -Selection $selection
        return [pscustomobject]@{ Result = 'Unchanged'; Detail = $null }
    }

    $answer = Invoke-AtCommand -Channel $Worker.Channel -Command $decision.Command
    # A write that got no answer may have landed: it is tried as one that did.
    if ($answer.Status -notin 'OK', 'Timeout') {
        return [pscustomobject]@{ Result = 'Failed'; Detail = "$($decision.Command) $($answer.Status)$(if ($null -ne $answer.ErrorCode) { " $($answer.ErrorCode)" })" }
    }
    $now = & $Worker.Clock
    # Undone, it goes back to what the modem had before the first of the changes on trial: the
    # last setting known to find a network.
    $Worker.NetworkModeTrial = [pscustomobject]@{
        Selection = $chosen
        Command   = $decision.Command
        Before    = if ($trial) { $trial.Before } else { $current }
        Since     = $now
        Until     = [DateTimeOffset]::Now.AddMilliseconds($script:RecoveryTimings.Maintenance)
        # When it may be tried again to save or undo it, after an attempt that failed.
        NextTry   = $null
        Failed    = $null
    }
    $Worker.NetworkModeWrite = [pscustomobject]@{ Command = $decision.Command; Before = $current.Text; Status = $answer.Status }
    # It registers the modem again: an intentional operation, which nothing escalates over.
    Open-WorkerMaintenanceWindow -Worker $Worker -Now $now
    [pscustomobject]@{ Result = 'Applied'; Detail = "$($decision.Command)$(if ($answer.Status -ne 'OK') { " $($answer.Status)" })" }
}

function Get-WorkerTrialWake {
    # When the trial of a network mode needs the worker next, by the clock: the end of its window,
    # or the next attempt after one that failed. None while the port is closed: undoing it waits
    # for the modem, and the look for it wakes the worker.
    param([hashtable] $Worker)

    $trial = $Worker.NetworkModeTrial
    if (-not $trial -or -not $Worker.Channel) {
        return $null
    }
    $at = $trial.Since + $script:RecoveryTimings.Maintenance
    if ($null -ne $trial.NextTry -and $trial.NextTry -gt $at) {
        $at = $trial.NextTry
    }
    $at
}

function Invoke-WorkerNetworkModeTrial {
    # Ends the trial of a network mode the user chose, once the modem registered with it in force
    # (saved) or found no network by the end of its window (the setting before written back).
    # Returns $true when something changed.
    param([hashtable] $Worker)

    $trial = $Worker.NetworkModeTrial
    $now = & $Worker.Clock
    if (-not $trial -or ($null -ne $trial.NextTry -and $now -lt $trial.NextTry)) {
        return $false
    }
    $facts = $Worker.Facts
    $registered = if ($facts -and $facts.PSObject.Properties['Registered']) { $facts.Registered } else { $null }
    $inForce = if ($facts -and $facts.PSObject.Properties['NetworkMode'] -and $facts.NetworkMode) { $facts.NetworkMode.Satisfied } else { $null }
    $readAt = if ($facts) { $Worker.LastPass } else { $null }
    $decision = Resolve-NetworkModeTrial -Trial $trial -Registered $registered -InForce $inForce -ReadAt $readAt -Now $now
    $mode = $trial.Selection.NetworkMode
    $failed = {
        param($what, $message)
        # Tried again a pass later; said once.
        $trial.NextTry = $now + $script:WorkerIntervals.PassWorking
        if ($trial.Failed -ne $what) {
            $trial.Failed = $what
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Network mode ${mode}: $message"
        }
    }
    switch ($decision.Action) {
        'Confirm' {
            # Kept on trial until it is saved: an unsaved mode would be undone by the next pass.
            try {
                Save-WorkerNetworkMode -Worker $Worker -Selection $trial.Selection
            }
            catch {
                & $failed 'Save' "registered with it, but the settings can't be saved: $($_.Exception.Message)"
                return $false
            }
            $Worker.NetworkModeTrial = $null
            $Worker.NetworkModeNotice = [pscustomobject]@{ Kind = 'Kept'; Mode = $mode; Time = [DateTimeOffset]::Now }
            Write-WorkerLog -Worker $Worker -Level 'Info' -Message "Network mode ${mode}: registered with it - saved"
            return $true
        }
        'Revert' {
            if (-not $Worker.Channel -or $Worker.Channel.State -ne 'Open') {
                # Undone once the modem is back.
                return $false
            }
            $undo = Undo-WorkerNetworkMode -Worker $Worker
            # The modem is given its window again, written back or not.
            Open-WorkerMaintenanceWindow -Worker $Worker -Now $now
            $minutes = [Math]::Round($script:RecoveryTimings.Maintenance / 60000)
            if ($undo.Status -ne 'OK') {
                # Not undone until the modem says so: the trial stays, and is undone again.
                & $failed $undo.Status "no network in $minutes min, and the setting before can't be written back yet: $($undo.Command) $($undo.Status)"
                return $true
            }
            $Worker.NetworkModeTrial = $null
            $Worker.NetworkModeNotice = [pscustomobject]@{ Kind = 'Reverted'; Mode = $mode; Time = [DateTimeOffset]::Now }
            $Worker.PassForced = $true
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Network mode ${mode}: no network in $minutes min - the setting before is written back: $($undo.Command) OK"
            return $true
        }
    }
    $false
}
function Get-WorkerBeat {
    # What a long wait runs about once a second, so that the supervisor never takes the worker
    # for hung: the heartbeat.
    param([hashtable] $Worker)

    $link = $Worker.Link
    { $link['Heartbeat'] = [Environment]::TickCount64 }.GetNewClosure()
}

function Test-WorkerLpac {
    # Whether lpac can run: the simulated device's always, the app's when it was installed with it.
    param([hashtable] $Worker)

    [bool]($Worker.Simulation -or (Test-Path -LiteralPath (Get-LpacPath) -PathType Leaf))
}

function Test-WorkerEuiccInUse {
    # Whether the eUICC is the SIM in use: lpac reaches it only then (AT-COMMANDS section 8).
    param([hashtable] $Worker)

    $Worker.SimType -eq 'Esim' -or ($null -eq $Worker.SimType -and $Worker.SimSlot -eq 1)
}

function Invoke-WorkerLpac {
    # Runs lpac for one operation, on the worker's AT channel (Invoke-LpacOperation): the
    # simulated device's lpac in development mode, the app's own otherwise. Returns the run.
    param([hashtable] $Worker, [string] $Operation, [hashtable] $Option = @{})

    # The worker is ending: no run starts, and one under way stops - its channels closed - well
    # within the time the app waits for the worker.
    $link = $Worker.Link
    $stop = { [bool]$link['Stop'] }.GetNewClosure()
    if (& $stop) {
        return [pscustomobject]@{ Outcome = 'Stopped'; Code = $null; Message = $null; Data = $null; Steps = [string[]]@(); Requests = 0; HttpRequests = 0; HttpFailure = $null; ElapsedMs = 0 }
    }
    $arguments = Get-LpacArgument -Operation $Operation @Option
    $lpac = if ($Worker.Simulation) { $Worker.Simulation.StartLpac($arguments) } else { Start-LpacProcess -Argument $arguments -Confirm:$false }
    $timeout = if ($Operation -eq 'DownloadProfile') { $script:EsimTimeoutMs.Download } else { $script:EsimTimeoutMs.Other }
    Invoke-LpacOperation -Channel $Worker.Channel -Lpac $lpac -TimeoutMs $timeout -Beat (Get-WorkerBeat -Worker $Worker) -Stop $stop
}

function Get-WorkerLpacFailure {
    # What went wrong in a run of lpac, in a few words for the log and the window: its outcome,
    # or the step that failed and lpac's reason - and the last request for the network that
    # failed, with its host. $null when it succeeded.
    param([object] $Run)

    $network = if ($Run.PSObject.Properties['HttpFailure'] -and $Run.HttpFailure) { " (HTTPS: $($Run.HttpFailure))" } else { '' }
    if ($Run.Outcome -ne 'Done') {
        return "$($Run.Outcome)$network"
    }
    if ($Run.Code -ne 0) {
        return "$($Run.Message)$(if ($Run.Data -is [string] -and $Run.Data) { ": $($Run.Data)" })$network"
    }
    $null
}

function Update-WorkerSimSlot {
    # Reads the SIM slot in use and the kind of SIM in it: once per port, after a switch, and at
    # the user's request. A read the modem left unanswered is tried again at the next pass; one
    # it refused, with the next port.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Reads the modem; changes the worker''s in-memory state only.')]
    param([hashtable] $Worker)

    $before = "$($Worker.SimSlot)/$($Worker.SimType)"
    $answer = Invoke-AtCommand -Channel $Worker.Channel -Command 'AT+GTDUALSIM?'
    $Worker.SimSlotRead = $answer.Status -notin 'Timeout', 'PortLost'
    $slot = ConvertFrom-AtSimSlot -Lines $answer.Lines
    $Worker.SimSlot = if ($slot) { $slot.Slot } else { $null }
    $Worker.SimType = if ($Worker.Channel.State -eq 'Open') { ConvertFrom-AtSimType -Lines (Invoke-AtCommand -Channel $Worker.Channel -Command 'AT+SIMTYPE?').Lines } else { $null }
    if ("$($Worker.SimSlot)/$($Worker.SimType)" -ne $before) {
        Write-WorkerLog -Worker $Worker -Level 'Info' -Message "SIM slot $(if ($null -ne $Worker.SimSlot) { $Worker.SimSlot } else { 'unknown' })$(if ($Worker.SimType) { ", $($Worker.SimType)" })"
    }
}

function Update-WorkerEsim {
    # Reads the eUICC through lpac - its facts, its profiles, its pending notifications - and
    # sends those notifications, once per read (never in observe-only mode: sending them changes
    # the eUICC). Runs when a read is due and the eUICC is the SIM in use, its SIM ready or with
    # no profile enabled. A read that fails is logged once, and waits for the next reason to read.
    # Returns $true when something changed.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Reads the eUICC; sends its notifications, as SGP.22 asks of an LPA, outside observe-only mode.')]
    param([hashtable] $Worker)

    $Worker.EsimDue = $false
    $failures = [System.Collections.Generic.List[string]]::new()
    $info = Invoke-WorkerLpac -Worker $Worker -Operation ChipInfo
    $why = Get-WorkerLpacFailure -Run $info
    if (-not $why) {
        $Worker.EsimInfo = ConvertFrom-LpacChipInfo -Data $info.Data
    }
    else {
        $failures.Add("chip info: $why")
    }
    if ($Worker.Channel -and $Worker.Channel.State -eq 'Open') {
        $list = Invoke-WorkerLpac -Worker $Worker -Operation ProfileList
        $why = Get-WorkerLpacFailure -Run $list
        if (-not $why) {
            $Worker.EsimProfiles = [object[]]@(ConvertFrom-LpacProfileList -Data $list.Data)
        }
        else {
            $failures.Add("profile list: $why")
        }
    }
    if ($Worker.Channel -and $Worker.Channel.State -eq 'Open') {
        Update-WorkerEsimNotification -Worker $Worker -Failures $failures
    }
    $Worker.EsimReadAt = [DateTimeOffset]::Now
    $failure = if ($failures.Count -gt 0) { $failures -join '; ' } else { $null }
    if ($failure -and $failure -ne $Worker.EsimFailure) {
        Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "eSIM: $failure"
    }
    elseif (-not $failure -and $Worker.EsimFailure) {
        Write-WorkerLog -Worker $Worker -Level 'Info' -Message 'eSIM: read again'
    }
    $Worker.EsimFailure = $failure
    $true
}

function Update-WorkerEsimNotification {
    # Lists the eUICC's pending notifications and sends them - each to its server, then removed
    # from the eUICC (AT-COMMANDS section 8) -, never in observe-only mode. What can't be sent
    # stays, and goes at the next read.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sends the eUICC''s notifications, as SGP.22 asks of an LPA, outside observe-only mode.')]
    param([hashtable] $Worker, [System.Collections.Generic.List[string]] $Failures)

    $list = Invoke-WorkerLpac -Worker $Worker -Operation ListNotifications
    $why = Get-WorkerLpacFailure -Run $list
    if ($why) {
        $Failures.Add("notification list: $why")
        return
    }
    $Worker.EsimNotifications = [object[]]@(ConvertFrom-LpacNotificationList -Data $list.Data)
    if ($Worker.EsimNotifications.Count -eq 0 -or $Worker.ObserveOnly -or -not $Worker.Channel -or $Worker.Channel.State -ne 'Open') {
        return
    }
    $sent = Invoke-WorkerLpac -Worker $Worker -Operation ProcessNotifications
    $why = Get-WorkerLpacFailure -Run $sent
    if ($why) {
        $Failures.Add("notifications not sent: $why")
    }
    else {
        Write-WorkerLog -Worker $Worker -Level 'Info' -Message "eSIM: $($Worker.EsimNotifications.Count) notification(s) sent"
    }
    if ($Worker.Channel -and $Worker.Channel.State -eq 'Open') {
        $again = Invoke-WorkerLpac -Worker $Worker -Operation ListNotifications
        if (-not (Get-WorkerLpacFailure -Run $again)) {
            $Worker.EsimNotifications = [object[]]@(ConvertFrom-LpacNotificationList -Data $again.Data)
        }
    }
}

function Get-WorkerEsimView {
    # The eSIM as a snapshot shows it: the slot in use and the kind of SIM, whether lpac and
    # ZXing.Net are there, the eUICC's EID - the window shows it, with Copy (decided 2026-10-04);
    # never logged - and its facts and profiles as read last - no ICCID -, how many notifications
    # wait, when it was read, the command under way and the last read's failure.
    param([hashtable] $Worker)

    $info = $Worker.EsimInfo
    # Not an if expression: it would unroll an eUICC's empty list into none read.
    $profiles = $null
    if ($null -ne $Worker.EsimProfiles) {
        $profiles = [object[]]@($Worker.EsimProfiles | ForEach-Object { [pscustomobject]@{ Aid = $_.Aid; State = $_.State; Nickname = $_.Nickname; Provider = $_.Provider; Name = $_.Name; Class = $_.Class } })
    }
    [pscustomobject]@{
        Slot           = $Worker.SimSlot
        SimType        = $Worker.SimType
        LpacAvailable  = Test-WorkerLpac -Worker $Worker
        QrAvailable    = Test-Path -LiteralPath (Get-ZxingPath) -PathType Leaf
        Eid            = if ($info) { $info.Eid } else { $null }
        Specification  = if ($info) { $info.Specification } else { $null }
        Firmware       = if ($info) { $info.Firmware } else { $null }
        FreeMemory     = if ($info) { $info.FreeMemory } else { $null }
        DefaultAddress = if ($info) { $info.DefaultAddress } else { $null }
        Profiles       = $profiles

        Notifications  = if ($null -ne $Worker.EsimNotifications) { @($Worker.EsimNotifications).Count } else { $null }
        ReadAt         = $Worker.EsimReadAt
        Operation      = $Worker.EsimOperation
        Failure        = $Worker.EsimFailure
    }
}

function ConvertFrom-WorkerSecret {
    # A command's secret as text, for the one call that needs it: a SecureString's, a string's,
    # or '' for none.
    param([object] $Value)

    if ($Value -is [securestring]) {
        return [System.Net.NetworkCredential]::new('', $Value).Password
    }
    if ($Value -is [string]) {
        return $Value
    }
    ''
}

function Invoke-WorkerEsimCommand {
    # The eSIM commands (Send-ModemCommand). Returns Result and Detail; never the activation code.
    # A download's code is typed (ActivationCode) or read from the image of its QR code (QrImage).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The user''s command, carried out by the worker.')]
    param([hashtable] $Worker, [string] $Kind, [hashtable] $Parameter)

    $outcome = { param($result, $detail) [pscustomobject]@{ Result = $result; Detail = $detail } }
    if ($Kind -eq 'SelectSimSlot') {
        $slot = [int]$Parameter['Slot']
        if ($slot -notin 0, 1) {
            return & $outcome 'Failed' "no slot $slot"
        }
        if ($Worker.NetworkModeTrial) {
            return & $outcome 'TrialOn' $null
        }
        if (-not $Worker.SimSlotRead) {
            Update-WorkerSimSlot -Worker $Worker
        }
        if ($Worker.SimSlot -eq $slot) {
            return & $outcome 'Unchanged' $null
        }
        Update-WorkerInboxBeforeSwitch -Worker $Worker
        $answer = Invoke-AtCommand -Channel $Worker.Channel -Command "AT+GTDUALSIM=$slot"
        $failure = if ($answer.Status -ne 'OK') { "AT+GTDUALSIM=$slot $($answer.Status)$(if ($null -ne $answer.ErrorCode) { " $($answer.ErrorCode)" })" } else { $null }
        if ($failure -and $answer.Status -notin 'Timeout', 'PortLost') {
            return & $outcome 'Failed' $failure
        }
        # The SIM changes: service drops, the SIM is read again - an intentional operation, which
        # nothing escalates over. A write left unanswered may have switched too, as a network
        # mode's may. The eUICC is read again once the slot says it is in use.
        Open-WorkerMaintenanceWindow -Worker $Worker -Now (& $Worker.Clock)
        Clear-WorkerSim -Worker $Worker
        $Worker.SimSlotRead = $false
        $Worker.EsimInfo = $null
        $Worker.EsimProfiles = $null
        $Worker.EsimNotifications = $null
        $Worker.EsimDue = $true
        return & $outcome $(if ($failure) { 'Failed' } else { 'Done' }) $failure
    }

    if (-not (Test-WorkerLpac -Worker $Worker)) {
        return & $outcome 'NoLpac' $null
    }
    # Read again at the user's request: the slot too.
    if (-not $Worker.SimSlotRead -or $Kind -eq 'ReadEsim') {
        Update-WorkerSimSlot -Worker $Worker
    }
    if (-not (Test-WorkerEuiccInUse -Worker $Worker)) {
        return & $outcome 'NotEuicc' $null
    }
    if ($Kind -eq 'ReadEsim') {
        [void](Update-WorkerEsim -Worker $Worker)
        return & $outcome $(if ($Worker.EsimFailure) { 'Failed' } else { 'Done' }) $Worker.EsimFailure
    }
    if ($Kind -in 'EnableProfile', 'DisableProfile' -and $Worker.NetworkModeTrial) {
        return & $outcome 'TrialOn' $null
    }

    $run = $null
    switch ($Kind) {
        'DownloadProfile' {
            $text = ConvertFrom-WorkerSecret -Value $Parameter['ActivationCode']
            $image = [string]$Parameter['QrImage']
            if ($image) {
                $read = Read-QrCode -Path $image
                if ($read.Problem) {
                    return & $outcome 'NoQrCode' $read.Problem
                }
                $text = $read.Text
            }
            $code = ConvertFrom-EsimActivationCode -Text $text
            if ($code.Problem) {
                return & $outcome 'BadCode' $code.Problem
            }
            $confirmation = ConvertFrom-WorkerSecret -Value $Parameter['ConfirmationCode']
            if ($code.ConfirmationRequired -and -not $confirmation) {
                return & $outcome 'ConfirmationNeeded' $null
            }
            $run = Invoke-WorkerLpac -Worker $Worker -Operation DownloadProfile -Option @{ ActivationCode = $code.Code; ConfirmationCode = $confirmation }
        }
        default {
            $aid = [string]$Parameter['Aid']
            $chosen = @($Worker.EsimProfiles | Where-Object { $_ -and $_.Aid -eq $aid }) | Select-Object -First 1
            if (-not $chosen) {
                return & $outcome 'UnknownProfile' $null
            }
            switch ($Kind) {
                'EnableProfile' {
                    if ($chosen.State -eq 'Enabled') {
                        return & $outcome 'Unchanged' $null
                    }
                    Update-WorkerInboxBeforeSwitch -Worker $Worker
                    $run = Invoke-WorkerLpac -Worker $Worker -Operation EnableProfile -Option @{ ProfileId = $aid }
                }
                'DisableProfile' {
                    if ($chosen.State -ne 'Enabled') {
                        return & $outcome 'Unchanged' $null
                    }
                    Update-WorkerInboxBeforeSwitch -Worker $Worker
                    $run = Invoke-WorkerLpac -Worker $Worker -Operation DisableProfile -Option @{ ProfileId = $aid }
                }
                'DeleteProfile' {
                    if ($chosen.State -eq 'Enabled') {
                        return & $outcome 'ProfileEnabled' $null
                    }
                    $run = Invoke-WorkerLpac -Worker $Worker -Operation DeleteProfile -Option @{ ProfileId = $aid }
                }
                'SetProfileNickname' {
                    if (-not $chosen.Iccid) {
                        return & $outcome 'UnknownProfile' $null
                    }
                    $run = Invoke-WorkerLpac -Worker $Worker -Operation SetNickname -Option @{ ProfileId = $chosen.Iccid; Nickname = [string]$Parameter['Nickname'] }
                }
            }
        }
    }
    $Worker.EsimDue = $true
    $why = Get-WorkerLpacFailure -Run $run
    if ($Kind -in 'EnableProfile', 'DisableProfile') {
        # The SIM resets with the switch: service drops, the SIM is read again - an intentional
        # operation, which nothing escalates over. A run that failed may have switched too: an
        # APDU answered too late fails lpac's run, not the eUICC's switch.
        Open-WorkerMaintenanceWindow -Worker $Worker -Now (& $Worker.Clock)
        Clear-WorkerSim -Worker $Worker
        $Worker.PassForced = $true
    }
    if ($why) {
        return & $outcome $(if ($run.Outcome -eq 'Timeout') { 'Timeout' } else { 'Failed' }) $why
    }
    if ($Kind -eq 'DeleteProfile' -and $chosen.Iccid) {
        # Its messages may stay in the slot's storage (AT-COMMANDS section 9): they show with its
        # name as it was last.
        Update-WorkerSmsOwner -Worker $Worker -Sim (Get-SimSettingFingerprint -Iccid $chosen.Iccid) -Name (Get-WorkerEsimProfileName -Entry $chosen)
        # Nothing else of a deleted profile is kept: its APN settings neither.
        try {
            Remove-SimSetting -Fingerprint (Get-SimSettingFingerprint -Iccid $chosen.Iccid) -Path $Worker.Paths.SimSettings -ApnSecretPath $Worker.Paths.ApnSecret -Confirm:$false
        }
        catch {
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Settings: the deleted profile's APN settings couldn't be forgotten ($($_.Exception.GetType().Name))"
        }
        $Worker.SimSettings = Import-SimSetting -Path $Worker.Paths.SimSettings
    }
    & $outcome 'Done' $null
}

function Update-WorkerStartAtLogon {
    # Reads whether the app starts at sign-in: the simulated device's task in development mode,
    # the installer's otherwise. A read that fails says nothing is known.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the worker''s in-memory state; reads only.')]
    param([hashtable] $Worker)

    $Worker.StartAtLogonRead = $true
    $Worker.StartAtLogon = if ($Worker.Simulation) {
        Get-SimulatedLogonTask -Worker $Worker
    }
    else {
        try {
            Get-AppLogonTask
        }
        catch {
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "The start at sign-in can't be read: $($_.Exception.Message)"
            $null
        }
    }
}

function Get-SimulatedLogonTask {
    # The simulated device's logon task; none for a device that plays no installed app.
    param([hashtable] $Worker)

    if ($Worker.Simulation.PSObject.Properties['LogonTask']) { $Worker.Simulation.LogonTask } else { $null }
}

function Set-WorkerStartAtLogon {
    # The user's SetStartAtLogon: the installer's logon task turned on or off - never created:
    # 'NoTask' when the app is not installed. Returns 'Enabled', 'Disabled' or 'NoTask'.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The user''s command; Set-AppLogonTask, which it calls, supports ShouldProcess.')]
    param([hashtable] $Worker, [bool] $Enabled)

    try {
        $current = if ($Worker.Simulation) { Get-SimulatedLogonTask -Worker $Worker } else { Get-AppLogonTask }
        if ($null -eq $current) {
            return 'NoTask'
        }
        if ($Worker.Simulation) {
            $Worker.Simulation.LogonTask = $Enabled
        }
        else {
            Set-AppLogonTask -Enabled $Enabled -Confirm:$false
        }
        if ($Enabled) { 'Enabled' } else { 'Disabled' }
    }
    finally {
        Update-WorkerStartAtLogon -Worker $Worker
    }
}

function Invoke-WorkerCommand {
    # Carries out one of the user's commands; returns its outcome for the snapshot. Never logs or
    # returns a secret.
    param([hashtable] $Worker, [object] $Command)

    $parameter = if ($Command.Parameter) { $Command.Parameter } else { @{} }
    $result = 'Done'
    $detail = $null
    $attemptsLeft = $null
    $parts = $null
    $channelOpen = $Worker.Channel -and $Worker.Channel.State -eq 'Open'
    $writes = $Command.Kind -in @('DisableSimPin', 'UnlockFcc', 'EnableAdapter', 'SetStartAtLogon', 'DeleteMessage', 'SendMessage', 'SelectSimSlot', 'EnableProfile', 'DisableProfile',
        'SetProfileNickname', 'DeleteProfile', 'DownloadProfile')
    try {
        if ($writes -and $Worker.ObserveOnly) {
            $result = 'Refused'
        }
        elseif ($Command.Kind -eq 'SetStartAtLogon' -and -not $Worker.Elevated) {
            $result = 'NotElevated'
        }
        elseif ($Command.Kind -in @('SaveSimPin', 'DisableSimPin', 'UnlockFcc', 'DeleteMessage', 'SendMessage') + $script:EsimCommandKinds -and -not $channelOpen) {
            $result = 'NoModem'
        }
        elseif ($Command.Kind -in 'DeleteMessage', 'SendMessage' -and -not (Test-WorkerSimReady -Worker $Worker)) {
            $result = 'NotReady'
        }
        else {
            switch ($Command.Kind) {
                'ConnectNow' {
                    # A function whose installation failed is tried again (decided 2026-10-04).
                    $Worker.BindFailed.Clear()
                    $Worker.BindFailedCarried.Clear()
                    $Worker.BindAtFailure = $null
                    $Worker.BindDue = $true
                    $Worker.LastScan = $null
                }
                'SaveSettings' {
                    # The network mode stays as saved: SetNetworkMode sets it, and saves it only
                    # once the modem has found a network with it.
                    $settings = ConvertTo-WorkerSettingTable -Settings $parameter['Settings']
                    $saved = (Import-AppSetting -Path $Worker.Paths.Settings).Settings
                    foreach ($name in $script:NetworkModeSettings) {
                        $settings[$name] = $saved.$name
                    }
                    # The APN settings are the SIM in use's (ARCHITECTURE -> Settings and logs),
                    # saved only for the SIM the window showed them for: with none, or another
                    # one since, nothing is saved.
                    $own = Get-WorkerSimSetting -Worker $Worker
                    foreach ($name in $script:SimSettingNames) {
                        # Left out: kept as they are.
                        if (-not $settings.ContainsKey($name)) {
                            $settings[$name] = $own.Settings.$name
                        }
                    }
                    $changed = $parameter.ContainsKey('ApnPassword') -or
                    @($script:SimSettingNames | Where-Object { [string]$settings[$_] -cne [string]$own.Settings.$_ }).Count -gt 0
                    # Everything checked before the first write: nothing is half saved.
                    $checked = ConvertTo-AppSetting -InputObject $settings
                    if ($checked.Problems.Count -gt 0) {
                        throw [System.ArgumentException]::new("Settings not saved: $($checked.Problems -join ' ')", 'Settings')
                    }
                    $password = $parameter['ApnPassword']
                    if ($password -and $password.Length -gt 0 -and -not (Test-AtStringValue -Value ([System.Net.NetworkCredential]::new('', $password).Password))) {
                        throw [System.ArgumentException]::new('The APN password must be printable ASCII without double quotes.', 'ApnPassword')
                    }
                    if ($changed -and $own.Source -eq 'Unknown') {
                        $result = 'NoSim'
                    }
                    elseif ($changed -and [string]$parameter['SimToken'] -ne [string]$Worker.SimToken) {
                        $result = 'SimChanged'
                    }
                    else {
                        try {
                            $secret = $Worker.Paths.ApnSecret
                            if ($changed) {
                                if ($own.Source -eq 'Legacy') {
                                    [void](Move-ApnSettingToSim -Fingerprint $Worker.Sim.Fingerprint -SettingsPath $Worker.Paths.Settings -Path $Worker.Paths.SimSettings `
                                            -ApnSecretPath $Worker.Paths.ApnSecret -Confirm:$false)
                                }
                                $entry = Save-SimSetting -Fingerprint $Worker.Sim.Fingerprint -Setting $settings -Path $Worker.Paths.SimSettings -Confirm:$false
                                $secret = Get-SimApnSecretPath -ApnSecretPath $Worker.Paths.ApnSecret -Id $entry.Id
                            }
                            # Once each SIM keeps its own, the settings file's are no SIM's.
                            if (Test-Path -LiteralPath $Worker.Paths.SimSettings -PathType Leaf) {
                                foreach ($name in $script:SimSettingNames) {
                                    $settings[$name] = $script:DefaultSettings[$name]
                                }
                            }
                            Export-AppSetting -Settings $settings -Path $Worker.Paths.Settings -Confirm:$false
                            if ($parameter.ContainsKey('ApnPassword')) {
                                if ($password -and $password.Length -gt 0) {
                                    Save-ApnPassword -Password $password -Path $secret -Confirm:$false
                                }
                                else {
                                    Remove-ApnPassword -Path $secret -Confirm:$false
                                }
                            }
                            # The cycle and the quota may have changed: usage is measured again at once.
                            $Worker.LastUsage = $null
                        }
                        finally {
                            # Read again whatever was written, even part of it.
                            $Worker.Settings = $null
                        }
                    }
                }
                'SetNetworkMode' {
                    $outcome = Set-WorkerNetworkMode -Worker $Worker -Parameter $parameter
                    $result = $outcome.Result
                    $detail = $outcome.Detail
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
                'SetStartAtLogon' {
                    $result = Set-WorkerStartAtLogon -Worker $Worker -Enabled ([bool]$parameter['Enabled'])
                }
                'OpenMessage' {
                    # Only the app's own record changes: the modem marked it read already. The
                    # record is read first when no listing has read it yet.
                    Import-WorkerSmsUnread -Worker $Worker
                    $opened = [string[]]@($parameter['Fingerprints'])
                    $left = [string[]]@($Worker.SmsUnread | Where-Object { $_ -notin $opened })
                    if ($left.Count -ne @($Worker.SmsUnread).Count) {
                        $Worker.SmsUnread = $left
                        Save-WorkerSmsUnread -Worker $Worker
                    }
                }
                'DeleteMessage' {
                    $outcome = Remove-WorkerMessage -Worker $Worker -Fingerprint ([string[]]@($parameter['Fingerprints']))
                    $result = $outcome.Result
                    $detail = $outcome.Detail
                    $Worker.MessagesDue = $true
                }
                { $_ -in $script:EsimCommandKinds } {
                    $outcome = Invoke-WorkerEsimCommand -Worker $Worker -Kind $Command.Kind -Parameter $parameter
                    $result = $outcome.Result
                    $detail = $outcome.Detail
                }
                'SendMessage' {
                    $outcome = Send-WorkerMessage -Worker $Worker -Number ([string]$parameter['Number']) -Text ([string]$parameter['Text'])
                    $result = $outcome.Result
                    $detail = $outcome.Detail
                    $parts = [pscustomobject]@{ Sent = $outcome.Sent; Count = $outcome.Parts }
                }
                default {
                    $result = 'Unknown'
                }
            }
        }
    }
    catch {
        $result = 'Failed'
        # A message's number or text, an activation code, may be in the error's text: its type
        # only, then.
        $detail = if ($Command.Kind -in @($script:MessageCommandKinds) + 'DownloadProfile') { $_.Exception.GetType().Name } else { $_.Exception.Message }
    }
    $outcome = [pscustomobject]@{
        Id           = $Command.Id
        Kind         = $Command.Kind
        Result       = $result
        Detail       = $detail
        AttemptsLeft = $attemptsLeft
        Parts        = $parts
        Time         = [DateTimeOffset]::Now
    }
    $level = if ($result -in 'Done', 'Disabled', 'Enabled', 'AlreadyOff', 'Restarted', 'NotLocked', 'Sent', 'Unchanged') { 'Info' } else { 'Warning' }
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
        when due; reads the messages when they may have changed; decides on recovery (Resolve-HealthCheck, Resolve-RecoveryAction) and takes
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
            -ProbeNotBefore $probe.NotBefore -RecoveryAt $Worker.RecoveryAt `
            -TrialAt (Get-WorkerTrialWake -Worker $Worker) `
            -UsageWanted:([bool]($Worker.Simulation -or $Worker.AdapterInstanceId)) -LastUsage $Worker.LastUsage
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

    if (-not $Worker.StartAtLogonRead) {
        Update-WorkerStartAtLogon -Worker $Worker
    }
    if ($null -eq $Worker.Settings) {
        $read = Import-AppSetting -Path $Worker.Paths.Settings
        $Worker.Settings = $read.Settings
        $Worker.SimSettings = Import-SimSetting -Path $Worker.Paths.SimSettings
        $Worker.SettingsProblems = [string[]]@($read.Problems)
        $Worker.SettingsIssues = [object[]]@($read.Issues)
        foreach ($problem in $read.Problems) {
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Settings: $problem"
        }
        $Worker.ApnPasswordStored = Test-WorkerApnPassword -Worker $Worker
        $Worker.PinStored = [bool](Get-SimPin -Path $Worker.Paths.SimPin)
    }

    # The user's commands.
    $command = $null
    while ($link['Commands'].TryDequeue([ref]$command)) {
        if ($command.Kind -eq 'SendMessage') {
            # A message's parts can take a minute each: the window says it is going out.
            $Worker.MessageOperation = 'Sending'
            & $publish
        }
        if ($command.Kind -in $script:EsimCommandKinds) {
            # lpac talks to the eUICC, and a download to the operator's server: the window says so.
            $Worker.EsimOperation = $command.Kind
            & $publish
        }
        $Worker.Results.Add((Invoke-WorkerCommand -Worker $Worker -Command $command))
        $Worker.MessageOperation = $null
        $Worker.EsimOperation = $null
        if ($command.Kind -in 'SetNetworkMode', 'SelectSimSlot', 'EnableProfile', 'DisableProfile') {
            # A mode on trial, a switch's maintenance window, are published at once, with its maintenance window: should the rest
            # of the cycle fail, the worker that replaces this one carries them on.
            & $publish
        }
        while ($Worker.Results.Count -gt $script:WorkerResultsKept) {
            $Worker.Results.RemoveAt(0)
        }
        $Worker.PassForced = $true
        $published = $true
        & $lost
        if ($null -eq $Worker.Settings) {
            $read = Import-AppSetting -Path $Worker.Paths.Settings
            $Worker.Settings = $read.Settings
            $Worker.SimSettings = Import-SimSetting -Path $Worker.Paths.SimSettings
            $Worker.SettingsProblems = [string[]]@($read.Problems)
            $Worker.SettingsIssues = [object[]]@($read.Issues)
        }
        $Worker.ApnPasswordStored = Test-WorkerApnPassword -Worker $Worker
        $Worker.PinStored = [bool](Get-SimPin -Path $Worker.Paths.SimPin)
    }

    # The modem's port. What is due is marked done only once it has run: a part that fails is due
    # again at the retry, and fails the next cycle too.
    & $lost
    if ((& $due).Scan) {
        $started = & $Worker.Clock
        $Worker.BindDue = $false
        Find-WorkerModem -Worker $Worker
        $Worker.LastScan = $started
        if (-not $Worker.Channel) {
            $observation = @{ Device = $Worker.Presence.Device; PortOpen = $false; PortError = $Worker.PortError; Binding = $Worker.BindState }
            $previous = if ($Worker.State) { @{ Previous = $Worker.State } } else { @{} }
            Register-WorkerDecision -Worker $Worker -Decision (Resolve-ConnectionState -Observation $observation @previous)
        }
        $published = $true
    }

    # The user asked to check now with the port open: the modem's other functions are put on
    # WinUSB if they aren't (a failed one is tried again).
    if ($Worker.BindDue) {
        $Worker.BindDue = $false
        if ($Worker.Channel) {
            $presence = Get-WorkerPresence -Worker $Worker
            if (Update-WorkerBinding -Worker $Worker -Presence $presence) {
                $presence = Get-WorkerPresence -Worker $Worker
            }
            if ($presence.Device -eq 'Present' -and $presence.AtInstanceId -eq $Worker.AtInstanceId) {
                $Worker.Presence = $presence
            }
            $published = $true
        }
    }

    # The modem's network adapter, looked for again while a pass finds none: a PnP read can miss
    # it, and the port stays open meanwhile.
    if ((& $due).AdapterLook) {
        $started = & $Worker.Clock
        $presence = Get-WorkerPresence -Worker $Worker
        $Worker.LastAdapterLook = $started
        if ($presence.Device -eq 'Present' -and $presence.AtInstanceId -eq $Worker.AtInstanceId -and $presence.AdapterInstanceId -and $presence.AdapterInstanceId -ne $Worker.AdapterInstanceId) {
            $Worker.AdapterInstanceId = $presence.AdapterInstanceId
            $Worker.PassForced = $true
            Write-WorkerLog -Worker $Worker -Level 'Info' -Message 'The modem''s network adapter is found'
        }
    }

    # A DoH server named by its template: looked up at the start, then every so often.
    if (Update-WorkerDohName -Worker $Worker) {
        $Worker.PassForced = $true
        $published = $true
    }

    # A connect pass.
    $passRan = $false
    if ((& $due).Pass) {
        $passRan = $true
        $started = & $Worker.Clock
        $options = @{}
        if ($Worker.State) {
            $options['Previous'] = $Worker.State
        }
        if ($Worker.Simulation) {
            $options['SimulatedAdapter'] = $Worker.Simulation.Adapter
        }
        $pass = Invoke-ModemConnect -Channel $Worker.Channel -Settings (Get-WorkerSetting -Worker $Worker) -AdapterInstanceId $Worker.AdapterInstanceId `
            -SimPinPath $Worker.Paths.SimPin -ApnSecretPath $Worker.Paths.ApnSecret -SimSettings $Worker.SimSettings -LogFolder $Worker.Paths.Log `
            -DataPath (Get-WorkerDataPath -Worker $Worker) -NetworkModeSupport $Worker.NetworkModeSupport -NetworkModeLastWrite $Worker.NetworkModeWrite `
            -WhatIf:$Worker.ObserveOnly -Confirm:$false @options
        $Worker.LastPass = $started
        $Worker.PassForced = $false
        Update-WorkerSim -Worker $Worker -Sim $pass.Sim -Facts $pass.Observation
        $wasOnline = $Worker.State -eq 'Online'
        Register-WorkerDecision -Worker $Worker -Decision $pass -Logged
        if (-not $wasOnline -and $Worker.State -eq 'Online' -and @($Worker.EsimNotifications | Where-Object { $_ }).Count -gt 0) {
            # Online again - maybe through the profile just switched to: the notifications that
            # couldn't be sent go now.
            $Worker.EsimDue = $true
        }
        $Worker.Facts = $pass.Observation
        if ($pass.Observation.NetworkModeSupport) {
            $Worker.NetworkModeSupport = $pass.Observation.NetworkModeSupport
        }
        if ($pass.Written) {
            # Never written again over the same setting, taken or refused.
            $Worker.NetworkModeWrite = $pass.Written
            if ($pass.Written.Status -in 'OK', 'Timeout', 'PortLost') {
                # The mode the settings ask, written over the modem's: it registers again - an
                # intentional operation, which nothing escalates over.
                Open-WorkerMaintenanceWindow -Worker $Worker -Now (& $Worker.Clock)
            }
        }
        $modeDecision = $pass.Observation.NetworkMode
        $modeProblem = if ($modeDecision -and $modeDecision.Problem) { "$($modeDecision.Problem) $($modeDecision.Managed)" } else { $null }
        if ($modeProblem -and $modeProblem -ne $Worker.NetworkModeLogged) {
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Network mode: not as the settings ask ($($modeDecision.Problem)); nothing written"
        }
        $Worker.NetworkModeLogged = $modeProblem
        # Encryption left as it is because Windows wouldn't read: said once per cause.
        $facts = $Worker.Facts
        $dnsUnread = if ($facts -and $facts.PSObject.Properties['DnsUnread']) { $facts.DnsUnread } else { $null }
        if ($dnsUnread -and $dnsUnread -ne $Worker.DnsUnreadLogged) {
            $what = if ($dnsUnread -eq 'Templates') { "Windows' list of DoH templates" } else { "the adapter's DNS settings" }
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Encrypted DNS: $what can't be read; left as it is until they can"
        }
        $Worker.DnsUnreadLogged = $dnsUnread
        # IPv6 DNS servers the network gives beside encrypted DNS: said once per set, by number -
        # the window lists them.
        $given = @(if ($facts -and $facts.PSObject.Properties['DnsAdvertised']) { $facts.DnsAdvertised | Where-Object { $_ } })
        $givenKey = $given -join ','
        if ($givenKey -and $givenKey -ne $Worker.DnsAdvertisedLogged) {
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Encrypted DNS: the network also gives $($given.Count) IPv6 DNS server(s), which Windows may query in the clear"
        }
        $Worker.DnsAdvertisedLogged = $givenKey
        # The probes follow the address the adapter carries; one set anew is proven anew.
        $configured = @($pass.Steps | Where-Object { $_.Action -eq 'ConfigureAdapter' -and $_.Result -eq 'Done' }).Count -gt 0
        $address = if ($facts -and $facts.AdapterConfigured -eq $true -and $facts.ContextAddress) { [string]$facts.ContextAddress } else { $null }
        Set-WorkerProbeAddress -Worker $Worker -Address $address -Again:$configured
        if ($configured -and $Worker.DohName.Failure) {
            # The adapter just got its address: a lookup of the DoH server's name that failed
            # without it is tried again at once.
            $Worker.DohName.Next = $null
        }
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

    # A network mode the user chose, on trial: saved once the modem registers with it, undone when
    # it finds no network.
    if ($Worker.NetworkModeTrial -and (Invoke-WorkerNetworkModeTrial -Worker $Worker)) {
        $published = $true
        & $lost
    }

    # The update notice: one request per app start, once the connection is first online.
    if (Update-WorkerUpdateCheck -Worker $Worker) {
        $published = $true
    }

    # The data path (H7), from the adapter's address.
    if ((& $due).Probe) {
        Invoke-WorkerProbe -Worker $Worker
        $published = $true
    }

    # Data usage, from the adapter's byte counters.
    if ((& $due).Usage) {
        $started = & $Worker.Clock
        Update-WorkerUsage -Worker $Worker
        $Worker.LastUsage = $started
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
                if ($code -match $script:WorkerMessageUrcPattern) {
                    $Worker.MessagesDue = $true
                }
            }
        }
        $published = $true
        & $lost
    }

    # The SIM slot in use, once per port; the eUICC through lpac, when it is the SIM in use and a
    # read is due - the first port, a command, a switch -, its SIM ready or with no profile
    # enabled: never while it resets.
    if ($Worker.Channel -and $Worker.Channel.State -eq 'Open' -and -not $Worker.SimSlotRead -and $Worker.Facts -and $Worker.Facts.Responsive) {
        Update-WorkerSimSlot -Worker $Worker
        $published = $true
        & $lost
    }
    if ($Worker.Channel -and $Worker.Channel.State -eq 'Open' -and $Worker.EsimDue -and $Worker.SimSlotRead -and (Test-WorkerEuiccInUse -Worker $Worker) -and
        $Worker.Facts -and $Worker.Facts.SimState -in 'Ready', 'NoProfile' -and (Test-WorkerLpac -Worker $Worker)) {
        $Worker.EsimOperation = 'ReadEsim'
        & $publish
        try {
            [void](Update-WorkerEsim -Worker $Worker)
        }
        finally {
            $Worker.EsimOperation = $null
        }
        $published = $true
        & $lost
    }

    # Messages: the notices set once per port, the storage read when it may have changed - on a
    # notice, after a command, when how full it is changed, checked after each pass -, once a pass
    # has identified the SIM in use, or found its ICCID can't be read: what comes in is told as
    # its own. A step the modem refused waits for the next pass. None in observe-only mode:
    # listing marks messages read on the modem.
    if ($Worker.Channel -and $Worker.Channel.State -eq 'Open' -and -not $Worker.ObserveOnly -and (Test-WorkerSimReady -Worker $Worker) -and
        (($Worker.Sim -and $Worker.Sim.Fingerprint) -or $Worker.SimUnreadLogged) -and ($passRan -or (-not $Worker.MessagesFailure -and ($Worker.MessagesDue -or -not $Worker.MessagesReady)))) {
        if (Update-WorkerInbox -Worker $Worker) {
            $published = $true
        }
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
    if ($Worker.UpdateCheck -or $Worker.DohName.Lookup) {
        # An answer under way is looked for at least this often.
        $Worker.WaitMs = [Math]::Min($Worker.WaitMs, $script:UpdatePollMs)
    }
    if ($null -ne $Worker.DohName.Next -and $Worker.DohName.Name -and -not $Worker.DohName.Lookup) {
        # The next lookup of the DoH server's name. While one is under way its Next has gone by:
        # the answer is looked for as often as above, never in a loop that doesn't wait.
        $Worker.WaitMs = [int][Math]::Max(0, [Math]::Min([long]$Worker.WaitMs, $Worker.DohName.Next - (& $Worker.Clock)))
    }
}

function Close-ModemWorker {
    <#
    .SYNOPSIS
        Ends a worker: closes its AT port, saves the data usage counted since the last save, and
        drops an update check and a lookup under way. The connection stays as it is.
    .EXAMPLE
        Close-ModemWorker -Worker $worker
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Worker
    )

    Close-WorkerChannel -Worker $Worker
    if ($Worker.UsageDirty) {
        try {
            Save-WorkerUsage -Worker $Worker
        }
        catch {
            Write-WorkerLog -Worker $Worker -Level 'Warning' -Message "Data usage not saved ($($_.Exception.GetType().Name))"
        }
    }
    if ($Worker.UpdateCheck) {
        Stop-UpdateCheck -Check $Worker.UpdateCheck -Confirm:$false
        $Worker.UpdateCheck = $null
    }
    Stop-WorkerDohLookup -Worker $Worker
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

        [object] $Previous,

        [switch] $CheckForUpdates
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

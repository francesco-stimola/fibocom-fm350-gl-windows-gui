# The supervisor, on the UI thread: starts the worker in a runspace of its own, watches its
# heartbeat, and replaces it when it ends or hangs - a new worker attaches to the connection, it
# never re-dials. And the single instance: one app per machine owns the modem's AT port. Design:
# docs/ARCHITECTURE.md -> Process model.

# Thresholds: the maintainer's decision (ROADMAP M3).
$script:SupervisorTimings = @{
    # A worker silent this long is hung. It beats at least every second, while it waits for the
    # modem too, so only a call that never returns (PnP, the network stack) gets this far.
    HungMs        = 60000
    # The wait before a new worker: doubled at every failure in a row, up to the longest.
    FirstDelayMs  = 5000
    LongestDelayMs = 300000
    # A worker that ran this long before it ended was no failure in a row: the count starts over.
    StableMs      = 600000
}

# The core module, imported by every worker runspace from the app's own folder.
$script:CoreModulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'FibocomFm350/FibocomFm350.psd1'

function Resolve-SupervisorAction {
    <#
    .SYNOPSIS
        Decides what the supervisor does about the worker.
    .DESCRIPTION
        A pure decision from the worker's state: -Ended (its runspace finished: an error ended
        it), -HeartbeatAgeMs (since its last sign of life), -UptimeMs (since it started), and
        -Failures, the workers that ended or hung in a row so far. -Stopping: the app is exiting.

        Returns Action - 'None', 'Restart' (it ended: start a new one) or 'Replace' (it hangs:
        abandon it, start a new one) - Reason ('Ended', 'Hung' or $null), Failures (the count
        after this one) and DelayMs: how long to wait before the new worker, doubled at every
        failure in a row up to the longest. A worker that ran long enough before it failed
        starts the count over. The new worker attaches to the connection: a restart never
        re-dials.
    .EXAMPLE
        Resolve-SupervisorAction -HeartbeatAgeMs 900 -UptimeMs 120000 -Failures 0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $Ended,

        [long] $HeartbeatAgeMs,

        [long] $UptimeMs,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $Failures,

        [switch] $Stopping
    )

    $timings = $script:SupervisorTimings
    $reason = if ($Stopping) { $null } elseif ($Ended) { 'Ended' } elseif ($HeartbeatAgeMs -gt $timings.HungMs) { 'Hung' } else { $null }
    if (-not $reason) {
        return [pscustomobject]@{ Action = 'None'; Reason = $null; Failures = $Failures; DelayMs = 0 }
    }
    $count = if ($UptimeMs -ge $timings.StableMs) { 1 } else { $Failures + 1 }
    $delay = [Math]::Min([double]$timings.LongestDelayMs, $timings.FirstDelayMs * [Math]::Pow(2, [Math]::Min($count - 1, 30)))
    [pscustomobject]@{
        Action   = if ($reason -eq 'Ended') { 'Restart' } else { 'Replace' }
        Reason   = $reason
        Failures = $count
        DelayMs  = [int]$delay
    }
}

function Start-WorkerRunspace {
    <#
    .SYNOPSIS
        Starts a worker (Invoke-ModemWorker) in a runspace of its own, and returns at once.
    .DESCRIPTION
        The runspace imports the core module itself, off the UI thread. -Previous is the last
        snapshot of the worker this one replaces: the new one starts from its state and attaches.
        -Worker carries Invoke-ModemWorker's other parameters (Simulation, DataFolder,
        ObserveOnly).

        Returns Generation, Link (New-ModemWorkerLink's), Runspace, PowerShell, Handle and
        Started ([Environment]::TickCount64). Stop-WorkerRunspace asks it to finish;
        Complete-WorkerRunspace releases it once it has.
    .EXAMPLE
        $worker = Start-WorkerRunspace -Generation 1 -Worker @{ DataFolder = $folder }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Generation = 1,

        [hashtable] $Worker = @{},

        [object] $Previous
    )

    if (-not $PSCmdlet.ShouldProcess("worker $Generation", 'Start')) {
        return
    }
    $link = New-ModemWorkerLink -Snapshot $Previous
    $parameters = @{ Link = $link; Generation = $Generation }
    foreach ($key in $Worker.Keys) {
        $parameters[$key] = $Worker[$key]
    }
    if ($Previous) {
        $parameters['Previous'] = $Previous
    }
    $runspace = [runspacefactory]::CreateRunspace([System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2())
    $runspace.Name = "fm350-worker-$Generation"
    $powershell = $null
    try {
        $runspace.Open()
        $powershell = [powershell]::Create($runspace)
        [void]$powershell.AddScript({
                param($Module, $Parameters)
                Import-Module -Name $Module -ErrorAction Stop
                Invoke-ModemWorker @Parameters
            }).AddArgument($script:CoreModulePath).AddArgument($parameters)
        $handle = $powershell.BeginInvoke()
    }
    catch {
        if ($powershell) { $powershell.Dispose() }
        $runspace.Dispose()
        Close-ModemWorkerLink -Link $link
        throw
    }
    [pscustomobject]@{
        Generation = $Generation
        Link       = $link
        Runspace   = $runspace
        PowerShell = $powershell
        Handle     = $handle
        Started    = [Environment]::TickCount64
    }
}

function Stop-WorkerRunspace {
    <#
    .SYNOPSIS
        Asks a worker to finish, and returns at once.
    .DESCRIPTION
        The worker ends its cycle, closes the AT port and returns; Complete-WorkerRunspace then
        releases it. -Abandon is for a worker that hangs: its pipeline is also asked to stop,
        asynchronously - it ends whenever the call it is stuck in returns.
    .EXAMPLE
        Stop-WorkerRunspace -Worker $worker
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object] $Worker,

        [switch] $Abandon
    )

    if (-not $PSCmdlet.ShouldProcess("worker $($Worker.Generation)", 'Stop')) {
        return
    }
    $Worker.Link['Stop'] = $true
    [void]$Worker.Link['Wake'].Set()
    if ($Abandon) {
        [void]$Worker.PowerShell.BeginStop($null, $null)
    }
}

function Complete-WorkerRunspace {
    <#
    .SYNOPSIS
        Releases a worker that has finished: its PowerShell, its runspace, its link.
    .DESCRIPTION
        Returns $false, releasing nothing, while the worker still runs. Otherwise releases it,
        sets the worker's Reason to the error that ended it ($null when it ended as asked), and
        returns $true.
    .EXAMPLE
        if (Complete-WorkerRunspace -Worker $worker) { ... }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object] $Worker
    )

    if (-not $Worker.Handle.IsCompleted) {
        return $false
    }
    $reason = $null
    try {
        [void]$Worker.PowerShell.EndInvoke($Worker.Handle)
    }
    catch {
        # EndInvoke wraps the error that ended the worker.
        $exception = if ($_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }
        $reason = $exception.Message
    }
    if (-not $reason -and $Worker.PowerShell.InvocationStateInfo.Reason) {
        $reason = $Worker.PowerShell.InvocationStateInfo.Reason.Message
    }
    $Worker.PowerShell.Dispose()
    $Worker.Runspace.Dispose()
    Close-ModemWorkerLink -Link $Worker.Link
    $Worker | Add-Member -NotePropertyName Reason -NotePropertyValue $reason -Force
    $true
}

function Receive-WorkerMessage {
    <#
    .SYNOPSIS
        Takes the errors and warnings a worker wrote, so that they don't pile up for weeks.
    .DESCRIPTION
        Returns them as text, oldest first, and empties the worker's error and warning streams.
    .EXAMPLE
        Receive-WorkerMessage -Worker $worker | ForEach-Object { Write-AppLog -Level Warning -Message $_ }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Worker
    )

    $streams = $Worker.PowerShell.Streams
    foreach ($record in @($streams.Error.ReadAll())) {
        "Worker $($Worker.Generation) error: $($record.Exception.Message)"
    }
    foreach ($record in @($streams.Warning.ReadAll())) {
        "Worker $($Worker.Generation) warning: $($record.Message)"
    }
}

function Enter-AppInstance {
    <#
    .SYNOPSIS
        Makes this app the only instance, or tells the one already running to show its window.
    .DESCRIPTION
        A named mutex keeps a second instance away from the modem's AT port (invariant 1). When
        another instance holds it, this one signals that instance's "show" event - it brings its
        window to the front - and returns Owned $false: the caller exits. The mutex is
        machine-wide; the event is per Windows session.

        Returns Owned, Mutex and ShowEvent; Exit-AppInstance releases them, on the thread that
        entered.
    .EXAMPLE
        $instance = Enter-AppInstance -Name 'fibocom-fm350-gl-windows-gui'
        if (-not $instance.Owned) { return }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9-]+$')]
        [string] $Name
    )

    $mutex = $null
    $owned = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, "Global\$Name")
        $owned = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        # The instance that held it ended without releasing it: it is ours now.
        $owned = $true
    }
    catch [System.UnauthorizedAccessException] {
        # Created by an instance with administrator rights, which this one doesn't have: held.
        $owned = $false
    }
    $showName = "Local\$Name-show"
    if (-not $owned) {
        if ($mutex) {
            $mutex.Dispose()
        }
        $existing = $null
        if ([System.Threading.EventWaitHandle]::TryOpenExisting($showName, [ref]$existing)) {
            [void]$existing.Set()
            $existing.Dispose()
        }
        return [pscustomobject]@{ Owned = $false; Mutex = $null; ShowEvent = $null }
    }
    $showEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, $showName)
    [pscustomobject]@{ Owned = $true; Mutex = $mutex; ShowEvent = $showEvent }
}

function Exit-AppInstance {
    <#
    .SYNOPSIS
        Releases what Enter-AppInstance took, on the thread that entered.
    .EXAMPLE
        Exit-AppInstance -Instance $instance
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Instance
    )

    if ($Instance.ShowEvent) {
        $Instance.ShowEvent.Dispose()
    }
    if ($Instance.Mutex) {
        try {
            $Instance.Mutex.ReleaseMutex()
        }
        catch [System.ApplicationException] {
            # Not owned by this thread any more: nothing to release.
            Write-Verbose 'The instance mutex was not held by this thread.'
        }
        $Instance.Mutex.Dispose()
    }
}

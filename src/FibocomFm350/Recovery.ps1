# The recovery ladder: what to do about a health check that keeps failing, and the steps R1-R6.
# Design: docs/ARCHITECTURE.md -> Health checks and the recovery ladder, Maintenance windows.

# Timings in ms. Values: the maintainer's decision (ROADMAP M4).
$script:RecoveryTimings = @{
    # How long a failing check is left to the connect pass, which takes the missing steps itself,
    # before the first recovery step. The AT port has been seen silent for almost three minutes
    # after it appeared (AT-COMMANDS section 2). H7 waits for its own failed rounds instead.
    Grace       = @{ H2 = 180000; H3 = 120000; H4 = 120000; H5 = 60000; H6 = 60000; H7 = 0 }
    # How long a step is given to work before the next one. A reset takes the modem off USB about
    # 49 s after its OK, and back about 28 s later (AT-COMMANDS section 3).
    Settle      = @{ R1 = 30000; R2 = 60000; R3 = 120000; R4 = 120000; R5 = 300000; R6 = 300000 }
    # The wait before a new cycle, after the first, the second... cycle that failed; the last one
    # repeats: the slow cadence, at which the failure is shown.
    Backoff     = @(300000, 900000, 3600000)
    # Health held this long starts the ladder and the cycles over.
    StableMs    = 600000
    # How long an intentional operation may keep the connection down: a maintenance window.
    Maintenance = 180000
}

# The steps, from the least disruptive (ARCHITECTURE -> Health checks and the recovery ladder).
$script:RecoverySteps = @('R1', 'R2', 'R3', 'R4', 'R5', 'R6')

# The steps that can mend each check, in order; the first is the check's entry step. H1 - no modem
# on USB - has none: nothing reaches a device that is gone. A port that doesn't answer leaves only
# the USB restart; a SIM that doesn't come ready, only the modem reset, which reads it again.
$script:RecoveryLadders = @{
    H2 = @('R6')
    H3 = @('R5')
    H4 = @('R3', 'R4', 'R5')
    H5 = @('R2', 'R3', 'R4', 'R5')
    H6 = @('R1', 'R2', 'R3', 'R4', 'R5')
    H7 = @('R2', 'R3', 'R4', 'R5')
}

# Steps that need administrator rights: the network adapter, the USB device.
$script:RecoveryElevatedSteps = @('R1', 'R6')

# The command each AT step sends. The connect pass, run right after, takes the steps back up:
# activates the context (R2), selects the operator automatically (R3), turns the radio on (R4).
$script:RecoveryCommands = @{
    R2 = 'AT+CGACT=0,1'
    R3 = 'AT+COPS=2'
    R4 = 'AT+CFUN=4'
    R5 = 'AT+CFUN=15'
}

function Get-RecoveryNextStep {
    # The first step of -Check's ladder above -Step ($null: the entry step), skipping those that
    # need rights the app doesn't have, and the reset when it must not run; $null when there is
    # none.
    param([string] $Check, [string] $Step, [bool] $Elevated, [bool] $NoReset)

    $ladder = if ($Check -and $script:RecoveryLadders.ContainsKey($Check)) { $script:RecoveryLadders[$Check] } else { @() }
    $above = if ($Step) { $script:RecoverySteps.IndexOf($Step) } else { -1 }
    @($ladder | Where-Object {
            $script:RecoverySteps.IndexOf($_) -gt $above -and ($Elevated -or $_ -notin $script:RecoveryElevatedSteps) -and -not ($NoReset -and $_ -eq 'R5')
        }) | Select-Object -First 1
}

function New-RecoveryHistory {
    # A copy of -History with the given changes, or a new history: what Resolve-RecoveryAction
    # remembers between its calls. Times in the worker's clock (ms).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object; changes no system state.')]
    param([object] $History, [hashtable] $Change = @{})

    $copy = [ordered]@{
        Check = $null; FailingSince = $null; HealthySince = $null; Step = $null; StepAt = $null
        Cycles = 0; CycleEndedAt = $null; MaintenanceUntil = $null; MaintenanceBroken = $false
    }
    if ($History) {
        foreach ($key in @($copy.Keys)) {
            if ($History.PSObject.Properties[$key]) {
                $copy[$key] = $History.$key
            }
        }
    }
    foreach ($key in $Change.Keys) {
        $copy[$key] = $Change[$key]
    }
    [pscustomobject]$copy
}

function Resolve-RecoveryAction {
    <#
    .SYNOPSIS
        Decides the next recovery step from the failing health check and what was done so far.
    .DESCRIPTION
        A pure decision (ARCHITECTURE -> Health checks and the recovery ladder): -Check is the
        failing check (Resolve-HealthCheck; $null when every check passes), -Blocked says it is
        out of the app's reach, -History is what the last call returned ($null the first time),
        -Now the worker's clock in ms.

        - Healthy: the episode is over. The ladder and the cycle count start over only after
          health has held StableMs; a failure before that carries on up the ladder - the last
          step mended the symptom, not its cause.
        - A step taken is given its settle time, whatever fails meanwhile: a reset takes the
          modem off USB.
        - A maintenance window (Open-MaintenanceWindow) suspends escalation until the window
          ends, or until the modem is healthy again after the operation broke the link.
        - Blocked: never escalated - no reset gives a PIN, an APN or administrator rights, nor
          lifts an FCC lock or enables an adapter the user disabled. -Unknown - the state
          couldn't be read - is not escalated either: one failed read must never break a
          connection that may well work.
        - A failing check is first left to the connect pass for its grace time, counted from
          when that check started failing; then the next step of its ladder runs, from the step
          after the last one taken (its entry step at the start). Past the top of its ladder the
          cycle is over: the next one starts after a backoff that grows with each failed cycle,
          up to the slow cadence.
        - -Resumed: the computer slept; the failing check gets its grace time again.
        - -Withhold: the app only observes - the step is named, not taken, and not remembered.
        - Without -Elevated, the steps that need administrator rights are skipped. With
          -NoReset - the SIM would ask for a PIN the app doesn't have after a reset - R5 is.

        Returns Action ('None' or the step to take now: 'R1' to 'R6'), Status ('Healthy',
        'Blocked', 'Maintenance', 'Watching' - a check fails and no step is due yet, or none can
        mend it -, 'Recovering' - a step is taken now -, 'Settling', 'Waiting' - between cycles
        -, 'SlowCadence' - waiting after the cycles have run out - or 'Withheld'), Check, Step
        (taken or settling), Cycles, WaitMs (until the decision may change with time alone;
        $null: only a change in health changes it) and History, to pass back next time.
    .EXAMPLE
        $recovery = Resolve-RecoveryAction -Now $now -Check 'H7' -History $recovery.History -Elevated
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [long] $Now,

        [ValidateSet('H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'H7')]
        [string] $Check,

        [switch] $Blocked,

        [object] $History,

        [switch] $Elevated,

        [switch] $Withhold,

        [switch] $Resumed,

        [switch] $Unknown,

        [switch] $NoReset
    )

    $timings = $script:RecoveryTimings
    $h = New-RecoveryHistory -History $History
    if ($Resumed) {
        $h.FailingSince = $null
    }
    $decide = {
        param($status, $action, $wait)
        [pscustomobject]@{
            Action  = if ($action) { $action } else { 'None' }
            Status  = $status
            Check   = $h.Check
            Step    = if ($status -eq 'Withheld') { $action } else { $h.Step }
            Cycles  = $h.Cycles
            WaitMs  = if ($null -ne $wait) { [long][Math]::Max(0, $wait) } else { $null }
            History = $h
        }
    }

    if (-not $Check) {
        if ($null -eq $h.HealthySince) {
            $h.HealthySince = $Now
        }
        $h.Check = $null
        $h.FailingSince = $null
        # A window closes once the link is back - not while the operation hasn't broken it yet.
        if ($null -ne $h.MaintenanceUntil -and ($h.MaintenanceBroken -or $Now -ge $h.MaintenanceUntil)) {
            $h.MaintenanceUntil = $null
            $h.MaintenanceBroken = $false
        }
        $stableAt = $h.HealthySince + $timings.StableMs
        if ($Now -ge $stableAt) {
            $h.Step = $null
            $h.StepAt = $null
            $h.Cycles = 0
            $h.CycleEndedAt = $null
        }
        $wait = if ($h.Step -or $h.Cycles -gt 0) { $stableAt - $Now } else { $null }
        return & $decide 'Healthy' $null $wait
    }

    $h.HealthySince = $null
    if ($Check -ne $h.Check) {
        # Another check fails now: its grace time is its own - a port that falls silent after a
        # step for the registration is given the silence it may need.
        $h.FailingSince = $null
    }
    $h.Check = $Check
    if ($h.Step -and $Now -lt $h.StepAt + $timings.Settle[$h.Step]) {
        return & $decide 'Settling' $null ($h.StepAt + $timings.Settle[$h.Step] - $Now)
    }
    if ($null -ne $h.MaintenanceUntil) {
        if ($Now -lt $h.MaintenanceUntil) {
            $h.FailingSince = $null
            $h.MaintenanceBroken = $true
            return & $decide 'Maintenance' $null ($h.MaintenanceUntil - $Now)
        }
        $h.MaintenanceUntil = $null
        $h.MaintenanceBroken = $false
    }
    if ($Blocked) {
        $h.FailingSince = $null
        return & $decide 'Blocked' $null $null
    }
    if ($Unknown) {
        $h.FailingSince = $null
        return & $decide 'Watching' $null $null
    }
    if ($null -eq $h.FailingSince) {
        $h.FailingSince = $Now
    }
    $graceEnd = $h.FailingSince + $(if ($timings.Grace.ContainsKey($Check)) { $timings.Grace[$Check] } else { 0 })
    if ($Now -lt $graceEnd) {
        return & $decide 'Watching' $null ($graceEnd - $Now)
    }

    $next = $null
    if ($h.Step) {
        $next = Get-RecoveryNextStep -Check $Check -Step $h.Step -Elevated $Elevated -NoReset $NoReset
        if (-not $next) {
            # The top of the ladder: the cycle is over.
            $h.Cycles++
            $h.CycleEndedAt = $Now
            $h.Step = $null
            $h.StepAt = $null
        }
    }
    if (-not $h.Step) {
        if ($h.Cycles -gt 0) {
            $backoff = $timings.Backoff[[Math]::Min($h.Cycles, $timings.Backoff.Count) - 1]
            if ($Now -lt $h.CycleEndedAt + $backoff) {
                $status = if ($h.Cycles -ge $timings.Backoff.Count) { 'SlowCadence' } else { 'Waiting' }
                return & $decide $status $null ($h.CycleEndedAt + $backoff - $Now)
            }
        }
        $next = Get-RecoveryNextStep -Check $Check -Step $null -Elevated $Elevated -NoReset $NoReset
    }
    if (-not $next) {
        return & $decide 'Watching' $null $null
    }
    if ($Withhold) {
        return & $decide 'Withheld' $next $null
    }
    $h.Step = $next
    $h.StepAt = $Now
    & $decide 'Recovering' $next $timings.Settle[$next]
}

function Open-MaintenanceWindow {
    <#
    .SYNOPSIS
        Opens a maintenance window in a recovery history: an intentional operation may keep the
        connection down for a while, and nothing escalates meanwhile.
    .DESCRIPTION
        A pure function: returns a copy of -History (Resolve-RecoveryAction's) whose window ends
        -DurationMs after -Now - or later, when a window already open ends later. The window
        closes early once every check passes again after a check failed in it - not at a
        healthy reading taken before the operation broke the link (ARCHITECTURE -> Maintenance
        windows).
    .EXAMPLE
        $history = Open-MaintenanceWindow -History $history -Now $now
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a new in-memory object; changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [object] $History,

        [Parameter(Mandatory)]
        [long] $Now,

        [ValidateRange(1, [int]::MaxValue)]
        [int] $DurationMs = $script:RecoveryTimings.Maintenance
    )

    $until = $Now + $DurationMs
    if ($History -and $History.PSObject.Properties['MaintenanceUntil'] -and $null -ne $History.MaintenanceUntil -and $History.MaintenanceUntil -gt $until) {
        $until = $History.MaintenanceUntil
    }
    New-RecoveryHistory -History $History -Change @{ MaintenanceUntil = $until; MaintenanceBroken = $false }
}

function Invoke-RecoveryStep {
    <#
    .SYNOPSIS
        Takes one step of the recovery ladder.
    .DESCRIPTION
        Only when Resolve-RecoveryAction decided it. Each step does the least that can mend what
        fails, and leaves the rest to the connect pass the caller runs right after:
        - R1: removes the adapter's configuration - its manual addresses and default routes -
          so that the pass sets it again from scratch (administrator rights).
        - R2: deactivates the data context; the pass activates it again.
        - R3: deregisters from the network (AT+COPS=2); the pass selects the operator
          automatically again.
        - R4: turns the radio off (AT+CFUN=4); the pass turns it on.
        - R5: resets the modem (AT+CFUN=15): it leaves USB and comes back; its OK may never
          arrive.
        - R6: restarts the modem's USB device (pnputil, administrator rights). The caller closes
          the AT port first.
        -Simulation is development mode's device (New-SimulatedDevice): its adapter and its USB
        device instead of the real ones.

        Returns Step, Result ('Done', 'Failed', 'PortLost' or 'NoModem' - nothing to act on) and
        Commands: each command or change, with its Status.
    .EXAMPLE
        Invoke-RecoveryStep -Step R2 -Channel $channel
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('R1', 'R2', 'R3', 'R4', 'R5', 'R6')]
        [string] $Step,

        [AtChannel] $Channel,

        # R1: the modem's network function (Resolve-ModemUsbDevice's Network.InstanceId).
        [string] $AdapterInstanceId,

        # R6: the modem's composite USB device (Resolve-ModemPresence's InstanceId).
        [string] $DeviceInstanceId,

        [object] $Simulation
    )

    $commands = [System.Collections.Generic.List[object]]::new()
    $outcome = {
        param($result)
        [pscustomobject]@{ Step = $Step; Result = $result; Commands = [object[]]$commands.ToArray() }
    }
    if (-not $PSCmdlet.ShouldProcess('the modem', "Recovery step $Step")) {
        return & $outcome 'Declined'
    }

    switch ($Step) {
        'R1' {
            $adapter = if ($Simulation) { $Simulation.Adapter.Read() } elseif ($AdapterInstanceId) { Get-ModemAdapterState -InstanceId $AdapterInstanceId } else { $null }
            if (-not $adapter) {
                return & $outcome 'NoModem'
            }
            $plan = Resolve-AdapterClearing -Adapter $adapter
            $applied = if ($Simulation) {
                @($Simulation.Adapter.Apply($plan))
            }
            else {
                @(Set-ModemAdapterConfiguration -InterfaceIndex $adapter.InterfaceIndex -Plan $plan -Confirm:$false)
            }
            foreach ($change in $applied) {
                $commands.Add([pscustomobject]@{ Command = $change.Action; Status = $(if ($change.Done) { 'OK' } else { 'Error' }) })
            }
            return & $outcome $(if (@($applied | Where-Object { -not $_.Done }).Count -eq 0) { 'Done' } else { 'Failed' })
        }
        'R6' {
            if ($Simulation) {
                $Simulation.Restart()
                $commands.Add([pscustomobject]@{ Command = 'restart-device'; Status = 'OK' })
                return & $outcome 'Done'
            }
            if (-not $DeviceInstanceId) {
                return & $outcome 'NoModem'
            }
            $restart = Restart-ModemUsbDevice -InstanceId $DeviceInstanceId -Confirm:$false
            $commands.Add([pscustomobject]@{ Command = 'restart-device'; Status = $(if ($restart.Done) { 'OK' } else { "Exit $($restart.ExitCode)" }) })
            return & $outcome $(if ($restart.Done) { 'Done' } else { 'Failed' })
        }
        default {
            if (-not $Channel -or $Channel.State -ne 'Open') {
                return & $outcome 'NoModem'
            }
            $answer = Invoke-AtCommand -Channel $Channel -Command $script:RecoveryCommands[$Step]
            $commands.Add([pscustomobject]@{ Command = $answer.Command; Status = $answer.Status; ErrorCode = $answer.ErrorCode })
            $result = if ($answer.Status -eq 'OK') {
                'Done'
            }
            elseif ($Step -eq 'R5' -and $answer.Status -in 'Timeout', 'PortLost') {
                # A reset: a timeout and a lost port both mean the command arrived.
                'Done'
            }
            elseif ($answer.Status -eq 'PortLost') {
                'PortLost'
            }
            else {
                'Failed'
            }
            return & $outcome $result
        }
    }
}

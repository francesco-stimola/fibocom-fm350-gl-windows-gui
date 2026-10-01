# The FCC lock: reading it, telling whether it explains a modem that doesn't register, and the
# unlock the user can ask for. Facts and sources: docs/AT-COMMANDS.md section 4; design:
# docs/ARCHITECTURE.md -> FCC lock.

# The three reads, in one command line.
$script:FccReadCommand = 'AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?'

# The unlock as done on our module ([UNLOCK]). Writes the modem's non-volatile memory. MayFail: the
# vendor manual documents +GTFCCEFFSTATUS as read-only, its set form answering ERROR, so an error
# there doesn't stop the sequence. The last step restarts the modem: its OK may never arrive.
$script:FccUnlockSequence = @(
    @{ Command = 'AT+GTFCCLOCKMODE=0'; MayFail = $false }
    @{ Command = 'AT+GTFCCLOCKSTATE=0'; MayFail = $false }
    @{ Command = 'AT+GTFCCEFFSTATUS=0,0'; MayFail = $true }
    @{ Command = 'AT&W'; MayFail = $false }
    @{ Command = 'AT+CFUN=1,1'; Restart = $true }
)

function ConvertFrom-AtFccLock {
    <#
    .SYNOPSIS
        Reads the FCC lock from the answer to AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?.
    .DESCRIPTION
        Returns Mode (0 no lock, 1 one-time unlock, 2 unlock at every power-on), State (0 not
        unlocked yet, 1 unlocked), EffectiveMode (the mode in force now) and Unlocked ($true or
        $false, from '+GTFCCEFFSTATUS: <effective mode>,<unlock status>'); $null for what the
        answer doesn't carry. A '+GTFCCEFFSTATUS:' line with one value is not the documented
        layout: it gives neither EffectiveMode nor Unlocked. Returns $null when none of the three
        lines is there.
    .EXAMPLE
        ConvertFrom-AtFccLock -Lines '+GTFCCLOCKMODE: 2', '+GTFCCLOCKSTATE: 0', '+GTFCCEFFSTATUS: 2,0'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    $mode = ConvertTo-AtInteger -Text (Get-AtArgument -Lines $Lines -Prefix '+GTFCCLOCKMODE' -Position 0)
    $state = ConvertTo-AtInteger -Text (Get-AtArgument -Lines $Lines -Prefix '+GTFCCLOCKSTATE' -Position 0)
    $effective = @(Get-AtPrefixedLine -Lines $Lines -Prefix '+GTFCCEFFSTATUS') | Select-Object -First 1
    $effectiveMode = $null
    $unlocked = $null
    if ($null -ne $effective) {
        $arguments = @(Split-AtArgument -Text $effective)
        if ($arguments.Count -eq 2) {
            $effectiveMode = ConvertTo-AtInteger -Text $arguments[0].Value
            $status = ConvertTo-AtInteger -Text $arguments[1].Value
            if ($status -in 0, 1) {
                $unlocked = $status -eq 1
            }
        }
    }
    if ($null -eq $mode -and $null -eq $state -and $null -eq $effective) {
        return
    }
    [pscustomobject]@{
        Mode          = $mode
        State         = $state
        EffectiveMode = $effectiveMode
        Unlocked      = $unlocked
    }
}

function Resolve-FccLock {
    <#
    .SYNOPSIS
        Tells whether the FCC lock explains a modem that doesn't register.
    .DESCRIPTION
        A pure decision (ARCHITECTURE -> FCC lock): the lock values explain a registration that
        never starts; they never stop a modem that registers. From -Fcc (ConvertFrom-AtFccLock's
        result, or $null when the reads failed) and -Registered, returns Diagnosis:
        - 'NotLocked': the modem registers, or the modem says it is unlocked.
        - 'Locked': not registered, and the modem says the lock is in effect (unlock status 0) -
          a locked module's radio doesn't come on, so it can't register. No reset changes that.
        - 'Unknown': not registered, and the lock can't be read.
        and PowerUpUnlock: $true when the mode in force is 2, a lock that comes back at every
        power loss.
    .EXAMPLE
        Resolve-FccLock -Fcc (ConvertFrom-AtFccLock -Lines $answer.Lines) -Registered:$false
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Fcc,

        [switch] $Registered
    )

    $unlocked = if ($null -ne $Fcc) { $Fcc.Unlocked }
    $diagnosis = if ($Registered -or $unlocked -eq $true) {
        'NotLocked'
    }
    elseif ($unlocked -eq $false) {
        'Locked'
    }
    else {
        'Unknown'
    }
    [pscustomobject]@{
        Diagnosis     = $diagnosis
        PowerUpUnlock = $null -ne $Fcc -and $Fcc.EffectiveMode -eq 2
    }
}

function Invoke-FccUnlock {
    <#
    .SYNOPSIS
        Lifts the FCC lock of a modem that is locked: writes its non-volatile memory and restarts
        it.
    .DESCRIPTION
        Only when the user asks for it, after a confirmation saying that it writes the modem's
        non-volatile memory and lifts a restriction set by the laptop's maker, at the user's
        responsibility (ARCHITECTURE -> FCC lock). Never automatic, never repeated by itself.

        Reads the lock first and writes nothing unless the modem says it is locked. Then runs the
        known sequence once, stopping at the first command that fails (except the documented
        read-only one, whose error is expected), and restarts the modem. The modem leaves USB:
        the caller waits for it, opens a new channel, and reads the lock again.

        Returns Result - 'Restarted', 'NotLocked' (nothing written), 'Unknown' (the lock can't
        be read; nothing written), 'Declined' (not confirmed; nothing written), 'Failed' (a
        command failed; the modem was not restarted) or 'PortLost' - and Steps: each command
        sent, with its Status and ErrorCode.
    .EXAMPLE
        Invoke-FccUnlock -Channel $channel -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AtChannel] $Channel
    )

    $steps = [System.Collections.Generic.List[object]]::new()
    $record = {
        param($answer)
        $steps.Add([pscustomobject]@{ Command = $answer.Command; Status = $answer.Status; ErrorCode = $answer.ErrorCode })
    }
    $result = {
        param($outcome)
        [pscustomobject]@{ Result = $outcome; Steps = [object[]]$steps.ToArray() }
    }

    $read = Invoke-AtCommand -Channel $Channel -Command $script:FccReadCommand
    & $record $read
    if ($read.Status -eq 'PortLost') {
        return & $result 'PortLost'
    }
    $lock = if ($read.Status -eq 'OK') { ConvertFrom-AtFccLock -Lines $read.Lines }
    $unlocked = if ($null -ne $lock) { $lock.Unlocked }
    if ($unlocked -eq $true) {
        return & $result 'NotLocked'
    }
    if ($unlocked -ne $false) {
        return & $result 'Unknown'
    }
    if (-not $PSCmdlet.ShouldProcess('the modem''s non-volatile memory', 'Lift the FCC lock and restart the modem')) {
        return & $result 'Declined'
    }

    foreach ($step in $script:FccUnlockSequence) {
        $answer = Invoke-AtCommand -Channel $Channel -Command $step['Command']
        & $record $answer
        if ($step['Restart']) {
            # The modem restarts: OK, a timeout and a lost port all mean the command arrived.
            return & $result $(if ($answer.Status -in 'OK', 'Timeout', 'PortLost') { 'Restarted' } else { 'Failed' })
        }
        if ($answer.Status -eq 'PortLost') {
            return & $result 'PortLost'
        }
        if ($answer.Status -ne 'OK' -and -not $step['MayFail']) {
            return & $result 'Failed'
        }
    }
}

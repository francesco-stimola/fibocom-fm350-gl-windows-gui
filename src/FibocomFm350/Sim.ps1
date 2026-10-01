# The SIM PIN: reading what the SIM needs, deciding whether the app may enter the stored PIN, and
# keeping that PIN. Facts and sources: docs/AT-COMMANDS.md section 3; design:
# docs/ARCHITECTURE.md -> SIM PIN.
#
# The rules that keep the SIM from locking: at most one attempt per stored PIN, none automatically
# with one attempt left, never a PIN for another SIM, never a PUK.

function ConvertFrom-AtPinRetry {
    <#
    .SYNOPSIS
        Reads how many attempts are left from the answer to AT+CPINR.
    .DESCRIPTION
        One '+CPINR: <code>,<retries>,<default retries>' line per PIN or PUK, the code quoted or
        not. Returns one object per line: Code ('SIM PIN', 'SIM PUK', ...), Retries and
        DefaultRetries ($null when not a number).
    .EXAMPLE
        ConvertFrom-AtPinRetry -Lines '+CPINR: SIM PIN,3,3'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    foreach ($text in Get-AtPrefixedLine -Lines $Lines -Prefix '+CPINR') {
        $arguments = @(Split-AtArgument -Text $text)
        $retries = if ($arguments.Count -gt 1) { ConvertTo-AtInteger -Text $arguments[1].Value }
        if (-not $arguments[0].Value -or $null -eq $retries) {
            continue
        }
        [pscustomobject]@{
            Code           = $arguments[0].Value
            Retries        = $retries
            DefaultRetries = if ($arguments.Count -gt 2) { ConvertTo-AtInteger -Text $arguments[2].Value } else { $null }
        }
    }
}

function ConvertFrom-AtFacilityLock {
    <#
    .SYNOPSIS
        Reads whether a lock is on from the answer to AT+CLCK=<facility>,2.
    .DESCRIPTION
        '+CLCK: <status>': 1 on, 0 off. For facility "SC", whether the SIM asks for its PIN at
        power-on. Returns $true, $false, or $null without a readable '+CLCK:' line.
    .EXAMPLE
        ConvertFrom-AtFacilityLock -Lines '+CLCK: 1'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    $status = ConvertTo-AtInteger -Text (Get-AtArgument -Lines $Lines -Prefix '+CLCK' -Position 0)
    if ($status -in 0, 1) {
        $status -eq 1
    }
}

function ConvertFrom-AtIccid {
    <#
    .SYNOPSIS
        Reads the SIM's ICCID from the answer to AT+ICCID (or AT+CCID).
    .DESCRIPTION
        '+ICCID: <iccid>', unquoted. The ICCID is an identifier: the app only uses it to tell
        whether a stored PIN belongs to the SIM in the modem, and never logs it. Returns the
        ICCID (hexadecimal digits: the last may be an F), or $null.
    .EXAMPLE
        ConvertFrom-AtIccid -Lines '+ICCID: 8900100000000000000'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    $value = Get-AtArgument -Lines $Lines -Prefix '+ICCID' -Position 0
    if (-not $value) {
        $value = Get-AtArgument -Lines $Lines -Prefix '+CCID' -Position 0
    }
    if ($value -match '^[0-9A-Fa-f]+$') {
        $value.ToUpperInvariant()
    }
}

function Resolve-SimPinAction {
    <#
    .SYNOPSIS
        Decides what to do about the SIM: continue, enter the stored PIN, ask the user, report, or
        wait.
    .DESCRIPTION
        A pure decision (ARCHITECTURE -> SIM PIN), from:
        - SimState: ConvertFrom-AtSimState's State.
        - PinStored: whether a PIN is stored.
        - PinForThisSim: whether the stored PIN belongs to the SIM in the modem; $null when the
          SIM can't be identified.
        - PinAttempted: whether the stored PIN was sent and its outcome is not known to be a
          success (it is cleared once the SIM is seen ready after it).
        - AttemptsLeft: PIN attempts left, $null when the modem can't tell.

        Returns Action and Reason:
        - Continue: the SIM is ready. Reason 'PinAccepted' when an attempt was pending: the
          caller then clears it.
        - SendPin: enter the stored PIN - once.
        - AskUser: the SIM waits for its PIN and the app may not send one. Reason: 'NoPin',
          'PinForOtherSim', 'SimNotIdentified', 'PinUnconfirmed' (the earlier attempt's outcome
          is unknown: never a second one) or 'LastAttempt'.
        - Report: nothing the app can do. Reason: 'PukRequired' (the user enters the PUK with a
          phone; the app never does), 'NoSim', 'SimFailure', 'SimOther'.
        - Wait: the SIM is busy; read it again later. Reason 'SimBusy'.
    .EXAMPLE
        Resolve-SimPinAction -SimState PinRequired -PinStored -PinForThisSim $true -AttemptsLeft 3
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Ready', 'PinRequired', 'PukRequired', 'Absent', 'Busy', 'Failure', 'Other')]
        [string] $SimState,

        [switch] $PinStored,

        [Nullable[bool]] $PinForThisSim,

        [switch] $PinAttempted,

        [Nullable[int]] $AttemptsLeft
    )

    $action, $reason = switch ($SimState) {
        'Ready' { 'Continue', $(if ($PinStored -and $PinAttempted) { 'PinAccepted' } else { $null }) }
        'Busy' { 'Wait', 'SimBusy' }
        'Absent' { 'Report', 'NoSim' }
        'PukRequired' { 'Report', 'PukRequired' }
        'Failure' { 'Report', 'SimFailure' }
        'Other' { 'Report', 'SimOther' }
        'PinRequired' {
            if (-not $PinStored) { 'AskUser', 'NoPin' }
            elseif ($null -eq $PinForThisSim) { 'AskUser', 'SimNotIdentified' }
            elseif (-not $PinForThisSim) { 'AskUser', 'PinForOtherSim' }
            elseif ($PinAttempted) { 'AskUser', 'PinUnconfirmed' }
            elseif ($null -ne $AttemptsLeft -and $AttemptsLeft -le 1) { 'AskUser', 'LastAttempt' }
            else { 'SendPin', $null }
        }
    }
    [pscustomobject]@{ Action = $action; Reason = $reason }
}

function Get-SimFingerprint {
    # What the PIN file keeps of the SIM's identity: a SHA-256 of its ICCID, never the ICCID.
    param([string] $Iccid)

    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Iccid.Trim().ToUpperInvariant())
    [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
}

function Save-SimPin {
    <#
    .SYNOPSIS
        Stores the SIM PIN, with the SIM it belongs to, encrypted for the current user.
    .DESCRIPTION
        The PIN (4 to 8 digits) and a fingerprint of the SIM's ICCID go in a file of their own
        next to the settings, both encrypted with DPAPI for the current user. A PIN just stored
        has not been attempted yet. Replaces any PIN stored before.
    .EXAMPLE
        Save-SimPin -Pin (Read-Host -AsSecureString) -Iccid $iccid
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [securestring] $Pin,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9A-Fa-f]+$')]
        [string] $Iccid,

        [string] $Path = (Get-AppDataPath -Name 'sim-pin.json')
    )

    # 4 to 8 digits (AT-COMMANDS section 3): anything else would only spend an attempt.
    if ([System.Net.NetworkCredential]::new('', $Pin).Password -notmatch '^\d{4,8}$') {
        throw [System.ArgumentException]::new('A SIM PIN is 4 to 8 digits.', 'Pin')
    }
    $content = [pscustomobject]@{
        Sim       = ConvertTo-ProtectedText -Text (Get-SimFingerprint -Iccid $Iccid)
        Pin       = ConvertTo-ProtectedText -Secret $Pin
        Attempted = $false
    } | ConvertTo-Json
    if ($PSCmdlet.ShouldProcess($Path, 'Store the SIM PIN')) {
        Write-AppFile -Path $Path -Content $content
    }
}

function Get-SimPin {
    <#
    .SYNOPSIS
        Returns the stored SIM PIN, whether it belongs to a given SIM, and whether it was
        attempted.
    .DESCRIPTION
        Returns nothing when no PIN is stored or the file can't be decrypted by the current user.
        Otherwise: Pin (a SecureString), ForThisSim ($true or $false for the SIM whose -Iccid is
        given, $null without one) and Attempted. These are what Resolve-SimPinAction takes.
    .EXAMPLE
        $stored = Get-SimPin -Iccid $iccid
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Iccid,

        [string] $Path = (Get-AppDataPath -Name 'sim-pin.json')
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $pin = ConvertFrom-ProtectedText -Text $content.Pin
        $sim = ConvertFrom-ProtectedText -Text $content.Sim
        $attempted = [bool]$content.Attempted
    }
    catch {
        return
    }
    if (-not $pin -or -not $sim) {
        return
    }
    [pscustomobject]@{
        Pin        = $pin
        ForThisSim = if ($Iccid) { [System.Net.NetworkCredential]::new('', $sim).Password -eq (Get-SimFingerprint -Iccid $Iccid) } else { $null }
        Attempted  = $attempted
    }
}

function Set-SimPinAttempt {
    <#
    .SYNOPSIS
        Records that the stored PIN was sent (before sending it), or that it worked.
    .DESCRIPTION
        -Attempted $true is written before AT+CPIN is sent, so that an attempt whose answer never
        arrives - a timeout, a crash - is never followed by a second one. -Attempted $false once
        the SIM is seen ready. Does nothing when no PIN is stored.
    .EXAMPLE
        Set-SimPinAttempt -Attempted $true
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [bool] $Attempted,

        [string] $Path = (Get-AppDataPath -Name 'sim-pin.json')
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $content.Attempted = $Attempted
    if ($PSCmdlet.ShouldProcess($Path, "Mark the SIM PIN as $(if ($Attempted) { 'attempted' } else { 'accepted' })")) {
        Write-AppFile -Path $Path -Content ($content | ConvertTo-Json)
    }
}

function Remove-SimPin {
    <#
    .SYNOPSIS
        Deletes the stored SIM PIN.
    .DESCRIPTION
        Done when the SIM rejects the PIN - it is never tried again - and when the user asks.
    .EXAMPLE
        Remove-SimPin
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Path = (Get-AppDataPath -Name 'sim-pin.json')
    )

    if ((Test-Path -LiteralPath $Path) -and $PSCmdlet.ShouldProcess($Path, 'Delete the SIM PIN')) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Disable-SimPin {
    <#
    .SYNOPSIS
        Turns the SIM's PIN request off, so that it no longer asks for its PIN at power-on.
    .DESCRIPTION
        A persistent change on the SIM card, not in the app: only when the user asks for it,
        after a confirmation that says so (ARCHITECTURE -> SIM PIN). It spends a PIN attempt like
        any PIN entry and follows the same rules: the SIM must be ready, and nothing is sent
        when only one attempt is left. Sends AT+CLCK="SC",0,"<pin>" once.

        Returns Result: 'Disabled', 'AlreadyOff' (nothing sent), 'PinRejected' (the PIN was
        wrong: an attempt was spent), 'LastAttempt' or 'SimNotReady' (nothing sent), 'Declined'
        (not confirmed), 'Failed' or 'PortLost'; and AttemptsLeft when the modem tells it.
    .EXAMPLE
        Disable-SimPin -Channel $channel -Pin $pin
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AtChannel] $Channel,

        [Parameter(Mandatory)]
        [securestring] $Pin
    )

    $attemptsLeft = $null
    $outcome = {
        param($result)
        [pscustomobject]@{ Result = $result; AttemptsLeft = $attemptsLeft }
    }
    $cpin = Invoke-AtCommand -Channel $Channel -Command 'AT+CPIN?'
    if ($cpin.Status -eq 'PortLost') {
        return & $outcome 'PortLost'
    }
    $sim = ConvertFrom-AtSimState -Lines $cpin.Lines -ErrorCode $cpin.ErrorCode
    if (-not $sim -or $sim.State -ne 'Ready') {
        return & $outcome 'SimNotReady'
    }
    $enabled = ConvertFrom-AtFacilityLock -Lines (Invoke-AtCommand -Channel $Channel -Command 'AT+CLCK="SC",2').Lines
    if ($enabled -eq $false) {
        return & $outcome 'AlreadyOff'
    }
    $retry = ConvertFrom-AtPinRetry -Lines (Invoke-AtCommand -Channel $Channel -Command 'AT+CPINR').Lines | Where-Object Code -EQ 'SIM PIN' | Select-Object -First 1
    if ($retry) {
        $attemptsLeft = $retry.Retries
    }
    if ($null -ne $attemptsLeft -and $attemptsLeft -le 1) {
        return & $outcome 'LastAttempt'
    }
    if (-not $PSCmdlet.ShouldProcess('the SIM card', 'Turn its PIN request off')) {
        return & $outcome 'Declined'
    }
    $answer = Invoke-AtCommand -Channel $Channel -Command ('AT+CLCK="SC",0,"{0}"' -f [System.Net.NetworkCredential]::new('', $Pin).Password)
    switch ($answer.Status) {
        'OK' { return & $outcome 'Disabled' }
        'PortLost' { return & $outcome 'PortLost' }
    }
    if ($answer.Status -eq 'CmeError' -and $answer.ErrorCode -eq 16) {
        if ($null -ne $attemptsLeft) {
            $attemptsLeft--
        }
        return & $outcome 'PinRejected'
    }
    & $outcome 'Failed'
}

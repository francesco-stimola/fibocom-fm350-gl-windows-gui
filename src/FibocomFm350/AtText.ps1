# Text on the AT port: framing it into lines and telling the lines apart.
# Facts and sources: docs/AT-COMMANDS.md section 2.
#
# The channel keeps the modem's echo on and uses it as an anchor: a command's answer starts after
# its echo, so anything else that arrives before the echo is left over from an earlier command
# (typically a late answer to one that timed out) and is discarded instead of being mistaken for
# this command's answer.

# Final result codes (V.250, 27.007), and the status each one gives the command.
$script:AtFinalResults = @{
    'OK'          = 'OK'
    'ERROR'       = 'Error'
    'NO CARRIER'  = 'NoCarrier'
    'BUSY'        = 'Busy'
    'NO ANSWER'   = 'NoAnswer'
    'NO DIALTONE' = 'NoDialtone'
}

# Prefixes of the unsolicited result codes the app enables. A line with one of them is a URC,
# unless it is the answer's own prefix (AT+CEREG? is answered by +CEREG: too). Codes that span two
# lines (+CMT, +CDS) are never enabled, so they are not listed.
$script:AtUrcPrefixes = @('+CREG', '+CGREG', '+CEREG', '+C5GREG', '+CSCON', '+CMTI', '+CDSI', '+CUSD', '+CGEV')

# Longest unterminated text kept between reads. Real lines are a few hundred characters at most
# (an SMS PDU); more than this without a line end is noise, and keeping it would grow forever.
$script:AtMaxRemainder = 4096

function Split-AtText {
    <#
    .SYNOPSIS
        Splits text received from the AT port into complete lines, keeping the unfinished tail.
    .DESCRIPTION
        A line ends at CR or LF: answers are framed by CR LF, and the echo ends with CR alone.
        Characters outside printable ASCII are dropped, because the port speaks the 7-bit IRA
        character set (PDUs and UCS-2 strings travel as hex), so anything else is line noise.
        Lines left empty are skipped.

        Returns an object with Lines (the complete lines) and Remainder (the text after the last
        line end, to pass back as -Buffer together with the next chunk). A remainder longer than
        4096 characters is noise and is dropped.
    .EXAMPLE
        Split-AtText -Buffer '+CSQ: 2' -Text "0,99`r`n`r`nOK`r`n+CE"

        Lines                 Remainder
        -----                 ---------
        {+CSQ: 20,99, OK}     +CE
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $Buffer = '',

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $all = $Buffer + $Text
    $cut = $all.LastIndexOfAny([char[]]"`r`n")
    $complete = if ($cut -ge 0) { $all.Substring(0, $cut) } else { '' }
    $remainder = if ($cut -ge 0) { $all.Substring($cut + 1) } else { $all }
    if ($remainder.Length -gt $script:AtMaxRemainder) {
        $remainder = ''
    }

    $lines = foreach ($raw in $complete.Split([char[]]"`r`n")) {
        $clean = ($raw -replace '[^\x20-\x7E]', '').Trim()
        if ($clean) {
            $clean
        }
    }

    [pscustomobject]@{
        Lines     = [string[]]@($lines)
        Remainder = $remainder
    }
}

function Get-AtCommandPrefix {
    # The information-response prefixes a command line expects: 'AT+CREG?' -> '+CREG';
    # 'AT+GTCCINFO?;+GTCAINFO?' -> '+GTCCINFO', '+GTCAINFO'; 'ATI' -> none.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Command
    )

    $body = $Command.Trim()
    if ($body -notmatch '^AT') {
        return
    }
    # Quoted arguments may contain ';' or '+'; they never carry a prefix.
    $body = $body.Substring(2) -replace '"[^"]*"', '""'
    foreach ($part in $body.Split(';')) {
        if ($part.Trim() -match '^(\+[A-Z0-9]+)') {
            $Matches[1].ToUpperInvariant()
        }
    }
}

function Resolve-AtLine {
    <#
    .SYNOPSIS
        Classifies one line from the AT port: echo, answer, final result, unsolicited or stale.
    .DESCRIPTION
        -Command is the command waiting for its answer; omit it when none is pending.
        -EchoSeen says whether that command's echo has arrived. Before the echo, only the echo
        itself and unsolicited codes are expected: anything else is left over from an earlier
        command. With no command pending, every line is unsolicited, except a stray final result.

        Returns an object with:
        - Kind: 'Echo', 'Response', 'Final', 'Urc' or 'Stale'.
        - Status, for a final result: 'OK', 'Error', 'CmeError', 'CmsError', 'NoCarrier',
          'Busy', 'NoAnswer' or 'NoDialtone'; otherwise $null.
        - ErrorCode: the number of a '+CME ERROR:' or '+CMS ERROR:', or $null.
        - ErrorText: the text after '+CME ERROR:' or '+CMS ERROR:', or $null.
    .EXAMPLE
        Resolve-AtLine -Line '+CME ERROR: 14' -Command 'AT+CPIN?' -EchoSeen

        Kind  Status   ErrorCode ErrorText
        ----  ------   --------- ---------
        Final CmeError        14 14
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Line,

        [string] $Command,

        [switch] $EchoSeen
    )

    $text = $Line.Trim()
    $status = $null
    $errorCode = $null
    $errorText = $null
    if ($script:AtFinalResults.ContainsKey($text)) {
        $status = $script:AtFinalResults[$text]
    }
    elseif ($text -match '^\+(CME|CMS) ERROR:\s*(.*)$') {
        $status = if ($Matches[1] -eq 'CME') { 'CmeError' } else { 'CmsError' }
        $errorText = $Matches[2]
        if ($errorText -match '^\d+$') {
            $errorCode = [int]$errorText
        }
    }

    $prefix = if ($text -match '^(\+[A-Z0-9]+)\s*:') { $Matches[1].ToUpperInvariant() }
    $isUrcPrefix = $prefix -and $prefix -in $script:AtUrcPrefixes

    $kind = if (-not $Command) {
        if ($status) { 'Stale' } else { 'Urc' }
    }
    elseif ($text -eq $Command.Trim()) {
        'Echo'
    }
    elseif (-not $EchoSeen) {
        if ($isUrcPrefix) { 'Urc' } else { 'Stale' }
    }
    elseif ($status) {
        'Final'
    }
    elseif ($isUrcPrefix -and $prefix -notin @(Get-AtCommandPrefix -Command $Command)) {
        'Urc'
    }
    else {
        'Response'
    }

    [pscustomobject]@{
        Kind      = $kind
        Status    = if ($kind -eq 'Final') { $status } else { $null }
        ErrorCode = if ($kind -eq 'Final') { $errorCode } else { $null }
        ErrorText = if ($kind -eq 'Final') { $errorText } else { $null }
    }
}

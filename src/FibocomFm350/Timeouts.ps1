# How long to wait for each command's answer. Facts and sources: docs/AT-COMMANDS.md section 2;
# design: docs/ARCHITECTURE.md -> AT channel.

# Commands the vendor manual documents as taking longer than the minimum, with their worst case in
# ms. Every other command is documented under 3 s.
$script:AtCommandDurations = @{
    '+COPS'  = 180000
    '+CMGS'  = 60000
    '+CGACT' = 30000
    '+CGATT' = 15000
    '+CUSD'  = 10000
    '+CMGL'  = 5000
}

# The least a command is given: margin for USB latency and a busy modem.
$script:AtMinimumTimeoutMs = 3000

function Get-AtCommandTimeout {
    <#
    .SYNOPSIS
        Returns how long to wait for a command line's answer, in milliseconds.
    .DESCRIPTION
        Each command gets its worst-case duration as documented by the vendor manual, never less
        than 3 s. A compound line ('AT+CPIN?;+CSQ') runs its commands one after the other, so it
        gets the sum of theirs. The form of a command doesn't matter: AT+COPS? gets the 3 min of
        AT+COPS=0.
    .EXAMPLE
        Get-AtCommandTimeout -Command 'AT+CGACT=1,1'

        30000
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $Command
    )

    # Quoted arguments may contain ';' or '+'; they never name a command.
    $body = ($Command.Trim() -replace '^AT', '') -replace '"[^"]*"', '""'
    $total = 0
    foreach ($part in $body.Split(';')) {
        $name = if ($part.Trim() -match '^(\+[A-Za-z0-9]+)') { $Matches[1].ToUpperInvariant() }
        $duration = if ($name -and $script:AtCommandDurations.ContainsKey($name)) { $script:AtCommandDurations[$name] } else { 0 }
        $total += [Math]::Max($duration, $script:AtMinimumTimeoutMs)
    }
    $total
}

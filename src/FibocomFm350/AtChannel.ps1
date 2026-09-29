# The AT channel: sends a command over a transport and collects its answer, keeping unsolicited
# result codes apart. Facts and sources: docs/AT-COMMANDS.md section 2.
#
# One channel per port, owned by one runspace (the app's worker). The channel owns its transport (a
# serial port or the simulated modem; the shape is described in Transport.ps1): Close-AtChannel
# releases it, and a lost port is never touched again.

# Unsolicited codes kept for Receive-AtUrc. Older ones are dropped beyond this, so a reader that
# falls behind can't make the queue grow for weeks.
$script:AtMaxQueuedUrcs = 1000

[NoRunspaceAffinity()]
class AtChannel {
    [object] $Transport
    # 'Open'; 'Lost' once the port is gone; 'Closed' after Close-AtChannel.
    [string] $State = 'Open'
    # Unterminated text carried over between reads.
    hidden [string] $Buffer = ''
    hidden [System.Collections.Generic.Queue[string]] $Urcs = [System.Collections.Generic.Queue[string]]::new()

    AtChannel([object] $transport) {
        $this.Transport = $transport
    }
}

function New-AtChannel {
    <#
    .SYNOPSIS
        Creates an AT channel over a transport (a serial port or the simulated modem).
    .DESCRIPTION
        The transport is Open-SerialAtTransport's or New-SimulatedModem's (any object with the shape
        described in Transport.ps1). The channel takes ownership of it: Close-AtChannel releases it.
        Run Initialize-AtChannel before the first command.
    .EXAMPLE
        $channel = New-AtChannel -Transport (Open-SerialAtTransport -PortName COM5)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object; changes no system state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [object] $Transport
    )

    $missing = @(
        foreach ($method in 'Write', 'Read', 'Close') {
            if (-not $Transport.PSObject.Methods[$method]) { "method $method" }
        }
        foreach ($property in 'PortName', 'Lost') {
            if (-not $Transport.PSObject.Properties[$property]) { "property $property" }
        }
    )
    if ($missing) {
        throw [System.ArgumentException]::new("Not a transport: no $($missing -join ', ').", 'Transport')
    }
    [AtChannel]::new($Transport)
}

function Add-AtQueuedUrc {
    # Queues an unsolicited line on the channel, dropping the oldest beyond the limit.
    param([AtChannel] $Channel, [string] $Line)

    $Channel.Urcs.Enqueue($Line)
    while ($Channel.Urcs.Count -gt $script:AtMaxQueuedUrcs) {
        [void]$Channel.Urcs.Dequeue()
    }
}

function Read-AtChannelLine {
    # Reads once from the transport (up to TimeoutMs) and returns the complete lines received.
    # Marks the channel Lost if the port is gone.
    param([AtChannel] $Channel, [int] $TimeoutMs)

    $text = $Channel.Transport.Read($TimeoutMs)
    if ($Channel.Transport.Lost) {
        $Channel.State = 'Lost'
    }
    if (-not $text) {
        return
    }
    $split = Split-AtText -Buffer $Channel.Buffer -Text $text
    $Channel.Buffer = $split.Remainder
    $split.Lines
}

function Invoke-AtCommand {
    <#
    .SYNOPSIS
        Sends one AT command line and returns its answer.
    .DESCRIPTION
        Writes the command, then collects the lines that follow its echo until a final result
        code or the timeout. Unsolicited result codes that arrive meanwhile are queued for
        Receive-AtUrc; lines left over from an earlier command (before this command's echo) are
        discarded and counted.

        Returns an object with:
        - Command, and Status: 'OK', 'Error', 'CmeError', 'CmsError', 'NoCarrier', 'Busy',
          'NoAnswer', 'NoDialtone', 'Timeout' or 'PortLost'.
        - Lines: the answer's lines, without echo and final result.
        - ErrorCode / ErrorText: from '+CME ERROR:' or '+CMS ERROR:', otherwise $null.
        - EchoSeen: whether the command's echo arrived; a timeout without it suggests the
          modem's echo was turned off (Initialize-AtChannel turns it back on).
        - Discarded: how many stale lines were dropped.
        - ElapsedMs.

        -NoEchoAnchor accepts an answer without waiting for the echo. It exists for ATE1, which
        is sent when the echo may be off, and is not meant for anything else.
        On a lost port the channel becomes 'Lost' and every later command returns 'PortLost'
        without touching the port.
    .EXAMPLE
        $answer = Invoke-AtCommand -Channel $channel -Command 'AT+CSQ' -TimeoutMs 1000
        if ($answer.Status -eq 'OK') { $answer.Lines }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AtChannel] $Channel,

        [Parameter(Mandatory)]
        [ValidatePattern('^AT')]
        [string] $Command,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $TimeoutMs,

        [switch] $NoEchoAnchor
    )

    if ($Channel.State -eq 'Closed') {
        throw [System.InvalidOperationException]::new('The AT channel is closed.')
    }

    $commandLine = $Command.Trim()
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $lines = [System.Collections.Generic.List[string]]::new()
    $echoSeen = $false
    $discarded = 0
    $final = $null
    $status = 'Timeout'

    if ($Channel.State -eq 'Lost') {
        $status = 'PortLost'
    }
    else {
        $Channel.Transport.Write("$commandLine`r")
        if ($Channel.Transport.Lost) {
            $Channel.State = 'Lost'
        }

        while (-not $final -and $Channel.State -eq 'Open') {
            $remaining = $TimeoutMs - $clock.ElapsedMilliseconds
            if ($remaining -le 0) {
                break
            }
            foreach ($line in @(Read-AtChannelLine -Channel $Channel -TimeoutMs $remaining)) {
                if ($final) {
                    # The command is answered: what follows in the same read is unsolicited.
                    if ((Resolve-AtLine -Line $line).Kind -eq 'Urc') {
                        Add-AtQueuedUrc -Channel $Channel -Line $line
                    }
                    else {
                        $discarded++
                    }
                    continue
                }
                $resolved = Resolve-AtLine -Line $line -Command $commandLine -EchoSeen:($echoSeen -or $NoEchoAnchor)
                switch ($resolved.Kind) {
                    'Echo' { $echoSeen = $true }
                    'Urc' { Add-AtQueuedUrc -Channel $Channel -Line $line }
                    'Response' { $lines.Add($line) }
                    'Final' { $final = $resolved }
                    'Stale' { $discarded++ }
                }
            }
        }
        if ($final) {
            $status = $final.Status
        }
        elseif ($Channel.State -eq 'Lost') {
            $status = 'PortLost'
        }
    }

    [pscustomobject]@{
        Command   = $commandLine
        Status    = $status
        Lines     = [string[]]$lines
        ErrorCode = if ($final) { $final.ErrorCode } else { $null }
        ErrorText = if ($final) { $final.ErrorText } else { $null }
        EchoSeen  = $echoSeen
        Discarded = $discarded
        ElapsedMs = $clock.ElapsedMilliseconds
    }
}

function Initialize-AtChannel {
    <#
    .SYNOPSIS
        Prepares the modem's AT port for the channel: echo on, numeric error codes.
    .DESCRIPTION
        Sends ATE1 (echo on; the channel anchors every answer on the echo) and AT+CMEE=1
        ('+CME ERROR: <n>' with a number, which the app maps itself, instead of firmware text).
        The second command is anchored on its echo, so an OK proves the channel is in step.
        Run it after opening the channel, and again after a timeout. Returns the answer to
        AT+CMEE=1, or to ATE1 if that one failed.
    .EXAMPLE
        $ready = Initialize-AtChannel -Channel $channel -TimeoutMs 2000
        if ($ready.Status -ne 'OK') { ... }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AtChannel] $Channel,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $TimeoutMs
    )

    $echo = Invoke-AtCommand -Channel $Channel -Command 'ATE1' -TimeoutMs $TimeoutMs -NoEchoAnchor
    if ($echo.Status -ne 'OK') {
        return $echo
    }
    Invoke-AtCommand -Channel $Channel -Command 'AT+CMEE=1' -TimeoutMs $TimeoutMs
}

function Receive-AtUrc {
    <#
    .SYNOPSIS
        Returns the unsolicited result codes received on the channel, oldest first.
    .DESCRIPTION
        Returns the codes queued while commands ran, plus whatever arrives within -TimeoutMs
        (0: don't wait, only return what is queued). Each is returned once. If the port is lost
        meanwhile, the channel becomes 'Lost' and the codes received so far are still returned:
        check the channel's State.
    .EXAMPLE
        foreach ($urc in Receive-AtUrc -Channel $channel -TimeoutMs 500) { ... }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AtChannel] $Channel,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $TimeoutMs = 0
    )

    if ($Channel.State -eq 'Closed') {
        throw [System.InvalidOperationException]::new('The AT channel is closed.')
    }

    if ($TimeoutMs -gt 0 -and $Channel.State -eq 'Open') {
        foreach ($line in @(Read-AtChannelLine -Channel $Channel -TimeoutMs $TimeoutMs)) {
            if ((Resolve-AtLine -Line $line).Kind -eq 'Urc') {
                Add-AtQueuedUrc -Channel $Channel -Line $line
            }
        }
    }

    while ($Channel.Urcs.Count -gt 0) {
        $Channel.Urcs.Dequeue()
    }
}

function Close-AtChannel {
    <#
    .SYNOPSIS
        Closes an AT channel and releases its port.
    .DESCRIPTION
        Safe to call more than once and on a channel whose port is lost. Queued unsolicited codes
        are discarded.
    .EXAMPLE
        Close-AtChannel -Channel $channel
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AtChannel] $Channel
    )

    if ($Channel.State -ne 'Closed') {
        $Channel.State = 'Closed'
        $Channel.Urcs.Clear()
        $Channel.Buffer = ''
        $Channel.Transport.Close()
    }
}

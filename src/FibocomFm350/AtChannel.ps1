# The AT channel: sends a command over a transport and collects its answer, keeping unsolicited
# result codes apart. Facts and sources: docs/AT-COMMANDS.md section 2.
#
# One channel per port, owned by one runspace (the app's worker). The channel owns its transport (a
# serial port or the simulated modem; the shape is described in Transport.ps1): Close-AtChannel
# releases it, and a lost port is never touched again.

# Unsolicited codes kept for Receive-AtUrc. Older ones are dropped beyond this, so a reader that
# falls behind can't make the queue grow for weeks.
$script:AtMaxQueuedUrcs = 1000

# Timed-out commands whose answers may still arrive. A modem that stops answering times out every
# command without ever echoing one; beyond this many, the oldest is forgotten.
$script:AtMaxLateCommands = 10

[NoRunspaceAffinity()]
class AtChannel {
    [object] $Transport
    # 'Open'; 'Lost' once the port is gone; 'Closed' after Close-AtChannel.
    [string] $State = 'Open'
    # Unterminated text carried over between reads.
    hidden [string] $Buffer = ''
    # Commands that timed out and whose answers may still arrive, oldest first. A stale final
    # result closes the oldest; the next command's echo closes them all.
    hidden [System.Collections.Generic.List[string]] $LateCommands = [System.Collections.Generic.List[string]]::new()
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
        discarded and counted. After a timeout, the channel remembers the command, so that its
        late answer is discarded as well instead of passing for unsolicited codes.

        The command must be printable ASCII: a CR would make the modem run two commands, and a
        character the port can't carry would make the echo unrecognizable.

        Returns an object with:
        - Command, and Status: 'OK', 'Error', 'CmeError', 'CmsError', 'NoCarrier', 'Busy',
          'NoAnswer', 'NoDialtone', 'Timeout' or 'PortLost'.
        - Lines: the answer's lines, without echo and final result.
        - ErrorCode / ErrorText: from '+CME ERROR:' or '+CMS ERROR:', otherwise $null.
        - EchoSeen: whether the command's echo arrived; a timeout without it suggests the
          modem's echo was turned off (Initialize-AtChannel turns it back on).
        - Discarded: how many stale lines were dropped.
        - ElapsedMs.

        -TimeoutMs defaults to the command's documented worst case (Get-AtCommandTimeout).
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
        [ValidatePattern('^AT[\x20-\x7E]*$')]
        [string] $Command,

        [ValidateRange(1, [int]::MaxValue)]
        [int] $TimeoutMs,

        [switch] $NoEchoAnchor
    )

    if ($Channel.State -eq 'Closed') {
        throw [System.InvalidOperationException]::new('The AT channel is closed.')
    }

    $commandLine = $Command.Trim()
    if (-not $PSBoundParameters.ContainsKey('TimeoutMs')) {
        $TimeoutMs = Get-AtCommandTimeout -Command $commandLine
    }
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
                    if ((Resolve-AtLine -Line $line -LateCommand $Channel.LateCommands.ToArray()).Kind -eq 'Urc') {
                        Add-AtQueuedUrc -Channel $Channel -Line $line
                    }
                    else {
                        $discarded++
                    }
                    continue
                }
                # Without an anchor, lines count as the answer only once no late answer is due.
                $anchored = $echoSeen -or ($NoEchoAnchor -and $Channel.LateCommands.Count -eq 0)
                $resolved = Resolve-AtLine -Line $line -Command $commandLine -EchoSeen:$anchored -LateCommand $Channel.LateCommands.ToArray()
                switch ($resolved.Kind) {
                    'Echo' {
                        $echoSeen = $true
                        # The modem runs one command at a time: nothing late can follow this echo.
                        $Channel.LateCommands.Clear()
                    }
                    'Urc' { Add-AtQueuedUrc -Channel $Channel -Line $line }
                    'Response' { $lines.Add($line) }
                    'Final' { $final = $resolved }
                    'Stale' {
                        $discarded++
                        if ($resolved.Status -and $Channel.LateCommands.Count -gt 0) {
                            # A stale final result closes the oldest late answer.
                            $Channel.LateCommands.RemoveAt(0)
                        }
                    }
                }
            }
        }
        if ($final) {
            $status = $final.Status
        }
        elseif ($Channel.State -eq 'Lost') {
            $status = 'PortLost'
        }
        else {
            $Channel.LateCommands.Add($commandLine)
            if ($Channel.LateCommands.Count -gt $script:AtMaxLateCommands) {
                $Channel.LateCommands.RemoveAt(0)
            }
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

function Send-AtMessagePdu {
    <#
    .SYNOPSIS
        Sends one message PDU with AT+CMGS: the command, the modem's '> ' prompt, then the PDU
        ended by Ctrl-Z.
    .DESCRIPTION
        27.005 clause 4.3 (docs/AT-COMMANDS.md section 9): AT+CMGS=<length> ends with CR, the
        modem answers CR LF '> ', takes the PDU in hexadecimal on one line ended by Ctrl-Z, and
        answers '+CMGS: <mr>' and OK, or '+CMS ERROR: <err>'. -Length counts the TPDU's octets
        and -Pdu is the PDU in hexadecimal, as ConvertTo-SmsPdu gives them.

        The prompt is awaited up to -PromptTimeoutMs; the answer up to -TimeoutMs, the command's
        documented worst case by default. When either doesn't come, ESC is sent, so the modem
        leaves its input mode instead of taking the next command for a PDU, and the channel
        remembers the command: its late answer is discarded. Unsolicited codes meanwhile are
        queued, as Invoke-AtCommand queues them; the echo of the command and of the PDU is left
        out.

        Returns Command ('AT+CMGS=<length>'), Status ('OK', 'CmsError', 'CmeError', 'Error',
        'NoPrompt', 'Timeout' or 'PortLost'), Reference (the message reference, or $null),
        ErrorCode, ElapsedMs.
    .EXAMPLE
        foreach ($part in ConvertTo-SmsPdu -Number $number -Text $text) { Send-AtMessagePdu -Channel $channel -Length $part.Length -Pdu $part.Pdu }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AtChannel] $Channel,

        [Parameter(Mandatory)]
        [ValidateRange(1, 255)]
        [int] $Length,

        [Parameter(Mandatory)]
        [ValidatePattern('^(?:[0-9A-Fa-f]{2})+$')]
        [string] $Pdu,

        [ValidateRange(1, [int]::MaxValue)]
        [int] $PromptTimeoutMs = 5000,

        [ValidateRange(1, [int]::MaxValue)]
        [int] $TimeoutMs = (Get-AtCommandTimeout -Command 'AT+CMGS=1')
    )

    if ($Channel.State -eq 'Closed') {
        throw [System.InvalidOperationException]::new('The AT channel is closed.')
    }
    $command = "AT+CMGS=$Length"
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $final = $null
    $reference = $null
    $echoSeen = $false
    $prompted = $false
    $status = 'NoPrompt'
    if ($Channel.State -eq 'Lost') {
        $status = 'PortLost'
    }
    else {
        $Channel.Transport.Write("$command`r")
        if ($Channel.Transport.Lost) {
            $Channel.State = 'Lost'
        }
        # The command's echo, then the prompt - or a final result: refused at once.
        while (-not $prompted -and -not $final -and $Channel.State -eq 'Open') {
            $remaining = $PromptTimeoutMs - $clock.ElapsedMilliseconds
            if ($remaining -le 0) {
                break
            }
            foreach ($line in @(Read-AtChannelLine -Channel $Channel -TimeoutMs $remaining)) {
                $resolved = Resolve-AtLine -Line $line -Command $command -EchoSeen:$echoSeen -LateCommand $Channel.LateCommands.ToArray()
                switch ($resolved.Kind) {
                    'Echo' {
                        $echoSeen = $true
                        $Channel.LateCommands.Clear()
                    }
                    'Urc' { Add-AtQueuedUrc -Channel $Channel -Line $line }
                    'Final' { $final = $resolved }
                }
            }
            # The prompt ends with no line end: it is what is left in the buffer.
            if ($echoSeen -and -not $final -and $Channel.Buffer.TrimStart().StartsWith('>')) {
                $prompted = $true
                $Channel.Buffer = ''
            }
        }
        if ($prompted) {
            $Channel.Transport.Write("$Pdu$([char]0x1A)")
            if ($Channel.Transport.Lost) {
                $Channel.State = 'Lost'
            }
            # The answer: the PDU's echo is left out, the reference kept.
            while (-not $final -and $Channel.State -eq 'Open') {
                $remaining = $TimeoutMs - $clock.ElapsedMilliseconds
                if ($remaining -le 0) {
                    break
                }
                foreach ($line in @(Read-AtChannelLine -Channel $Channel -TimeoutMs $remaining)) {
                    if ($final) {
                        if ((Resolve-AtLine -Line $line).Kind -eq 'Urc') {
                            Add-AtQueuedUrc -Channel $Channel -Line $line
                        }
                        continue
                    }
                    $resolved = Resolve-AtLine -Line $line -Command $command -EchoSeen
                    switch ($resolved.Kind) {
                        'Urc' { Add-AtQueuedUrc -Channel $Channel -Line $line }
                        'Final' { $final = $resolved }
                        'Response' {
                            if ($line -match '^\s*\+CMGS\s*:\s*(\d+)') {
                                $reference = [int]$Matches[1]
                            }
                        }
                    }
                }
            }
        }
        if ($final) {
            $status = $final.Status
        }
        elseif ($Channel.State -eq 'Lost') {
            $status = 'PortLost'
        }
        else {
            $status = if ($prompted) { 'Timeout' } else { 'NoPrompt' }
            # ESC cancels the input; a late answer is discarded, and so is what is left of the
            # PDU's echo, which no line end closed.
            $Channel.Buffer = ''
            $Channel.Transport.Write([string][char]0x1B)
            if ($Channel.Transport.Lost) {
                $Channel.State = 'Lost'
            }
            $Channel.LateCommands.Add($command)
            if ($Channel.LateCommands.Count -gt $script:AtMaxLateCommands) {
                $Channel.LateCommands.RemoveAt(0)
            }
        }
    }

    [pscustomobject]@{
        Command   = $command
        Status    = $status
        Reference = $reference
        ErrorCode = if ($final) { $final.ErrorCode } else { $null }
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
        ATE1 can't be anchored - the echo may be off - so its answer may be a late one from a
        command that timed out; it is not trusted. AT+CMEE=1 is anchored on its echo, so its OK
        proves the channel is in step. Run it after opening the channel, and again after a
        timeout. Returns the answer to AT+CMEE=1, or to ATE1 if the port was lost. -TimeoutMs
        applies to each of the two commands and defaults to their documented worst case.
    .EXAMPLE
        $ready = Initialize-AtChannel -Channel $channel
        if ($ready.Status -ne 'OK') { ... }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AtChannel] $Channel,

        [ValidateRange(1, [int]::MaxValue)]
        [int] $TimeoutMs
    )

    $timeout = @{}
    if ($PSBoundParameters.ContainsKey('TimeoutMs')) {
        $timeout['TimeoutMs'] = $TimeoutMs
    }
    $echo = Invoke-AtCommand -Channel $Channel -Command 'ATE1' -NoEchoAnchor @timeout
    if ($echo.Status -eq 'PortLost') {
        return $echo
    }
    Invoke-AtCommand -Channel $Channel -Command 'AT+CMEE=1' @timeout
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
            $resolved = Resolve-AtLine -Line $line -LateCommand $Channel.LateCommands.ToArray()
            if ($resolved.Kind -eq 'Urc') {
                Add-AtQueuedUrc -Channel $Channel -Line $line
            }
            elseif ($resolved.Status -and $Channel.LateCommands.Count -gt 0) {
                # The final result of the oldest late answer: nothing more of it will come.
                $Channel.LateCommands.RemoveAt(0)
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
        $Channel.LateCommands.Clear()
        $Channel.Transport.Close()
    }
}

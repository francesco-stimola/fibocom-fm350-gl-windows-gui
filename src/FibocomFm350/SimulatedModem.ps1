# The simulated modem: a transport (the shape is described in Transport.ps1) that answers from
# fixtures and plays scripted faults. The tests drive it, and so does the app's development mode
# (no device, no admin rights). Fixture format: docs/SETUP.md -> Fixtures.

[NoRunspaceAffinity()]
class SimulatedModem {
    [string] $PortName
    [bool] $Lost = $false
    # The last 1000 commands received, oldest first, as written (without the CR). Bounded: the
    # development mode runs the simulated modem for as long as the app is open.
    [System.Collections.Generic.List[string]] $Received = [System.Collections.Generic.List[string]]::new()
    [bool] $Echo = $true
    [bool] $Closed = $false

    hidden [System.Collections.Generic.Dictionary[string, string[]]] $Answers
    hidden [System.Collections.Generic.Dictionary[string, System.Collections.Generic.Queue[hashtable]]] $Behaviors
    # Pending output, ordered by due time: @{ Due = <ms on Clock>; Text = <string> }.
    hidden [System.Collections.Generic.List[hashtable]] $Output = [System.Collections.Generic.List[hashtable]]::new()
    hidden [System.Diagnostics.Stopwatch] $Clock = [System.Diagnostics.Stopwatch]::StartNew()
    hidden [bool] $VanishWhenDrained = $false
    # A modem runs one command at a time: a command's output (echo included) can't come out before
    # the previous command's answer. Delay of the next command's output, in ms from now.
    hidden [long] $BusyUntil = 0

    SimulatedModem([string] $portName) {
        $this.PortName = $portName
        $comparer = [System.StringComparer]::OrdinalIgnoreCase
        $this.Answers = [System.Collections.Generic.Dictionary[string, string[]]]::new($comparer)
        $this.Behaviors = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.Queue[hashtable]]]::new($comparer)
    }

    # The standing answer to $command: its lines as the modem sends them, final result last.
    [void] SetAnswer([string] $command, [string[]] $lines) {
        $this.Answers[$command.Trim()] = $lines
    }

    # A one-shot behaviour for the next time $command arrives (queued: several can be lined up).
    # Keys, all optional:
    #   Lines     string[]  answer with these lines instead of the standing answer
    #   DelayMs   int       the answer (not the echo) arrives this much later
    #   SplitAt   int[]     cut the output (echo + answer) at these character offsets: each piece
    #                       comes out of a separate Read
    #   Garbage   string    text sent before the answer, as line noise
    #   UrcAfter  int       send Urc after this many answer lines
    #   Urc       string    the unsolicited line for UrcAfter
    #   NoFinal   bool      leave out the final result code
    #   Vanish    bool      the port disappears once this output has been read
    #   Then      hashtable command -> lines: standing answers that change once this command
    #                       has run (a context activated, a SIM unlocked)
    #   Times     int       queue the behaviour this many times (default 1)
    [void] Script([string] $command, [hashtable] $behavior) {
        $key = $command.Trim()
        if (-not $this.Behaviors.ContainsKey($key)) {
            $this.Behaviors[$key] = [System.Collections.Generic.Queue[hashtable]]::new()
        }
        $times = if ($behavior.ContainsKey('Times')) { [int]$behavior['Times'] } else { 1 }
        for ($i = 0; $i -lt $times; $i++) {
            $this.Behaviors[$key].Enqueue($behavior)
        }
    }

    # An unsolicited line, sent $delayMs from now.
    [void] EmitUnsolicited([string] $line, [int] $delayMs) {
        $this.Enqueue("`r`n$line`r`n", $delayMs)
    }

    # The device disappears now (unplugged, reset): the open port is lost.
    [void] Vanish() {
        $this.Lost = $true
        $this.Output.Clear()
    }

    # The device is back, possibly under another COM number, with its power-on defaults; it can
    # be opened again by a new channel.
    [void] Reappear([string] $portName) {
        $this.PortName = $portName
        $this.Lost = $false
        $this.Closed = $false
        $this.Echo = $true
        $this.VanishWhenDrained = $false
        $this.BusyUntil = 0
        $this.Output.Clear()
    }

    # The port opened again after Close, by a new channel: the device keeps its answers and what
    # scripted commands changed (the development mode's worker restarts on the same device). A
    # lost port stays lost until Reappear.
    [void] Reopen() {
        $this.Closed = $false
        $this.Output.Clear()
        $this.BusyUntil = 0
    }

    [void] Write([string] $text) {
        if (-not $this.IsUsable()) {
            return
        }
        foreach ($command in $text.Split("`r")) {
            $command = $command.Trim()
            if ($command) {
                $this.Handle($command)
            }
        }
    }

    [string] Read([int] $timeoutMs) {
        $deadline = $this.Clock.ElapsedMilliseconds + [Math]::Max(0, $timeoutMs)
        while ($true) {
            $now = $this.Clock.ElapsedMilliseconds
            if ($this.Output.Count -gt 0 -and $this.Output[0]['Due'] -le $now) {
                $text = $this.Output[0]['Text']
                $this.Output.RemoveAt(0)
                return $text
            }
            if (-not $this.IsUsable()) {
                return ''
            }
            $wakeAt = $deadline
            if ($this.Output.Count -gt 0 -and $this.Output[0]['Due'] -lt $wakeAt) {
                $wakeAt = $this.Output[0]['Due']
            }
            if ($wakeAt -le $now) {
                return ''
            }
            [System.Threading.Thread]::Sleep([int]($wakeAt - $now))
        }
        return ''
    }

    [void] Close() {
        $this.Closed = $true
        $this.Output.Clear()
    }

    # False once the port is lost; the modem vanishes once scripted output with Vanish is drained.
    hidden [bool] IsUsable() {
        if ($this.Closed) {
            throw [System.ObjectDisposedException]::new("SimulatedModem($($this.PortName))")
        }
        if ($this.VanishWhenDrained -and $this.Output.Count -eq 0) {
            $this.Vanish()
        }
        return -not $this.Lost
    }

    hidden [void] Handle([string] $command) {
        $this.Received.Add($command)
        if ($this.Received.Count -gt 1000) {
            $this.Received.RemoveAt(0)
        }
        $behavior = @{}
        if ($this.Behaviors.ContainsKey($command) -and $this.Behaviors[$command].Count -gt 0) {
            $behavior = $this.Behaviors[$command].Dequeue()
        }

        # The echo reflects the setting in force when the command arrives.
        $echoText = if ($this.Echo) { "$command`r" } else { '' }
        $lines = [System.Collections.Generic.List[string]]::new()
        if ($behavior.ContainsKey('Lines')) {
            $lines.AddRange([string[]]$behavior['Lines'])
        }
        else {
            $lines.AddRange($this.StandingAnswer($command))
        }
        if ($behavior['NoFinal'] -and $lines.Count -gt 0) {
            $lines.RemoveAt($lines.Count - 1)
        }
        if ($behavior.ContainsKey('UrcAfter')) {
            $lines.Insert([Math]::Min([int]$behavior['UrcAfter'], $lines.Count), [string]$behavior['Urc'])
        }

        $answer = [string]$behavior['Garbage']
        foreach ($line in $lines) {
            $answer += "`r`n$line`r`n"
        }

        $wait = [Math]::Max(0, $this.BusyUntil - $this.Clock.ElapsedMilliseconds)
        $delay = $wait + [int]$behavior['DelayMs']
        $cuts = @($behavior['SplitAt'] | Where-Object { $null -ne $_ })
        if ($cuts.Count -gt 0) {
            $whole = $echoText + $answer
            $start = 0
            foreach ($cut in ($cuts | Sort-Object)) {
                if ($cut -gt $start -and $cut -lt $whole.Length) {
                    $this.Enqueue($whole.Substring($start, $cut - $start), $delay)
                    $start = $cut
                }
            }
            $this.Enqueue($whole.Substring($start), $delay)
        }
        else {
            if ($echoText) {
                $this.Enqueue($echoText, $wait)
            }
            $this.Enqueue($answer, $delay)
        }
        $this.BusyUntil = $this.Clock.ElapsedMilliseconds + $delay
        if ($behavior['Vanish']) {
            $this.VanishWhenDrained = $true
        }
        if ($behavior.ContainsKey('Then')) {
            foreach ($changed in $behavior['Then'].Keys) {
                $this.SetAnswer($changed, [string[]]$behavior['Then'][$changed])
            }
        }
    }

    hidden [string[]] StandingAnswer([string] $command) {
        if ($command -match '^ATE([01])$') {
            $this.Echo = $Matches[1] -eq '1'
            return @('OK')
        }
        if ($command -eq 'AT' -or $command -match '^AT\+CMEE=[012]$') {
            return @('OK')
        }
        if ($this.Answers.ContainsKey($command)) {
            return $this.Answers[$command]
        }
        return @('ERROR')
    }

    hidden [void] Enqueue([string] $text, [int] $delayMs) {
        if (-not $text) {
            return
        }
        $due = $this.Clock.ElapsedMilliseconds + [Math]::Max(0, $delayMs)
        $index = $this.Output.Count
        while ($index -gt 0 -and $this.Output[$index - 1]['Due'] -gt $due) {
            $index--
        }
        $this.Output.Insert($index, @{ Due = $due; Text = $text })
    }
}

function Import-AtFixture {
    <#
    .SYNOPSIS
        Reads an AT fixture file: one command and the answer the modem gives to it.
    .DESCRIPTION
        Format (docs/SETUP.md -> Fixtures): lines starting with '#' are notes, blank lines are
        ignored, the first other line is the command, and the remaining lines are the answer as
        the modem sends it, without echo or framing, ending with its final result code.

        Returns an object with Path, Command, Lines (the answer) and Notes.
    .EXAMPLE
        Import-AtFixture -Path tests/fixtures/documented/csq.txt
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string] $Path
    )

    process {
        $notes = [System.Collections.Generic.List[string]]::new()
        $content = [System.Collections.Generic.List[string]]::new()
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^\s*#') {
                $notes.Add($line.TrimStart().Substring(1).Trim())
            }
            elseif ($line.Trim()) {
                $content.Add($line.Trim())
            }
        }

        if ($content.Count -lt 2 -or $content[0] -notmatch '^AT') {
            throw "Fixture '$Path': expected a command starting with AT, then its answer."
        }
        $lines = [string[]]$content.GetRange(1, $content.Count - 1)
        $last = Resolve-AtLine -Line $lines[-1] -Command $content[0] -EchoSeen
        if ($last.Kind -ne 'Final') {
            throw "Fixture '$Path': the answer must end with a final result code, not '$($lines[-1])'."
        }

        [pscustomobject]@{
            Path    = $Path
            Command = $content[0]
            Lines   = $lines
            Notes   = [string[]]$notes
        }
    }
}

function New-SimulatedModem {
    <#
    .SYNOPSIS
        Creates a simulated FM350 that answers from fixtures, for tests and development mode.
    .DESCRIPTION
        The simulated modem is a transport for New-AtChannel. It keeps echo on (the FM350's
        power-on default), answers AT, ATE0/ATE1 and AT+CMEE by itself, answers any command
        with a fixture, and anything else with ERROR.

        Scripted faults and events are methods on the returned object: Script($command,
        $behavior) for one-shot behaviours (delay, split output, garbage, a URC inside the answer,
        no final result, the port vanishing, answers that change once the command has run),
        EmitUnsolicited($line, $delayMs), Vanish() and
        Reappear($portName). SetAnswer($command, $lines) sets a standing answer. Reopen() opens
        the port again after a channel closed it. Received lists the commands written to it.
    .EXAMPLE
        $modem = New-SimulatedModem -Fixture (Get-ChildItem tests/fixtures/documented)
        $modem.Script('AT+COPS=0', @{ DelayMs = 500 })
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object; changes no system state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [string] $PortName = 'SIMULATED',

        [Parameter(ValueFromPipeline)]
        [object[]] $Fixture = @()
    )

    begin {
        $modem = [SimulatedModem]::new($PortName)
        $seen = @{}
    }

    process {
        foreach ($item in $Fixture) {
            # A fixture already imported, a file from Get-ChildItem, or a path.
            $loaded = if ($item.PSObject.Properties['Command']) {
                $item
            }
            elseif ($item -is [System.IO.FileInfo]) {
                Import-AtFixture -Path $item.FullName
            }
            else {
                Import-AtFixture -Path ([string]$item)
            }
            if ($seen.ContainsKey($loaded.Command)) {
                throw "Fixtures '$($seen[$loaded.Command])' and '$($loaded.Path)' both answer '$($loaded.Command)'."
            }
            $seen[$loaded.Command] = $loaded.Path
            $modem.SetAnswer($loaded.Command, $loaded.Lines)
        }
    }

    end {
        $modem
    }
}

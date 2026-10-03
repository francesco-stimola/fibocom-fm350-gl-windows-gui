# The simulated modem: a transport (the shape is described in Transport.ps1) that answers from
# fixtures and plays scripted faults. The tests drive it, and so does the app's development mode
# (no device, no admin rights). Fixture format: docs/SETUP.md -> Fixtures.

# The simulated modem's network mode and bands (AT+GTACT, AT-COMMANDS section 5), when it has one:
# the mode and the band list of each RAT it keeps, what it supports, and what a change does - the
# modem registers again, in the network around it, whose cells use some LTE and NR bands and offer
# 5G SA or not. Like the device, it lists each band once every band is allowed, drops n77 by itself
# once registered, and keeps its setting across a reset.
[NoRunspaceAffinity()]
class SimulatedNetworkMode {
    [int] $Rat = 20
    [string[]] $Preferences = @('6', '3')
    [int[]] $SupportedRats = @(1, 2, 4, 10, 14, 16, 17, 20)
    # The band codes it supports, by RAT, and those it keeps.
    [hashtable] $Supported = @{ UMTS = [int[]]@(); LTE = [int[]]@(); NR = [int[]]@() }
    [hashtable] $Bands = @{ UMTS = [int[]]@(); LTE = [int[]]@(); NR = [int[]]@() }
    # Codes it drops by itself once it has tried to register after a write that set them, when
    # the other code is in the list too: n77 with n78 (AT-COMMANDS section 5).
    [hashtable] $Dropped = @{ 5077 = 5078 }
    # The network around it: the band codes its cells use, and whether it offers 5G SA.
    [int[]] $NetworkLte = @()
    [int[]] $NetworkNr = @()
    [bool] $Standalone = $false
    # Registration reads that find it searching after a change, before it registers again.
    [int] $SearchReads = 1
    # Its answers in each situation: Registration (Lte, Sa, Searching) and Radio - the
    # AT+CESQ and AT+GTCCINFO?;+GTCAINFO? answers on EN-DC, LTE alone, 5G SA, and none.
    [hashtable] $Registration = @{}
    [hashtable] $Radio = @{}
    hidden [int] $Searching = 0
    hidden [bool] $DropPending = $false
    # Its radio answers follow what it does - a change, a registration, a restart -, never
    # the answers a scenario starts from.
    hidden [bool] $RadioDue = $false

    static [string] $RegistrationRead = 'AT+CEREG?;+C5GREG?'
    static [hashtable] $Rats = @{
        1 = @('UMTS'); 2 = @('LTE'); 4 = @('UMTS', 'LTE'); 10 = @('UMTS', 'LTE', 'NR'); 14 = @('NR')
        16 = @('UMTS', 'NR'); 17 = @('LTE', 'NR'); 20 = @('UMTS', 'LTE', 'NR')
    }

    # The answer to an AT+GTACT command, or $null for any other command.
    [string[]] Answer([string] $command) {
        if ($command -eq 'AT+GTACT?') {
            $values = [System.Collections.Generic.List[string]]::new()
            $values.Add([string]$this.Rat)
            $values.AddRange([string[]]$this.Preferences)
            foreach ($kind in 'UMTS', 'LTE', 'NR') {
                if ($kind -in [SimulatedNetworkMode]::Rats[$this.Rat]) {
                    foreach ($code in $this.Bands[$kind]) {
                        $values.Add([string]$code)
                    }
                }
            }
            return @("+GTACT: $($values -join ',')", 'OK')
        }
        if ($command -eq 'AT+GTACT=?') {
            $lists = @(
                ($this.SupportedRats -join ','), '2,3,6', '2,3,6', '', ($this.Supported['UMTS'] -join ','),
                ($this.Supported['LTE'] -join ','), '', '', ($this.Supported['NR'] -join ',')
            )
            return @("+GTACT: $(($lists | ForEach-Object { "($_)" }) -join ',')", 'OK')
        }
        if ($command -match '^AT\+GTACT=(.+)$') {
            if ($this.Write($Matches[1])) {
                return @('OK')
            }
            return @('ERROR')
        }
        return $null
    }

    # A write: the mode, then for each RAT named by a code its new list - code 0 gives every RAT
    # of the mode all its bands. Refused whole when a value is not one it takes.
    hidden [bool] Write([string] $text) {
        $fields = @($text.Split(',') | ForEach-Object { $_.Trim() })
        $value = 0
        if (-not [int]::TryParse($fields[0], [ref]$value) -or $value -notin $this.SupportedRats) {
            return $false
        }
        $preferred = @(foreach ($index in 1, 2) { if ($index -lt $fields.Count) { $fields[$index] } else { '' } })
        if (@($preferred | Where-Object { $_ -notin '', '2', '3', '6' }).Count -gt 0) {
            return $false
        }
        $offered = $this.Supported
        $named = @{ UMTS = [System.Collections.Generic.List[int]]::new(); LTE = [System.Collections.Generic.List[int]]::new(); NR = [System.Collections.Generic.List[int]]::new() }
        $all = $false
        foreach ($field in @($fields | Select-Object -Skip 3)) {
            $code = 0
            if (-not [int]::TryParse($field, [ref]$code)) {
                return $false
            }
            if ($code -eq 0) {
                $all = $true
                continue
            }
            $kind = @('UMTS', 'LTE', 'NR' | Where-Object { $code -in $offered[$_] })
            if ($kind.Count -eq 0) {
                return $false
            }
            $named[$kind[0]].Add($code)
        }
        $this.Rat = if ($value -eq 10) { 20 } else { $value }
        $this.Preferences = [string[]]$preferred
        foreach ($kind in 'UMTS', 'LTE', 'NR') {
            if ($all -and $kind -in [SimulatedNetworkMode]::Rats[$this.Rat]) {
                $this.Bands[$kind] = [int[]]$this.Supported[$kind]
            }
            elseif ($named[$kind].Count -gt 0) {
                $chosen = $named[$kind]
                $this.Bands[$kind] = [int[]]@($this.Supported[$kind] | Where-Object { $_ -in $chosen })
            }
        }
        $this.DropPending = $true
        return $true
    }

    # What follows a command: a write registers the modem again, after SearchReads registration
    # reads, if the network around it has cells it may use; registered, its radio answers match
    # its mode and n77 goes.
    [void] After([string] $command, [bool] $succeeded, [object] $modem) {
        if ($succeeded -and $command -match '^AT\+GTACT=[^?]') {
            $modem.SetAnswer([SimulatedNetworkMode]::RegistrationRead, [string[]]$this.Registration['Searching'])
            # The data context goes with the registration.
            $modem.SetAnswer('AT+CGACT?', @('OK'))
            $this.Searching = $this.SearchReads
            $this.RadioDue = $true
        }
        elseif ($command -eq [SimulatedNetworkMode]::RegistrationRead -and $this.Searching -gt 0) {
            $this.Searching--
            if ($this.Searching -eq 0) {
                $this.Drop()
                $found = $this.Found()
                if ($found -eq 'Lte') {
                    $modem.SetAnswer([SimulatedNetworkMode]::RegistrationRead, [string[]]$this.Registration['Lte'])
                }
                elseif ($found -eq 'Sa') {
                    $modem.SetAnswer([SimulatedNetworkMode]::RegistrationRead, [string[]]$this.Registration['Sa'])
                }
                $this.RadioDue = $true
            }
        }
        $this.Settle($modem)
    }

    # Keeps what the modem answers consistent with its mode: a registration on LTE that the mode
    # can't have - after a reset, the radio back on - is the one the mode finds, or none.
    [void] Settle([object] $modem) {
        $current = ($modem.GetAnswer([SimulatedNetworkMode]::RegistrationRead) -join '|')
        $onLte = $current -eq ($this.Registration['Lte'] -join '|')
        $onSa = $current -eq ($this.Registration['Sa'] -join '|')
        if (($onLte -or $onSa) -and $this.Searching -eq 0) {
            $found = $this.Found()
            if (($onLte -and $found -ne 'Lte') -or ($onSa -and $found -ne 'Sa')) {
                $answer = if ($found) { $this.Registration[$found] } else { $this.Registration['Searching'] }
                $modem.SetAnswer([SimulatedNetworkMode]::RegistrationRead, [string[]]$answer)
                $onLte = $found -eq 'Lte'
                $onSa = $found -eq 'Sa'
                $this.RadioDue = $true
            }
        }
        if (($onLte -or $onSa) -and $this.DropPending) {
            $this.Drop()
        }
        if ($this.RadioDue) {
            $situation = if ($onLte -and $this.NrLeg()) { 'Endc' } elseif ($onLte) { 'Lte' } elseif ($onSa) { 'Sa' } else { 'None' }
            if ($this.Radio.ContainsKey($situation)) {
                foreach ($read in $this.Radio[$situation].Keys) {
                    $modem.SetAnswer($read, [string[]]$this.Radio[$situation][$read])
                }
            }
            $this.RadioDue = $false
        }
    }

    # The codes it drops by itself, once it has tried to register.
    hidden [void] Drop() {
        foreach ($kind in 'UMTS', 'LTE', 'NR') {
            $list = $this.Bands[$kind]
            $pairs = $this.Dropped
            $gone = @($pairs.Keys | Where-Object { $_ -in $list -and $pairs[$_] -in $list })
            $this.Bands[$kind] = [int[]]@($list | Where-Object { $_ -notin $gone })
        }
        $this.DropPending = $false
    }

    # Back from a restart: its answers, back to their defaults, are made to match its mode.
    [void] Restarted() {
        $this.Searching = 0
        $this.RadioDue = $true
    }

    # 'Lte' or 'Sa': the network the modem finds in its mode and bands; '' for none.
    [string] Found() {
        $inMode = [SimulatedNetworkMode]::Rats[$this.Rat]
        $lte = $this.Bands['LTE']
        $nr = $this.Bands['NR']
        if ('LTE' -in $inMode -and @($this.NetworkLte | Where-Object { $_ -in $lte }).Count -gt 0) {
            return 'Lte'
        }
        if ('NR' -in $inMode -and $this.Standalone -and @($this.NetworkNr | Where-Object { $_ -in $nr }).Count -gt 0) {
            return 'Sa'
        }
        return ''
    }

    # Whether an LTE registration gets an NR leg: the mode has NR, and its bands a cell's.
    [bool] NrLeg() {
        $nr = $this.Bands['NR']
        return 'NR' -in [SimulatedNetworkMode]::Rats[$this.Rat] -and @($this.NetworkNr | Where-Object { $_ -in $nr }).Count -gt 0
    }
}

[NoRunspaceAffinity()]
class SimulatedModem {
    [string] $PortName
    [bool] $Lost = $false
    # The last 1000 commands received, oldest first, as written (without the CR). Bounded: the
    # development mode runs the simulated modem for as long as the app is open.
    [System.Collections.Generic.List[string]] $Received = [System.Collections.Generic.List[string]]::new()
    [bool] $Echo = $true
    [bool] $Closed = $false
    # Hung: the modem takes commands and answers nothing - no echo, no result - until it is
    # restarted (Reappear).
    [bool] $Hung = $false
    # The device's state beyond its answers, which scripted commands can change: DataPath ('Down':
    # traffic doesn't get through), read by the simulated device.
    [System.Collections.Generic.Dictionary[string, string]] $Flags = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Its network mode and bands (SimulatedNetworkMode), or $null: AT+GTACT answered from fixtures.
    [object] $NetworkMode

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

    # The standing answer to $command, or none.
    [string[]] GetAnswer([string] $command) {
        if ($this.Answers.ContainsKey($command.Trim())) {
            return $this.Answers[$command.Trim()]
        }
        return @()
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
    #                       has run (a context activated, a SIM unlocked) - when it succeeded:
    #                       its answer ends with OK
    #   Flags     hashtable flag -> value: device flags set once this command has run, when it
    #                       succeeded
    #   Times     int       queue the behaviour this many times (default 1)
    #   Keep      bool      a standing behaviour: every time the command arrives, never used up
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
        if ($this.NetworkMode) {
            $this.NetworkMode.Restarted()
        }
        $this.PortName = $portName
        $this.Lost = $false
        $this.Closed = $false
        $this.Hung = $false
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
        if ($this.Hung) {
            return
        }
        $behavior = @{}
        if ($this.Behaviors.ContainsKey($command) -and $this.Behaviors[$command].Count -gt 0) {
            $queue = $this.Behaviors[$command]
            $behavior = if ($queue.Peek()['Keep']) { $queue.Peek() } else { $queue.Dequeue() }
        }

        # The echo reflects the setting in force when the command arrives.
        $echoText = if ($this.Echo) { "$command`r" } else { '' }
        $lines = [System.Collections.Generic.List[string]]::new()
        # A scripted answer stands in for the network mode's own: the command then changes nothing.
        $own = if ($this.NetworkMode -and -not $behavior.ContainsKey('Lines')) { $this.NetworkMode.Answer($command) } else { $null }
        if ($behavior.ContainsKey('Lines')) {
            $lines.AddRange([string[]]$behavior['Lines'])
        }
        elseif ($null -ne $own) {
            $lines.AddRange([string[]]$own)
        }
        else {
            $lines.AddRange($this.StandingAnswer($command))
        }
        $succeeded = $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq 'OK'
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
        if ($succeeded -and $behavior.ContainsKey('Then')) {
            foreach ($changed in $behavior['Then'].Keys) {
                $this.SetAnswer($changed, [string[]]$behavior['Then'][$changed])
            }
        }
        if ($succeeded -and $behavior.ContainsKey('Flags')) {
            foreach ($flag in $behavior['Flags'].Keys) {
                $this.Flags[$flag] = [string]$behavior['Flags'][$flag]
            }
        }
        if ($this.NetworkMode) {
            $this.NetworkMode.After($command, $succeeded, $this)
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

function New-SimulatedNetworkMode {
    # A simulated modem's network mode (SimulatedNetworkMode), from its description in
    # Data/Simulation.psd1: each key sets the property of the same name.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object; changes no system state.')]
    param([hashtable] $Description)

    $mode = [SimulatedNetworkMode]::new()
    foreach ($key in $Description.Keys) {
        $value = $Description[$key]
        $mode.$key = switch ($key) {
            { $_ -in 'Supported', 'Bands' } {
                $lists = @{}
                foreach ($rat in $value.Keys) {
                    $lists[$rat] = [int[]]@($value[$rat])
                }
                $lists
            }
            default { $value }
        }
    }
    $mode
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
        Hung makes it answer nothing until it reappears; Flags is device state that scripted
        commands change (the simulated device reads DataPath).
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

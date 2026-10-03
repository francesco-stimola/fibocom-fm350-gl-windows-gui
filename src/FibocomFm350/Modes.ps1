# The network mode and its bands: what AT+GTACT reads and writes, and when the app writes it.
# Facts and sources: docs/AT-COMMANDS.md section 5; design: docs/ARCHITECTURE.md -> Modes and bands.
#
# Band codes are handled as codes, not band numbers, wherever they travel back to the modem: a code
# read and written back is never lost, even one the app doesn't understand (invariant 9).

# The modes the app offers, by their setting name: the +GTACT RAT and preferred RATs written, and
# the RATs whose band lists the app keeps. Which modes: the maintainer's decision (ROADMAP M5).
$script:NetworkModes = [ordered]@{
    Automatic = @{ Rat = 20; Preferences = @(6, 3); Lte = $true; Nr = $true }
    LteOnly   = @{ Rat = 2; Preferences = @(3, 3); Lte = $true; Nr = $false }
    NrOnly    = @{ Rat = 14; Preferences = @(6, 6); Lte = $false; Nr = $true }
}

# How many RATs each +GTACT <rat> value combines (AT-COMMANDS section 5): in a two-RAT mode only the
# first preference counts, in a one-RAT mode none.
$script:GtactRatCounts = @{ 1 = 1; 2 = 1; 4 = 2; 10 = 3; 14 = 1; 16 = 2; 17 = 2; 20 = 3 }

# A change the user asks for is tried: confirmed by a registration seen this long after the write at
# the earliest - before it, a reading may still be the one the change is about to end - and undone
# when none came by the end of the maintenance window it opened.
$script:NetworkModeConfirmAfterMs = 10000

# Codes the modem drops by itself, each when the other code is in the same list: n77 with n78
# (AT-COMMANDS section 5). A list asked with both is the modem's with the second alone.
$script:NetworkModeDroppedCodes = @{ 5077 = 5078 }

function Get-NetworkModeName {
    # The app's name of a +GTACT RAT value, or $null for a mode the app doesn't offer.
    param([Nullable[int]] $Rat)

    foreach ($name in $script:NetworkModes.Keys) {
        if ($script:NetworkModes[$name].Rat -eq $Rat) {
            return $name
        }
    }
    $null
}

function ConvertTo-AtNetworkModeCommand {
    <#
    .SYNOPSIS
        Writes the AT+GTACT command that sets a mode, its preferred RATs and band codes.
    .DESCRIPTION
        'AT+GTACT=<rat>,<pref1>,<pref2>,<band>,...' (AT-COMMANDS section 5), with a missing
        preference left empty and empty values at the end left out. The codes are written as
        given, in their order: those read from the modem go back unchanged.
    .EXAMPLE
        ConvertTo-AtNetworkModeCommand -Rat 20 -Preferences 6, 3 -Code 103, 5078
        AT+GTACT=20,6,3,103,5078
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int] $Rat,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Preferences = @(),

        [AllowEmptyCollection()]
        [int[]] $Code = @()
    )

    $values = [System.Collections.Generic.List[string]]::new()
    $values.Add([string]$Rat)
    $preferred = @($Preferences)
    foreach ($index in 0, 1) {
        $values.Add($(if ($index -lt $preferred.Count -and $null -ne $preferred[$index]) { [string]$preferred[$index] } else { '' }))
    }
    foreach ($value in $Code) {
        $values.Add([string]$value)
    }
    while ($values.Count -gt 1 -and $values[$values.Count - 1] -eq '') {
        $values.RemoveAt($values.Count - 1)
    }
    'AT+GTACT=' + ($values -join ',')
}

function Split-NetworkModeCode {
    # Sorts band codes by RAT: LteCodes and NrCodes, with their band numbers (Lte, Nr), and
    # OtherCodes - UMTS codes and any the codec doesn't recognize. AllBands: a code 0 is among them.
    param([AllowEmptyCollection()] [int[]] $Code)

    $sorted = @{ LTE = [System.Collections.Generic.List[int]]::new(); NR = [System.Collections.Generic.List[int]]::new(); Other = [System.Collections.Generic.List[int]]::new() }
    $bands = @{ LTE = [System.Collections.Generic.List[int]]::new(); NR = [System.Collections.Generic.List[int]]::new() }
    $all = $false
    foreach ($value in $Code) {
        $decoded = ConvertFrom-GtactBandCode -Code ([string]$value)
        switch ($decoded.Kind) {
            { $_ -in 'LTE', 'NR' } {
                $sorted[$_].Add($value)
                $bands[$_].Add($decoded.Band)
            }
            'AllBands' { $all = $true }
            default { $sorted['Other'].Add($value) }
        }
    }
    [pscustomobject]@{
        LteCodes   = [int[]]$sorted['LTE'].ToArray()
        NrCodes    = [int[]]$sorted['NR'].ToArray()
        OtherCodes = [int[]]$sorted['Other'].ToArray()
        Lte        = [int[]]$bands['LTE'].ToArray()
        Nr         = [int[]]$bands['NR'].ToArray()
        AllBands   = $all
    }
}

function ConvertFrom-AtNetworkMode {
    <#
    .SYNOPSIS
        Reads the network mode and its band lists from the answer to AT+GTACT?.
    .DESCRIPTION
        '+GTACT: <rat>,<pref1>,<pref2>,<band>,...' (AT-COMMANDS section 5): the modem lists the
        band codes of the RATs in its mode - UMTS codes too, in a mode with UMTS.

        Returns Rat (automatic, 10, read as 20, as the modem reports it), Preferences (the two
        preferred RATs, $null where empty), Mode (the app's name for the RAT, or $null), Codes
        (every band code, in the modem's order: written back as they are, they lose nothing),
        LteCodes, NrCodes and OtherCodes (by RAT; UMTS codes and unknown ones are Other), Lte and
        Nr (band numbers), AllBands ($true when a code 0 stands for every band) and Text (the
        values as read, to tell whether they changed). $null without a +GTACT line whose RAT is
        a number, or with a band field that is no code.
    .EXAMPLE
        ConvertFrom-AtNetworkMode -Lines '+GTACT: 2,3,3,103,120'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Lines
    )

    $text = @(Get-AtPrefixedLine -Lines $Lines -Prefix '+GTACT') | Where-Object { $_ -notmatch '\(' } | Select-Object -First 1
    if ($null -eq $text) {
        return $null
    }
    $fields = @($text -split ',' | ForEach-Object { $_.Trim() })
    $rat = ConvertTo-AtInteger -Text $fields[0]
    if ($null -eq $rat) {
        return $null
    }
    if ($rat -eq 10) {
        $rat = 20
    }
    $preferences = [object[]]@(foreach ($index in 1, 2) {
            if ($index -lt $fields.Count) { ConvertTo-AtInteger -Text $fields[$index] } else { $null }
        })
    $codes = [System.Collections.Generic.List[int]]::new()
    foreach ($field in @($fields | Select-Object -Skip 3)) {
        if ($field -notmatch '^(0|[1-9][0-9]{0,8})$') {
            return $null
        }
        $codes.Add([int]$field)
    }
    $split = Split-NetworkModeCode -Code $codes.ToArray()
    [pscustomobject]@{
        Rat         = $rat
        Preferences = $preferences
        Mode        = Get-NetworkModeName -Rat $rat
        Codes       = [int[]]$codes.ToArray()
        LteCodes    = $split.LteCodes
        NrCodes     = $split.NrCodes
        OtherCodes  = $split.OtherCodes
        Lte         = $split.Lte
        Nr          = $split.Nr
        AllBands    = $split.AllBands
        Text        = ($fields -join ',')
    }
}

function ConvertFrom-AtNetworkModeSupport {
    <#
    .SYNOPSIS
        Reads the values the modem supports from the answer to AT+GTACT=?.
    .DESCRIPTION
        Parenthesized lists (AT-COMMANDS section 5): the RATs, the first and second preferred
        RAT, then the band codes of GSM, UMTS, LTE, CDMA, EVDO and NR. Band codes are sorted by
        what they decode to, whatever list they stand in.

        Returns Rats (the RAT values), Modes (the app's modes whose RAT the modem takes, in the
        app's order), LteCodes and NrCodes (in the modem's order), Lte and Nr (their band
        numbers). $null without a +GTACT line of lists.
    .EXAMPLE
        ConvertFrom-AtNetworkModeSupport -Lines $answer.Lines
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Lines
    )

    $text = @(Get-AtPrefixedLine -Lines $Lines -Prefix '+GTACT') | Where-Object { $_ -match '\(' } | Select-Object -First 1
    if ($null -eq $text) {
        return $null
    }
    $groups = @([regex]::Matches($text, '\(([^)]*)\)') | ForEach-Object {
            , [int[]]@($_.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^(0|[1-9][0-9]{0,8})$' } | ForEach-Object { [int]$_ })
        })
    if ($groups.Count -lt 1) {
        return $null
    }
    $rats = [int[]]$groups[0]
    $codes = [int[]]@($groups | Select-Object -Skip 3 | ForEach-Object { $_ })
    $split = Split-NetworkModeCode -Code $codes
    [pscustomobject]@{
        Rats     = $rats
        Modes    = [string[]]@($script:NetworkModes.Keys | Where-Object { $script:NetworkModes[$_].Rat -in $rats })
        LteCodes = $split.LteCodes
        NrCodes  = $split.NrCodes
        Lte      = $split.Lte
        Nr       = $split.Nr
    }
}

function Resolve-NetworkMode {
    <#
    .SYNOPSIS
        Decides whether the modem's network mode and bands are as the settings ask, and what to
        write when they are not.
    .DESCRIPTION
        A pure decision (ARCHITECTURE -> Modes and bands) from the settings (NetworkMode, empty
        when the app doesn't manage it; LteBands and NrBands, empty for every band), the modem's
        setting as read (-Current, ConvertFrom-AtNetworkMode's) and what it supports (-Support,
        ConvertFrom-AtNetworkModeSupport's).

        The mode is compared on its RAT and the preferences that count for it. For each RAT the
        mode manages, the band list asked is the settings' bands the modem supports, or all it
        supports. By default the modem keeps the settings when it uses no band they leave out:
        a band asked that it leaves out is no reason to write again - the FM350 drops n77 by
        itself (AT-COMMANDS section 5), and writing it back would register the modem again at
        every pass, for nothing. -Exact asks for the very lists: what the user has just chosen -
        but for a code the modem drops by itself next to the one it keeps (n77 beside n78).

        -LastWrite (Command, and Before: the setting's Text when it was written) is the app's
        last write: the same command over the same setting as then is not written again - the
        modem didn't keep it, and writing it once more would change nothing.

        Returns Managed; Satisfied ($true, $false, or $null when the setting or what the modem
        supports is not known); Command (what to write, or $null); Problem ('ModeUnsupported',
        'NoSupportedBand': a RAT's bands keep none the modem supports, 'NotKept', or $null);
        Narrowed (the choice can keep the modem off a network a wider one would find: NR alone, or
        LTE bands chosen); Missing (Lte, Nr: bands asked that the modem's lists leave out).
    .EXAMPLE
        Resolve-NetworkMode -Settings $settings -Current $current -Support $support
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Settings,

        [AllowNull()]
        [object] $Current,

        [AllowNull()]
        [object] $Support,

        [switch] $Exact,

        [AllowNull()]
        [object] $LastWrite
    )

    $name = [string]$Settings.NetworkMode
    $missing = [ordered]@{ Lte = [int[]]@(); Nr = [int[]]@() }
    $result = [ordered]@{ Managed = [bool]$name; Satisfied = $null; Command = $null; Problem = $null; Narrowed = $false; Missing = $null }
    $finish = {
        $result.Missing = [pscustomobject]$missing
        [pscustomobject]$result
    }
    if (-not $name -or -not $script:NetworkModes.Contains($name)) {
        return & $finish
    }
    $mode = $script:NetworkModes[$name]
    $rats = @(foreach ($rat in 'Lte', 'Nr') { if ($mode[$rat]) { $rat } })
    $chosen = @{
        Lte = [int[]]@($Settings.LteBands | Where-Object { $null -ne $_ })
        Nr  = [int[]]@($Settings.NrBands | Where-Object { $null -ne $_ })
    }
    $result.Narrowed = -not $mode.Lte -or $chosen.Lte.Count -gt 0
    if (-not $Current -or -not $Support) {
        return & $finish
    }
    if ($mode.Rat -notin $Support.Rats) {
        $result.Satisfied = $false
        $result.Problem = 'ModeUnsupported'
        return & $finish
    }

    $wanted = @{}
    foreach ($rat in $rats) {
        $supported = [int[]]@($Support."${rat}Codes")
        $codes = @($chosen[$rat] | ConvertTo-GtactBandCode -Rat $rat.ToUpperInvariant() -ErrorAction SilentlyContinue)
        $wanted[$rat] = [int[]]@($supported | Where-Object { $chosen[$rat].Count -eq 0 -or $_ -in $codes })
        if ($wanted[$rat].Count -eq 0) {
            $result.Satisfied = $false
            $result.Problem = 'NoSupportedBand'
            return & $finish
        }
    }

    $count = $script:GtactRatCounts[$mode.Rat]
    $same = $Current.Rat -eq $mode.Rat
    foreach ($index in 0, 1) {
        if ($same -and $count -gt $index + 1) {
            $same = $Current.Preferences[$index] -eq $mode.Preferences[$index]
        }
    }
    $kept = $same
    foreach ($rat in $rats) {
        $read = [int[]]@(if ($Current.AllBands) { $Support."${rat}Codes" } else { $Current."${rat}Codes" })
        $want = $wanted[$rat]
        $extra = @($read | Where-Object { $_ -notin $want })
        $left = @($want | Where-Object { $_ -notin $read })
        # What the modem drops by itself is no difference, even for the very lists.
        $dropped = @($left | Where-Object { $script:NetworkModeDroppedCodes.ContainsKey($_) -and $script:NetworkModeDroppedCodes[$_] -in $read })
        $ok = $extra.Count -eq 0 -and $(if ($Exact) { $left.Count -eq $dropped.Count } else { $read.Count -gt 0 })
        if (-not $ok) {
            $kept = $false
        }
        if ($same -and $left.Count -gt 0) {
            $missing[$rat] = [int[]]@($left | ForEach-Object { (ConvertFrom-GtactBandCode -Code ([string]$_)).Band })
        }
    }
    $result.Satisfied = $kept
    if ($kept) {
        return & $finish
    }
    $codes = [int[]]@(foreach ($rat in $rats) { $wanted[$rat] })
    $command = ConvertTo-AtNetworkModeCommand -Rat $mode.Rat -Preferences $mode.Preferences -Code $codes
    if ($LastWrite -and $LastWrite.Command -eq $command -and $LastWrite.Before -eq $Current.Text) {
        $result.Problem = 'NotKept'
    }
    else {
        $result.Command = $command
    }
    & $finish
}

function Resolve-NetworkModeTrial {
    <#
    .SYNOPSIS
        Decides whether a network mode the user chose has found a network, or is to be undone.
    .DESCRIPTION
        A pure decision. -Trial is the change being tried (Since: when it was written, in the
        worker's clock, ms); -Registered whether the modem was registered at -ReadAt, the time
        of that reading ($null: not known); -InForce whether the modem had the mode on trial
        then (Resolve-NetworkMode's Satisfied); -Now the clock.
        - Confirm: registered with the mode on trial in force, as read at least
          NetworkModeConfirmAfterMs after the write - a reading taken sooner may be the
          registration the change is about to end, and a modem that didn't keep the write is
          registered with its old mode.
        - Revert: -TimeoutMs gone without that: the mode finds no network here, and no reset
          would change it; the setting before is written back.
        - Wait: neither yet. WaitMs: until the revert is due.
    .EXAMPLE
        Resolve-NetworkModeTrial -Trial $trial -Registered $true -InForce $true -ReadAt $lastPass -Now $now
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Trial,

        [AllowNull()]
        [object] $Registered,

        [AllowNull()]
        [object] $InForce,

        [Nullable[long]] $ReadAt,

        [Parameter(Mandatory)]
        [long] $Now,

        [ValidateRange(1, [int]::MaxValue)]
        [int] $TimeoutMs = $script:RecoveryTimings.Maintenance
    )

    $deadline = $Trial.Since + $TimeoutMs
    $action = if ($Registered -eq $true -and $InForce -eq $true -and $null -ne $ReadAt -and $ReadAt -ge $Trial.Since + $script:NetworkModeConfirmAfterMs) {
        'Confirm'
    }
    elseif ($Now -ge $deadline) {
        'Revert'
    }
    else {
        'Wait'
    }
    [pscustomobject]@{
        Action = $action
        WaitMs = if ($action -eq 'Wait') { $deadline - $Now } else { $null }
    }
}

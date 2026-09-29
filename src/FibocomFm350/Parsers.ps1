# Parsers for the modem's status answers: identity, SIM, registration, operator, signal,
# temperature. Facts and sources: docs/AT-COMMANDS.md sections 3, 4 and 6.
#
# Every parser is pure: it takes the answer lines of Invoke-AtCommand, picks the lines with the
# prefix it knows, ignores the others (an unexpected line never breaks a parse), and returns
# $null for what the answer doesn't carry.

# 27.007 <AcT> values, as the FM350 is expected to use them (AT-COMMANDS section 3: the vendor
# manual's own table disagrees and is under verification).
$script:AccessTechnologies = @{
    0 = 'GSM'; 1 = 'GSM Compact'; 2 = 'UMTS'; 3 = 'EDGE'; 4 = 'HSDPA'; 5 = 'HSUPA'; 6 = 'HSPA'
    7 = 'LTE'; 8 = 'EC-GSM-IoT'; 9 = 'NB-IoT'; 10 = 'LTE-5GC'; 11 = 'NR-SA'; 12 = 'NG-RAN'; 13 = 'EN-DC'
}

# 27.007 registration <stat>.
$script:RegistrationStates = @{
    0 = 'NotSearching'; 1 = 'Home'; 2 = 'Searching'; 3 = 'Denied'; 4 = 'Unknown'; 5 = 'Roaming'
    6 = 'HomeSmsOnly'; 7 = 'RoamingSmsOnly'; 8 = 'EmergencyOnly'; 9 = 'HomeCsfbNotPreferred'
    10 = 'RoamingCsfbNotPreferred'
}

# +GTSENRDTEMP sensor numbers named by the vendor manual; the others are reported by number.
$script:TemperatureSensors = @{
    1 = 'SocMax'; 10 = 'Modem5G'; 11 = 'Modem4G'; 14 = 'LtePa'; 15 = 'NrPa'; 16 = 'Rf'; 19 = 'Pmic'; 23 = 'Crystal'
}

function Split-AtArgument {
    # Splits the text after a '+XXX:' prefix into arguments, on commas outside double quotes.
    # Returns objects with Value (quotes removed, trimmed) and Quoted.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyString()] [string] $Text)

    $current = [System.Text.StringBuilder]::new()
    $inQuotes = $false
    $quoted = $false
    foreach ($character in $Text.ToCharArray()) {
        if ($character -eq '"') {
            $inQuotes = -not $inQuotes
            $quoted = $true
        }
        elseif ($character -eq ',' -and -not $inQuotes) {
            [pscustomobject]@{ Value = if ($quoted) { "$current" } else { "$current".Trim() }; Quoted = $quoted }
            [void]$current.Clear()
            $quoted = $false
        }
        elseif ($inQuotes -or -not $quoted) {
            # Inside quotes, or an unquoted argument; blanks around a quoted one are skipped.
            [void]$current.Append($character)
        }
    }
    [pscustomobject]@{ Value = if ($quoted) { "$current" } else { "$current".Trim() }; Quoted = $quoted }
}

function Get-AtPrefixedLine {
    # The text after '<prefix>:' on each line that has it.
    param([string[]] $Lines, [string] $Prefix)

    foreach ($line in $Lines) {
        if ($line -match "^\s*$([regex]::Escape($Prefix))\s*:\s*(.*)$") {
            $Matches[1]
        }
    }
}

function Get-AtArgument {
    # The argument at $Position (0-based) of the first line with $Prefix; $null if absent or empty.
    param([string[]] $Lines, [string] $Prefix, [int] $Position)

    $text = @(Get-AtPrefixedLine -Lines $Lines -Prefix $Prefix) | Select-Object -First 1
    if ($null -ne $text) {
        $arguments = @(Split-AtArgument -Text $text)
        if ($arguments.Count -gt $Position -and $arguments[$Position].Value) {
            $arguments[$Position].Value
        }
    }
}

function ConvertTo-AtInteger {
    # An integer, or $null when the text isn't one.
    param([AllowEmptyString()] [string] $Text)

    $value = 0
    if ([int]::TryParse($Text, [ref]$value)) { $value } else { $null }
}

function ConvertFrom-AtIdentity {
    <#
    .SYNOPSIS
        Reads manufacturer, model and firmware from the answers to AT+CGMI?, AT+CGMM?, AT+GMR?
        and AT+GTPKGVER?.
    .DESCRIPTION
        The FM350 quotes the values: '+CGMI: "<manufacturer>"', '+CGMM: "<model>","<short name>"',
        '+CGMR: "<firmware>"' (or '+GMR:' on older firmware), '+GTPKGVER: "<package>"'.
        Returns Manufacturer, Model, ModelShortName, Firmware and Package; $null for any not
        present. The IMEI is not read here: it is an identifier.
    .EXAMPLE
        ConvertFrom-AtIdentity -Lines '+CGMI: "Fibocom"', '+CGMM: "FM350-GL","FM350"'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Lines
    )

    $firmware = Get-AtArgument -Lines $Lines -Prefix '+CGMR' -Position 0
    if (-not $firmware) {
        $firmware = Get-AtArgument -Lines $Lines -Prefix '+GMR' -Position 0
    }

    [pscustomobject]@{
        Manufacturer   = Get-AtArgument -Lines $Lines -Prefix '+CGMI' -Position 0
        Model          = Get-AtArgument -Lines $Lines -Prefix '+CGMM' -Position 0
        ModelShortName = Get-AtArgument -Lines $Lines -Prefix '+CGMM' -Position 1
        Firmware       = $firmware
        Package        = Get-AtArgument -Lines $Lines -Prefix '+GTPKGVER' -Position 0
    }
}

function ConvertFrom-AtSimState {
    <#
    .SYNOPSIS
        Reads the SIM state from the answer to AT+CPIN?.
    .DESCRIPTION
        Returns Ready ($true for '+CPIN: READY') and Waiting: what the SIM is waiting for
        ('SIM PIN', 'SIM PUK', ...), or $null when it is ready. Returns $null if the answer has no
        '+CPIN:' line. A missing or busy SIM answers '+CME ERROR' instead (10, 14): see
        Invoke-AtCommand's Status and ErrorCode.
    .EXAMPLE
        ConvertFrom-AtSimState -Lines '+CPIN: SIM PIN'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Lines
    )

    $text = @(Get-AtPrefixedLine -Lines $Lines -Prefix '+CPIN') | Select-Object -First 1
    if ($null -eq $text) {
        return
    }
    $code = $text.Trim().Trim('"')
    [pscustomobject]@{
        Ready   = $code -eq 'READY'
        Waiting = if ($code -eq 'READY') { $null } else { $code }
    }
}

function ConvertFrom-AtRegistration {
    <#
    .SYNOPSIS
        Reads a registration report: +CREG, +CGREG, +CEREG or +C5GREG, as an answer or as an
        unsolicited code.
    .DESCRIPTION
        The answer to a read ('+CEREG: <n>,<stat>[,...]') and the unsolicited code
        ('+CEREG: <stat>[,...]') differ by their first argument; the parser tells them apart by
        the second: an unquoted number means the read form.
        Returns Domain ('CS', 'PS', 'EPS', '5GS'), Stat and State (27.007 names: 'Home',
        'Roaming', 'Searching', 'Denied', ...), Registered ($true for home or roaming, SMS-only
        and CSFB-not-preferred included), Tac and CellId as reported (location data), AcT and
        Technology, and RejectCause when the report carries one. Returns $null if the line is not
        a registration report.
    .EXAMPLE
        ConvertFrom-AtRegistration -Line '+CEREG: 2,1,"ABCD","0ABCDEF0",7'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string] $Line
    )

    process {
        if ($Line -notmatch '^\s*\+(?<prefix>CREG|CGREG|CEREG|C5GREG)\s*:\s*(?<rest>.*)$') {
            return
        }
        $domain = @{ CREG = 'CS'; CGREG = 'PS'; CEREG = 'EPS'; C5GREG = '5GS' }[$Matches['prefix']]
        $arguments = @(Split-AtArgument -Text $Matches['rest'])
        $readForm = $arguments.Count -ge 2 -and -not $arguments[1].Quoted -and $arguments[1].Value -match '^\d+$'
        if ($readForm) {
            $arguments = @($arguments | Select-Object -Skip 1)
        }
        $value = { param($i) if ($arguments.Count -gt $i -and $arguments[$i].Value) { $arguments[$i].Value } }

        $stat = ConvertTo-AtInteger -Text (& $value 0)
        if ($null -eq $stat) {
            return
        }
        # <stat>,<tac or lac>,<ci>,<AcT>, then <cause_type>,<reject_cause>; +CGREG has <rac> before
        # the cause, +C5GREG two NSSAI arguments (AT-COMMANDS section 3).
        $act = ConvertTo-AtInteger -Text (& $value 3)
        $causeAt = switch ($domain) { 'PS' { 6 } '5GS' { 7 } default { 5 } }

        [pscustomobject]@{
            Domain      = $domain
            Stat        = $stat
            State       = $script:RegistrationStates[$stat] ?? 'Unknown'
            Registered  = $stat -in 1, 5, 6, 7, 9, 10
            Tac         = & $value 1
            CellId      = & $value 2
            AcT         = $act
            Technology  = if ($null -ne $act) { $script:AccessTechnologies[$act] } else { $null }
            RejectCause = ConvertTo-AtInteger -Text (& $value $causeAt)
        }
    }
}

function ConvertFrom-AtOperator {
    <#
    .SYNOPSIS
        Reads the operator and access technology from the answer to AT+COPS?.
    .DESCRIPTION
        '+COPS: <mode>[,<format>,<oper>[,<AcT>]]'. Returns Mode, Automatic ($true for mode 0),
        Format, Operator ($null when not registered), AcT and Technology ('LTE', 'EN-DC' for 5G
        NSA, 'NR-SA' for 5G SA, ...: the 27.007 table). Returns $null without a '+COPS:' line.
    .EXAMPLE
        ConvertFrom-AtOperator -Lines '+COPS: 0,0,"Operator",13'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Lines
    )

    $text = @(Get-AtPrefixedLine -Lines $Lines -Prefix '+COPS') | Select-Object -First 1
    if ($null -eq $text) {
        return
    }
    $arguments = @(Split-AtArgument -Text $text)
    $value = { param($i) if ($arguments.Count -gt $i -and $arguments[$i].Value) { $arguments[$i].Value } }
    $mode = ConvertTo-AtInteger -Text (& $value 0)
    $act = ConvertTo-AtInteger -Text (& $value 3)

    [pscustomobject]@{
        Mode       = $mode
        Automatic  = $mode -eq 0
        Format     = ConvertTo-AtInteger -Text (& $value 1)
        Operator   = & $value 2
        AcT        = $act
        Technology = if ($null -ne $act) { $script:AccessTechnologies[$act] } else { $null }
    }
}

function ConvertFrom-AtSignalQuality {
    <#
    .SYNOPSIS
        Reads signal quality from the answers to AT+CSQ and AT+CESQ.
    .DESCRIPTION
        '+CSQ: <rssi>,<ber>' gives Rssi. '+CESQ: <rxlev>,<ber>,<rscp>,<ecno>,<rsrq>,<rsrp>,
        <ss_rsrq>,<ss_rsrp>,<ss_sinr>' gives LteRsrq, LteRsrp and NrRsrq, NrRsrp, NrSinr (the NR
        fields are valid on NR and on EN-DC). Each value is a ConvertFrom-MeasurementIndex object,
        or $null when not reported.
    .EXAMPLE
        ConvertFrom-AtSignalQuality -Lines '+CESQ: 99,99,255,255,20,60,255,255,255'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Lines
    )

    $measure = {
        param($arguments, $position, $kind)
        if ($arguments.Count -gt $position) {
            $index = ConvertTo-AtInteger -Text $arguments[$position].Value
            if ($null -ne $index) {
                ConvertFrom-MeasurementIndex -Kind $kind -Index $index
            }
        }
    }

    $csq = @(Get-AtPrefixedLine -Lines $Lines -Prefix '+CSQ') | Select-Object -First 1
    $cesq = @(Get-AtPrefixedLine -Lines $Lines -Prefix '+CESQ') | Select-Object -First 1
    # @() outside the if: an if statement unrolls an array of one into a single object.
    $csqArguments = @(if ($null -ne $csq) { Split-AtArgument -Text $csq })
    $cesqArguments = @(if ($null -ne $cesq) { Split-AtArgument -Text $cesq })

    [pscustomobject]@{
        Rssi    = & $measure $csqArguments 0 'Rssi'
        LteRsrq = & $measure $cesqArguments 4 'LteRsrq'
        LteRsrp = & $measure $cesqArguments 5 'LteRsrp'
        NrRsrq  = & $measure $cesqArguments 6 'NrRsrq'
        NrRsrp  = & $measure $cesqArguments 7 'NrRsrp'
        NrSinr  = & $measure $cesqArguments 8 'NrSinr'
    }
}

function ConvertFrom-AtTemperature {
    <#
    .SYNOPSIS
        Reads the module's temperature sensors from the answer to AT+GTSENRDTEMP.
    .DESCRIPTION
        One '+GTSENRDTEMP: <sensor>,<value>' line per sensor; the value is in thousandths of a
        degree Celsius (AT-COMMANDS section 4: inferred, to be confirmed on the device). Returns
        one object per sensor: Sensor, Name (the vendor's, or $null), Celsius.
    .EXAMPLE
        ConvertFrom-AtTemperature -Lines '+GTSENRDTEMP: 1,45000'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Lines
    )

    foreach ($text in Get-AtPrefixedLine -Lines $Lines -Prefix '+GTSENRDTEMP') {
        $arguments = @(Split-AtArgument -Text $text)
        if ($arguments.Count -lt 2) {
            continue
        }
        $sensor = ConvertTo-AtInteger -Text $arguments[0].Value
        $value = ConvertTo-AtInteger -Text $arguments[1].Value
        if ($null -eq $sensor -or $null -eq $value) {
            continue
        }
        [pscustomobject]@{
            Sensor  = $sensor
            Name    = $script:TemperatureSensors[$sensor]
            Celsius = $value / 1000
        }
    }
}

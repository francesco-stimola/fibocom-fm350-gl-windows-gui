# Parsers for the FM350's cell and carrier-aggregation reports, +GTCCINFO and +GTCAINFO.
# Facts and sources: docs/AT-COMMANDS.md sections 4.1-4.3 and 6. Pure, like Parsers.ps1.

# +GTCAINFO modulation codes; 6 means unknown.
$script:Modulations = @{ 0 = 'BPSK'; 1 = 'QPSK'; 2 = '16QAM'; 3 = '64QAM'; 4 = '256QAM'; 5 = '1024QAM' }

function ConvertFrom-AtBandwidthCode {
    # Bandwidth code -> MHz: the code is MHz x 5, except 6 = 1.4 MHz; 0 or absent -> $null.
    param($Code)

    if ($null -eq $Code -or $Code -le 0) { return }
    if ($Code -eq 6) { 1.4 } else { $Code / 5 }
}

function ConvertFrom-AtBandField {
    # ConvertFrom-GtactBandCode for a band code read from the modem; $null for a value it doesn't
    # take (negative, or more than nine digits), so an odd field never makes a parser throw.
    param($Code)

    if ($null -eq $Code -or $Code -lt 0 -or $Code -gt 999999999) { return }
    ConvertFrom-GtactBandCode -Code "$Code"
}

function Get-AtBandName {
    # A +GTACT band code as 'B3' or 'n78'; $null for anything else.
    param($Code)

    $decoded = ConvertFrom-AtBandField -Code $Code
    if (-not $decoded) {
        return
    }
    switch ($decoded.Kind) {
        'LTE' { "B$($decoded.Band)" }
        'NR' { "n$($decoded.Band)" }
    }
}

function ConvertFrom-AtCellInfo {
    <#
    .SYNOPSIS
        Reads the serving and neighbour cells from the answer to AT+GTCCINFO?.
    .DESCRIPTION
        One line per cell. Serving and neighbour lines have different layouts, told apart by the
        first field (1 serving, 2 neighbour): a serving line carries band and bandwidth, an LTE
        neighbour carries bandwidth but no band or SINR, an NR neighbour SINR but no band or
        bandwidth. Lines for other technologies (WCDMA) are skipped: the app manages LTE and NR.

        Returns one object per cell: Serving, Technology ('LTE' or 'NR'), Mcc, Mnc, Tac and
        CellId as reported (location data: never logged), Arfcn, Pci, BandCode, Band ('B3',
        'n78'), BandwidthMHz, and Sinr, Rsrp, Rsrq as ConvertFrom-MeasurementIndex objects
        ($null when not reported).
    .EXAMPLE
        ConvertFrom-AtCellInfo -Lines '+GTCCINFO:', '1,4,001,01,ABCD,0ABCDEF0,1300,123,103,100,40,60,60,20'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    foreach ($line in $Lines) {
        if ($line -notmatch '^\s*[12]\s*,') {
            continue
        }
        $fields = @(Split-AtArgument -Text $line | ForEach-Object Value)
        $number = { param($i) if ($fields.Count -gt $i) { ConvertTo-AtInteger -Text $fields[$i] } }
        $text = { param($i) if ($fields.Count -gt $i -and $fields[$i]) { $fields[$i] } }

        $technology = switch ($fields[1]) {
            '4' { 'LTE' }
            '9' { 'NR' }
        }
        if (-not $technology) {
            continue
        }
        $serving = $fields[0] -eq '1'

        # Positions (0-based) of the fields that differ between layouts.
        $at = if ($serving) {
            @{ Band = 8; Bandwidth = 9; Sinr = 10; Rsrp = 12; Rsrq = 13 }
        }
        elseif ($technology -eq 'LTE') {
            @{ Band = -1; Bandwidth = 8; Sinr = -1; Rsrp = 10; Rsrq = 11 }
        }
        else {
            @{ Band = -1; Bandwidth = -1; Sinr = 8; Rsrp = 10; Rsrq = 11 }
        }
        $measure = {
            param($position, $kind)
            if ($position -ge 0) {
                $index = & $number $position
                if ($null -ne $index) {
                    ConvertFrom-MeasurementIndex -Kind "$technology$kind" -Index $index
                }
            }
        }
        $bandCode = if ($at.Band -ge 0) { & $number $at.Band } else { $null }

        [pscustomobject]@{
            Serving      = $serving
            Technology   = $technology
            Mcc          = & $text 2
            Mnc          = & $text 3
            Tac          = & $text 4
            CellId       = & $text 5
            Arfcn        = & $number 6
            Pci          = & $number 7
            BandCode     = $bandCode
            Band         = Get-AtBandName -Code $bandCode
            BandwidthMHz = if ($at.Bandwidth -ge 0) { ConvertFrom-AtBandwidthCode -Code (& $number $at.Bandwidth) } else { $null }
            Sinr         = & $measure $at.Sinr 'Sinr'
            Rsrp         = & $measure $at.Rsrp 'Rsrp'
            Rsrq         = & $measure $at.Rsrq 'Rsrq'
        }
    }
}

function ConvertFrom-AtCarrierAggregation {
    <#
    .SYNOPSIS
        Reads the aggregated carriers from the answer to AT+GTCAINFO?.
    .DESCRIPTION
        A 'PCC:' line for each technology's primary carrier and an 'SCC<n>:' (or 'SCC <n>:') line
        per secondary carrier. Fields are read from the start of the line: the tail changed
        between firmware versions. The technology comes from the band code.

        Returns one object per carrier: Carrier ('PCC', 'SCC1', ...), Primary, Active (a primary
        always; a secondary when configured and activated), UplinkCa (secondaries), Technology,
        BandCode, Band, Pci, Arfcn, DlBandwidthMHz, UlBandwidthMHz (secondaries), DlMimoLayers,
        UlMimoLayers, DlModulation and UlModulation ('256QAM', ...; $null when unknown).
    .EXAMPLE
        ConvertFrom-AtCarrierAggregation -Lines 'PCC:103,123,1300,100,2,1,4,3,60'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    foreach ($line in $Lines) {
        if ($line -notmatch '^\s*(?<role>PCC|SCC\s*(?<n>\d+))\s*:\s*(?<rest>.*)$') {
            continue
        }
        $primary = $Matches['role'] -eq 'PCC'
        $carrier = if ($primary) { 'PCC' } else { "SCC$($Matches['n'])" }
        $fields = @(Split-AtArgument -Text $Matches['rest'] | ForEach-Object Value)
        $number = { param($i) if ($i -ge 0 -and $fields.Count -gt $i) { ConvertTo-AtInteger -Text $fields[$i] } }

        # Positions (0-based): a secondary line starts with <scell_state>,<ul_configured>, and has
        # an uplink bandwidth after the downlink one.
        $at = if ($primary) {
            @{ Band = 0; Pci = 1; Arfcn = 2; DlBw = 3; UlBw = -1; DlMimo = 4; UlMimo = 5; DlMod = 6; UlMod = 7 }
        }
        else {
            @{ Band = 2; Pci = 3; Arfcn = 4; DlBw = 5; UlBw = 6; DlMimo = 7; UlMimo = 8; DlMod = 9; UlMod = 10 }
        }
        $bandCode = & $number $at.Band
        $decoded = ConvertFrom-AtBandField -Code $bandCode
        $technology = if ($decoded -and $decoded.Kind -in 'LTE', 'NR') { $decoded.Kind } else { $null }
        $modulation = { param($i) $code = & $number $i; if ($null -ne $code) { $script:Modulations[$code] } }

        [pscustomobject]@{
            Carrier        = $carrier
            Primary        = $primary
            Active         = $primary -or (& $number 0) -eq 2
            UplinkCa       = if ($primary) { $null } else { (& $number 1) -eq 1 }
            Technology     = $technology
            BandCode       = $bandCode
            Band           = Get-AtBandName -Code $bandCode
            Pci            = & $number $at.Pci
            Arfcn          = & $number $at.Arfcn
            DlBandwidthMHz = ConvertFrom-AtBandwidthCode -Code (& $number $at.DlBw)
            UlBandwidthMHz = ConvertFrom-AtBandwidthCode -Code (& $number $at.UlBw)
            DlMimoLayers   = & $number $at.DlMimo
            UlMimoLayers   = & $number $at.UlMimo
            DlModulation   = & $modulation $at.DlMod
            UlModulation   = & $modulation $at.UlMod
        }
    }
}

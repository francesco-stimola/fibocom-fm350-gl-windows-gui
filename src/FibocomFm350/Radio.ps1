# What the radio is doing, as the tray and the window show it: technology, signal bars, cells and
# carriers. Facts and sources: docs/AT-COMMANDS.md sections 3, 4 and 6.

# Signal bars: an RSRP at or above the n-th edge earns n bars (dBm). Thresholds: the maintainer's
# decision (ROADMAP M3).
$script:SignalBarEdges = @(-115, -105, -95, -85)

function Resolve-RadioStatus {
    <#
    .SYNOPSIS
        Sums up the radio for display: technology, signal bars, cells and carriers.
    .DESCRIPTION
        A pure function of the status reads: -Operator (ConvertFrom-AtOperator), -Signal
        (ConvertFrom-AtSignalQuality), -Cell (ConvertFrom-AtCellInfo) and -Carrier
        (ConvertFrom-AtCarrierAggregation).

        Technology is told from the serving cells, never from +COPS's access technology, which
        the FM350 reports as EN-DC on an LTE cell with NR switched off, nor from +CESQ's NR
        fields, which it fills on an idle LTE anchor cell with no NR leg (AT-COMMANDS section 3):
        '5G SA' (an NR serving cell and no LTE one), '5G NSA' (an LTE serving cell with an NR
        serving cell: the NR leg in use), 'LTE-A' (an LTE serving cell with an active secondary
        carrier), 'LTE' (an LTE serving cell), or $null when no serving cell is reported.
        NrAvailable: NR measured (+CESQ) while no NR leg is in use - 5G the modem could add
        (decided 2026-10-01: the app says '5G' only for the leg in use).

        Rsrp is the serving RSRP in dBm - the LTE anchor's, the NR cell's on 5G SA - and Bars
        (0 to 4) follow from it; both $null when nothing is measured.

        Returns Operator (as +COPS reports it, numeric: MCC and MNC), Technology, NrAvailable, Rsrp, Bars,
        Signal, Cells and Carriers. Cells carry no location - MCC, MNC, TAC and cell identity
        are left out: what is shown never needs them.
    .EXAMPLE
        Resolve-RadioStatus -Operator $operator -Signal $signal -Cell $cells -Carrier $carriers
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Operator,

        [AllowNull()]
        [object] $Signal,

        [AllowEmptyCollection()]
        [object[]] $Cell = @(),

        [AllowEmptyCollection()]
        [object[]] $Carrier = @()
    )

    $lte = @($Cell | Where-Object { $_.Serving -and $_.Technology -eq 'LTE' }) | Select-Object -First 1
    $nr = @($Cell | Where-Object { $_.Serving -and $_.Technology -eq 'NR' }) | Select-Object -First 1
    $measured = { param($value) if ($null -ne $value) { $value.Value } }
    $nrMeasured = [bool]($Signal -and $null -ne $Signal.NrRsrp)
    $secondary = @($Carrier | Where-Object { -not $_.Primary -and $_.Active }).Count -gt 0
    $operatorName = if ($Operator) { $Operator.Operator } else { $null }

    $technology = if ($nr -and -not $lte) {
        '5G SA'
    }
    elseif ($lte -and $nr) {
        '5G NSA'
    }
    elseif ($lte -and $secondary) {
        'LTE-A'
    }
    elseif ($lte) {
        'LTE'
    }
    else {
        $null
    }

    # The serving RSRP: +CESQ's, else the serving cell's.
    $rsrp = if ($technology -eq '5G SA') {
        $value = & $measured $(if ($Signal) { $Signal.NrRsrp })
        if ($null -eq $value -and $nr) { $value = & $measured $nr.Rsrp }
        $value
    }
    else {
        $value = & $measured $(if ($Signal) { $Signal.LteRsrp })
        if ($null -eq $value -and $lte) { $value = & $measured $lte.Rsrp }
        $value
    }
    $bars = if ($null -ne $rsrp) { @($script:SignalBarEdges | Where-Object { $rsrp -ge $_ }).Count } else { $null }

    [pscustomobject]@{
        Operator    = $operatorName
        Technology  = $technology
        NrAvailable = $nrMeasured -and -not $nr -and [bool]$lte
        Rsrp        = $rsrp
        Bars        = $bars
        Signal      = $Signal
        Cells       = [object[]]@($Cell | Select-Object -Property Serving, Technology, Band, Arfcn, Pci, BandwidthMHz, Rsrp, Rsrq, Sinr)
        Carriers    = [object[]]@($Carrier)
    }
}

function Get-ModemRadioStatus {
    <#
    .SYNOPSIS
        Reads the radio's status for display on an open AT channel.
    .DESCRIPTION
        Reads AT+CESQ, AT+GTCCINFO?;+GTCAINFO? and AT+COPS?, and sums them up with
        Resolve-RadioStatus. Changes nothing on the modem. A read that fails leaves its part
        empty; one that gets no answer - a timeout, a lost port - ends the reads there, so a modem
        that stopped answering costs one command's timeout, never AT+COPS's three minutes.

        Returns Resolve-RadioStatus's object, with Answered: $false when a read got no answer.
    .EXAMPLE
        Get-ModemRadioStatus -Channel $channel
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AtChannel] $Channel
    )

    $silent = 'Timeout', 'PortLost'
    $report = [string[]]@()
    $operator = $null
    $answer = Invoke-AtCommand -Channel $Channel -Command 'AT+CESQ'
    $signal = ConvertFrom-AtSignalQuality -Lines $answer.Lines
    $answered = $answer.Status -notin $silent
    if ($answered) {
        $answer = Invoke-AtCommand -Channel $Channel -Command 'AT+GTCCINFO?;+GTCAINFO?'
        $report = $answer.Lines
        $answered = $answer.Status -notin $silent
    }
    if ($answered) {
        $answer = Invoke-AtCommand -Channel $Channel -Command 'AT+COPS?'
        $operator = ConvertFrom-AtOperator -Lines $answer.Lines
        $answered = $answer.Status -notin $silent
    }
    $status = Resolve-RadioStatus -Operator $operator -Signal $signal -Cell @(ConvertFrom-AtCellInfo -Lines $report) -Carrier @(ConvertFrom-AtCarrierAggregation -Lines $report)
    $status | Add-Member -NotePropertyName Answered -NotePropertyValue $answered -PassThru
}

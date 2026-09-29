# Radio measurements are reported as indexes into ranges. Facts and sources: docs/AT-COMMANDS.md
# section 6 (range edges from the vendor manual, which cites 3GPP TS 36.133 and 38.133; +CSQ from
# 27.007).
#
# Each kind maps an index to the edge the specification names for it, plus whether that edge is a
# bin (the bin starts there), a ceiling (the lowest index: "below this") or a floor (the highest
# index: "this or more"). Indexes meaning "not known" (255; 99 for RSSI) and indexes outside the
# documented range give $null.

# Kind -> Lowest and Highest valid index, the value named by an index in between, and the values
# named by the lowest and highest index.
$script:MeasurementScales = @{
    # 27.007 +CSQ: 0 = -113 dBm or less, 1 = -111, 2..30 = -109..-53, 31 = -51 or more.
    Rssi    = @{ Unit = 'dBm'; Lowest = 0; Highest = 31; Step = { param($i) -113 + 2 * $i }; Low = -113; High = -51 }
    # 36.133 via [FIBOCOM]: 0 below -140; i in [i - 141, i - 140); 97 = -44 or more.
    LteRsrp = @{ Unit = 'dBm'; Lowest = 0; Highest = 97; Step = { param($i) $i - 141 }; Low = -140; High = -44 }
    # 0 below -19.5; i in [i/2 - 20, i/2 - 19.5); 34 = -3 or more.
    LteRsrq = @{ Unit = 'dB'; Lowest = 0; Highest = 34; Step = { param($i) $i / 2 - 20 }; Low = -19.5; High = -3 }
    # Vendor-defined, signed: -100 = -50 or less; i in (i/2 - 0.5, i/2]; 100 = above 50.
    LteSinr = @{ Unit = 'dB'; Lowest = -100; Highest = 100; Step = { param($i) $i / 2 }; Low = -50; High = 50 }
    # 38.133 via [FIBOCOM]: 0 below -156; i in [i - 157, i - 156); 126 = -31 or more.
    NrRsrp  = @{ Unit = 'dBm'; Lowest = 0; Highest = 126; Step = { param($i) $i - 157 }; Low = -156; High = -31 }
    # 0 below -43; i in [i/2 - 43.5, i/2 - 43); 126 in [19.5, 20) - a bin, the documented top.
    NrRsrq  = @{ Unit = 'dB'; Lowest = 0; Highest = 126; Step = { param($i) $i / 2 - 43.5 }; Low = -43; High = $null }
    # 0 below -23; i in [i/2 - 23.5, i/2 - 23); 127 = 40 or more.
    NrSinr  = @{ Unit = 'dB'; Lowest = 0; Highest = 127; Step = { param($i) $i / 2 - 23.5 }; Low = -23; High = 40 }
}

function ConvertFrom-MeasurementIndex {
    <#
    .SYNOPSIS
        Converts a reported measurement index into dBm or dB.
    .DESCRIPTION
        Kinds: Rssi (+CSQ), LteRsrp, LteRsrq, LteSinr (the vendor's signed RSSNR), NrRsrp, NrRsrq,
        NrSinr. Returns an object with Kind, Index, Value, Unit and Bound:
        - Bound 'Bin': the index names a range, and Value is the edge the specification names
          for it (the lower edge; for LteSinr the upper edge, as the vendor defines it).
        - Bound 'Below': the lowest index; the measurement is below Value.
        - Bound 'Above': the highest index; the measurement is Value or more.
        Returns $null for "not known" (255, or 99 for Rssi) and for an index outside the range.
    .EXAMPLE
        ConvertFrom-MeasurementIndex -Kind LteRsrp -Index 60

        Kind    Index Value Unit Bound
        ----    ----- ----- ---- -----
        LteRsrp    60   -81 dBm  Bin
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Rssi', 'LteRsrp', 'LteRsrq', 'LteSinr', 'NrRsrp', 'NrRsrq', 'NrSinr')]
        [string] $Kind,

        [Parameter(Mandatory, ValueFromPipeline)]
        [int] $Index
    )

    process {
        $scale = $script:MeasurementScales[$Kind]
        if ($Index -lt $scale.Lowest -or $Index -gt $scale.Highest) {
            return
        }

        $bound = 'Bin'
        $value = & $scale.Step $Index
        if ($Index -eq $scale.Lowest) {
            $bound = 'Below'
            $value = $scale.Low
        }
        elseif ($Index -eq $scale.Highest -and $null -ne $scale.High) {
            $bound = 'Above'
            $value = $scale.High
        }

        [pscustomobject]@{
            Kind  = $Kind
            Index = $Index
            Value = [double]$value
            Unit  = $scale.Unit
            Bound = $bound
        }
    }
}

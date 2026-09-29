# Band codes used by AT+GTACT (Fibocom). Facts and sources: docs/AT-COMMANDS.md section 5.
#
#   LTE band N  ->  100 + N               (B3  -> 103; documented up to B71 -> 171)
#   NR  band N  ->  "50" followed by N    (n1  -> 501, n78 -> 5078, n512 -> 50512)
#   0           ->  automatic band selection
#
# LTE bands from 100 up have no documented code (100 + N would leave the 101-199 range), so they
# are refused rather than guessed; NR bands are documented up to n512.
# Decoding never loses information: a code that matches no known rule (UMTS codes included) comes
# back as 'Unknown' with its raw value, so a band list read from the modem can be written back
# unchanged.

$script:MaxLteBand = 99
$script:MaxNrBand = 512

function ConvertTo-GtactBandCode {
    <#
    .SYNOPSIS
        Encodes an LTE or NR band number as an AT+GTACT band code.
    .DESCRIPTION
        LTE bands 1-99 and NR bands 1-512 are accepted. An LTE band above 99 is reported as a
        non-terminating error and produces no output, so a pipeline carries on with its next band.
    .EXAMPLE
        ConvertTo-GtactBandCode -Rat NR -Band 78
        5078
    .EXAMPLE
        3, 7, 20 | ConvertTo-GtactBandCode -Rat LTE
        103
        107
        120
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('LTE', 'NR')]
        [string] $Rat,

        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateRange(1, 512)]
        [int] $Band
    )

    process {
        if ($Rat -eq 'LTE' -and $Band -gt $script:MaxLteBand) {
            $exception = [System.ArgumentOutOfRangeException]::new(
                'Band', $Band, "LTE band $Band has no documented AT+GTACT code (LTE bands 1-$script:MaxLteBand).")
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    $exception, 'LteBandOutOfRange', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Band))
            return
        }

        switch ($Rat) {
            'LTE' { 100 + $Band }
            'NR' { [int]"50$Band" }
        }
    }
}

function ConvertFrom-GtactBandCode {
    <#
    .SYNOPSIS
        Decodes an AT+GTACT band code into its radio access technology and band number.
    .DESCRIPTION
        Returns an object with Kind ('LTE', 'NR', 'AllBands' or 'Unknown'), Band (the band
        number, or $null) and Code (the input, unchanged).
    .EXAMPLE
        ConvertFrom-GtactBandCode -Code 5078

        Kind Band Code
        ---- ---- ----
        NR     78 5078
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Code
    )

    process {
        $kind = 'Unknown'
        $band = $null

        if ($Code -eq 0) {
            $kind = 'AllBands'
        }
        elseif ($Code -gt 100 -and $Code -le 100 + $script:MaxLteBand) {
            $kind = 'LTE'
            $band = $Code - 100
        }
        elseif ("$Code" -match '^50([1-9][0-9]{0,2})$' -and [int]$Matches[1] -le $script:MaxNrBand) {
            $kind = 'NR'
            $band = [int]$Matches[1]
        }

        [pscustomobject]@{
            Kind = $kind
            Band = $band
            Code = $Code
        }
    }
}

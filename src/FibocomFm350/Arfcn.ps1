# Channel numbers to frequency and band. Facts and sources: docs/AT-COMMANDS.md section 6; the
# tables are transcribed in Data/EutraBands.psd1 (3GPP TS 36.101) and Data/NrBands.psd1
# (3GPP TS 38.101-1). The band the modem reports is preferred; these are for when it reports
# none (an NR neighbour cell) and for showing the frequency.

$script:EutraBands = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'Data/EutraBands.psd1')).Bands
$script:NrData = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'Data/NrBands.psd1')

function ConvertFrom-Earfcn {
    <#
    .SYNOPSIS
        Converts an LTE downlink channel number (EARFCN) into its band and frequency.
    .DESCRIPTION
        F_DL = F_DL_low + 0.1 (N_DL - N_Offs-DL), 3GPP TS 36.101 clause 5.7.3. Downlink channel
        numbers are unique across bands, so the answer is one band. Returns Earfcn, Band (the
        number), Name ('B3') and DownlinkMHz; $null for a number outside every band.
    .EXAMPLE
        ConvertFrom-Earfcn -Earfcn 1300

        Earfcn Band Name DownlinkMHz
        ------ ---- ---- -----------
          1300    3 B3          1815
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Earfcn
    )

    process {
        foreach ($band in $script:EutraBands) {
            if ($Earfcn -ge $band.First -and $Earfcn -le $band.Last) {
                return [pscustomobject]@{
                    Earfcn      = $Earfcn
                    Band        = $band.Band
                    Name        = "B$($band.Band)"
                    DownlinkMHz = [Math]::Round($band.FdlLowMHz + 0.1 * ($Earfcn - $band.NOffsDl), 1)
                }
            }
        }
    }
}

function ConvertFrom-NrArfcn {
    <#
    .SYNOPSIS
        Converts an NR channel number (NR-ARFCN, FR1) into its frequency and candidate bands.
    .DESCRIPTION
        F_REF = F_REF-Offs + dF_Global (N_REF - N_REF-Offs), 3GPP TS 38.101-1 clause 5.4.2.1.
        NR bands overlap (n77 and n78, n1 and n65 ...), so a channel can belong to several:
        Bands lists every band whose downlink range contains it ('n77', 'n78'). Returns Arfcn,
        FrequencyMHz and Bands; $null outside FR1 (above 2016666).
    .EXAMPLE
        ConvertFrom-NrArfcn -Arfcn 632448

        Arfcn FrequencyMHz Bands
        ----- ------------ -----
        632448     3486.72 {n77, n78}
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Arfcn
    )

    process {
        $raster = $script:NrData.Raster | Where-Object { $Arfcn -ge $_.First -and $Arfcn -le $_.Last } | Select-Object -First 1
        if (-not $raster) {
            return
        }
        $bands = foreach ($band in $script:NrData.Bands) {
            if ($Arfcn -ge $band.First -and $Arfcn -le $band.Last) {
                "n$($band.Band)"
            }
        }
        [pscustomobject]@{
            Arfcn        = $Arfcn
            FrequencyMHz = [Math]::Round($raster.OffsetMHz + $raster.StepKHz / 1000 * ($Arfcn - $raster.OffsetArfcn), 3)
            Bands        = [string[]]@($bands)
        }
    }
}

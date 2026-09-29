@{
    RootModule           = 'FibocomFm350.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '5b026e47-4ab2-42df-b52d-b3b1f15999d8'
    Author               = 'Francesco Stimola'
    Copyright            = '(c) 2026 Francesco Stimola. Licensed under AGPL-3.0-or-later.'
    Description          = 'Core library of fibocom-fm350-gl-windows-gui: AT protocol, parsing and connection logic for the Fibocom FM350-GL 5G modem.'
    PowerShellVersion    = '7.6'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'ConvertFrom-GtactBandCode'
        'ConvertTo-GtactBandCode'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('Fibocom', 'FM350', '5G', 'LTE', 'Modem', 'Windows')
            LicenseUri = 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/blob/main/LICENSE'
            ProjectUri = 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui'
        }
    }
}

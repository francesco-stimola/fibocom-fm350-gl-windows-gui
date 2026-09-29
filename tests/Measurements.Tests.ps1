BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

# Range edges from docs/AT-COMMANDS.md section 6 and 27.007 (+CSQ).
Describe 'ConvertFrom-MeasurementIndex' {
    It '<Kind> index <Index> is <Value> (<Bound>)' -ForEach @(
        @{ Kind = 'Rssi'; Index = 0; Value = -113; Bound = 'Below' }
        @{ Kind = 'Rssi'; Index = 1; Value = -111; Bound = 'Bin' }
        @{ Kind = 'Rssi'; Index = 20; Value = -73; Bound = 'Bin' }
        @{ Kind = 'Rssi'; Index = 30; Value = -53; Bound = 'Bin' }
        @{ Kind = 'Rssi'; Index = 31; Value = -51; Bound = 'Above' }
        @{ Kind = 'LteRsrp'; Index = 0; Value = -140; Bound = 'Below' }
        @{ Kind = 'LteRsrp'; Index = 1; Value = -140; Bound = 'Bin' }
        @{ Kind = 'LteRsrp'; Index = 60; Value = -81; Bound = 'Bin' }
        @{ Kind = 'LteRsrp'; Index = 96; Value = -45; Bound = 'Bin' }
        @{ Kind = 'LteRsrp'; Index = 97; Value = -44; Bound = 'Above' }
        @{ Kind = 'LteRsrq'; Index = 0; Value = -19.5; Bound = 'Below' }
        @{ Kind = 'LteRsrq'; Index = 1; Value = -19.5; Bound = 'Bin' }
        @{ Kind = 'LteRsrq'; Index = 20; Value = -10; Bound = 'Bin' }
        @{ Kind = 'LteRsrq'; Index = 33; Value = -3.5; Bound = 'Bin' }
        @{ Kind = 'LteRsrq'; Index = 34; Value = -3; Bound = 'Above' }
        @{ Kind = 'LteSinr'; Index = -100; Value = -50; Bound = 'Below' }
        @{ Kind = 'LteSinr'; Index = -99; Value = -49.5; Bound = 'Bin' }
        @{ Kind = 'LteSinr'; Index = 0; Value = 0; Bound = 'Bin' }
        @{ Kind = 'LteSinr'; Index = 40; Value = 20; Bound = 'Bin' }
        @{ Kind = 'LteSinr'; Index = 99; Value = 49.5; Bound = 'Bin' }
        @{ Kind = 'LteSinr'; Index = 100; Value = 50; Bound = 'Above' }
        @{ Kind = 'NrRsrp'; Index = 0; Value = -156; Bound = 'Below' }
        @{ Kind = 'NrRsrp'; Index = 1; Value = -156; Bound = 'Bin' }
        @{ Kind = 'NrRsrp'; Index = 90; Value = -67; Bound = 'Bin' }
        @{ Kind = 'NrRsrp'; Index = 125; Value = -32; Bound = 'Bin' }
        @{ Kind = 'NrRsrp'; Index = 126; Value = -31; Bound = 'Above' }
        @{ Kind = 'NrRsrq'; Index = 0; Value = -43; Bound = 'Below' }
        @{ Kind = 'NrRsrq'; Index = 1; Value = -43; Bound = 'Bin' }
        @{ Kind = 'NrRsrq'; Index = 60; Value = -13.5; Bound = 'Bin' }
        # The documented top is a bin, [19.5, 20).
        @{ Kind = 'NrRsrq'; Index = 126; Value = 19.5; Bound = 'Bin' }
        @{ Kind = 'NrSinr'; Index = 0; Value = -23; Bound = 'Below' }
        @{ Kind = 'NrSinr'; Index = 1; Value = -23; Bound = 'Bin' }
        @{ Kind = 'NrSinr'; Index = 70; Value = 11.5; Bound = 'Bin' }
        @{ Kind = 'NrSinr'; Index = 126; Value = 39.5; Bound = 'Bin' }
        @{ Kind = 'NrSinr'; Index = 127; Value = 40; Bound = 'Above' }
    ) {
        $measure = ConvertFrom-MeasurementIndex -Kind $Kind -Index $Index
        $measure.Value | Should -Be $Value
        $measure.Bound | Should -Be $Bound
        $measure.Unit | Should -Be $(if ($Kind -eq 'Rssi' -or $Kind -match 'Rsrp$') { 'dBm' } else { 'dB' })
    }

    It 'gives nothing for <Kind> index <Index> (not known, or out of range)' -ForEach @(
        @{ Kind = 'Rssi'; Index = 99 }
        @{ Kind = 'Rssi'; Index = 32 }
        @{ Kind = 'Rssi'; Index = -1 }
        @{ Kind = 'LteRsrp'; Index = 255 }
        @{ Kind = 'LteRsrp'; Index = 98 }
        @{ Kind = 'LteRsrq'; Index = 255 }
        @{ Kind = 'LteSinr'; Index = 255 }
        @{ Kind = 'LteSinr'; Index = -101 }
        @{ Kind = 'NrRsrp'; Index = 255 }
        @{ Kind = 'NrRsrq'; Index = 127 }
        @{ Kind = 'NrRsrq'; Index = 255 }
        @{ Kind = 'NrSinr'; Index = 255 }
    ) {
        ConvertFrom-MeasurementIndex -Kind $Kind -Index $Index | Should -BeNullOrEmpty
    }
}

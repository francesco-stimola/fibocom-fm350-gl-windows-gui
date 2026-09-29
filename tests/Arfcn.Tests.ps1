# Channel numbers against values worked out by hand from the 3GPP formulas and tables
# (36.101 Table 5.7.3-1, 38.101-1 Tables 5.4.2.1-1 and 5.4.2.3-1), including the rows whose
# extraction needed repair (a lost dash, footnote marks glued to band numbers).

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-Earfcn' {
    It 'EARFCN <Earfcn> is B<Band> at <MHz> MHz' -ForEach @(
        @{ Earfcn = 0; Band = 1; MHz = 2110 }
        @{ Earfcn = 599; Band = 1; MHz = 2169.9 }
        @{ Earfcn = 600; Band = 2; MHz = 1930 }
        @{ Earfcn = 1199; Band = 2; MHz = 1989.9 }
        @{ Earfcn = 1300; Band = 3; MHz = 1815 }
        @{ Earfcn = 3100; Band = 7; MHz = 2655 }
        @{ Earfcn = 6300; Band = 20; MHz = 806 }
        # Bands whose F_DL_low has a decimal part.
        @{ Earfcn = 3800; Band = 9; MHz = 1844.9 }
        @{ Earfcn = 4949; Band = 11; MHz = 1495.8 }
        @{ Earfcn = 9870; Band = 31; MHz = 462.5 }
        @{ Earfcn = 60200; Band = 53; MHz = 2489.5 }
        @{ Earfcn = 9660; Band = 29; MHz = 717 }
        @{ Earfcn = 9920; Band = 32; MHz = 1452 }
        @{ Earfcn = 41589; Band = 41; MHz = 2689.9 }
        @{ Earfcn = 66436; Band = 66; MHz = 2110 }
        @{ Earfcn = 67335; Band = 66; MHz = 2199.9 }
        @{ Earfcn = 68586; Band = 71; MHz = 617 }
        @{ Earfcn = 70656; Band = 106; MHz = 935 }
    ) {
        $channel = ConvertFrom-Earfcn -Earfcn $Earfcn
        $channel.Band | Should -Be $Band
        $channel.Name | Should -Be "B$Band"
        $channel.DownlinkMHz | Should -Be $MHz
    }

    It 'gives nothing for EARFCN <Earfcn>, outside every band' -ForEach @(
        @{ Earfcn = 5000 }
        @{ Earfcn = 36000 - 1 }
        @{ Earfcn = 200000 }
    ) {
        ConvertFrom-Earfcn -Earfcn $Earfcn | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-NrArfcn' {
    It 'NR-ARFCN <Arfcn> is <MHz> MHz in <Bands>' -ForEach @(
        @{ Arfcn = 632448; MHz = 3486.72; Bands = @('n77', 'n78') }
        @{ Arfcn = 653334; MHz = 3800.01; Bands = @('n77') }
        @{ Arfcn = 422000; MHz = 2110; Bands = @('n1', 'n65', 'n66') }
        # 3000 MHz: the first channel of the 15 kHz raster, in no band.
        @{ Arfcn = 600000; MHz = 3000; Bands = @() }
        @{ Arfcn = 743334; MHz = 5150.01; Bands = @('n46') }
        @{ Arfcn = 795000; MHz = 5925; Bands = @('n46', 'n47', 'n96', 'n102') }
        @{ Arfcn = 720000; MHz = 4800; Bands = @('n79') }
        @{ Arfcn = 187500; MHz = 937.5; Bands = @('n8', 'n106') }
    ) {
        $channel = ConvertFrom-NrArfcn -Arfcn $Arfcn
        $channel.FrequencyMHz | Should -Be $MHz
        ($channel.Bands -join ',') | Should -Be ($Bands -join ',')
    }

    It 'gives nothing outside FR1' {
        ConvertFrom-NrArfcn -Arfcn 2016667 | Should -BeNullOrEmpty
    }

    It 'returns Bands as an array, even with one band or none' {
        (ConvertFrom-NrArfcn -Arfcn 720000).Bands.GetType().IsArray | Should -BeTrue
        (ConvertFrom-NrArfcn -Arfcn 600000).Bands.GetType().IsArray | Should -BeTrue
    }
}

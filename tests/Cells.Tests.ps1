# Cell and carrier-aggregation parsers, fed by documented fixtures played through the channel.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    . "$PSScriptRoot/FixtureAnswer.ps1"
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-AtCellInfo' {
    Context 'on LTE' {
        BeforeAll {
            $script:cells = @(ConvertFrom-AtCellInfo -Lines (Get-FixtureAnswer -Name 'gtccinfo.lte.txt'))
        }

        It 'reads one serving cell and two neighbours' {
            $script:cells.Count | Should -Be 3
            $script:cells.Serving | Should -Be @($true, $false, $false)
        }

        It 'reads the serving cell with band, bandwidth and SINR' {
            $serving = $script:cells[0]
            $serving.Technology | Should -Be 'LTE'
            $serving.Mcc | Should -Be '001'
            $serving.Mnc | Should -Be '01'
            $serving.Tac | Should -Be 'ABCD'
            $serving.CellId | Should -Be '0ABCDEF0'
            $serving.Arfcn | Should -Be 1300
            $serving.Pci | Should -Be 123
            $serving.BandCode | Should -Be 103
            $serving.Band | Should -Be 'B3'
            $serving.BandwidthMHz | Should -Be 20
            $serving.Sinr.Value | Should -Be 20
            $serving.Rsrp.Value | Should -Be -81
            $serving.Rsrq.Value | Should -Be -10
        }

        It 'reads an LTE neighbour: bandwidth, no band, no SINR' {
            $neighbour = $script:cells[1]
            $neighbour.Pci | Should -Be 45
            $neighbour.Band | Should -BeNullOrEmpty
            $neighbour.BandwidthMHz | Should -Be 20
            $neighbour.Sinr | Should -BeNullOrEmpty
            $neighbour.Rsrp.Value | Should -Be -86
            $neighbour.Rsrq.Value | Should -Be -11
        }

        It 'leaves out a value reported as 255' {
            $script:cells[2].Rsrq | Should -BeNullOrEmpty
            $script:cells[2].Rsrp.Value | Should -Be -101
        }
    }

    It 'reads both serving cells on EN-DC, LTE first' {
        $cells = @(ConvertFrom-AtCellInfo -Lines (Get-FixtureAnswer -Name 'gtccinfo.endc.txt'))
        $serving = @($cells | Where-Object Serving)
        $serving.Technology | Should -Be @('LTE', 'NR')
        $nr = $serving[1]
        $nr.Arfcn | Should -Be 632448
        $nr.Band | Should -Be 'n78'
        $nr.BandwidthMHz | Should -Be 100
        $nr.Sinr.Value | Should -Be 11.5
        $nr.Rsrp.Value | Should -Be -67
        $nr.Rsrq.Value | Should -Be -13.5
    }

    It 'reads an NR neighbour: SINR, no band, no bandwidth' {
        $neighbour = @(ConvertFrom-AtCellInfo -Lines (Get-FixtureAnswer -Name 'gtccinfo.sa.txt'))[1]
        $neighbour.Serving | Should -BeFalse
        $neighbour.Technology | Should -Be 'NR'
        $neighbour.Band | Should -BeNullOrEmpty
        $neighbour.BandwidthMHz | Should -BeNullOrEmpty
        $neighbour.Sinr.Value | Should -Be 6.5
        $neighbour.Rsrp.Value | Should -Be -72
        $neighbour.Rsrq.Value | Should -Be -16
    }

    It 'skips WCDMA lines, the header and anything unexpected' {
        $cells = @(ConvertFrom-AtCellInfo -Lines @(
                '+GTCCINFO:'
                '1,2,001,01,ABCD,0ABCDEF0,10700,100,1,20,30,1,90,0,40'
                'noise'
                '1,4,001,01,ABCD,0ABCDEF0,1300,123,103,100,40,60,60,20'
            ))
        $cells.Count | Should -Be 1
        $cells[0].Technology | Should -Be 'LTE'
    }

    It 'survives band code <Code>' -ForEach @(
        @{ Code = '-1' }
        @{ Code = '1000000000' }
        @{ Code = '2147483647' }
    ) {
        $cell = ConvertFrom-AtCellInfo -Lines "1,4,001,01,ABCD,0ABCDEF0,1300,123,$Code,100,40,60,60,20"
        $cell.Band | Should -BeNullOrEmpty
        $cell.Rsrp.Value | Should -Be -81
    }

    It 'accepts empty lines' {
        ConvertFrom-AtCellInfo -Lines '', '1,4,001,01,ABCD,0ABCDEF0,1300,123,103,100,40,60,60,20' |
            Should -HaveCount 1
    }
}

Describe 'ConvertFrom-AtCarrierAggregation' {
    Context 'LTE-A with two secondary carriers' {
        BeforeAll {
            $script:carriers = @(ConvertFrom-AtCarrierAggregation -Lines (Get-FixtureAnswer -Name 'gtcainfo.ltea.txt'))
        }

        It 'reads the primary and both secondaries' {
            $script:carriers.Carrier | Should -Be @('PCC', 'SCC1', 'SCC2')
            $script:carriers.Technology | Should -Be @('LTE', 'LTE', 'LTE')
            $script:carriers.Band | Should -Be @('B3', 'B7', 'B20')
        }

        It 'reads the primary carrier' {
            $primary = $script:carriers[0]
            $primary.Primary | Should -BeTrue
            $primary.Active | Should -BeTrue
            $primary.UplinkCa | Should -BeNullOrEmpty
            $primary.Pci | Should -Be 123
            $primary.Arfcn | Should -Be 1300
            $primary.DlBandwidthMHz | Should -Be 20
            $primary.UlBandwidthMHz | Should -BeNullOrEmpty
            $primary.DlMimoLayers | Should -Be 2
            $primary.UlMimoLayers | Should -Be 1
            $primary.DlModulation | Should -Be '256QAM'
            $primary.UlModulation | Should -Be '64QAM'
        }

        It 'tells an active secondary from a deactivated one' {
            $script:carriers[1].Active | Should -BeTrue
            $script:carriers[1].UplinkCa | Should -BeFalse
            $script:carriers[1].UlBandwidthMHz | Should -Be 20
            $script:carriers[1].UlModulation | Should -Be '16QAM'
            $script:carriers[2].Active | Should -BeFalse
            $script:carriers[2].DlBandwidthMHz | Should -Be 10
        }
    }

    It 'reads an NR primary carrier from its band code' {
        $carrier = ConvertFrom-AtCarrierAggregation -Lines 'PCC:5078,321,632448,500,4,1,4,2,50'
        $carrier.Technology | Should -Be 'NR'
        $carrier.Band | Should -Be 'n78'
        $carrier.DlBandwidthMHz | Should -Be 100
    }

    It 'accepts "SCC <n>:" with a space' {
        (ConvertFrom-AtCarrierAggregation -Lines 'SCC 1:2,1,107,45,3100,100,100,2,1,4,2,55').Carrier | Should -Be 'SCC1'
    }

    It 'reads the leading fields of a shorter line, as older firmware sends' {
        $carrier = ConvertFrom-AtCarrierAggregation -Lines 'PCC:103,123,1300,100'
        $carrier.Band | Should -Be 'B3'
        $carrier.DlBandwidthMHz | Should -Be 20
        $carrier.DlMimoLayers | Should -BeNullOrEmpty
        $carrier.DlModulation | Should -BeNullOrEmpty
    }

    It 'gives no modulation for the unknown code 6' {
        (ConvertFrom-AtCarrierAggregation -Lines 'PCC:103,123,1300,100,2,1,6,6,60').DlModulation | Should -BeNullOrEmpty
    }

    It 'survives band code <Code>' -ForEach @(
        @{ Code = '-1' }
        @{ Code = '2000000000' }
    ) {
        $carrier = ConvertFrom-AtCarrierAggregation -Lines "PCC:$Code,123,1300,100"
        $carrier.Band | Should -BeNullOrEmpty
        $carrier.Technology | Should -BeNullOrEmpty
        $carrier.DlBandwidthMHz | Should -Be 20
    }

    It 'accepts empty lines' {
        ConvertFrom-AtCarrierAggregation -Lines '', 'PCC:103,123,1300,100' | Should -HaveCount 1
    }
}

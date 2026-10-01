# The radio as the tray and the window show it: the technology told from what is measured, never
# from +COPS's access technology; the signal bars; cells without their location - on captured
# answers and on made-up ones.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    . "$PSScriptRoot/FixtureAnswer.ps1"

    $script:lteOperator = ConvertFrom-AtOperator -Lines (Get-FixtureAnswer -Name 'cops.lte.txt' -Folder device)
    $script:lteSignal = ConvertFrom-AtSignalQuality -Lines (Get-FixtureAnswer -Name 'cesq.lte.txt' -Folder device)
    $script:nsaSignal = ConvertFrom-AtSignalQuality -Lines (Get-FixtureAnswer -Name 'cesq.nsa.txt')

    # The cells and carriers of a captured +GTCCINFO?;+GTCAINFO? answer.
    function Get-TestReport {
        param([string] $Name)
        $lines = Get-FixtureAnswer -Name $Name -Folder device
        @{ Cell = @(ConvertFrom-AtCellInfo -Lines $lines); Carrier = @(ConvertFrom-AtCarrierAggregation -Lines $lines) }
    }

    # A signal reading with only the LTE RSRP, at an index.
    function Get-TestSignal {
        param([int] $LteRsrpIndex)
        ConvertFrom-AtSignalQuality -Lines "+CESQ: 99,99,255,255,20,$LteRsrpIndex,255,255,255"
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Resolve-RadioStatus' {
    It 'calls an LTE cell LTE, though +COPS reports EN-DC there' {
        $report = Get-TestReport -Name 'gtccinfo.lte.txt'
        $status = Resolve-RadioStatus -Operator $script:lteOperator -Signal $script:lteSignal @report
        $script:lteOperator.Technology | Should -Be 'EN-DC'
        $status.Technology | Should -Be 'LTE'
        $status.Operator | Should -Be '00101'
    }

    It 'calls LTE with an active secondary carrier LTE-A' {
        $report = Get-TestReport -Name 'gtccinfo.ltea.txt'
        (Resolve-RadioStatus -Operator $script:lteOperator -Signal $script:lteSignal @report).Technology | Should -Be 'LTE-A'
    }

    It 'calls an LTE anchor with an NR leg 5G NSA' {
        $report = Get-TestReport -Name 'gtccinfo.endc.txt'
        (Resolve-RadioStatus -Operator $script:lteOperator -Signal $script:lteSignal @report).Technology | Should -Be '5G NSA'
    }

    It 'calls an LTE cell with NR measured 5G NSA, though no NR cell is listed' {
        $report = Get-TestReport -Name 'gtccinfo.lte.txt'
        (Resolve-RadioStatus -Operator $script:lteOperator -Signal $script:nsaSignal @report).Technology | Should -Be '5G NSA'
    }

    It 'calls an NR cell alone 5G SA, and takes its RSRP' {
        $cells = @(ConvertFrom-AtCellInfo -Lines (Get-FixtureAnswer -Name 'gtccinfo.sa.txt'))
        $status = Resolve-RadioStatus -Signal (ConvertFrom-AtSignalQuality -Lines '+CESQ: 99,99,255,255,255,255,60,80,70') -Cell $cells
        $status.Technology | Should -Be '5G SA'
        $status.Rsrp | Should -Be -77
    }

    It 'says nothing without cells or an operator' {
        $status = Resolve-RadioStatus -Operator (ConvertFrom-AtOperator -Lines (Get-FixtureAnswer -Name 'cops.nosim.txt' -Folder device)) `
            -Signal (ConvertFrom-AtSignalQuality -Lines (Get-FixtureAnswer -Name 'cesq.nosim.txt' -Folder device)) -Cell @() -Carrier @()
        $status.Technology | Should -BeNullOrEmpty
        $status.Rsrp | Should -BeNullOrEmpty
        $status.Bars | Should -BeNullOrEmpty
        $status.Operator | Should -BeNullOrEmpty
    }

    It 'takes the serving cell''s RSRP when +CESQ has none' {
        $report = Get-TestReport -Name 'gtccinfo.lte.txt'
        $status = Resolve-RadioStatus -Signal $null @report
        $status.Rsrp | Should -Be ($report.Cell | Where-Object Serving | Select-Object -First 1).Rsrp.Value
    }

    It '<Rsrp> dBm: <Bars> bars' -ForEach @(
        @{ Index = 0; Rsrp = -140; Bars = 0 }
        @{ Index = 25; Rsrp = -116; Bars = 0 }
        @{ Index = 26; Rsrp = -115; Bars = 1 }
        @{ Index = 36; Rsrp = -105; Bars = 2 }
        @{ Index = 46; Rsrp = -95; Bars = 3 }
        @{ Index = 55; Rsrp = -86; Bars = 3 }
        @{ Index = 56; Rsrp = -85; Bars = 4 }
        @{ Index = 97; Rsrp = -44; Bars = 4 }
    ) {
        $status = Resolve-RadioStatus -Operator $script:lteOperator -Signal (Get-TestSignal -LteRsrpIndex $Index)
        $status.Rsrp | Should -Be $Rsrp
        $status.Bars | Should -Be $Bars
    }

    It 'gives cells without their location' {
        $report = Get-TestReport -Name 'gtccinfo.endc.txt'
        $status = Resolve-RadioStatus -Operator $script:lteOperator -Signal $script:lteSignal @report
        $status.Cells.Count | Should -Be 3
        foreach ($name in 'Mcc', 'Mnc', 'Tac', 'CellId') {
            $status.Cells[0].PSObject.Properties.Name | Should -Not -Contain $name
        }
        $status.Cells[1].Band | Should -Be 'n78'
        $status.Carriers.Count | Should -Be 5
    }
}

Describe 'Get-ModemRadioStatus' {
    It 'reads the signal, the operator, the cells and the carriers' {
        $modem = New-SimulatedModem -Fixture (Get-ChildItem "$PSScriptRoot/fixtures/device" -Filter '*.txt' | Where-Object Name -In 'cesq.lte.txt', 'cops.lte.txt', 'gtccinfo.ltea.txt')
        $channel = New-AtChannel -Transport $modem
        try {
            $status = Get-ModemRadioStatus -Channel $channel
        }
        finally {
            Close-AtChannel -Channel $channel
        }
        $status.Technology | Should -Be 'LTE-A'
        $status.Bars | Should -Be 2
        $modem.Received | Should -Be @('AT+CESQ', 'AT+COPS?', 'AT+GTCCINFO?;+GTCAINFO?')
    }

    It 'leaves out what fails to read' {
        $channel = New-AtChannel -Transport (New-SimulatedModem)
        try {
            $status = Get-ModemRadioStatus -Channel $channel
        }
        finally {
            Close-AtChannel -Channel $channel
        }
        $status.Technology | Should -BeNullOrEmpty
        @($status.Cells).Count | Should -Be 0
    }
}

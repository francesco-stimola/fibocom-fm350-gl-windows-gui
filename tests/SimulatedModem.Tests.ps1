BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Import-AtFixture' {
    It 'reads the command, the answer and the notes' {
        $fixture = Import-AtFixture -Path "$PSScriptRoot/fixtures/documented/csq.txt"
        $fixture.Command | Should -Be 'AT+CSQ'
        $fixture.Lines | Should -Be @('+CSQ: 20,99', 'OK')
        $fixture.Notes | Should -Match '\[27\.007\]'
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a file with no command'; Content = "# note`n+CSQ: 20,99`nOK"; Message = '*expected a command*' }
        @{ Name = 'a command with no answer'; Content = 'AT+CSQ'; Message = '*expected a command*' }
        @{ Name = 'an answer with no final result'; Content = "AT+CSQ`n+CSQ: 20,99"; Message = '*final result code*' }
    ) {
        $path = Join-Path -Path $TestDrive -ChildPath 'bad.txt'
        Set-Content -LiteralPath $path -Value $Content
        { Import-AtFixture -Path $path -ErrorAction Stop } | Should -Throw -ExpectedMessage $Message
    }
}

Describe 'New-SimulatedModem' {
    It 'answers from fixture files' {
        $modem = New-SimulatedModem -Fixture (Get-ChildItem -Path "$PSScriptRoot/fixtures/documented" -Filter 'csq.txt')
        $channel = New-AtChannel -Transport $modem
        try {
            [void](Initialize-AtChannel -Channel $channel -TimeoutMs 1000)
            (Invoke-AtCommand -Channel $channel -Command 'AT+CSQ' -TimeoutMs 1000).Lines | Should -Be @('+CSQ: 20,99')
        }
        finally {
            Close-AtChannel -Channel $channel
        }
    }

    It 'refuses two fixtures that answer the same command' {
        $path = "$PSScriptRoot/fixtures/documented/csq.txt"
        { New-SimulatedModem -Fixture $path, $path -ErrorAction Stop } | Should -Throw '*both answer*'
    }

    It 'starts with echo on, as the FM350 does, and follows ATE0' {
        $modem = New-SimulatedModem
        $modem.Echo | Should -BeTrue
        $modem.Write("ATE0`r")
        $modem.Echo | Should -BeFalse
    }
}

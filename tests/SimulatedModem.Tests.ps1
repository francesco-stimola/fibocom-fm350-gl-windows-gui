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
            [void](Initialize-AtChannel -Channel $channel -TimeoutMs 5000)
            (Invoke-AtCommand -Channel $channel -Command 'AT+CSQ' -TimeoutMs 5000).Lines | Should -Be @('+CSQ: 20,99')
        }
        finally {
            Close-AtChannel -Channel $channel
        }
    }

    It 'refuses two fixtures that answer the same command' {
        $path = "$PSScriptRoot/fixtures/documented/csq.txt"
        { New-SimulatedModem -Fixture $path, $path -ErrorAction Stop } | Should -Throw '*both answer*'
    }

    It 'remembers only the last 1000 commands' {
        $modem = New-SimulatedModem
        foreach ($i in 1..1005) {
            $modem.Write("AT+X$i`r")
        }
        $modem.Received.Count | Should -Be 1000
        $modem.Received[0] | Should -Be 'AT+X6'
        $modem.Received[-1] | Should -Be 'AT+X1005'
    }

    It 'starts with echo on, as the FM350 does, and follows ATE0' {
        $modem = New-SimulatedModem
        $modem.Echo | Should -BeTrue
        $modem.Write("ATE0`r")
        $modem.Echo | Should -BeFalse
    }

    It 'changes its standing answers once a scripted command has run' {
        $modem = New-SimulatedModem
        $modem.SetAnswer('AT+CGACT?', @('OK'))
        $modem.Script('AT+CGACT=1,1', @{ Lines = @('OK'); Then = @{ 'AT+CGACT?' = @('+CGACT: 1,1', 'OK') } })
        $channel = New-AtChannel -Transport $modem
        try {
            (Invoke-AtCommand -Channel $channel -Command 'AT+CGACT?' -TimeoutMs 5000).Lines | Should -BeNullOrEmpty
            (Invoke-AtCommand -Channel $channel -Command 'AT+CGACT=1,1' -TimeoutMs 5000).Status | Should -Be 'OK'
            (Invoke-AtCommand -Channel $channel -Command 'AT+CGACT?' -TimeoutMs 5000).Lines | Should -Be @('+CGACT: 1,1')
            (Invoke-AtCommand -Channel $channel -Command 'AT+CGACT?' -TimeoutMs 5000).Lines | Should -Be @('+CGACT: 1,1')
        }
        finally {
            Close-AtChannel -Channel $channel
        }
    }
}

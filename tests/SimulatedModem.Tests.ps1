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

Describe 'The simulated modem''s messages' {
    BeforeAll {
        $script:pdu = '07910100000000F0040B910100000000F000006201402143658005E8329BFD06'
    }

    BeforeEach {
        $script:modem = New-SimulatedModem -Messaging
        $script:channel = New-AtChannel -Transport $script:modem
        $null = Initialize-AtChannel -Channel $script:channel -TimeoutMs 5000
        $script:ask = { param($command) Invoke-AtCommand -Channel $script:channel -Command $command -TimeoutMs 5000 }
    }

    AfterEach {
        Close-AtChannel -Channel $script:channel
    }

    It 'starts as the device does: PDU mode, notices off, one storage of 70' {
        (& $script:ask 'AT+CMGF?').Lines | Should -Be @('+CMGF: 0')
        (& $script:ask 'AT+CNMI?').Lines | Should -Be @('+CNMI: 0, 0, 0, 0, 0')
        (& $script:ask 'AT+CPMS?').Lines | Should -Be @('+CPMS: "MT", 0, 70, "MT", 0, 70, "MT", 0, 70')
    }

    It 'stores a message that comes in, and announces it once +CNMI asks for it' {
        $script:modem.Messaging.Deliver($script:pdu, $script:modem)
        Receive-AtUrc -Channel $script:channel -TimeoutMs 200 | Should -BeNullOrEmpty
        (& $script:ask 'AT+CNMI=2,1,0,0,0').Status | Should -Be 'OK'
        $script:modem.Messaging.Deliver($script:pdu, $script:modem)

        Receive-AtUrc -Channel $script:channel -TimeoutMs 500 | Should -Be @('+CMTI: "MT",2')
        (& $script:ask 'AT+CPMS?').Lines | Should -Be @('+CPMS: "MT", 2, 70, "MT", 2, 70, "MT", 2, 70')
    }

    It 'marks a message read once listed or read' {
        $script:modem.Messaging.Deliver($script:pdu, $script:modem)
        $script:modem.Messaging.Deliver($script:pdu, $script:modem)
        (& $script:ask 'AT+CMGR=2').Lines[0] | Should -Be '+CMGR: 0,,24'

        (& $script:ask 'AT+CMGL=0').Lines | Should -Be @('+CMGL: 1,0,,24', $script:pdu)
        (& $script:ask 'AT+CMGL=0').Lines | Should -BeNullOrEmpty
        (& $script:ask 'AT+CMGL=4').Lines | Should -Be @('+CMGL: 1,1,,24', $script:pdu, '+CMGL: 2,1,,24', $script:pdu)
    }

    It 'deletes one place, or by flag, and refuses a place with nothing' {
        foreach ($i in 1..3) { $script:modem.Messaging.Deliver($script:pdu, $script:modem) }
        $null = & $script:ask 'AT+CMGR=1'
        (& $script:ask 'AT+CMGD=2').Status | Should -Be 'OK'
        (& $script:ask 'AT+CMGD=2').ErrorCode | Should -Be 321
        (& $script:ask 'AT+CMGD=0,1').Status | Should -Be 'OK'
        @((& $script:ask 'AT+CMGL=4').Lines | Where-Object { $_ -like '+CMGL:*' }) | Should -Be @('+CMGL: 3,0,,24')
        (& $script:ask 'AT+CMGD=1,4').Status | Should -Be 'OK'
        (& $script:ask 'AT+CMGL=4').Lines | Should -BeNullOrEmpty
    }

    It 'stores at the lowest free place, and nothing once full' {
        $script:modem.Messaging.Capacity = 2
        foreach ($i in 1..3) { $script:modem.Messaging.Deliver($script:pdu, $script:modem) }
        $null = & $script:ask 'AT+CMGD=1'
        $script:modem.Messaging.Deliver($script:pdu, $script:modem)

        @($script:modem.Messaging.Stored | ForEach-Object Index | Sort-Object) | Should -Be @(1, 2)
    }

    It 'takes a message already stored, read or not, without a notice' {
        (& $script:ask 'AT+CNMI=2,1,0,0,0').Status | Should -Be 'OK'
        $script:modem.Messaging.Store(1, $script:pdu) | Should -Be 1
        $script:modem.Messaging.Store(0, $script:pdu) | Should -Be 2
        $script:modem.Messaging.Capacity = 2
        $script:modem.Messaging.Store(0, $script:pdu) | Should -Be 0 -Because 'the storage is full'

        (& $script:ask 'AT+CMGL=4').Lines -match '^\+CMGL' | Should -Be @('+CMGL: 1,1,,24', '+CMGL: 2,0,,24')
        Receive-AtUrc -Channel $script:channel | Should -BeNullOrEmpty
    }

    It 'delivers a message that comes in on its own once its time has come' {
        (& $script:ask 'AT+CNMI=2,1,0,0,0').Status | Should -Be 'OK'
        $script:modem.Messaging.Arrivals.Add([pscustomobject]@{ AtMs = 0; Pdu = $script:pdu })
        $script:modem.Messaging.Arrivals.Add([pscustomobject]@{ AtMs = [long]::MaxValue; Pdu = $script:pdu })

        Receive-AtUrc -Channel $script:channel -TimeoutMs 500 | Should -Be @('+CMTI: "MT",1')
        $script:modem.Messaging.Arrivals.Count | Should -Be 1 -Because 'a message whose time has not come waits'
        $script:modem.Messaging.Stored.Count | Should -Be 1
    }

    It 'takes a PDU after AT+CMGS''s prompt, and nothing after ESC' {
        $script:modem.Write("AT+CMGS=18`r")
        $script:modem.Write("0011$([char]0x1B)")
        $script:modem.Messaging.Sent.Count | Should -Be 0
        $part = @(ConvertTo-SmsPdu -Number '+10000000000' -Text 'hello')[0]
        (Send-AtMessagePdu -Channel $script:channel -Length $part.Length -Pdu $part.Pdu).Status | Should -Be 'OK'
        $script:modem.Messaging.Sent | Should -Be @($part.Pdu)
    }
}

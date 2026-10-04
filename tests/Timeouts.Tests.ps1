# Per-command timeouts: each command's documented worst case, never less than 3 s; compound lines
# add up.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Get-AtCommandTimeout' {
    It 'gives <Command> <Expected> ms' -ForEach @(
        @{ Command = 'AT+COPS=0'; Expected = 180000 }
        @{ Command = 'AT+COPS?'; Expected = 180000 }
        @{ Command = 'AT+COPS=?'; Expected = 180000 }
        @{ Command = 'AT+CMGS=23'; Expected = 60000 }
        @{ Command = 'AT+CGACT=1,1'; Expected = 30000 }
        @{ Command = 'AT+CGATT=1'; Expected = 15000 }
        @{ Command = 'AT+CUSD=1,"*100#",15'; Expected = 10000 }
        @{ Command = 'AT+CMGL=4'; Expected = 5000 }
        # Not in the manual: measured on our eUICC, decided 2026-10-04.
        @{ Command = 'AT+CGLA=1,16,"81E2910003BF2D00"'; Expected = 10000 }
        @{ Command = 'AT+CCHO="A0000005591010FFFFFFFF8900000100"'; Expected = 3000 }
        # Documented under 3 s, or not listed: the minimum.
        @{ Command = 'AT+CMGR=1'; Expected = 3000 }
        @{ Command = 'AT+CSQ'; Expected = 3000 }
        @{ Command = 'AT'; Expected = 3000 }
        @{ Command = 'ATE1'; Expected = 3000 }
        @{ Command = 'AT&W'; Expected = 3000 }
        @{ Command = 'at+cgact=1,1'; Expected = 30000 }
        @{ Command = '  AT+CGACT=1,1  '; Expected = 30000 }
    ) {
        Get-AtCommandTimeout -Command $Command | Should -Be $Expected
    }

    It 'adds up the commands of a compound line' {
        Get-AtCommandTimeout -Command 'AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?' | Should -Be 9000
        Get-AtCommandTimeout -Command 'AT+CGACT=1,1;+CSQ' | Should -Be 33000
    }

    It 'does not read a command name inside a quoted argument' {
        Get-AtCommandTimeout -Command 'AT+CGDCONT=1,"IP","a;+COPS"' | Should -Be 3000
    }
}

Describe 'Invoke-AtCommand without a timeout' {
    BeforeAll {
        $script:modem = New-SimulatedModem
        $script:channel = New-AtChannel -Transport $script:modem
        [void](Initialize-AtChannel -Channel $script:channel)
    }

    AfterAll {
        Close-AtChannel -Channel $script:channel
    }

    It 'waits the documented worst case: a 3.5 s answer to AT+CGACT is not a timeout' {
        $script:modem.Script('AT+CGACT=1,1', @{ Lines = @('OK'); DelayMs = 3500 })
        $answer = Invoke-AtCommand -Channel $script:channel -Command 'AT+CGACT=1,1'
        $answer.Status | Should -Be 'OK'
        $answer.ElapsedMs | Should -BeGreaterOrEqual 3400
    }

    It 'gives up after the 3 s minimum on an undocumented command' {
        $script:modem.Script('AT+CSQ', @{ Lines = @('+CSQ: 20,99'); NoFinal = $true })
        $answer = Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ'
        $answer.Status | Should -Be 'Timeout'
        $answer.ElapsedMs | Should -BeGreaterOrEqual 2900
        $answer.ElapsedMs | Should -BeLessThan 6000
    }
}

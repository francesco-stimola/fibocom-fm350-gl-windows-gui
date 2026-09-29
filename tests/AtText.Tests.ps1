BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Split-AtText' {
    It 'splits <Name>' -ForEach @(
        @{ Name = 'a framed answer'; Buffer = ''; Text = "`r`n+CSQ: 20,99`r`n`r`nOK`r`n"; Lines = @('+CSQ: 20,99', 'OK'); Remainder = '' }
        @{ Name = 'an echo ended by CR alone'; Buffer = ''; Text = "AT+CSQ`r`r`n+CSQ: 20,99`r`n"; Lines = @('AT+CSQ', '+CSQ: 20,99'); Remainder = '' }
        @{ Name = 'a line completed by the next chunk'; Buffer = '+CSQ: 2'; Text = "0,99`r`n`r`nOK`r`n+CE"; Lines = @('+CSQ: 20,99', 'OK'); Remainder = '+CE' }
        @{ Name = 'text with no line end yet'; Buffer = ''; Text = 'OK'; Lines = @(); Remainder = 'OK' }
        @{ Name = 'an empty chunk'; Buffer = '+CS'; Text = ''; Lines = @(); Remainder = '+CS' }
        @{ Name = 'LF-only line ends'; Buffer = ''; Text = "+CSQ: 20,99`nOK`n"; Lines = @('+CSQ: 20,99', 'OK'); Remainder = '' }
        @{ Name = 'a noise-only line, dropped'; Buffer = ''; Text = "$([char]0)$([char]0xFF)$([char]0xFE)`r`nOK`r`n"; Lines = @('OK'); Remainder = '' }
        @{ Name = 'noise inside a line, removed'; Buffer = ''; Text = "$([char]0xFF)O$([char]7)K`r`n"; Lines = @('OK'); Remainder = '' }
        @{ Name = 'padding around a line, trimmed'; Buffer = ''; Text = "  OK `t`r`n"; Lines = @('OK'); Remainder = '' }
    ) {
        $split = Split-AtText -Buffer $Buffer -Text $Text
        ($split.Lines -join '|') | Should -BeExactly ($Lines -join '|')
        $split.Remainder | Should -BeExactly $Remainder
    }

    It 'returns Lines as an array even when there is one line or none' {
        (Split-AtText -Text "OK`r`n").Lines.GetType().IsArray | Should -BeTrue
        (Split-AtText -Text 'O').Lines.GetType().IsArray | Should -BeTrue
    }

    It 'drops an unterminated remainder that outgrows any real line' {
        $split = Split-AtText -Buffer ('x' * 4000) -Text ('y' * 200)
        $split.Remainder | Should -BeExactly ''
        $split.Lines | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-AtLine' {
    It 'with nothing pending, reads <Line> as <Kind>' -ForEach @(
        @{ Line = '+CEREG: 1'; Kind = 'Urc' }
        @{ Line = 'RING'; Kind = 'Urc' }
        @{ Line = 'an unknown banner'; Kind = 'Urc' }
        @{ Line = 'OK'; Kind = 'Stale' }
        @{ Line = '+CME ERROR: 14'; Kind = 'Stale' }
    ) {
        (Resolve-AtLine -Line $Line).Kind | Should -Be $Kind
    }

    It 'before the echo of <Command>, reads <Line> as <Kind>' -ForEach @(
        @{ Command = 'AT+CSQ'; Line = 'AT+CSQ'; Kind = 'Echo' }
        @{ Command = 'AT+CSQ'; Line = 'at+csq'; Kind = 'Echo' }
        @{ Command = 'AT+CSQ'; Line = '+CSQ: 20,99'; Kind = 'Stale' }
        @{ Command = 'AT+CSQ'; Line = 'OK'; Kind = 'Stale' }
        @{ Command = 'AT+CSQ'; Line = '+CEREG: 1'; Kind = 'Urc' }
        # Its own prefix can't be its answer yet: the echo hasn't come.
        @{ Command = 'AT+CEREG?'; Line = '+CEREG: 1'; Kind = 'Urc' }
    ) {
        (Resolve-AtLine -Line $Line -Command $Command).Kind | Should -Be $Kind
    }

    It 'after the echo of <Command>, reads <Line> as <Kind>' -ForEach @(
        @{ Command = 'AT+CSQ'; Line = '+CSQ: 20,99'; Kind = 'Response' }
        @{ Command = 'AT+CSQ'; Line = '+CEREG: 1'; Kind = 'Urc' }
        @{ Command = 'AT+CSQ'; Line = 'AT+CSQ'; Kind = 'Echo' }
        @{ Command = 'AT+CEREG?'; Line = '+CEREG: 2,1'; Kind = 'Response' }
        @{ Command = 'AT+GTCCINFO?;+GTCAINFO?'; Line = '+GTCAINFO:'; Kind = 'Response' }
        @{ Command = 'AT+GTCCINFO?;+GTCAINFO?'; Line = 'PCC:103,123,1300,100'; Kind = 'Response' }
        @{ Command = 'AT+GTCCINFO?;+GTCAINFO?'; Line = '+CEREG: 1'; Kind = 'Urc' }
        # A prefix inside a quoted argument is not the command's own.
        @{ Command = 'AT+CUSD=1,"+CEREG",15'; Line = '+CEREG: 1'; Kind = 'Urc' }
        @{ Command = 'ATI'; Line = 'Fibocom'; Kind = 'Response' }
    ) {
        (Resolve-AtLine -Line $Line -Command $Command -EchoSeen).Kind | Should -Be $Kind
    }

    It 'reads final result <Line> as <Status>' -ForEach @(
        @{ Line = 'OK'; Status = 'OK'; Code = $null; Text = $null }
        @{ Line = 'ERROR'; Status = 'Error'; Code = $null; Text = $null }
        @{ Line = '+CME ERROR: 14'; Status = 'CmeError'; Code = 14; Text = '14' }
        @{ Line = '+CME ERROR: SIM busy'; Status = 'CmeError'; Code = $null; Text = 'SIM busy' }
        @{ Line = '+CMS ERROR: 314'; Status = 'CmsError'; Code = 314; Text = '314' }
        @{ Line = 'NO CARRIER'; Status = 'NoCarrier'; Code = $null; Text = $null }
        @{ Line = 'BUSY'; Status = 'Busy'; Code = $null; Text = $null }
        @{ Line = 'NO ANSWER'; Status = 'NoAnswer'; Code = $null; Text = $null }
        @{ Line = 'NO DIALTONE'; Status = 'NoDialtone'; Code = $null; Text = $null }
    ) {
        $resolved = Resolve-AtLine -Line $Line -Command 'AT+CPIN?' -EchoSeen
        $resolved.Kind | Should -Be 'Final'
        $resolved.Status | Should -Be $Status
        $resolved.ErrorCode | Should -Be $Code
        $resolved.ErrorText | Should -Be $Text
    }

    It 'gives no status or error to a line that is not a final result' {
        $resolved = Resolve-AtLine -Line '+CSQ: 20,99' -Command 'AT+CSQ' -EchoSeen
        $resolved.Status | Should -BeNullOrEmpty
        $resolved.ErrorCode | Should -BeNullOrEmpty
        $resolved.ErrorText | Should -BeNullOrEmpty
    }
}

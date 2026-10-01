# The log: what redaction removes - secrets, identifiers, location, message content - what it
# keeps, and the rolling daily files.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-RedactedText' {
    It 'redacts <Name>' -ForEach @(
        @{ Name = 'the PIN of AT+CPIN='; Text = 'AT+CPIN="1234"'; Expected = 'AT+CPIN=***' }
        @{ Name = 'an unquoted PIN'; Text = 'AT+CPIN=1234'; Expected = 'AT+CPIN=***' }
        @{ Name = 'AT+CPWD'; Text = 'AT+CPWD="SC","1234","5678"'; Expected = 'AT+CPWD=***' }
        @{ Name = 'the password of AT+CLCK'; Text = 'AT+CLCK="SC",0,"1234"'; Expected = 'AT+CLCK="SC",0,***' }
        @{ Name = 'APN credentials in AT+CGAUTH='; Text = 'AT+CGAUTH=1,1,"user","pass,word"'; Expected = 'AT+CGAUTH=1,1,***' }
        @{ Name = 'APN credentials in a +CGAUTH: answer'; Text = '+CGAUTH: 1,2,"user","secret"'; Expected = '+CGAUTH: 1,2,***' }
        @{ Name = 'an IMEI'; Text = '356938035643809'; Expected = '<id>' }
        @{ Name = 'an IMSI'; Text = '+CIMI: 222015602712345'; Expected = '+CIMI: <id>' }
        @{ Name = 'an ICCID ending in F'; Text = '+ICCID: 893910452000123456F'; Expected = '+ICCID: <id>' }
        @{ Name = 'an EID'; Text = '+EID: "89049032000001000000012345678901"'; Expected = '+EID: <id>' }
        @{ Name = 'a phone number'; Text = '+CNUM: "","+393331234567",145'; Expected = '+CNUM: "","<number>",145' }
        @{ Name = 'the module serial number'; Text = '+CFSN: "AB12CD34EF"'; Expected = '+CFSN: <id>' }
        @{ Name = 'TAC and cell identity in +CEREG'; Text = '+CEREG: 2,1,"5A1F","01C2D3E4",7'; Expected = '+CEREG: 2,1,"<loc>","<loc>",7' }
        @{ Name = 'TAC, cell identity and RAC in +CGREG'; Text = '+CGREG: 2,1,"5A1F","01C2D3E4",7,"0A"'; Expected = '+CGREG: 2,1,"<loc>","<loc>",7,"<loc>"' }
        @{ Name = 'a padded +C5GREG'; Text = '+C5GREG: 2,1,"005A1F","0001C2D3E4",13'; Expected = '+C5GREG: 2,1,"<loc>","<loc>",13' }
        @{ Name = 'a +GTCCINFO serving cell'; Text = '1,4,222,10,5A1F,01C2D3E4,1850,123,103,100,40,60,50,20'; Expected = '1,4,222,10,<loc>,<loc>,1850,123,103,100,40,60,50,20' }
        @{ Name = 'a USSD reply'; Text = '+CUSD: 0,"Credito 5,20 EUR",15'; Expected = '+CUSD: 0,***' }
        @{ Name = 'a message PDU'; Text = '07913396050036F0040B913366554433F20000'; Expected = '<pdu>' }
        @{ Name = 'a PIN, keeping the rest of the line'; Text = 'EnterPin: Done - AT+CPIN="1234" OK; next'; Expected = 'EnterPin: Done - AT+CPIN=*** OK; next' }
        @{ Name = 'a redacted PIN again, unchanged'; Text = 'AT+CPIN=*** OK'; Expected = 'AT+CPIN=*** OK' }
        @{ Name = 'credentials, keeping the rest of the line'; Text = 'AT+CGAUTH=1,2,"me","a b" OK'; Expected = 'AT+CGAUTH=1,2,*** OK' }
    ) {
        ConvertTo-RedactedText -Text $Text | Should -Be $Expected
    }

    It 'keeps <Name>' -ForEach @(
        @{ Name = 'a read of the SIM state'; Text = 'AT+CPIN?' }
        @{ Name = 'the SIM state'; Text = '+CPIN: SIM PIN' }
        @{ Name = 'a read of the PIN request'; Text = 'AT+CLCK="SC",2' }
        @{ Name = 'no APN authentication'; Text = 'AT+CGAUTH=1,0' }
        @{ Name = 'signal quality'; Text = '+CSQ: 20,99' }
        @{ Name = 'the firmware'; Text = '+GTPKGVER: "81600.0000.00.29.22.06_5006.0000.065.006.048_E09"' }
        @{ Name = 'addresses'; Text = '+CGCONTRDP: 1,6,"internet","198.51.100.23.255.255.255.0","198.51.100.1","203.0.113.53"' }
        @{ Name = 'the "not known" location pattern'; Text = '+CEREG: 2,2,"FFFF","0FFFFFFF",7' }
        @{ Name = 'a +GTCCINFO neighbour without location'; Text = '2,4,,,FFFF,00FFFFFFF,6400,100,,55,55,16' }
        @{ Name = 'a band list'; Text = '+GTACT: 20,6,3,101,103,107,5078' }
        @{ Name = 'an error'; Text = '+CME ERROR: 16' }
        @{ Name = 'a timestamp-like number of 13 digits'; Text = 'took 1234567890123 ticks' }
    ) {
        ConvertTo-RedactedText -Text $Text | Should -Be $Text
    }

    It 'redacts every line of a multi-line text' {
        $text = "AT+CPIN=""1234""`r`n+CIMI: 222015602712345`nOK"
        ConvertTo-RedactedText -Text $text | Should -Be (@('AT+CPIN=***', '+CIMI: <id>', 'OK') -join [Environment]::NewLine)
    }
}

Describe 'Write-AppLog' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive "logs-$([guid]::NewGuid())"
        $script:time = [DateTimeOffset]::new(2026, 10, 1, 9, 30, 0, 123, [TimeSpan]::FromHours(2))
    }

    It 'writes one redacted, timestamped line to the day''s file' {
        Write-AppLog -Folder $script:folder -Time $script:time -Level Warning -Message 'Sent AT+CPIN="1234"'
        $file = Join-Path $script:folder 'fm350-2026-10-01.log'
        Get-Content -LiteralPath $file | Should -Be @('2026-10-01T09:30:00.123+02:00 WARNING Sent AT+CPIN=***')
    }

    It 'indents the continuation lines of a multi-line message' {
        Write-AppLog -Folder $script:folder -Time $script:time -Message "Answer:`n+CIMI: 222015602712345"
        Get-Content -LiteralPath (Join-Path $script:folder 'fm350-2026-10-01.log') | Should -Be @('2026-10-01T09:30:00.123+02:00 INFO    Answer:', '    +CIMI: <id>')
    }

    It 'starts a new file each day and keeps the 14 newest' {
        foreach ($day in 0..19) {
            Write-AppLog -Folder $script:folder -Time $script:time.AddDays($day) -Message "day $day"
        }
        $files = @(Get-ChildItem -LiteralPath $script:folder -Filter 'fm350-*.log' | Sort-Object Name)
        $files.Count | Should -Be 14
        $files[0].Name | Should -Be 'fm350-2026-10-07.log'
        $files[-1].Name | Should -Be 'fm350-2026-10-20.log'
    }

    It 'stops a day''s file at its limit, saying so once' {
        InModuleScope FibocomFm350 { $script:LogMaxBytesPerDay = 400 }
        try {
            foreach ($i in 1..20) {
                Write-AppLog -Folder $script:folder -Time $script:time -Message "line number $i of the day"
            }
            $lines = Get-Content -LiteralPath (Join-Path $script:folder 'fm350-2026-10-01.log')
            @($lines | Where-Object { $_ -match 'daily limit' }).Count | Should -Be 1
            $lines[-1] | Should -Match 'daily limit'
            (Get-Item -LiteralPath (Join-Path $script:folder 'fm350-2026-10-01.log')).Length | Should -BeLessOrEqual 500
        }
        finally {
            InModuleScope FibocomFm350 { $script:LogMaxBytesPerDay = 10MB }
        }
    }
}

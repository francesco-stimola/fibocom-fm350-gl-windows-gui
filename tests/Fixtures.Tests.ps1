# Every fixture follows the format and names its source, and carries no identifier except the
# documented fakes (tests/fixtures/fakes.psd1; rules in docs/SETUP.md -> Fixtures).

BeforeDiscovery {
    $script:fixtureCases = Get-ChildItem -Path "$PSScriptRoot/fixtures" -Recurse -File | Where-Object Extension -In '.txt', '.json' | ForEach-Object {
        @{ Name = [System.IO.Path]::GetRelativePath("$PSScriptRoot/fixtures", $_.FullName); Path = $_.FullName; Json = $_.Extension -eq '.json' }
    }
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    $script:fakes = Import-PowerShellDataFile -Path "$PSScriptRoot/fixtures/fakes.psd1"

    # Describes each identifier-like value in $Line that is not a documented fake.
    function Find-UnredactedValue {
        param([string] $Line)

        # A message PDU: its numbers are semi-octets, read by decoding it. One that doesn't decode
        # is checked as any other line.
        if ($Line -match '^\s*(?:[0-9A-Fa-f]{2}){10,}\s*$') {
            $sms = ConvertFrom-SmsPdu -Pdu $Line
            if (-not $sms.Problem) {
                foreach ($address in @($sms.ServiceCentre, $sms.Address) | Where-Object { $_ }) {
                    if ($address -notin ($script:fakes.PhoneNumbers + $script:fakes.SmsSenders)) {
                        "address '$address' in a message PDU"
                    }
                }
                return
            }
        }
        foreach ($match in [regex]::Matches($Line, '(?<!\d)\d{14,}(?!\d)')) {
            if ($match.Value -notin $script:fakes.LongNumbers) {
                "long number '$($match.Value)' (IMEI, IMSI, ICCID or EID?)"
            }
        }
        foreach ($match in [regex]::Matches($Line, '"(\+?\d{7,})"')) {
            if ($match.Groups[1].Value -notin ($script:fakes.PhoneNumbers + $script:fakes.SerialNumbers)) {
                "phone number '$($match.Groups[1].Value)'"
            }
        }
        if ($Line -match '^\s*\+CFSN\s*:\s*"([^"]*)"' -and $Matches[1] -notin $script:fakes.SerialNumbers) {
            "serial number '$($Matches[1])'"
        }
        # Registration reports: every quoted hex field is location data (TAC, cell identity, RAC).
        if ($Line -match '^\+C(5G|E|G)?REG:') {
            foreach ($match in [regex]::Matches($Line, '"([0-9A-Fa-f]+)"')) {
                $value = $match.Groups[1].Value
                if ($value -notin ($script:fakes.Tac + $script:fakes.CellId) -and $value -notmatch $script:fakes.LocationNotKnown) {
                    "location field '$value'"
                }
            }
        }
        # +GTCCINFO cell lines: TAC at position 5, cell identity at position 6.
        if ($Line -match '^[12],\d+,') {
            $fields = $Line.Split(',')
            if ($fields.Count -ge 6) {
                if ($fields[4] -notin $script:fakes.Tac -and $fields[4] -notmatch $script:fakes.LocationNotKnown) {
                    "TAC '$($fields[4])'"
                }
                if ($fields[5] -notin $script:fakes.CellId -and $fields[5] -notmatch $script:fakes.LocationNotKnown) {
                    "cell identity '$($fields[5])'"
                }
            }
        }
        # PnP instance IDs, with the backslashes JSON doubles: the part after the device ID.
        foreach ($match in [regex]::Matches($Line, 'USB\\{1,2}[^\\"]+\\{1,2}([^\\",\s]+)')) {
            $instance = $match.Groups[1].Value
            if ($instance -notin $script:fakes.SerialNumbers -and $instance -notmatch "^\d+&$($script:fakes.InstanceIdHash)&\d+&[0-9A-Fa-f]+$") {
                "PnP instance '$instance'"
            }
        }
        foreach ($match in [regex]::Matches($Line, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}')) {
            if ("{$($match.Value)}" -notin $script:fakes.ContainerIds) {
                "GUID '$($match.Value)'"
            }
        }
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Fixture <Name>' -ForEach $script:fixtureCases {
    It 'follows the fixture format and names its source' {
        if ($Json) {
            # PnP device records: { "Source": ..., "Devices": [ ... ] }
            $fixture = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
            $source = $fixture.Source
            @($fixture.Devices).Count | Should -BeGreaterThan 0
        }
        else {
            $source = (Import-AtFixture -Path $Path -ErrorAction Stop).Notes -join ' '
        }
        $source | Should -Match '\[[0-9A-Z.-]+\]|captured' -Because 'a fixture says where its content comes from'
    }

    It 'carries no identifier other than the documented fakes' {
        $found = foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -notmatch '^\s*#') {
                Find-UnredactedValue -Line $line
            }
        }
        $found | Should -BeNullOrEmpty
    }
}

Describe 'The simulated modem of development mode' {
    It 'answers with no identifier other than the documented fakes' {
        $data = Import-PowerShellDataFile -Path "$PSScriptRoot/../src/FibocomFm350/Data/Simulation.psd1"
        # Every answer line: the base answers, and each scenario's answers and changes.
        $answers = @($data.Answers) + @($data.Scenarios.Values | ForEach-Object { $_['Answers'] } | Where-Object { $_ })
        $answers += @($data.Scenarios.Values | ForEach-Object { $_['Then'] } | Where-Object { $_ } | ForEach-Object { $_.Values } | Where-Object { $_ -is [hashtable] })
        $lines = @($answers | ForEach-Object { $_.Values } | ForEach-Object { $_ } | Where-Object { $_ -is [string] })
        $lines.Count | Should -BeGreaterThan 30
        $found = foreach ($line in $lines) {
            Find-UnredactedValue -Line $line
        }
        $found | Should -BeNullOrEmpty
    }
}

Describe 'The identifier check itself' {
    It 'flags <Name>' -ForEach @(
        @{ Name = 'an IMEI'; Line = '356938035643809' }
        @{ Name = 'an IMSI'; Line = '+CIMI: 222015602712345' }
        @{ Name = 'an ICCID'; Line = '+ICCID: 8939104520001234567' }
        @{ Name = 'a phone number'; Line = '+CNUM: "","+393331234567",145' }
        @{ Name = 'a module serial number'; Line = '+CFSN: "AB12CD34EF"' }
        @{ Name = 'a real TAC in +CEREG'; Line = '+CEREG: 2,1,"5A1F","0ABCDEF0",7' }
        @{ Name = 'a real cell identity in +GTCCINFO'; Line = '1,4,001,01,ABCD,1C2D3E4F,1300,123,103,100,40,60,50,20' }
        @{ Name = 'a generated PnP instance'; Line = '"InstanceId": "USB\\VID_0E8D&PID_7127\\7&2a3b4c5d&0&1",' }
        @{ Name = 'a USB serial number in a PnP instance'; Line = '"Parent": "USB\\VID_0E8D&PID_7127\\A1B2C3D4E5",' }
        @{ Name = 'a real container ID'; Line = '"ContainerId": "{3f2504e0-4f89-11d3-9a0c-0305e82c3301}",' }
        @{ Name = 'a real nine-digit cell identity in +CREG'; Line = '+CREG: 2,6,"ABCD","001C2D3E4",13' }
        @{ Name = 'a real neighbour TAC in +GTCCINFO'; Line = '2,4,,,5A1F,00FFFFFFF,6400,100,,55,55,16' }
        @{ Name = 'a real sender in a message PDU'; Line = '00040C9193331332547600006201402143658005E8329BFD06' }
        @{ Name = 'a real service centre in a message PDU'; Line = '07919333133254F6040B910100000000F000006201402143658005E8329BFD06' }
        @{ Name = 'a sender''s real name in a message PDU'; Line = '00040ED0D637396C7EBBCB00006201402143658005E8329BFD06' }
    ) {
        Find-UnredactedValue -Line $Line | Should -Not -BeNullOrEmpty
    }

    It 'accepts <Name>' -ForEach @(
        @{ Name = 'the fake IMEI'; Line = '000000000000000' }
        @{ Name = 'the fake serial number'; Line = '+CFSN: "0000000000"' }
        @{ Name = 'fake location in +CEREG'; Line = '+CEREG: 2,1,"ABCD","0ABCDEF0",7' }
        @{ Name = 'fake location in +GTCCINFO'; Line = '1,4,001,01,ABCD,0ABCDEF0,1300,123,103,100,40,60,50,20' }
        @{ Name = 'ordinary numbers'; Line = '+CSQ: 20,99' }
        @{ Name = 'a fake PnP instance'; Line = '"InstanceId": "USB\\VID_0E8D&PID_7127&MI_06\\8&00000000&0&0006",' }
        @{ Name = 'a hardware ID'; Line = '"USB\\VID_0E8D&PID_7127&REV_0001&MI_06",' }
        @{ Name = 'a fake container ID'; Line = '"ContainerId": "{00000000-0000-0000-0000-000000000001}",' }
        @{ Name = 'location not known in +CREG'; Line = '+CREG: 2,"FFFF","00FFFFFFF",0' }
        @{ Name = 'location not known in a +GTCCINFO neighbour'; Line = '2,4,,,FFFF,00FFFFFFF,6400,100,,55,55,16' }
        @{ Name = 'padded fakes in +C5GREG'; Line = '+C5GREG: 2,1,"00ABCD","000ABCDEF0",13' }
        @{ Name = 'a message PDU with the fake numbers'; Line = '07910100000000F0040B910100000000F000006201402143658005E8329BFD06' }
        @{ Name = 'a message PDU from a fake name'; Line = '00040ED04F78591EA6BFE500006201402143658005E8329BFD06' }
    ) {
        Find-UnredactedValue -Line $Line | Should -BeNullOrEmpty
    }
}

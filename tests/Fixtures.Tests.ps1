# Every fixture follows the format and names its source, and carries no identifier except the
# documented fakes (tests/fixtures/fakes.psd1; rules in docs/SETUP.md -> Fixtures).

BeforeDiscovery {
    $script:fixtureCases = Get-ChildItem -Path "$PSScriptRoot/fixtures" -Recurse -Filter '*.txt' | ForEach-Object {
        @{ Name = [System.IO.Path]::GetRelativePath("$PSScriptRoot/fixtures", $_.FullName); Path = $_.FullName }
    }
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    $script:fakes = Import-PowerShellDataFile -Path "$PSScriptRoot/fixtures/fakes.psd1"

    # Describes each identifier-like value in $Line that is not a documented fake.
    function Find-UnredactedValue {
        param([string] $Line)

        foreach ($match in [regex]::Matches($Line, '(?<!\d)\d{14,}(?!\d)')) {
            if ($match.Value -notin $script:fakes.LongNumbers) {
                "long number '$($match.Value)' (IMEI, IMSI, ICCID or EID?)"
            }
        }
        foreach ($match in [regex]::Matches($Line, '"(\+?\d{7,})"')) {
            if ($match.Groups[1].Value -notin $script:fakes.PhoneNumbers) {
                "phone number '$($match.Groups[1].Value)'"
            }
        }
        # Registration reports: every quoted hex field is a TAC or a cell identity.
        if ($Line -match '^\+C(5G|E|G)?REG:') {
            foreach ($match in [regex]::Matches($Line, '"([0-9A-Fa-f]+)"')) {
                if ($match.Groups[1].Value -notin ($script:fakes.Tac + $script:fakes.CellId)) {
                    "location field '$($match.Groups[1].Value)'"
                }
            }
        }
        # +GTCCINFO cell lines: TAC at position 5, cell identity at position 6.
        if ($Line -match '^[12],\d+,') {
            $fields = $Line.Split(',')
            if ($fields.Count -ge 6) {
                if ($fields[4] -notin $script:fakes.Tac) {
                    "TAC '$($fields[4])'"
                }
                if ($fields[5] -notin $script:fakes.CellId) {
                    "cell identity '$($fields[5])'"
                }
            }
        }
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Fixture <Name>' -ForEach $script:fixtureCases {
    It 'follows the fixture format and names its source' {
        $fixture = Import-AtFixture -Path $Path -ErrorAction Stop
        ($fixture.Notes -join ' ') | Should -Match '\[[0-9A-Z.-]+\]|captured' -Because 'a fixture says where its content comes from'
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

Describe 'The identifier check itself' {
    It 'flags <Name>' -ForEach @(
        @{ Name = 'an IMEI'; Line = '356938035643809' }
        @{ Name = 'an IMSI'; Line = '+CIMI: 222015602712345' }
        @{ Name = 'an ICCID'; Line = '+ICCID: 8939104520001234567' }
        @{ Name = 'a phone number'; Line = '+CNUM: "","+393331234567",145' }
        @{ Name = 'a real TAC in +CEREG'; Line = '+CEREG: 2,1,"5A1F","0ABCDEF0",7' }
        @{ Name = 'a real cell identity in +GTCCINFO'; Line = '1,4,001,01,ABCD,1C2D3E4F,1300,123,103,100,40,60,50,20' }
    ) {
        Find-UnredactedValue -Line $Line | Should -Not -BeNullOrEmpty
    }

    It 'accepts <Name>' -ForEach @(
        @{ Name = 'the fake IMEI'; Line = '000000000000000' }
        @{ Name = 'fake location in +CEREG'; Line = '+CEREG: 2,1,"ABCD","0ABCDEF0",7' }
        @{ Name = 'fake location in +GTCCINFO'; Line = '1,4,001,01,ABCD,0ABCDEF0,1300,123,103,100,40,60,50,20' }
        @{ Name = 'ordinary numbers'; Line = '+CSQ: 20,99' }
    ) {
        Find-UnredactedValue -Line $Line | Should -BeNullOrEmpty
    }
}

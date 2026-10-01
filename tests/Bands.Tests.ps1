BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    . "$PSScriptRoot/FixtureAnswer.ps1"
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-GtactBandCode' {
    It 'encodes <Rat> band <Band> as <Code>' -ForEach @(
        @{ Rat = 'LTE'; Band = 1; Code = 101 }
        @{ Rat = 'LTE'; Band = 3; Code = 103 }
        @{ Rat = 'LTE'; Band = 7; Code = 107 }
        @{ Rat = 'LTE'; Band = 20; Code = 120 }
        @{ Rat = 'LTE'; Band = 99; Code = 199 }
        @{ Rat = 'NR'; Band = 1; Code = 501 }
        @{ Rat = 'NR'; Band = 9; Code = 509 }
        @{ Rat = 'NR'; Band = 10; Code = 5010 }
        @{ Rat = 'NR'; Band = 78; Code = 5078 }
        @{ Rat = 'NR'; Band = 99; Code = 5099 }
        @{ Rat = 'NR'; Band = 100; Code = 50100 }
        @{ Rat = 'NR'; Band = 257; Code = 50257 }
        @{ Rat = 'NR'; Band = 512; Code = 50512 }
    ) {
        ConvertTo-GtactBandCode -Rat $Rat -Band $Band | Should -Be $Code
    }

    It 'encodes bands from the pipeline, in order' {
        3, 7, 20 | ConvertTo-GtactBandCode -Rat LTE | Should -Be @(103, 107, 120)
    }

    # Each refusal guards the round trip: an accepted value here would encode to a code that
    # decodes as something else (LTE 100 -> 200) or to an undocumented encoding (n513+, UMTS).
    It 'refuses <Rat> band <Band>' -ForEach @(
        @{ Rat = 'LTE'; Band = 0 }
        @{ Rat = 'NR'; Band = 0 }
        @{ Rat = 'NR'; Band = 513 }
        @{ Rat = 'UMTS'; Band = 1 }
    ) {
        { ConvertTo-GtactBandCode -Rat $Rat -Band $Band } |
            Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
    }

    It 'refuses LTE band <Band> with an error and no output' -ForEach @(
        @{ Band = 100 }
        @{ Band = 512 }
    ) {
        $output = ConvertTo-GtactBandCode -Rat LTE -Band $Band -ErrorVariable failures -ErrorAction SilentlyContinue
        $output | Should -BeNullOrEmpty
        $failures | Should -HaveCount 1
        $failures[0].FullyQualifiedErrorId | Should -BeLike 'LteBandOutOfRange*'
        $failures[0].Exception | Should -BeOfType ([System.ArgumentOutOfRangeException])
    }

    It 'skips a refused LTE band in a pipeline and encodes the rest' {
        $output = 3, 100, 7 | ConvertTo-GtactBandCode -Rat LTE -ErrorVariable failures -ErrorAction SilentlyContinue
        $output | Should -Be @(103, 107)
        $failures | Should -HaveCount 1
    }
}

Describe 'ConvertFrom-GtactBandCode' {
    It 'decodes <Code> as <Kind> <Band>' -ForEach @(
        @{ Code = 0; Kind = 'AllBands'; Band = $null }
        @{ Code = 101; Kind = 'LTE'; Band = 1 }
        @{ Code = 103; Kind = 'LTE'; Band = 3 }
        @{ Code = 171; Kind = 'LTE'; Band = 71 }
        @{ Code = 199; Kind = 'LTE'; Band = 99 }
        @{ Code = 501; Kind = 'NR'; Band = 1 }
        @{ Code = 5010; Kind = 'NR'; Band = 10 }
        @{ Code = 5078; Kind = 'NR'; Band = 78 }
        @{ Code = 50100; Kind = 'NR'; Band = 100 }
        @{ Code = 50512; Kind = 'NR'; Band = 512 }
    ) {
        $decoded = ConvertFrom-GtactBandCode -Code $Code
        Should -ActualValue $decoded.Kind -Be $Kind
        Should -ActualValue $decoded.Band -Be $Band
        Should -ActualValue $decoded.Code -Be $Code
    }

    It 'keeps unrecognized code <Code> as Unknown with its raw value' -ForEach @(
        @{ Code = 5 }
        @{ Code = 100 }
        @{ Code = 200 }
        @{ Code = 500 }
        @{ Code = 5000 }
        @{ Code = 5001 }
        @{ Code = 50012 }
        @{ Code = 50513 }
        @{ Code = 501000 }
    ) {
        $decoded = ConvertFrom-GtactBandCode -Code $Code
        Should -ActualValue $decoded.Kind -Be 'Unknown'
        Should -ActualValue $decoded.Band -BeNullOrEmpty
        Should -ActualValue $decoded.Code -Be $Code
    }

    It 'decodes a code given as text: <Code>' -ForEach @(
        @{ Code = '0'; Kind = 'AllBands'; Value = 0 }
        @{ Code = '103'; Kind = 'LTE'; Value = 103 }
        @{ Code = '5078'; Kind = 'NR'; Value = 5078 }
    ) {
        $decoded = $Code | ConvertFrom-GtactBandCode
        Should -ActualValue $decoded.Kind -Be $Kind
        Should -ActualValue $decoded.Code -Be $Value
        Should -ActualValue $decoded.Code -BeOfType ([int])
    }

    # An empty field must never read as 0 ("automatic band selection"): written back, it would
    # drop the band lock. Leading zeros and non-integers are refused too, so Code is the raw value.
    It 'refuses code <Label>' -ForEach @(
        @{ Label = '-1'; Code = -1 }
        @{ Label = 'empty'; Code = '' }
        @{ Label = 'blank'; Code = ' ' }
        @{ Label = 'abc'; Code = 'abc' }
        @{ Label = '05078 (leading zero)'; Code = '05078' }
        @{ Label = '1.5'; Code = '1.5' }
        @{ Label = '1000000000 (too long)'; Code = '1000000000' }
    ) {
        { ConvertFrom-GtactBandCode -Code $Code } |
            Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
    }

    # -ErrorAction Stop makes the outcome independent of the caller's $ErrorActionPreference
    # (GitHub's pwsh shell sets it to Stop; an interactive session leaves it at Continue).
    It 'refuses an empty field from the pipeline' {
        { '' | ConvertFrom-GtactBandCode -ErrorAction Stop } |
            Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
    }
}

Describe 'Band code round trip' {
    It 'decodes every encodable band back to itself' {
        $bands = @{ LTE = 1..99; NR = 1..512 }
        $failures = foreach ($rat in $bands.Keys) {
            foreach ($band in $bands[$rat]) {
                $decoded = ConvertTo-GtactBandCode -Rat $rat -Band $band | ConvertFrom-GtactBandCode
                if ($decoded.Kind -ne $rat -or $decoded.Band -ne $band) {
                    "$rat $band -> $($decoded.Kind) $($decoded.Band)"
                }
            }
        }
        $failures | Should -BeNullOrEmpty
    }
}

Describe 'Band codes the device reports' {
    BeforeAll {
        # AT-COMMANDS section 5: the bands documented for the FM350-GL.
        $script:documentedLte = 1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 18, 19, 20, 25, 26, 28, 29, 30, 32, 34, 38, 39, 40, 41, 42, 43, 46, 48, 66, 71
        $script:documentedNr = 1, 2, 3, 5, 7, 8, 20, 25, 28, 30, 38, 40, 41, 48, 66, 71, 77, 78, 79
    }

    It 'decodes the supported lists of AT+GTACT=? to the documented LTE and NR bands' {
        $line = (Get-FixtureAnswer -Name 'gtact.test.txt' -Folder device)[0]
        # Groups: RATs, pref1, pref2, GSM, UMTS, LTE, CDMA, EVDO, NR.
        $groups = @([regex]::Matches($line, '\(([^)]*)\)') | ForEach-Object { $_.Groups[1].Value })
        $groups.Count | Should -Be 9
        $lte = $groups[5] -split ',' | ConvertFrom-GtactBandCode
        $nr = $groups[8] -split ',' | ConvertFrom-GtactBandCode
        @($lte.Kind | Sort-Object -Unique) | Should -Be @('LTE')
        @($nr.Kind | Sort-Object -Unique) | Should -Be @('NR')
        $lte.Band | Should -Be $script:documentedLte
        $nr.Band | Should -Be $script:documentedNr
    }

    It 'decodes <Fixture>: <Case>' -ForEach @(
        @{ Fixture = 'gtact.combined.txt'; Case = 'LTE and NR codes written together'; Lte = @(3, 20); Nr = @(78) }
        @{ Fixture = 'gtact.ltefull-n78.txt'; Case = 'every LTE code written, NR kept on n78'; Lte = $null; Nr = @(78) }
        @{ Fixture = 'gtact.auto.txt'; Case = 'automatic, every NR band but n77'; Lte = $null; Nr = @(1, 2, 3, 5, 7, 8, 20, 25, 28, 30, 38, 40, 41, 48, 66, 71, 78, 79) }
    ) {
        $fields = ((Get-FixtureAnswer -Name $Fixture -Folder device)[0] -replace '^\+GTACT:\s*', '') -split ','
        $fields[0..2] | Should -Be @('20', '6', '3')
        $bands = $fields | Select-Object -Skip 3 | ConvertFrom-GtactBandCode
        # UMTS codes 1-10 are kept as Unknown, with their raw value (AT-COMMANDS section 5).
        ($bands | Where-Object Kind -EQ 'Unknown').Code | Should -Be @(1, 2, 4, 5, 8)
        ($bands | Where-Object Kind -EQ 'LTE').Band | Should -Be $(if ($Lte) { $Lte } else { $script:documentedLte })
        ($bands | Where-Object Kind -EQ 'NR').Band | Should -Be $Nr
    }

    It 'decodes AT+GTACT? in LTE-only mode, which lists every LTE band' {
        $fields = ((Get-FixtureAnswer -Name 'gtact.lteonly.txt' -Folder device)[0] -replace '^\+GTACT:\s*', '') -split ','
        $fields[0..2] | Should -Be @('2', '3', '3')
        $bands = $fields | Select-Object -Skip 3 | ConvertFrom-GtactBandCode
        @($bands.Kind | Sort-Object -Unique) | Should -Be @('LTE')
        $bands.Band | Should -Be $script:documentedLte
    }
}

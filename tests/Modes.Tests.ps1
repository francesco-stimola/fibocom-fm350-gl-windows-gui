# The network mode and its bands (AT+GTACT): the read and test forms parsed from the device's
# captures, the command written, the decision to write - or not - and the trial of a mode the user
# chose.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    . "$PSScriptRoot/FixtureAnswer.ps1"

    $script:lteAll = 1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 18, 19, 20, 25, 26, 28, 29, 30, 32, 34, 38, 39, 40, 41, 42, 43, 46, 48, 66, 71
    $script:nrAll = 1, 2, 3, 5, 7, 8, 20, 25, 28, 30, 38, 40, 41, 48, 66, 71, 77, 78, 79
    $script:support = ConvertFrom-AtNetworkModeSupport -Lines (Get-FixtureAnswer -Name 'gtact.test.txt' -Folder device)
    $script:read = @{}
    foreach ($name in 'auto', 'lteonly', 'combined', 'ltefull-n78', 'n77-n78', 'n77-alone', 'nronly') {
        $script:read[$name] = ConvertFrom-AtNetworkMode -Lines (Get-FixtureAnswer -Name "gtact.$name.txt" -Folder device)
    }

    function Get-TestSetting {
        param([string] $Mode = 'Automatic', [int[]] $Lte = @(), [int[]] $Nr = @())
        (ConvertTo-AppSetting -InputObject @{ NetworkMode = $Mode; LteBands = $Lte; NrBands = $Nr }).Settings
    }

    function ConvertTo-TestRead {
        param([string] $Text)
        ConvertFrom-AtNetworkMode -Lines @("+GTACT: $Text")
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-AtNetworkModeSupport' {
    It 'reads the modes, and the LTE and NR bands of the device' {
        $script:support.Rats | Should -Be @(1, 2, 4, 10, 14, 16, 17, 20)
        $script:support.Modes | Should -Be @('Automatic', 'LteOnly', 'NrOnly')
        $script:support.Lte | Should -Be $script:lteAll
        $script:support.Nr | Should -Be $script:nrAll
        $script:support.LteCodes[0..1] | Should -Be @(101, 102)
        $script:support.NrCodes[-3..-1] | Should -Be @(5077, 5078, 5079)
    }

    It 'offers only the modes whose RAT the modem takes' {
        $support = ConvertFrom-AtNetworkModeSupport -Lines @('+GTACT: (1,2,4),(2,3),(2,3),(),(1),(103,120),(),(),()')
        $support.Modes | Should -Be @('LteOnly')
        $support.Lte | Should -Be @(3, 20)
        $support.Nr | Should -BeNullOrEmpty
    }

    It 'reads nothing from an answer without lists' {
        ConvertFrom-AtNetworkModeSupport -Lines @('+GTACT: 20,6,3,0') | Should -BeNullOrEmpty
        ConvertFrom-AtNetworkModeSupport -Lines @() | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AtNetworkMode' {
    It 'reads automatic mode, UMTS codes kept as other codes, n77 left out' {
        $read = $script:read['auto']
        $read.Rat | Should -Be 20
        $read.Preferences | Should -Be @(6, 3)
        $read.Mode | Should -Be 'Automatic'
        $read.OtherCodes | Should -Be @(1, 2, 4, 5, 8)
        $read.Lte | Should -Be $script:lteAll
        $read.Nr | Should -Be @($script:nrAll | Where-Object { $_ -ne 77 })
        $read.AllBands | Should -BeFalse
        $read.Codes.Count | Should -Be (5 + 31 + 18)
    }

    It 'reads LTE-only mode' {
        $read = $script:read['lteonly']
        $read.Mode | Should -Be 'LteOnly'
        $read.Preferences | Should -Be @(3, 3)
        $read.Lte | Should -Be $script:lteAll
        $read.NrCodes | Should -BeNullOrEmpty
        $read.OtherCodes | Should -BeNullOrEmpty
    }

    It 'reads LTE and NR bands set together' {
        $read = $script:read['combined']
        $read.Lte | Should -Be @(3, 20)
        $read.Nr | Should -Be @(78)
        $read.Codes | Should -Be @(1, 2, 4, 5, 8, 103, 120, 5078)
        $read.Text | Should -Be '20,6,3,1,2,4,5,8,103,120,5078'
    }

    It 'reads automatic as 20, a mode the app doesn''t offer by its RAT, empty preferences and code 0' {
        $read = ConvertTo-TestRead '10,,,0'
        $read.Rat | Should -Be 20
        $read.Preferences | Should -Be @($null, $null)
        $read.AllBands | Should -BeTrue
        (ConvertTo-TestRead '17,6').Mode | Should -BeNullOrEmpty
        (ConvertTo-TestRead '17,6').Preferences | Should -Be @(6, $null)
    }

    It 'reads nothing from <Case>' -ForEach @(
        @{ Case = 'no answer'; Lines = @() }
        @{ Case = 'the test form'; Lines = @('+GTACT: (1,2),(2,3),(2,3)') }
        @{ Case = 'a RAT that is no number'; Lines = @('+GTACT: x,6,3') }
        @{ Case = 'an empty band field'; Lines = @('+GTACT: 20,6,3,103,,120') }
        @{ Case = 'a band code with a leading zero'; Lines = @('+GTACT: 20,6,3,0103') }
    ) {
        ConvertFrom-AtNetworkMode -Lines $Lines | Should -BeNullOrEmpty
    }

    It 'gives back every code it read, unknown ones too, in the command that writes them' {
        $read = ConvertTo-TestRead '20,6,3,1,2,4,5,8,103,5078,600'
        $read.OtherCodes | Should -Be @(1, 2, 4, 5, 8, 600)
        ConvertTo-AtNetworkModeCommand -Rat $read.Rat -Preferences $read.Preferences -Code $read.Codes | Should -Be 'AT+GTACT=20,6,3,1,2,4,5,8,103,5078,600'
    }
}

Describe 'The network mode as the device kept it' {
    It 'reads NR-only mode: NR codes alone, n77 dropped without a registration' {
        $read = $script:read['nronly']
        $read.Mode | Should -Be 'NrOnly'
        $read.LteCodes | Should -BeNullOrEmpty
        $read.OtherCodes | Should -BeNullOrEmpty
        $read.Nr | Should -Be @($script:nrAll | Where-Object { $_ -ne 77 })
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting -Mode NrOnly) -Current $read -Support $script:support
        $decision.Satisfied | Should -BeTrue
        $decision.Missing.Nr | Should -Be @(77)
    }

    It 'keeps n77 asked with n78 as the modem kept it: n78 only, nothing to write again' {
        $read = $script:read['n77-n78']
        $read.Nr | Should -Be @(78)
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting -Nr 77, 78) -Current $read -Support $script:support
        $decision.Satisfied | Should -BeTrue
        $decision.Command | Should -BeNullOrEmpty
        $decision.Missing.Nr | Should -Be @(77)
    }

    It 'keeps n77 alone, as the modem does' {
        $read = $script:read['n77-alone']
        $read.Nr | Should -Be @(77)
        (Resolve-NetworkMode -Settings (Get-TestSetting -Nr 77) -Current $read -Support $script:support -Exact).Satisfied | Should -BeTrue
    }
}
Describe 'ConvertTo-AtNetworkModeCommand' {
    It 'writes <Expected>' -ForEach @(
        @{ Rat = 20; Preferences = @(6, 3); Code = @(103, 5078); Expected = 'AT+GTACT=20,6,3,103,5078' }
        @{ Rat = 2; Preferences = @(3, 3); Code = @(); Expected = 'AT+GTACT=2,3,3' }
        @{ Rat = 20; Preferences = @($null, $null); Code = @(0); Expected = 'AT+GTACT=20,,,0' }
        @{ Rat = 17; Preferences = @(6, $null); Code = @(); Expected = 'AT+GTACT=17,6' }
        @{ Rat = 20; Preferences = @(); Code = @(); Expected = 'AT+GTACT=20' }
    ) {
        ConvertTo-AtNetworkModeCommand -Rat $Rat -Preferences $Preferences -Code $Code | Should -Be $Expected
    }

    It 'writes numbers in the invariant culture, whatever the user''s' {
        $saved = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo('ar-SA')
            ConvertTo-AtNetworkModeCommand -Rat 20 -Preferences 6, 3 -Code 5078 | Should -Be 'AT+GTACT=20,6,3,5078'
        }
        finally {
            [cultureinfo]::CurrentCulture = $saved
        }
    }
}

Describe 'Resolve-NetworkMode' {
    It 'leaves a mode the app doesn''t manage alone' {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting -Mode '') -Current $script:read['lteonly'] -Support $script:support
        $decision.Managed | Should -BeFalse
        $decision.Satisfied | Should -BeNullOrEmpty
        $decision.Command | Should -BeNullOrEmpty
    }

    It 'decides nothing while <Case> is not known' -ForEach @(
        @{ Case = 'the setting'; Current = $false; Support = $true }
        @{ Case = 'what the modem supports'; Current = $true; Support = $false }
    ) {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting) -Current $(if ($Current) { $script:read['lteonly'] }) -Support $(if ($Support) { $script:support })
        $decision.Managed | Should -BeTrue
        $decision.Satisfied | Should -BeNullOrEmpty
        $decision.Command | Should -BeNullOrEmpty
    }

    It 'keeps automatic mode as the modem reads it, n77 left out by the modem: nothing to write' {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting) -Current $script:read['auto'] -Support $script:support
        $decision.Satisfied | Should -BeTrue
        $decision.Command | Should -BeNullOrEmpty
        $decision.Missing.Nr | Should -Be @(77)
        $decision.Missing.Lte | Should -BeNullOrEmpty
    }

    It 'takes n77 left out beside n78 for the modem''s own, even for the very lists the user asks' {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting) -Current $script:read['auto'] -Support $script:support -Exact
        $decision.Satisfied | Should -BeTrue
        $decision.Command | Should -BeNullOrEmpty
    }

    It 'writes the very lists the user asks when any other band is left out' {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting) -Current $script:read['combined'] -Support $script:support -Exact
        $decision.Satisfied | Should -BeFalse
        $decision.Command | Should -Be ('AT+GTACT=20,6,3,' + (@($script:support.LteCodes) + @($script:support.NrCodes) -join ','))
        (Resolve-NetworkMode -Settings (Get-TestSetting -Nr 77) -Current $script:read['n77-n78'] -Support $script:support -Exact).Satisfied | Should -BeFalse -Because 'n77 alone is kept by the modem: it is worth writing'
    }

    It 'takes code 0 for every band' {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting) -Current (ConvertTo-TestRead '20,6,3,0') -Support $script:support -Exact
        $decision.Satisfied | Should -BeTrue
    }

    It 'writes the mode asked over another: <Case>' -ForEach @(
        @{ Case = 'automatic over LTE only'; Mode = 'Automatic'; Read = 'lteonly'; Prefix = 'AT+GTACT=20,6,3,101,' ; Nr = $true }
        @{ Case = 'LTE only over automatic'; Mode = 'LteOnly'; Read = 'auto'; Prefix = 'AT+GTACT=2,3,3,101,'; Nr = $false }
        @{ Case = 'NR only over automatic'; Mode = 'NrOnly'; Read = 'auto'; Prefix = 'AT+GTACT=14,6,6,501,'; Nr = $true }
    ) {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting -Mode $Mode) -Current $script:read[$Read] -Support $script:support
        $decision.Satisfied | Should -BeFalse
        $decision.Command | Should -BeLike "$Prefix*"
        ($decision.Command -match ',5078') | Should -Be $Nr
        $decision.Missing.Lte | Should -BeNullOrEmpty -Because 'bands are compared only within the same mode'
    }

    It 'writes the preferences that count: <Case>' -ForEach @(
        @{ Case = 'automatic, LTE preferred'; Read = '20,3,6,0'; Mode = 'Automatic'; Satisfied = $false }
        @{ Case = 'LTE only, any preference'; Read = '2,2,6,0'; Mode = 'LteOnly'; Satisfied = $true }
        @{ Case = 'NR only, no preference'; Read = '14,,,0'; Mode = 'NrOnly'; Satisfied = $true }
    ) {
        (Resolve-NetworkMode -Settings (Get-TestSetting -Mode $Mode) -Current (ConvertTo-TestRead $Read) -Support $script:support).Satisfied | Should -Be $Satisfied
    }

    It 'restricts the bands asked, and leaves the other RAT''s list whole' {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting -Nr 78) -Current $script:read['auto'] -Support $script:support
        $decision.Satisfied | Should -BeFalse
        $decision.Command | Should -Be ('AT+GTACT=20,6,3,' + ((@($script:support.LteCodes) + 5078) -join ','))
        $decision.Narrowed | Should -BeFalse -Because 'NR bands don''t keep the modem off an LTE network'
    }

    It 'keeps a restriction the modem has: B3 and B20, n78' {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting -Lte 3, 20 -Nr 78) -Current $script:read['combined'] -Support $script:support -Exact
        $decision.Satisfied | Should -BeTrue
        $decision.Narrowed | Should -BeTrue
    }

    It 'writes again when the modem uses a band left out: every LTE band, B3 and B20 asked' {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting -Lte 3, 20 -Nr 78) -Current $script:read['ltefull-n78'] -Support $script:support
        $decision.Satisfied | Should -BeFalse
        $decision.Command | Should -Be 'AT+GTACT=20,6,3,103,120,5078'
    }

    It 'doesn''t write again for a band asked that the modem leaves out: n78 used, n78 and n79 asked' {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting -Nr 78, 79) -Current $script:read['ltefull-n78'] -Support $script:support
        $decision.Satisfied | Should -BeTrue
        $decision.Command | Should -BeNullOrEmpty
        $decision.Missing.Nr | Should -Be @(79)
    }

    It 'writes every band again after a reset brought them all back' {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting -Lte 3, 20 -Nr 78) -Current $script:read['auto'] -Support $script:support
        $decision.Command | Should -Be 'AT+GTACT=20,6,3,103,120,5078'
    }

    It 'writes again when the modem lists no band of a RAT the mode uses' {
        (Resolve-NetworkMode -Settings (Get-TestSetting -Mode LteOnly) -Current (ConvertTo-TestRead '2,3,3') -Support $script:support).Satisfied | Should -BeFalse
    }

    It 'leaves out bands the modem doesn''t support, and refuses a list left with none' {
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting -Lte 3, 99) -Current $script:read['auto'] -Support $script:support
        $decision.Command | Should -BeLike 'AT+GTACT=20,6,3,103,501,*'
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting -Nr 99) -Current $script:read['auto'] -Support $script:support
        $decision.Problem | Should -Be 'NoSupportedBand'
        $decision.Command | Should -BeNullOrEmpty
    }

    It 'refuses a mode the modem doesn''t take' {
        $support = ConvertFrom-AtNetworkModeSupport -Lines @('+GTACT: (1,2,4),(2,3),(2,3),(),(1),(103,120),(),(),()')
        $decision = Resolve-NetworkMode -Settings (Get-TestSetting -Mode NrOnly) -Current (ConvertTo-TestRead '2,3,3,103,120') -Support $support
        $decision.Problem | Should -Be 'ModeUnsupported'
        $decision.Command | Should -BeNullOrEmpty
    }

    It 'never writes again a command the modem didn''t keep' {
        $settings = Get-TestSetting -Mode LteOnly
        $current = $script:read['auto']
        $first = Resolve-NetworkMode -Settings $settings -Current $current -Support $script:support
        $first.Command | Should -Not -BeNullOrEmpty
        $again = Resolve-NetworkMode -Settings $settings -Current $current -Support $script:support -LastWrite @{ Command = $first.Command; Before = $current.Text }
        $again.Command | Should -BeNullOrEmpty
        $again.Problem | Should -Be 'NotKept'
        $changed = Resolve-NetworkMode -Settings $settings -Current $script:read['combined'] -Support $script:support -LastWrite @{ Command = $first.Command; Before = $current.Text }
        $changed.Command | Should -Be $first.Command -Because 'the setting changed since: the write is worth making'
    }

    It 'calls narrowed what can keep the modem off a network: <Case>' -ForEach @(
        @{ Case = 'automatic, every band'; Mode = 'Automatic'; Lte = @(); Nr = @(); Narrowed = $false }
        @{ Case = 'LTE only, every band'; Mode = 'LteOnly'; Lte = @(); Nr = @(); Narrowed = $false }
        @{ Case = 'NR only'; Mode = 'NrOnly'; Lte = @(); Nr = @(); Narrowed = $true }
        @{ Case = 'LTE bands chosen'; Mode = 'Automatic'; Lte = @(20); Nr = @(); Narrowed = $true }
        @{ Case = 'not managed'; Mode = ''; Lte = @(20); Nr = @(); Narrowed = $false }
    ) {
        (Resolve-NetworkMode -Settings (Get-TestSetting -Mode $Mode -Lte $Lte -Nr $Nr) -Current $script:read['auto'] -Support $script:support).Narrowed | Should -Be $Narrowed
    }
}

Describe 'Resolve-NetworkModeTrial' {
    BeforeAll {
        $script:confirmAfter = & (Get-Module FibocomFm350) { $script:NetworkModeConfirmAfterMs }
        $script:window = & (Get-Module FibocomFm350) { $script:RecoveryTimings.Maintenance }
    }

    It '<Case>: <Action>' -ForEach @(
        @{ Case = 'registered right after the write'; After = 1000; Read = 1000; Registered = $true; InForce = $true; Action = 'Wait' }
        @{ Case = 'registered once the change has taken'; After = 'confirm'; Read = 'confirm'; Registered = $true; InForce = $true; Action = 'Confirm' }
        @{ Case = 'registered as read right after the write, the clock later'; After = 60000; Read = 0; Registered = $true; InForce = $true; Action = 'Wait' }
        @{ Case = 'not registered yet'; After = 60000; Read = 60000; Registered = $false; InForce = $true; Action = 'Wait' }
        @{ Case = 'registration not known'; After = 60000; Read = $null; Registered = $null; InForce = $true; Action = 'Wait' }
        @{ Case = 'no network by the end of the window'; After = 'window'; Read = 'window'; Registered = $false; InForce = $true; Action = 'Revert' }
        @{ Case = 'registered as read at the end of the window'; After = 'window'; Read = 'window'; Registered = $true; InForce = $true; Action = 'Confirm' }
        @{ Case = 'registered only as read right after the write, at the end of the window'; After = 'window'; Read = 0; Registered = $true; InForce = $true; Action = 'Revert' }
        @{ Case = 'registered with its old mode: the write not kept'; After = 'confirm'; Read = 'confirm'; Registered = $true; InForce = $false; Action = 'Wait' }
        @{ Case = 'registered, the mode not known'; After = 'confirm'; Read = 'confirm'; Registered = $true; InForce = $null; Action = 'Wait' }
        @{ Case = 'registered with its old mode at the end of the window'; After = 'window'; Read = 'window'; Registered = $true; InForce = $false; Action = 'Revert' }
    ) {
        $offset = { param($value) switch ($value) { 'confirm' { $script:confirmAfter } 'window' { $script:window } default { $value } } }
        $after = & $offset $After
        $readAt = if ($null -ne $Read) { 50000 + (& $offset $Read) } else { $null }
        $decision = Resolve-NetworkModeTrial -Trial @{ Since = 50000 } -Registered $Registered -InForce $InForce -ReadAt $readAt -Now (50000 + $after)
        $decision.Action | Should -Be $Action
        if ($Action -eq 'Wait') {
            $decision.WaitMs | Should -Be ($script:window - $after)
        }
    }
}

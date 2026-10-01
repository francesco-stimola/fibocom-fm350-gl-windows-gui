# The SIM PIN: SIM states from +CPIN? and its errors, attempts left, the PIN request flag, the
# ICCID, the decision matrix, and the encrypted store.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    . "$PSScriptRoot/FixtureAnswer.ps1"

    function ConvertTo-TestSecret {
        param([string] $Text)
        $secret = [securestring]::new()
        foreach ($character in $Text.ToCharArray()) { $secret.AppendChar($character) }
        $secret
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-AtSimState: the SIM state' {
    It 'reads <Line> as <State>' -ForEach @(
        @{ Line = '+CPIN: READY'; State = 'Ready' }
        @{ Line = '+CPIN: SIM PIN'; State = 'PinRequired' }
        @{ Line = '+CPIN: SIM PUK'; State = 'PukRequired' }
        @{ Line = '+CPIN: "SIM PIN"'; State = 'PinRequired' }
        @{ Line = '+CPIN: PH-SIM PIN'; State = 'Other' }
        @{ Line = '+CPIN: SIM PIN2'; State = 'Other' }
    ) {
        (ConvertFrom-AtSimState -Lines $Line).State | Should -Be $State
    }

    It 'reads CME <Code> as <State>' -ForEach @(
        @{ Code = 10; State = 'Absent' }
        @{ Code = 11; State = 'PinRequired' }
        @{ Code = 12; State = 'PukRequired' }
        @{ Code = 13; State = 'Failure' }
        @{ Code = 14; State = 'Busy' }
        @{ Code = 15; State = 'Other' }
        @{ Code = 17; State = 'Other' }
        @{ Code = 18; State = 'Other' }
    ) {
        $sim = ConvertFrom-AtSimState -Lines @() -ErrorCode $Code
        $sim.State | Should -Be $State
        $sim.Ready | Should -BeFalse
    }

    It 'reads CME <Code>, a failure of the modem, as no SIM state at all' -ForEach @(
        @{ Code = 0 }
        @{ Code = 3 }
        @{ Code = 100 }
    ) {
        ConvertFrom-AtSimState -Lines @() -ErrorCode $Code | Should -BeNullOrEmpty
    }

    It 'reads the captured missing SIM through the channel: CME 10, Absent' {
        $answer = Get-FixtureResult -Name 'cpin.nosim.txt' -Folder device
        (ConvertFrom-AtSimState -Lines @($answer.Lines) -ErrorCode $answer.ErrorCode).State | Should -Be 'Absent'
    }

    It 'prefers the +CPIN: line to an error code' {
        (ConvertFrom-AtSimState -Lines '+CPIN: READY' -ErrorCode 14).State | Should -Be 'Ready'
    }
}

Describe 'ConvertFrom-AtPinRetry' {
    It 'reads every code with its attempts' {
        $retries = @(ConvertFrom-AtPinRetry -Lines (Get-FixtureAnswer -Name 'cpinr.txt'))
        $retries.Code | Should -Be @('SIM PIN', 'SIM PUK', 'SIM PIN2', 'SIM PUK2')
        $retries[0].Retries | Should -Be 3
        $retries[0].DefaultRetries | Should -Be 3
        $retries[1].Retries | Should -Be 10
    }

    It 'reads <Line>' -ForEach @(
        @{ Line = '+CPINR: "SIM PIN",1,3'; Code = 'SIM PIN'; Retries = 1 }
        @{ Line = '+CPINR: SIM PIN,0'; Code = 'SIM PIN'; Retries = 0 }
    ) {
        $retry = ConvertFrom-AtPinRetry -Lines $Line
        $retry.Code | Should -Be $Code
        $retry.Retries | Should -Be $Retries
    }

    It 'skips <Line>' -ForEach @(
        @{ Line = '+CPINR: SIM PIN' }
        @{ Line = '+CPINR: SIM PIN,x,3' }
        @{ Line = '+CPINR: ,3,3' }
    ) {
        ConvertFrom-AtPinRetry -Lines $Line | Should -BeNullOrEmpty
    }

    It 'reads nothing from the captured CME 100 of a firmware without AT+CPINR' {
        ConvertFrom-AtPinRetry -Lines @((Get-FixtureResult -Name 'cpinr.absent.txt' -Folder device).Lines) | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AtPinCounter' {
    It 'reads the SIM PIN attempts from <Name>: <Retries>' -ForEach @(
        @{ Name = 'epinc.txt'; Retries = 3 }
        @{ Name = 'epinc.wrong-pin.txt'; Retries = 2 }
    ) {
        $retry = @(ConvertFrom-AtPinCounter -Lines (Get-FixtureAnswer -Name $Name -Folder device))
        $retry.Count | Should -Be 1
        $retry[0].Code | Should -Be 'SIM PIN'
        $retry[0].Retries | Should -Be $Retries
        $retry[0].DefaultRetries | Should -BeNullOrEmpty
    }

    It 'reads <Line>' -ForEach @(
        @{ Line = '+EPINC:1,3,10,10'; Retries = 1 }
        @{ Line = '+EPINC: 0, 3, 10, 10'; Retries = 0 }
    ) {
        (ConvertFrom-AtPinCounter -Lines $Line).Retries | Should -Be $Retries
    }

    It 'skips <Line>' -ForEach @(
        @{ Line = '+EPINC: x, 3, 10, 10' }
        @{ Line = '+EPINC:' }
        @{ Line = '+CPINR: SIM PIN,3,3' }
    ) {
        ConvertFrom-AtPinCounter -Lines $Line | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AtFacilityLock' {
    It 'reads the SIM PIN request as on' {
        ConvertFrom-AtFacilityLock -Lines (Get-FixtureAnswer -Name 'clck.sc.on.txt') | Should -BeTrue
    }

    It 'reads <Line> as <Expected>' -ForEach @(
        @{ Line = '+CLCK: 0'; Expected = $false }
        @{ Line = '+CLCK: 1,7'; Expected = $true }
        @{ Line = '+CLCK: 2'; Expected = $null }
        @{ Line = 'OK'; Expected = $null }
    ) {
        ConvertFrom-AtFacilityLock -Lines $Line | Should -Be $Expected
    }
}

Describe 'ConvertFrom-AtIccid' {
    It 'reads the documented answer' {
        ConvertFrom-AtIccid -Lines (Get-FixtureAnswer -Name 'iccid.txt') | Should -Be '8900100000000000000'
    }

    It 'reads the captured answer of a locked SIM, its lower-case filler in upper case' {
        ConvertFrom-AtIccid -Lines (Get-FixtureAnswer -Name 'iccid.locked.txt' -Folder device) | Should -Be '8900100000000000000F'
    }

    It 'reads <Line>' -ForEach @(
        @{ Line = '+CCID: 8900100000000000000'; Expected = '8900100000000000000' }
        @{ Line = '+ICCID: 890010000000000000f'; Expected = '890010000000000000F' }
        @{ Line = '+ICCID: "8900100000000000000"'; Expected = '8900100000000000000' }
        @{ Line = '+ICCID: not-one'; Expected = $null }
        @{ Line = '+ICCID:'; Expected = $null }
    ) {
        ConvertFrom-AtIccid -Lines $Line | Should -Be $Expected
    }
}

Describe 'Resolve-SimPinAction' {
    It '<SimState>, stored <Stored>, this SIM <ForThisSim>, attempted <Attempted>, <Left> left: <Action> <Reason>' -ForEach @(
        # Ready: nothing to do; a pending attempt is confirmed.
        @{ SimState = 'Ready'; Stored = $false; ForThisSim = $null; Attempted = $false; Left = $null; Action = 'Continue'; Reason = $null }
        @{ SimState = 'Ready'; Stored = $true; ForThisSim = $true; Attempted = $false; Left = 3; Action = 'Continue'; Reason = $null }
        @{ SimState = 'Ready'; Stored = $true; ForThisSim = $true; Attempted = $true; Left = 3; Action = 'Continue'; Reason = 'PinAccepted' }
        # Only the stored PIN's SIM confirms its attempt.
        @{ SimState = 'Ready'; Stored = $true; ForThisSim = $false; Attempted = $true; Left = $null; Action = 'Continue'; Reason = $null }
        @{ SimState = 'Ready'; Stored = $true; ForThisSim = $null; Attempted = $true; Left = $null; Action = 'Continue'; Reason = $null }
        # The SIM waits for its PIN.
        @{ SimState = 'PinRequired'; Stored = $true; ForThisSim = $true; Attempted = $false; Left = 3; Action = 'SendPin'; Reason = $null }
        @{ SimState = 'PinRequired'; Stored = $true; ForThisSim = $true; Attempted = $false; Left = 2; Action = 'SendPin'; Reason = $null }
        @{ SimState = 'PinRequired'; Stored = $true; ForThisSim = $true; Attempted = $false; Left = $null; Action = 'SendPin'; Reason = $null }
        @{ SimState = 'PinRequired'; Stored = $true; ForThisSim = $true; Attempted = $false; Left = 1; Action = 'AskUser'; Reason = 'LastAttempt' }
        @{ SimState = 'PinRequired'; Stored = $true; ForThisSim = $true; Attempted = $false; Left = 0; Action = 'AskUser'; Reason = 'LastAttempt' }
        @{ SimState = 'PinRequired'; Stored = $true; ForThisSim = $true; Attempted = $true; Left = 3; Action = 'AskUser'; Reason = 'PinUnconfirmed' }
        @{ SimState = 'PinRequired'; Stored = $true; ForThisSim = $true; Attempted = $true; Left = $null; Action = 'AskUser'; Reason = 'PinUnconfirmed' }
        @{ SimState = 'PinRequired'; Stored = $true; ForThisSim = $false; Attempted = $false; Left = 3; Action = 'AskUser'; Reason = 'PinForOtherSim' }
        @{ SimState = 'PinRequired'; Stored = $true; ForThisSim = $null; Attempted = $false; Left = 3; Action = 'AskUser'; Reason = 'SimNotIdentified' }
        @{ SimState = 'PinRequired'; Stored = $false; ForThisSim = $null; Attempted = $false; Left = 3; Action = 'AskUser'; Reason = 'NoPin' }
        # Nothing the app may do.
        @{ SimState = 'PukRequired'; Stored = $true; ForThisSim = $true; Attempted = $false; Left = 3; Action = 'Report'; Reason = 'PukRequired' }
        @{ SimState = 'Absent'; Stored = $true; ForThisSim = $null; Attempted = $false; Left = $null; Action = 'Report'; Reason = 'NoSim' }
        @{ SimState = 'Failure'; Stored = $false; ForThisSim = $null; Attempted = $false; Left = $null; Action = 'Report'; Reason = 'SimFailure' }
        @{ SimState = 'Other'; Stored = $true; ForThisSim = $true; Attempted = $false; Left = 3; Action = 'Report'; Reason = 'SimOther' }
        @{ SimState = 'Busy'; Stored = $true; ForThisSim = $true; Attempted = $false; Left = 3; Action = 'Wait'; Reason = 'SimBusy' }
    ) {
        $decision = Resolve-SimPinAction -SimState $SimState -PinStored:$Stored -PinForThisSim $ForThisSim -PinAttempted:$Attempted -AttemptsLeft $Left
        $decision.Action | Should -Be $Action
        $decision.Reason | Should -Be $Reason
    }

    It 'never sends a PIN for a SIM that is not waiting for one' {
        foreach ($state in 'Ready', 'PukRequired', 'Absent', 'Busy', 'Failure', 'Other') {
            (Resolve-SimPinAction -SimState $state -PinStored -PinForThisSim $true -AttemptsLeft 3).Action | Should -Not -Be 'SendPin'
        }
    }

    It 'refuses an unknown SIM state' {
        { Resolve-SimPinAction -SimState 'Locked' -ErrorAction Stop } | Should -Throw
    }
}

Describe 'SIM PIN store' {
    BeforeEach {
        $script:path = Join-Path $TestDrive "pin-$([guid]::NewGuid()).json"
        $script:iccid = '8900100000000000000'
    }

    It 'stores the PIN and the SIM encrypted, and gives the PIN back for that SIM' {
        Save-SimPin -Pin (ConvertTo-TestSecret '1234') -Iccid $script:iccid -Path $script:path
        $text = Get-Content -LiteralPath $script:path -Raw
        $text | Should -Not -Match '1234'
        $text | Should -Not -Match $script:iccid
        $stored = Get-SimPin -Iccid $script:iccid -Path $script:path
        [System.Net.NetworkCredential]::new('', $stored.Pin).Password | Should -Be '1234'
        $stored.ForThisSim | Should -BeTrue
        $stored.Attempted | Should -BeFalse
    }

    It 'tells another SIM apart, and says nothing without one' {
        Save-SimPin -Pin (ConvertTo-TestSecret '1234') -Iccid $script:iccid -Path $script:path
        (Get-SimPin -Iccid '8900100000000000001' -Path $script:path).ForThisSim | Should -BeFalse
        (Get-SimPin -Path $script:path).ForThisSim | Should -BeNullOrEmpty
    }

    It 'matches the SIM whatever the case of its ICCID' {
        Save-SimPin -Pin (ConvertTo-TestSecret '1234') -Iccid '890010000000000000f' -Path $script:path
        (Get-SimPin -Iccid '890010000000000000F' -Path $script:path).ForThisSim | Should -BeTrue
    }

    It 'records an attempt, and its confirmation' {
        Save-SimPin -Pin (ConvertTo-TestSecret '1234') -Iccid $script:iccid -Path $script:path
        Set-SimPinAttempt -Attempted $true -Path $script:path
        (Get-SimPin -Iccid $script:iccid -Path $script:path).Attempted | Should -BeTrue
        Set-SimPinAttempt -Attempted $false -Path $script:path
        (Get-SimPin -Iccid $script:iccid -Path $script:path).Attempted | Should -BeFalse
    }

    It 'starts a new PIN as not attempted' {
        Save-SimPin -Pin (ConvertTo-TestSecret '1234') -Iccid $script:iccid -Path $script:path
        Set-SimPinAttempt -Attempted $true -Path $script:path
        Save-SimPin -Pin (ConvertTo-TestSecret '5678') -Iccid $script:iccid -Path $script:path
        (Get-SimPin -Iccid $script:iccid -Path $script:path).Attempted | Should -BeFalse
    }

    It 'gives nothing when no PIN is stored, once removed, or for a damaged file' {
        Get-SimPin -Path $script:path | Should -BeNullOrEmpty
        Set-SimPinAttempt -Attempted $true -Path $script:path
        Test-Path -LiteralPath $script:path | Should -BeFalse
        Save-SimPin -Pin (ConvertTo-TestSecret '1234') -Iccid $script:iccid -Path $script:path
        Remove-SimPin -Path $script:path
        Get-SimPin -Path $script:path | Should -BeNullOrEmpty
        Set-Content -LiteralPath $script:path -Value '{ "Pin": "x", "Sim": "y", "Attempted": false }'
        Get-SimPin -Path $script:path | Should -BeNullOrEmpty
    }

    It 'refuses a PIN that is not 4 to 8 digits: <Pin>' -ForEach @(
        @{ Pin = '123' }
        @{ Pin = '123456789' }
        @{ Pin = '12a4' }
        @{ Pin = '' }
    ) {
        { Save-SimPin -Pin (ConvertTo-TestSecret $Pin) -Iccid '8900100000000000000' -Path $script:path -ErrorAction Stop } | Should -Throw '*4 to 8 digits*'
        Test-Path -LiteralPath $script:path | Should -BeFalse
    }
}

# Health checks: which check fails for each state the connection can be in, the data path's verdict
# from its probe rounds, and the probe itself - an address not usable yet is not probed, and an
# echo request really leaves from the address it is given (on the loopback interface).

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Resolve-HealthCheck' {
    It '<State> (<Reason>) -> <Check>, blocked <Blocked>' -ForEach @(
        @{ State = 'Online'; Reason = $null; Blocked = $false; Check = $null }
        @{ State = 'NoDevice'; Reason = 'NoDevice'; Blocked = $true; Check = 'H1' }
        @{ State = 'NoDevice'; Reason = 'NoDriver'; Blocked = $true; Check = 'H1' }
        @{ State = 'NoDevice'; Reason = 'DeviceProblem'; Blocked = $true; Check = 'H1' }
        @{ State = 'NoDevice'; Reason = 'PortFailed'; Blocked = $false; Check = 'H2' }
        @{ State = 'NoDevice'; Reason = $null; Blocked = $false; Check = 'H2' }
        @{ State = 'PortOpen'; Reason = $null; Blocked = $false; Check = 'H2' }
        @{ State = 'Identified'; Reason = 'SimBusy'; Blocked = $false; Check = 'H3' }
        @{ State = 'Identified'; Reason = 'SimUnknown'; Blocked = $false; Check = 'H3' }
        @{ State = 'Identified'; Reason = 'NoPin'; Blocked = $true; Check = 'H3' }
        @{ State = 'Identified'; Reason = 'PukRequired'; Blocked = $true; Check = 'H3' }
        @{ State = 'SimReady'; Reason = 'Searching'; Blocked = $false; Check = 'H4' }
        @{ State = 'SimReady'; Reason = 'FccLocked'; Blocked = $true; Check = 'H4' }
        @{ State = 'Registered'; Reason = 'NoAddress'; Blocked = $false; Check = 'H5' }
        @{ State = 'Registered'; Reason = 'ApnNeeded'; Blocked = $true; Check = 'H5' }
        @{ State = 'Registered'; Reason = 'ApnPasswordUnreadable'; Blocked = $true; Check = 'H5' }
        @{ State = 'DataActive'; Reason = $null; Blocked = $false; Check = 'H6' }
        @{ State = 'DataActive'; Reason = 'AdapterDisabled'; Blocked = $true; Check = 'H6' }
        @{ State = 'DataActive'; Reason = 'NotElevated'; Blocked = $true; Check = 'H6' }
        @{ State = 'DataActive'; Reason = 'DataPathFailed'; Blocked = $false; Check = 'H7' }
    ) {
        $health = Resolve-HealthCheck -State $State -Reason $Reason -Blocked:$Blocked
        $health.Check | Should -Be $Check
        $health.Blocked | Should -Be $Blocked
    }

    It 'takes a missing context definition for H5, not for the registration: <Action> -> <Check>' -ForEach @(
        @{ Action = 'DefineContext'; Check = 'H5' }
        @{ Action = 'RadioOn'; Check = 'H4' }
        @{ Action = 'AutoRegister'; Check = 'H4' }
        @{ Action = 'None'; Check = 'H4' }
    ) {
        (Resolve-HealthCheck -State 'SimReady' -Action $Action).Check | Should -Be $Check
    }

    It 'says what couldn''t be read is unknown, never a failure: <Reason>' -ForEach @(
        @{ State = 'Identified'; Reason = 'SimUnknown'; Unknown = $true }
        @{ State = 'Registered'; Reason = 'ContextUnknown'; Unknown = $true }
        @{ State = 'Registered'; Reason = 'NoAddress'; Unknown = $false }
        @{ State = 'Identified'; Reason = 'SimBusy'; Unknown = $false }
        @{ State = 'Online'; Reason = $null; Unknown = $false }
    ) {
        (Resolve-HealthCheck -State $State -Reason $Reason).Unknown | Should -Be $Unknown
    }

    It 'never lets recovery act under another program that holds the AT port' {
        $health = Resolve-HealthCheck -State 'NoDevice' -Reason 'PortInUse'
        $health.Check | Should -Be 'H2'
        $health.Blocked | Should -BeTrue
    }

    It 'calls every state the state machine gives a check, or healthy' {
        foreach ($state in (Get-Command Resolve-ConnectionState).Parameters['Previous'].Attributes.ValidValues) {
            $health = Resolve-HealthCheck -State $state
            if ($state -eq 'Online') { $health.Check | Should -BeNullOrEmpty } else { $health.Check | Should -Match '^H[1-7]$' }
        }
    }
}

Describe 'Resolve-DataPathHealth' {
    It '<Rounds> -> <Healthy>' -ForEach @(
        @{ Rounds = @(); Healthy = $null }
        @{ Rounds = @('Passed'); Healthy = $true }
        @{ Rounds = @('Failed'); Healthy = $null }
        @{ Rounds = @('Failed', 'Failed'); Healthy = $false }
        @{ Rounds = @('Passed', 'Failed'); Healthy = $true }
        @{ Rounds = @('Passed', 'Failed', 'Failed'); Healthy = $false }
        @{ Rounds = @('Failed', 'Failed', 'Passed'); Healthy = $true }
        @{ Rounds = @('Failed', 'Passed', 'Failed'); Healthy = $true }
    ) {
        Resolve-DataPathHealth -Rounds $Rounds | Should -Be $Healthy
    }

    It 'takes rounds never answered since the app started for nothing: <Rounds> -> <Healthy>' -ForEach @(
        @{ Rounds = @('Failed', 'Failed'); Healthy = $null }
        @{ Rounds = @('Failed', 'Failed', 'Failed', 'Failed'); Healthy = $null }
        @{ Rounds = @(); Healthy = $null }
    ) {
        Resolve-DataPathHealth -Rounds $Rounds -Unproven | Should -Be $Healthy
    }

    It 'takes the number of failed rounds it is given' {
        Resolve-DataPathHealth -Rounds 'Failed', 'Failed' -FailedRounds 3 | Should -BeNullOrEmpty
        Resolve-DataPathHealth -Rounds 'Failed', 'Failed', 'Failed' -FailedRounds 3 | Should -BeFalse
    }
}

Describe 'Test-ModemDataPath' {
    It 'sends nothing from an address Windows is still checking: <State>' -ForEach @(
        @{ State = 'Tentative' }
        @{ State = 'Duplicate' }
    ) {
        Mock -ModuleName FibocomFm350 Get-NetIPAddress { [pscustomobject]@{ IPAddress = '192.0.2.10'; AddressState = $State } }
        $round = Test-ModemDataPath -SourceAddress '192.0.2.10'
        $round.Result | Should -Be 'NotReady'
        $round.Sent | Should -Be 0
        $round.AddressState | Should -Be $State
    }

    It 'sends nothing from an address the computer doesn''t have' {
        Mock -ModuleName FibocomFm350 Get-NetIPAddress { }
        $round = Test-ModemDataPath -SourceAddress '192.0.2.10'
        $round.Result | Should -Be 'NotReady'
        $round.AddressState | Should -Be 'Missing'
    }

    It 'gets a reply sent from the address it is given (loopback)' {
        $round = Test-ModemDataPath -SourceAddress '127.0.0.1' -Target '127.0.0.1' -Requests 1
        $round.Result | Should -Be 'Passed'
        $round.Sent | Should -Be 1
        $round.Status | Should -Be 0
    }

    It 'fails a round when no request gets a reply, and stops at the first that does' {
        $round = Test-ModemDataPath -SourceAddress '127.0.0.1' -Target '192.0.2.1' -Requests 2 -TimeoutMs 200
        $round.Result | Should -Be 'Failed'
        $round.Sent | Should -Be 2
        $round.Status | Should -Not -Be 0
        $round = Test-ModemDataPath -SourceAddress '127.0.0.1' -Target '192.0.2.1', '127.0.0.1' -Requests 3 -TimeoutMs 200
        $round.Result | Should -Be 'Passed'
        $round.Sent | Should -Be 2
    }
}

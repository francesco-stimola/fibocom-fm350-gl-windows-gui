# The connection state machine: a matrix of observations, from no device to online, every reason
# to stop, and the drop from a further state.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force

    # An observation of a modem that is online; each case changes what it needs to.
    function Get-TestObservation {
        param([hashtable] $Change = @{})
        $facts = [ordered]@{
            Device            = 'Present'
            PortOpen          = $true
            Responsive        = $true
            Sim               = [pscustomobject]@{ Action = 'Continue'; Reason = $null }
            Fcc               = $null
            RadioOn           = $true
            OperatorMode      = 0
            Registered        = $true
            RegistrationState = 'Home'
            ContextDefined    = $true
            ContextActive     = $true
            ContextAddress    = '198.51.100.23'
            ApnSet            = $true
            Adapter           = 'Present'
            AdapterConfigured = $true
            AdapterProblem    = $null
            DataPath          = $null
        }
        foreach ($key in $Change.Keys) {
            $facts[$key] = $Change[$key]
        }
        [pscustomobject]$facts
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Resolve-ConnectionState' {
    It '<Name>: <State>, <Action>, <Reason>' -ForEach @(
        @{ Name = 'everything up'; Change = @{}; State = 'Online'; Action = 'None'; Reason = $null; Blocked = $false }
        @{ Name = 'everything up, data path passed'; Change = @{ DataPath = $true }; State = 'Online'; Action = 'None'; Reason = $null; Blocked = $false }
        # The device and its port.
        @{ Name = 'no modem'; Change = @{ Device = 'Absent' }; State = 'NoDevice'; Action = 'None'; Reason = 'NoDevice'; Blocked = $true }
        @{ Name = 'nothing known about the device'; Change = @{ Device = $null }; State = 'NoDevice'; Action = 'None'; Reason = 'NoDevice'; Blocked = $true }
        @{ Name = 'AT port without its driver'; Change = @{ Device = 'NoDriver' }; State = 'NoDevice'; Action = 'None'; Reason = 'NoDriver'; Blocked = $true }
        @{ Name = 'AT port with a problem'; Change = @{ Device = 'Problem' }; State = 'NoDevice'; Action = 'None'; Reason = 'DeviceProblem'; Blocked = $true }
        @{ Name = 'port not open'; Change = @{ PortOpen = $false }; State = 'NoDevice'; Action = 'OpenPort'; Reason = $null; Blocked = $false }
        @{ Name = 'modem not answering'; Change = @{ Responsive = $false }; State = 'PortOpen'; Action = 'Initialize'; Reason = $null; Blocked = $false }
        # The SIM.
        @{ Name = 'PIN to enter'; Change = @{ Sim = [pscustomobject]@{ Action = 'SendPin'; Reason = $null } }; State = 'Identified'; Action = 'EnterPin'; Reason = $null; Blocked = $false }
        @{ Name = 'SIM busy'; Change = @{ Sim = [pscustomobject]@{ Action = 'Wait'; Reason = 'SimBusy' } }; State = 'Identified'; Action = 'None'; Reason = 'SimBusy'; Blocked = $false }
        @{ Name = 'PIN needed from the user'; Change = @{ Sim = [pscustomobject]@{ Action = 'AskUser'; Reason = 'NoPin' } }; State = 'Identified'; Action = 'None'; Reason = 'NoPin'; Blocked = $true }
        @{ Name = 'PUK needed'; Change = @{ Sim = [pscustomobject]@{ Action = 'Report'; Reason = 'PukRequired' } }; State = 'Identified'; Action = 'None'; Reason = 'PukRequired'; Blocked = $true }
        @{ Name = 'no SIM'; Change = @{ Sim = [pscustomobject]@{ Action = 'Report'; Reason = 'NoSim' } }; State = 'Identified'; Action = 'None'; Reason = 'NoSim'; Blocked = $true }
        @{ Name = 'SIM not read'; Change = @{ Sim = $null }; State = 'Identified'; Action = 'None'; Reason = 'SimUnknown'; Blocked = $false }
        # Registration, the radio, the FCC lock.
        @{ Name = 'FCC-locked, not registered'; Change = @{ Registered = $false; RadioOn = $false; Fcc = [pscustomobject]@{ Diagnosis = 'Locked' } }; State = 'SimReady'; Action = 'None'; Reason = 'FccLocked'; Blocked = $true }
        @{ Name = 'radio off'; Change = @{ Registered = $false; RadioOn = $false; Fcc = [pscustomobject]@{ Diagnosis = 'NotLocked' } }; State = 'SimReady'; Action = 'RadioOn'; Reason = $null; Blocked = $false }
        @{ Name = 'radio off, lock unknown'; Change = @{ Registered = $false; RadioOn = $false; Fcc = [pscustomobject]@{ Diagnosis = 'Unknown' } }; State = 'SimReady'; Action = 'RadioOn'; Reason = $null; Blocked = $false }
        @{ Name = 'deregistered by a command'; Change = @{ Registered = $false; OperatorMode = 2 }; State = 'SimReady'; Action = 'AutoRegister'; Reason = $null; Blocked = $false }
        @{ Name = 'manual operator selection kept'; Change = @{ Registered = $false; OperatorMode = 1; RegistrationState = 'Searching' }; State = 'SimReady'; Action = 'None'; Reason = 'Searching'; Blocked = $false }
        @{ Name = 'context not defined yet, searching'; Change = @{ Registered = $false; RegistrationState = 'Searching'; ContextDefined = $false; ContextActive = $false }; State = 'SimReady'; Action = 'DefineContext'; Reason = $null; Blocked = $false }
        @{ Name = 'searching'; Change = @{ Registered = $false; RegistrationState = 'Searching'; ContextActive = $false }; State = 'SimReady'; Action = 'None'; Reason = 'Searching'; Blocked = $false }
        @{ Name = 'registration denied'; Change = @{ Registered = $false; RegistrationState = 'Denied'; ContextActive = $false }; State = 'SimReady'; Action = 'None'; Reason = 'Denied'; Blocked = $false }
        @{ Name = 'registration not read'; Change = @{ Registered = $null; RegistrationState = $null }; State = 'SimReady'; Action = 'None'; Reason = 'NotRegistered'; Blocked = $false }
        # A lock value never stops a modem that registers.
        @{ Name = 'registered with a locked-looking value'; Change = @{ Fcc = [pscustomobject]@{ Diagnosis = 'Locked' } }; State = 'Online'; Action = 'None'; Reason = $null; Blocked = $false }
        # The data context.
        @{ Name = 'context to define'; Change = @{ ContextDefined = $false; ContextActive = $false; ContextAddress = $null }; State = 'SimReady'; Action = 'DefineContext'; Reason = $null; Blocked = $false }
        @{ Name = 'context to activate'; Change = @{ ContextActive = $false; ContextAddress = $null }; State = 'Registered'; Action = 'ActivateContext'; Reason = $null; Blocked = $false }
        @{ Name = 'context active without an IPv4 address'; Change = @{ ContextAddress = $null }; State = 'Registered'; Action = 'None'; Reason = 'NoAddress'; Blocked = $false }
        # With no APN in the settings the network chose one - the IMS APN on some networks.
        @{ Name = 'context without an address, no APN set'; Change = @{ ContextAddress = $null; ApnSet = $false }; State = 'Registered'; Action = 'None'; Reason = 'ApnNeeded'; Blocked = $true }
        @{ Name = 'context without an address, settings differ'; Change = @{ ContextAddress = $null; ContextDefined = $false }; State = 'Registered'; Action = 'DeactivateContext'; Reason = $null; Blocked = $false }
        @{ Name = 'context without an address, settings differ, no APN set'; Change = @{ ContextAddress = $null; ContextDefined = $false; ApnSet = $false }; State = 'Registered'; Action = 'DeactivateContext'; Reason = $null; Blocked = $false }
        @{ Name = 'context on the IMS APN with an address, no APN set'; Change = @{ ContextApn = 'ims.mnc001.mcc001.gprs'; ApnSet = $false }; State = 'Registered'; Action = 'None'; Reason = 'ApnNeeded'; Blocked = $true }
        @{ Name = 'context on the IMS APN, written in capitals'; Change = @{ ContextApn = 'IMS.MNC001.MCC001.GPRS'; ApnSet = $false }; State = 'Registered'; Action = 'None'; Reason = 'ApnNeeded'; Blocked = $true }
        @{ Name = 'context on the IMS APN, without the operator part'; Change = @{ ContextApn = 'ims'; ApnSet = $false }; State = 'Registered'; Action = 'None'; Reason = 'ApnNeeded'; Blocked = $true }
        @{ Name = 'context on the IMS APN, settings differ'; Change = @{ ContextApn = 'ims.mnc001.mcc001.gprs'; ContextDefined = $false }; State = 'Registered'; Action = 'DeactivateContext'; Reason = $null; Blocked = $false }
        @{ Name = 'context on the IMS APN, the APN of the settings'; Change = @{ ContextApn = 'ims.mnc001.mcc001.gprs' }; State = 'Registered'; Action = 'None'; Reason = 'NoAddress'; Blocked = $false }
        @{ Name = 'context on an APN that only starts with ims'; Change = @{ ContextApn = 'ims.example.mnc001.mcc001.gprs'; ApnSet = $false }; State = 'Online'; Action = 'None'; Reason = $null; Blocked = $false }
        @{ Name = 'context on the internet APN, no APN set'; Change = @{ ContextApn = 'internet.mnc001.mcc001.gprs'; ApnSet = $false }; State = 'Online'; Action = 'None'; Reason = $null; Blocked = $false }
        # What couldn't be read is never taken for "no": nothing is written over it.
        @{ Name = 'activation not read, not registered'; Change = @{ Registered = $false; RegistrationState = 'Searching'; ContextDefined = $false; ContextActive = $null }; State = 'SimReady'; Action = 'None'; Reason = 'Searching'; Blocked = $false }
        @{ Name = 'active context differing from the settings, registration lost a moment'; Change = @{ Registered = $false; RegistrationState = 'Searching'; ContextDefined = $false }; State = 'SimReady'; Action = 'None'; Reason = 'Searching'; Blocked = $false }
        @{ Name = 'activation not read'; Change = @{ ContextActive = $null; ContextAddress = $null }; State = 'Registered'; Action = 'None'; Reason = 'ContextUnknown'; Blocked = $false }
        @{ Name = 'parameters not read'; Change = @{ ContextRead = $false; ContextAddress = $null }; State = 'Registered'; Action = 'None'; Reason = 'ContextUnknown'; Blocked = $false }
        @{ Name = 'parameters not read, settings differ'; Change = @{ ContextRead = $false; ContextAddress = $null; ContextDefined = $false }; State = 'Registered'; Action = 'None'; Reason = 'ContextUnknown'; Blocked = $false }
        @{ Name = 'parameters not read, no APN set'; Change = @{ ContextRead = $false; ContextAddress = $null; ApnSet = $false }; State = 'Registered'; Action = 'None'; Reason = 'ContextUnknown'; Blocked = $false }
        # The adapter.
        @{ Name = 'no network adapter'; Change = @{ Adapter = 'Absent'; AdapterConfigured = $null }; State = 'DataActive'; Action = 'None'; Reason = 'NoAdapter'; Blocked = $true }
        @{ Name = 'network adapter disabled'; Change = @{ Adapter = 'Disabled'; AdapterConfigured = $null }; State = 'DataActive'; Action = 'None'; Reason = 'AdapterDisabled'; Blocked = $true }
        @{ Name = 'adapter to configure'; Change = @{ AdapterConfigured = $false }; State = 'DataActive'; Action = 'ConfigureAdapter'; Reason = $null; Blocked = $false }
        @{ Name = 'adapter that cannot be configured'; Change = @{ AdapterConfigured = $false; AdapterProblem = 'NoGateway' }; State = 'DataActive'; Action = 'None'; Reason = 'NoGateway'; Blocked = $false }
        @{ Name = 'data path failing'; Change = @{ DataPath = $false }; State = 'DataActive'; Action = 'None'; Reason = 'DataPathFailed'; Blocked = $false }
    ) {
        $result = Resolve-ConnectionState -Observation (Get-TestObservation -Change $Change)
        $result.State | Should -Be $State
        $result.Action | Should -Be $Action
        $result.Reason | Should -Be $Reason
        $result.Blocked | Should -Be $Blocked
    }

    It 'attaches to a connection that is up: no step at all' {
        $result = Resolve-ConnectionState -Observation (Get-TestObservation)
        $result.Action | Should -Be 'None'
        $result.Dropped | Should -BeFalse
    }

    It 'leaves an active context that differs from the settings as it is, and says so' {
        $result = Resolve-ConnectionState -Observation (Get-TestObservation -Change @{ ContextDefined = $false })
        $result.State | Should -Be 'Online'
        $result.Action | Should -Be 'None'
        $result.SettingsPending | Should -BeTrue
    }

    It 'says the connection dropped when the state is behind the previous one: <Previous> -> <State>' -ForEach @(
        @{ Previous = 'Online'; Change = @{ ContextActive = $false; ContextAddress = $null }; State = 'Registered'; Dropped = $true }
        @{ Previous = 'Online'; Change = @{ Device = 'Absent' }; State = 'NoDevice'; Dropped = $true }
        @{ Previous = 'Registered'; Change = @{}; State = 'Online'; Dropped = $false }
        @{ Previous = 'Online'; Change = @{}; State = 'Online'; Dropped = $false }
    ) {
        $result = Resolve-ConnectionState -Observation (Get-TestObservation -Change $Change) -Previous $Previous
        $result.State | Should -Be $State
        $result.Dropped | Should -Be $Dropped
    }

    It 'takes the observation as a hashtable too' {
        $facts = @{ Device = 'Present'; PortOpen = $true; Responsive = $false }
        (Resolve-ConnectionState -Observation $facts).Action | Should -Be 'Initialize'
    }

    It 'refuses an unknown previous state' {
        { Resolve-ConnectionState -Observation (Get-TestObservation) -Previous 'Dialing' -ErrorAction Stop } | Should -Throw
    }
}

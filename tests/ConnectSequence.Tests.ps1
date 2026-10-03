# The connect sequence on the simulated modem: from a registered modem to online, attaching to a
# connection that is up without touching it, the SIM PIN rules, the FCC lock, APN credentials,
# steps that fail. The adapter's I/O is mocked; everything on the AT port is real.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force

    $script:fixtures = "$PSScriptRoot/fixtures"
    $script:adapterId = 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000'
    $script:fccRead = 'AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?'

    function Get-FixtureLine {
        param([string] $Name)
        $fixture = Import-AtFixture -Path "$script:fixtures/$Name"
        [string[]]$fixture.Lines
    }

    # A modem registered on LTE, its SIM ready, its radio on, the app's context defined and
    # active; -Answers replaces standing answers.
    function Get-OnlineModem {
        param([hashtable] $Answers = @{})
        $standing = @{
            'AT+CPIN?'           = @('+CPIN: READY', 'OK')
            'AT+CFUN?'           = @('+CFUN: 1', 'OK')
            'AT+CEREG?;+C5GREG?' = @('+CEREG: 0,1', '+C5GREG: 0,1', 'OK')
            'AT+COPS?'           = @('+COPS: 0,2,"00101",7', 'OK')
            'AT+CGDCONT?'        = Get-FixtureLine 'documented/cgdcont.app.txt'
            'AT+CGACT?'          = Get-FixtureLine 'documented/cgact.active.txt'
            'AT+CGCONTRDP=1'     = Get-FixtureLine 'documented/cgcontrdp.data.txt'
            'AT+CGAUTH?'         = Get-FixtureLine 'device/cgauth.read.txt'
            $script:fccRead      = Get-FixtureLine 'device/fcc.unlocked.txt'
        }
        foreach ($key in $Answers.Keys) {
            $standing[$key] = $Answers[$key]
        }
        $modem = New-SimulatedModem
        foreach ($key in $standing.Keys) {
            $modem.SetAnswer($key, [string[]]$standing[$key])
        }
        $modem
    }

    # The adapter before and after configuration, as Get-ModemAdapterState reads it.
    $script:freshAdapter = [pscustomobject]@{
        InterfaceIndex = 12; InterfaceGuid = [guid]'8D1E3C2A-0B4F-4E6D-9A7C-1F2E3D4C5B6A'; Name = 'Ethernet 3'; Status = 'Up'; Dhcp = 'Enabled'; InterfaceMetric = 25; AutomaticMetric = $true
        Addresses = @([pscustomobject]@{ Address = '169.254.10.20'; PrefixLength = 16; Origin = 'WellKnown' }); Gateways = @(); DnsServers = @()
    }
    $script:configuredAdapter = [pscustomobject]@{
        InterfaceIndex = 12; InterfaceGuid = [guid]'8D1E3C2A-0B4F-4E6D-9A7C-1F2E3D4C5B6A'; Name = 'Ethernet 3'; Status = 'Up'; Dhcp = 'Disabled'; InterfaceMetric = 500; AutomaticMetric = $false
        Addresses = @([pscustomobject]@{ Address = '198.51.100.23'; PrefixLength = 24; Origin = 'Manual' })
        Gateways = @('198.51.100.1'); DnsServers = @('203.0.113.53', '203.0.113.54', '2001:db8::53')
    }

    function ConvertTo-TestSecret {
        param([string] $Text)
        $secret = [securestring]::new()
        foreach ($character in $Text.ToCharArray()) { $secret.AppendChar($character) }
        $secret
    }

    # +CGPADDR on the IMS APN of a network that gives it no IPv4 address: an IPv6 one only.
    $script:imsIPv6Only = @('+CGPADDR: 1,"0.0.0.0.0.0.0.0.32.1.13.184.0.0.0.1",""', 'OK')

    # Commands that change the modem's state.
    function Get-WriteCommand {
        param($Modem)
        @($Modem.Received | Where-Object { $_ -match '=' -and $_ -notmatch '=\?$' -and $_ -notin 'AT+CMEE=1' -and $_ -notmatch '^AT\+(CGCONTRDP|CGPADDR|GTDNS)=' })
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Invoke-ModemConnect' {
    BeforeEach {
        $script:settings = (ConvertTo-AppSetting -InputObject $null).Settings
        $script:pinPath = Join-Path $TestDrive "pin-$([guid]::NewGuid()).json"
        $script:passwordPath = Join-Path $TestDrive "apn-$([guid]::NewGuid()).dat"
        $script:logFolder = Join-Path $TestDrive "logs-$([guid]::NewGuid())"
        $script:adapterState = $script:configuredAdapter
        Mock -ModuleName FibocomFm350 Get-ModemAdapterState { $script:adapterState }
        # The app runs elevated; a test session may not be.
        Mock -ModuleName FibocomFm350 Test-AppElevation { $true }
        # Applies the plan to the adapter as Get-ModemAdapterState will read it next.
        Mock -ModuleName FibocomFm350 Set-ModemAdapterConfiguration {
            $state = $script:adapterState | Select-Object -Property *
            foreach ($action in $Plan.Actions) {
                switch ($action.Action) {
                    'DisableDhcp' { $state.Dhcp = 'Disabled' }
                    'RemoveAddress' { $state.Addresses = @($state.Addresses | Where-Object Address -NE $action.Address) }
                    'SetAddress' { $state.Addresses = @($state.Addresses) + [pscustomobject]@{ Address = $action.Address; PrefixLength = $action.PrefixLength; Origin = 'Manual' } }
                    'RemoveGateway' { $state.Gateways = @($state.Gateways | Where-Object { $_ -ne $action.NextHop }) }
                    'SetGateway' { $state.Gateways = @($state.Gateways) + $action.NextHop }
                    'SetDns' { $state.DnsServers = $action.Servers }
                    'SetMetric' { $state.InterfaceMetric = $action.Metric; $state.AutomaticMetric = $false }
                }
                [pscustomobject]@{ Action = $action.Action; Done = $true; Error = $null }
            }
            $script:adapterState = $state
        }
        # One pass on a channel the worker keeps open; $connect opens and closes one around it.
        $script:pass = {
            param($Channel, [hashtable] $Extra = @{})
            Invoke-ModemConnect -Channel $Channel -Settings $script:settings -AdapterInstanceId $script:adapterId `
                -SimPinPath $script:pinPath -ApnSecretPath $script:passwordPath -LogFolder $script:logFolder -Confirm:$false @Extra
        }
        $script:connect = {
            param($Modem, [hashtable] $Extra = @{})
            $channel = New-AtChannel -Transport $Modem
            try {
                & $script:pass $channel $Extra
            }
            finally {
                Close-AtChannel -Channel $channel
            }
        }
    }

    Context 'attaching and connecting' {
        It 'attaches to a connection that is up: no step, no write, the adapter untouched' {
            $modem = Get-OnlineModem
            $pass = & $script:connect $modem @{ Previous = 'Online' }
            $pass.State | Should -Be 'Online'
            $pass.Action | Should -Be 'None'
            $pass.Steps.Action | Should -Be @('Initialize')
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
            Should -Invoke -ModuleName FibocomFm350 Set-ModemAdapterConfiguration -Times 0 -Exactly
        }

        It 'attaches the same way at startup, with no previous state' {
            $modem = Get-OnlineModem
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'Online'
            $pass.Dropped | Should -BeFalse
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
        }

        It 'brings a registered modem online: defines, activates, configures - each once' {
            $script:adapterState = $script:freshAdapter
            $modem = Get-OnlineModem -Answers @{
                'AT+CGDCONT?' = Get-FixtureLine 'device/cgdcont.attached.txt'
                'AT+CGACT?'   = @('OK')
            }
            $modem.Script('AT+CGDCONT=1,"IPV4V6",""', @{ Lines = @('OK'); Then = @{ 'AT+CGDCONT?' = Get-FixtureLine 'documented/cgdcont.app.txt' } })
            $modem.Script('AT+CGACT=1,1', @{ Lines = @('OK'); Then = @{ 'AT+CGACT?' = Get-FixtureLine 'documented/cgact.active.txt' } })
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'Online'
            $pass.Steps.Action | Should -Be @('Initialize', 'DefineContext', 'ActivateContext', 'ConfigureAdapter')
            @($pass.Steps.Result | Select-Object -Unique) | Should -Be @('Done')
            Get-WriteCommand -Modem $modem | Should -Be @('AT+CGDCONT=1,"IPV4V6",""', 'AT+CGACT=1,1')
            Should -Invoke -ModuleName FibocomFm350 Set-ModemAdapterConfiguration -Times 1 -Exactly -ParameterFilter {
                $InterfaceIndex -eq 12 -and ($Plan.Actions.Action -join ',') -eq 'DisableDhcp,SetAddress,SetGateway,SetDns,SetMetric'
            }
        }

        It 'leaves the adapter alone without administrator rights, and says so' {
            Mock -ModuleName FibocomFm350 Test-AppElevation { $false }
            $script:adapterState = $script:freshAdapter
            $modem = Get-OnlineModem
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'DataActive'
            $pass.Reason | Should -Be 'NotElevated'
            $pass.Blocked | Should -BeTrue
            $pass.Steps.Action | Should -Be @('Initialize')
            Should -Invoke -ModuleName FibocomFm350 Set-ModemAdapterConfiguration -Times 0 -Exactly
        }

        It 'configures the simulated adapter of development mode, which needs no rights' {
            Mock -ModuleName FibocomFm350 Test-AppElevation { $false }
            $device = New-SimulatedDevice -Scenario Connect
            $pass = & $script:connect $device.Modem @{ SimulatedAdapter = $device.Adapter }
            $pass.State | Should -Be 'Online'
            # ForEach-Object: .Address on an array is the array's own Address() method.
            $device.Adapter.Read().Addresses | ForEach-Object Address | Should -Contain '192.0.2.10'
            Should -Invoke -ModuleName FibocomFm350 Set-ModemAdapterConfiguration -Times 0 -Exactly
            Should -Invoke -ModuleName FibocomFm350 Get-ModemAdapterState -Times 0 -Exactly
        }

        It 'reads the PIN attempts left for the user while the SIM waits, with no PIN stored' {
            $modem = Get-OnlineModem -Answers @{
                'AT+CPIN?'  = Get-FixtureLine 'device/cpin.pin.txt'
                'AT+CPINR'  = Get-FixtureLine 'device/cpinr.absent.txt'
                'AT+EPINC?' = Get-FixtureLine 'device/epinc.wrong-pin.txt'
            }
            $pass = & $script:connect $modem
            $pass.Reason | Should -Be 'NoPin'
            $pass.Observation.SimState | Should -Be 'PinRequired'
            $pass.Observation.PinAttemptsLeft | Should -Be 2
            $modem.Received | Should -Not -Contain 'AT+ICCID' -Because 'the SIM is identified only for a stored PIN'
        }

        It 'writes the APN of the settings' {
            $script:settings = (ConvertTo-AppSetting -InputObject @{ Apn = 'internet.example'; PdpType = 'IP' }).Settings
            $modem = Get-OnlineModem -Answers @{ 'AT+CGDCONT?' = Get-FixtureLine 'device/cgdcont.attached.txt'; 'AT+CGACT?' = @('OK') }
            $modem.SetAnswer('AT+CGDCONT=1,"IP","internet.example"', @('OK'))
            $pass = & $script:connect $modem
            $pass.Steps[1].Commands[0].Command | Should -Be 'AT+CGDCONT=1,"IP","internet.example"'
        }

        It 'leaves an active context that differs from the settings alone, and says so' {
            $script:settings = (ConvertTo-AppSetting -InputObject @{ Apn = 'other.example' }).Settings
            $modem = Get-OnlineModem
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'Online'
            $pass.SettingsPending | Should -BeTrue
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
        }

        It 'asks for the APN when the network put the app''s context on the IMS APN, and writes nothing' {
            $modem = Get-OnlineModem -Answers @{ 'AT+CGCONTRDP=1' = Get-FixtureLine 'device/cgcontrdp.app-ims.txt'; 'AT+CGPADDR=1' = $script:imsIPv6Only }
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'Registered'
            $pass.Reason | Should -Be 'ApnNeeded'
            $pass.Blocked | Should -BeTrue
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
        }

        It 'asks for the APN, and leaves the adapter alone, when the IMS APN came with an IPv4 address' {
            $script:adapterState = $script:freshAdapter
            $modem = Get-OnlineModem -Answers @{
                'AT+CGCONTRDP=1' = Get-FixtureLine 'device/cgcontrdp.app-ims.txt'
                'AT+CGPADDR=1'   = Get-FixtureLine 'device/cgpaddr.app-ims.txt'
            }
            $pass = & $script:connect $modem
            $pass.Observation.ContextAddress | Should -Be '192.0.2.77'
            $pass.State | Should -Be 'Registered'
            $pass.Reason | Should -Be 'ApnNeeded'
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
            Should -Invoke -ModuleName FibocomFm350 Set-ModemAdapterConfiguration -Times 0 -Exactly
        }

        It 'moves a context without an address to the APN of the settings: deactivate, define, activate' {
            $script:settings = (ConvertTo-AppSetting -InputObject @{ Apn = 'internet.example' }).Settings
            $modem = Get-OnlineModem -Answers @{ 'AT+CGCONTRDP=1' = Get-FixtureLine 'device/cgcontrdp.app-ims.txt'; 'AT+CGPADDR=1' = $script:imsIPv6Only }
            $modem.Script('AT+CGACT=0,1', @{ Lines = @('OK'); Then = @{ 'AT+CGACT?' = @('OK') } })
            $modem.Script('AT+CGDCONT=1,"IPV4V6","internet.example"', @{ Lines = @('OK'); Then = @{ 'AT+CGDCONT?' = @('+CGDCONT: 1,"IPV4V6","internet.example","",0,0', 'OK') } })
            $modem.Script('AT+CGACT=1,1', @{ Lines = @('OK'); Then = @{
                        'AT+CGACT?'      = Get-FixtureLine 'documented/cgact.active.txt'
                        'AT+CGCONTRDP=1' = Get-FixtureLine 'documented/cgcontrdp.data.txt'
                    }
                })
            $pass = & $script:connect $modem
            $pass.Steps.Action | Should -Be @('Initialize', 'DeactivateContext', 'DefineContext', 'ActivateContext')
            $pass.State | Should -Be 'Online'
            Get-WriteCommand -Modem $modem | Should -Be @('AT+CGACT=0,1', 'AT+CGDCONT=1,"IPV4V6","internet.example"', 'AT+CGACT=1,1')
        }

        It 'turns the radio on, then waits for the registration' {
            # With the radio off the device reports <stat> 4, unknown (device/cereg.radiooff.txt).
            $modem = Get-OnlineModem -Answers @{
                'AT+CFUN?'           = @('+CFUN: 4', 'OK')
                'AT+CEREG?;+C5GREG?' = @('+CEREG: 0,4', '+C5GREG: 0,4', 'OK')
            }
            $modem.Script('AT+CFUN=1', @{ Lines = @('OK'); Then = @{ 'AT+CFUN?' = @('+CFUN: 1', 'OK'); 'AT+CEREG?;+C5GREG?' = @('+CEREG: 0,2', '+C5GREG: 0,2', 'OK') } })
            $pass = & $script:connect $modem
            $pass.Steps.Action | Should -Be @('Initialize', 'RadioOn')
            $pass.State | Should -Be 'SimReady'
            $pass.Reason | Should -Be 'Searching'
            $pass.Blocked | Should -BeFalse
        }

        It 'selects the operator automatically after a deregistration' {
            $modem = Get-OnlineModem -Answers @{
                'AT+CEREG?;+C5GREG?' = @('+CEREG: 0,0', '+C5GREG: 0,0', 'OK')
                'AT+COPS?'           = @('+COPS: 2', 'OK')
            }
            $modem.SetAnswer('AT+COPS=0', @('OK'))
            $pass = & $script:connect $modem
            $pass.Steps.Action | Should -Be @('Initialize', 'AutoRegister')
        }
    }

    Context 'the FCC lock' {
        It 'stops at a locked module: no radio command, no escalation' {
            $modem = Get-OnlineModem -Answers @{
                'AT+CFUN?'           = @('+CFUN: 4', 'OK')
                'AT+CEREG?;+C5GREG?' = @('+CEREG: 0,0', '+C5GREG: 0,0', 'OK')
                $script:fccRead      = Get-FixtureLine 'documented/fcc.locked.txt'
            }
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'SimReady'
            $pass.Reason | Should -Be 'FccLocked'
            $pass.Blocked | Should -BeTrue
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
        }

        It 'tries the radio once when the lock can''t be read, and stays unblocked when it is refused' {
            $modem = Get-OnlineModem -Answers @{
                'AT+CFUN?'           = @('+CFUN: 4', 'OK')
                'AT+CEREG?;+C5GREG?' = @('+CEREG: 0,0', '+C5GREG: 0,0', 'OK')
                $script:fccRead      = @('+CME ERROR: 100')
                'AT+CFUN=1'          = Get-FixtureLine 'documented/cfun.locked.txt'
            }
            $pass = & $script:connect $modem
            $pass.Steps[-1].Action | Should -Be 'RadioOn'
            $pass.Steps[-1].Commands[0].ErrorCode | Should -Be 0
            $pass.Action | Should -Be 'RadioOn'
            $pass.Blocked | Should -BeFalse
            @($modem.Received | Where-Object { $_ -eq 'AT+CFUN=1' }).Count | Should -Be 1
        }

        It 'never reads the lock on a registered modem' {
            $modem = Get-OnlineModem -Answers @{ $script:fccRead = Get-FixtureLine 'documented/fcc.locked.txt' }
            (& $script:connect $modem).State | Should -Be 'Online'
            $modem.Received | Should -Not -Contain $script:fccRead
        }
    }

    Context 'the SIM PIN' {
        BeforeEach {
            $script:locked = @{
                'AT+CPIN?'  = @('+CPIN: SIM PIN', 'OK')
                'AT+ICCID'  = Get-FixtureLine 'documented/iccid.txt'
                'AT+CPINR'  = Get-FixtureLine 'documented/cpinr.txt'
            }
            Save-SimPin -Pin (ConvertTo-TestSecret '1234') -Iccid '8900100000000000000' -Path $script:pinPath
        }

        It 'enters the stored PIN once, then goes on' {
            $modem = Get-OnlineModem -Answers $script:locked
            $modem.Script('AT+CPIN="1234"', @{ Lines = @('OK'); Then = @{ 'AT+CPIN?' = @('+CPIN: READY', 'OK') } })
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'Online'
            $pass.Steps.Action | Should -Be @('Initialize', 'EnterPin')
            $pass.Steps[1].Commands[0].Command | Should -Be 'AT+CPIN=***'
            @($modem.Received | Where-Object { $_ -like 'AT+CPIN=*' }).Count | Should -Be 1
            (Get-SimPin -Path $script:pinPath).Attempted | Should -BeFalse
        }

        It 'keeps the PIN out of the result and the log' {
            $modem = Get-OnlineModem -Answers $script:locked
            $modem.Script('AT+CPIN="1234"', @{ Lines = @('OK'); Then = @{ 'AT+CPIN?' = @('+CPIN: READY', 'OK') } })
            $pass = & $script:connect $modem
            ($pass | ConvertTo-Json -Depth 6) | Should -Not -Match '1234'
            (Get-Content -Path "$script:logFolder/*.log" -Raw) | Should -Not -Match '1234'
            (Get-Content -Path "$script:logFolder/*.log" -Raw) | Should -Match 'EnterPin: Done - AT\+CPIN=\*\*\* OK'
        }

        It 'deletes a PIN the SIM rejects, and never sends it again' {
            $modem = Get-OnlineModem -Answers $script:locked
            $modem.SetAnswer('AT+CPIN="1234"', @('+CME ERROR: 16'))
            $channel = New-AtChannel -Transport $modem
            try {
                $pass = & $script:pass $channel
                $pass.Steps[-1].Result | Should -Be 'PinRejected'
                $pass.State | Should -Be 'Identified'
                $pass.Reason | Should -Be 'NoPin'
                $pass.Blocked | Should -BeTrue
                Get-SimPin -Path $script:pinPath | Should -BeNullOrEmpty
                [void](& $script:pass $channel)
            }
            finally {
                Close-AtChannel -Channel $channel
            }
            @($modem.Received | Where-Object { $_ -like 'AT+CPIN=*' }).Count | Should -Be 1
        }

        It 'never sends a second attempt after an answer that never came' {
            $modem = Get-OnlineModem -Answers $script:locked
            $modem.Script('AT+CPIN="1234"', @{ Lines = @('OK'); NoFinal = $true })
            $channel = New-AtChannel -Transport $modem
            try {
                $pass = & $script:pass $channel
                $pass.Steps[-1].Result | Should -Be 'PinUnconfirmed'
                (Get-SimPin -Path $script:pinPath).Attempted | Should -BeTrue
                $again = & $script:pass $channel
                $again.Reason | Should -Be 'PinUnconfirmed'
            }
            finally {
                Close-AtChannel -Channel $channel
            }
            @($modem.Received | Where-Object { $_ -like 'AT+CPIN=*' }).Count | Should -Be 1
        }

        It 'confirms an unconfirmed attempt once its SIM is seen ready' {
            Set-SimPinAttempt -Attempted $true -Path $script:pinPath
            $modem = Get-OnlineModem -Answers @{ 'AT+ICCID' = Get-FixtureLine 'documented/iccid.txt' }
            (& $script:connect $modem).State | Should -Be 'Online'
            (Get-SimPin -Path $script:pinPath).Attempted | Should -BeFalse
        }

        It 'keeps an attempt pending when <Name> is seen ready' -ForEach @(
            @{ Name = 'another SIM'; Iccid = @('+ICCID: 8900100000000000001', 'OK') }
            @{ Name = 'a SIM it cannot identify'; Iccid = @('+CME ERROR: 100') }
        ) {
            Set-SimPinAttempt -Attempted $true -Path $script:pinPath
            $modem = Get-OnlineModem -Answers @{ 'AT+ICCID' = $Iccid }
            (& $script:connect $modem).State | Should -Be 'Online'
            (Get-SimPin -Path $script:pinPath).Attempted | Should -BeTrue
        }

        It 'sends no PIN when its attempt cannot be recorded' {
            $modem = Get-OnlineModem -Answers $script:locked
            (Get-Item -LiteralPath $script:pinPath).IsReadOnly = $true
            try {
                $pass = & $script:connect $modem
            }
            finally {
                (Get-Item -LiteralPath $script:pinPath).IsReadOnly = $false
            }
            $pass.Steps[-1].Action | Should -Be 'EnterPin'
            $pass.Steps[-1].Result | Should -Be 'Failed'
            $pass.Steps[-1].Commands | Should -BeNullOrEmpty
            @($modem.Received | Where-Object { $_ -like 'AT+CPIN=*' }).Count | Should -Be 0
            Get-ChildItem -LiteralPath (Split-Path $script:pinPath) -Filter '*.tmp' | Should -BeNullOrEmpty
        }

        It 'sends nothing with one attempt left' {
            $modem = Get-OnlineModem -Answers ($script:locked + @{})
            $modem.SetAnswer('AT+CPINR', @('+CPINR: SIM PIN,1,3', 'OK'))
            $pass = & $script:connect $modem
            $pass.Reason | Should -Be 'LastAttempt'
            $modem.Received | Should -Not -Contain 'AT+CPIN="1234"'
        }

        It 'reads the attempts left from +EPINC where +CPINR is absent, as on the FM350' {
            $answers = $script:locked.Clone()
            $answers['AT+CPINR'] = Get-FixtureLine 'device/cpinr.absent.txt'
            $answers['AT+EPINC?'] = @('+EPINC: 1, 3, 10, 10', 'OK')
            $modem = Get-OnlineModem -Answers $answers
            $pass = & $script:connect $modem
            $pass.Reason | Should -Be 'LastAttempt'
            $modem.Received | Should -Not -Contain 'AT+CPIN="1234"'
        }

        It 'enters the PIN as captured: SIM PIN, no +CPINR, +EPINC, then busy for a moment' {
            $answers = $script:locked.Clone()
            $answers['AT+CPIN?'] = Get-FixtureLine 'device/cpin.pin.txt'
            $answers['AT+CPINR'] = Get-FixtureLine 'device/cpinr.absent.txt'
            $answers['AT+EPINC?'] = Get-FixtureLine 'device/epinc.txt'
            $modem = Get-OnlineModem -Answers $answers
            $modem.Script('AT+CPIN="1234"', @{ Lines = @('OK'); Then = @{ 'AT+CPIN?' = Get-FixtureLine 'device/cpin.busy.txt' } })
            $pass = & $script:connect $modem
            $pass.Steps.Action | Should -Be @('Initialize', 'EnterPin')
            $pass.State | Should -Be 'Identified'
            $pass.Reason | Should -Be 'SimBusy'
            $pass.Blocked | Should -BeFalse
            (Get-SimPin -Path $script:pinPath).Attempted | Should -BeFalse
        }

        It 'sends nothing to another SIM' {
            Save-SimPin -Pin (ConvertTo-TestSecret '1234') -Iccid '8900100000000000001' -Path $script:pinPath
            $modem = Get-OnlineModem -Answers $script:locked
            $pass = & $script:connect $modem
            $pass.Reason | Should -Be 'PinForOtherSim'
            $modem.Received | Should -Not -Contain 'AT+CPIN="1234"'
        }

        It 'sends nothing to a SIM it cannot identify' {
            $modem = Get-OnlineModem -Answers $script:locked
            $modem.SetAnswer('AT+ICCID', @('+CME ERROR: 100'))
            (& $script:connect $modem).Reason | Should -Be 'SimNotIdentified'
            $modem.Received | Should -Not -Contain 'AT+CPIN="1234"'
        }

        It 'reports a SIM waiting for its PUK, and sends nothing' {
            $modem = Get-OnlineModem -Answers @{ 'AT+CPIN?' = @('+CPIN: SIM PUK', 'OK') }
            $pass = & $script:connect $modem
            $pass.Reason | Should -Be 'PukRequired'
            $pass.Blocked | Should -BeTrue
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
        }

        It 'reports a missing SIM' {
            $modem = Get-OnlineModem -Answers @{ 'AT+CPIN?' = Get-FixtureLine 'device/cpin.nosim.txt' }
            (& $script:connect $modem).Reason | Should -Be 'NoSim'
        }
    }

    Context 'APN credentials' {
        BeforeEach {
            $script:inactive = @{ 'AT+CGACT?' = @('OK') }
        }

        It 'sets the credentials before activating, and keeps the password out of the result and the log' {
            $script:settings = (ConvertTo-AppSetting -InputObject @{ ApnAuthentication = 'PAP'; ApnUser = 'me' }).Settings
            Save-ApnPassword -Password (ConvertTo-TestSecret 'pa55word') -Path $script:passwordPath
            $modem = Get-OnlineModem -Answers $script:inactive
            $modem.SetAnswer('AT+CGAUTH=1,1,"me","pa55word"', @('OK'))
            $modem.Script('AT+CGACT=1,1', @{ Lines = @('OK'); Then = @{ 'AT+CGACT?' = @('+CGACT: 1,1', 'OK') } })
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'Online'
            $modem.Received | Should -Contain 'AT+CGAUTH=1,1,"me","pa55word"'
            ($pass | ConvertTo-Json -Depth 6) | Should -Not -Match 'pa55word'
            (Get-Content -Path "$script:logFolder/*.log" -Raw) | Should -Not -Match 'pa55word'
        }

        It 'clears credentials left on the app''s context when the settings have none' {
            $modem = Get-OnlineModem -Answers ($script:inactive + @{ 'AT+CGAUTH?' = @('+CGAUTH: 0,0,"",""', '+CGAUTH: 1,1,"old",""', 'OK') })
            $modem.SetAnswer('AT+CGAUTH=1,0', @('OK'))
            $modem.Script('AT+CGACT=1,1', @{ Lines = @('OK'); Then = @{ 'AT+CGACT?' = @('+CGACT: 1,1', 'OK') } })
            [void](& $script:connect $modem)
            Get-WriteCommand -Modem $modem | Should -Be @('AT+CGAUTH=1,0', 'AT+CGACT=1,1')
        }

        It 'stops, blocked, when the stored password cannot be read, and sends no credentials' {
            $script:settings = (ConvertTo-AppSetting -InputObject @{ ApnAuthentication = 'PAP'; ApnUser = 'me' }).Settings
            Set-Content -LiteralPath $script:passwordPath -Value 'not encrypted for this user'
            $modem = Get-OnlineModem -Answers $script:inactive
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'Registered'
            $pass.Reason | Should -Be 'ApnPasswordUnreadable'
            $pass.Blocked | Should -BeTrue
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
        }

        It 'sends an empty password when none is stored, as some operators expect' {
            $script:settings = (ConvertTo-AppSetting -InputObject @{ ApnAuthentication = 'PAP'; ApnUser = 'me' }).Settings
            $modem = Get-OnlineModem -Answers $script:inactive
            $modem.SetAnswer('AT+CGAUTH=1,1,"me",""', @('OK'))
            $modem.Script('AT+CGACT=1,1', @{ Lines = @('OK'); Then = @{ 'AT+CGACT?' = @('+CGACT: 1,1', 'OK') } })
            (& $script:connect $modem).State | Should -Be 'Online'
            Get-WriteCommand -Modem $modem | Should -Be @('AT+CGAUTH=1,1,"me",""', 'AT+CGACT=1,1')
        }

        It 'leaves an active context alone when the stored password cannot be read' {
            $script:settings = (ConvertTo-AppSetting -InputObject @{ ApnAuthentication = 'PAP'; ApnUser = 'me' }).Settings
            Set-Content -LiteralPath $script:passwordPath -Value 'not encrypted for this user'
            $modem = Get-OnlineModem
            (& $script:connect $modem).State | Should -Be 'Online'
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
        }

        It 'does not activate when the credentials are refused' {
            $script:settings = (ConvertTo-AppSetting -InputObject @{ ApnAuthentication = 'CHAP'; ApnUser = 'me' }).Settings
            $modem = Get-OnlineModem -Answers $script:inactive
            $pass = & $script:connect $modem
            $pass.Steps[-1].Result | Should -Be 'Failed'
            $modem.Received | Should -Not -Contain 'AT+CGACT=1,1'
        }
    }

    Context 'steps that fail' {
        It 'tries a failing step once per pass, and says what is missing' {
            $modem = Get-OnlineModem -Answers @{ 'AT+CGACT?' = @('OK') }
            $modem.SetAnswer('AT+CGACT=1,1', @('+CME ERROR: 149'))
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'Registered'
            $pass.Action | Should -Be 'ActivateContext'
            $pass.Steps[-1].Commands[-1].ErrorCode | Should -Be 149
            @($modem.Received | Where-Object { $_ -eq 'AT+CGACT=1,1' }).Count | Should -Be 1
            (Get-Content -Path "$script:logFolder/*.log" -Raw) | Should -Match 'WARNING ActivateContext: Failed'
        }

        It 'stops when the port is lost, and says the connection dropped' {
            $modem = Get-OnlineModem
            $modem.Script('AT+CFUN?', @{ Vanish = $true; Lines = @(); NoFinal = $true })
            $pass = & $script:connect $modem @{ Previous = 'Online' }
            $pass.State | Should -Be 'NoDevice'
            $pass.Action | Should -Be 'OpenPort'
            $pass.Dropped | Should -BeTrue
        }

        It 'takes the address from +CGPADDR when +CGCONTRDP leaves it out, as the FM350 does' {
            $script:adapterState = $script:freshAdapter
            $modem = Get-OnlineModem -Answers @{
                'AT+CGCONTRDP=1' = Get-FixtureLine 'device/cgcontrdp.app.txt'
                'AT+CGPADDR=1'   = Get-FixtureLine 'device/cgpaddr.app.txt'
            }
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'Online'
            $pass.Observation.ContextAddress | Should -Be '192.0.2.53'
            Should -Invoke -ModuleName FibocomFm350 Set-ModemAdapterConfiguration -Times 1 -Exactly -ParameterFilter {
                $set = $Plan.Actions | Where-Object Action -EQ 'SetAddress'
                $route = $Plan.Actions | Where-Object Action -EQ 'SetGateway'
                $set.Address -eq '192.0.2.53' -and $set.PrefixLength -eq 32 -and $route.NextHop -eq '0.0.0.0'
            }
        }

        It 'stays without an address when neither +CGCONTRDP nor +CGPADDR gives one' {
            $modem = Get-OnlineModem -Answers @{
                'AT+CGCONTRDP=1' = Get-FixtureLine 'device/cgcontrdp.app.txt'
                'AT+CGPADDR=1'   = @('+CGPADDR: 1,"0.0.0.0.0.0.0.0.32.1.13.184.0.0.0.1",""', 'OK')
            }
            $script:settings = (ConvertTo-AppSetting -InputObject @{ Apn = 'internet' }).Settings
            $modem.SetAnswer('AT+CGDCONT?', @('+CGDCONT: 1,"IPV4V6","internet","",0,0', 'OK'))
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'Registered'
            $pass.Reason | Should -Be 'NoAddress'
        }

        It 'takes a failed address read for unknown, not for no address: <Name>' -ForEach @(
            @{ Name = 'an active context with other settings is not deactivated'; Apn = 'other.example' }
            @{ Name = 'no APN is asked for'; Apn = '' }
        ) {
            $script:settings = (ConvertTo-AppSetting -InputObject @{ Apn = $Apn }).Settings
            $modem = Get-OnlineModem -Answers @{
                'AT+CGCONTRDP=1' = Get-FixtureLine 'device/cgcontrdp.app.txt'
                'AT+CGPADDR=1'   = @('+CME ERROR: 100')
            }
            $pass = & $script:connect $modem
            $pass.State | Should -Be 'Registered'
            $pass.Reason | Should -Be 'ContextUnknown'
            $pass.Blocked | Should -BeFalse
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
        }

        It 'takes a failed +CGCONTRDP read for unknown too' {
            $modem = Get-OnlineModem -Answers @{ 'AT+CGCONTRDP=1' = @('+CME ERROR: 0') }
            $pass = & $script:connect $modem
            $pass.Reason | Should -Be 'ContextUnknown'
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
        }

        It 'never writes a definition over a context whose activation is <Name>' -ForEach @(
            @{ Name = 'not known'; Activation = @('+CME ERROR: 100') }
            @{ Name = 'active, while the registration is lost a moment'; Activation = @('+CGACT: 1,1', 'OK') }
        ) {
            $script:settings = (ConvertTo-AppSetting -InputObject @{ Apn = 'new.example' }).Settings
            $modem = Get-OnlineModem -Answers @{
                'AT+CEREG?;+C5GREG?' = @('+CEREG: 0,2', '+C5GREG: 0,2', 'OK')
                'AT+CGACT?'          = $Activation
            }
            $pass = & $script:connect $modem
            $pass.Reason | Should -Be 'Searching'
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
        }

        It 'stops at a disabled adapter, blocked, and leaves it alone' {
            $script:adapterState = $script:freshAdapter | Select-Object -Property *
            $script:adapterState.Status = 'Disabled'
            $pass = & $script:connect (Get-OnlineModem)
            $pass.State | Should -Be 'DataActive'
            $pass.Reason | Should -Be 'AdapterDisabled'
            $pass.Blocked | Should -BeTrue
            Should -Invoke -ModuleName FibocomFm350 Set-ModemAdapterConfiguration -Times 0 -Exactly
        }

        It 'takes a modem error on +CPIN? for an unknown SIM state, not a blocked one' {
            $pass = & $script:connect (Get-OnlineModem -Answers @{ 'AT+CPIN?' = @('+CME ERROR: 100') })
            $pass.State | Should -Be 'Identified'
            $pass.Reason | Should -Be 'SimUnknown'
            $pass.Blocked | Should -BeFalse
        }

        It 'takes the DNS servers from +GTDNS when the context has none' {
            $script:adapterState = $script:freshAdapter
            $modem = Get-OnlineModem -Answers @{
                'AT+CGCONTRDP=1' = @('+CGCONTRDP: 1,6,"internet","198.51.100.23.255.255.255.0","198.51.100.1","",""', 'OK')
                'AT+GTDNS=1'     = Get-FixtureLine 'documented/gtdns.txt'
            }
            [void](& $script:connect $modem)
            Should -Invoke -ModuleName FibocomFm350 Set-ModemAdapterConfiguration -Times 1 -Exactly -ParameterFilter {
                (($Plan.Actions | Where-Object Action -EQ 'SetDns').Servers -join ',') -eq '203.0.113.53,203.0.113.54'
            }
        }

        It 'changes nothing under -WhatIf' {
            $modem = Get-OnlineModem -Answers @{ 'AT+CGACT?' = @('OK') }
            $channel = New-AtChannel -Transport $modem
            try {
                $pass = Invoke-ModemConnect -Channel $channel -Settings $script:settings -SimPinPath $script:pinPath -WhatIf
            }
            finally {
                Close-AtChannel -Channel $channel
            }
            $pass.Action | Should -Be 'ActivateContext'
            Get-WriteCommand -Modem $modem | Should -BeNullOrEmpty
        }
    }
}

Describe 'Disable-SimPin' {
    BeforeEach {
        $script:modem = New-SimulatedModem
        $script:modem.SetAnswer('AT+CPIN?', @('+CPIN: READY', 'OK'))
        $script:modem.SetAnswer('AT+CLCK="SC",2', @('+CLCK: 1', 'OK'))
        $script:modem.SetAnswer('AT+CPINR', @('+CPINR: SIM PIN,3,3', 'OK'))
        $script:modem.SetAnswer('AT+CLCK="SC",0,"1234"', @('OK'))
        $script:channel = New-AtChannel -Transport $script:modem
        [void](Initialize-AtChannel -Channel $script:channel)
        $script:pin = ConvertTo-TestSecret '1234'
    }

    AfterEach {
        Close-AtChannel -Channel $script:channel
    }

    It 'turns the PIN request off with one command' {
        (Disable-SimPin -Channel $script:channel -Pin $script:pin -Confirm:$false).Result | Should -Be 'Disabled'
        @($script:modem.Received | Where-Object { $_ -like 'AT+CLCK="SC",0*' }).Count | Should -Be 1
    }

    It 'reports a wrong PIN and the attempts left' {
        $script:modem.SetAnswer('AT+CLCK="SC",0,"1234"', @('+CME ERROR: 16'))
        $result = Disable-SimPin -Channel $script:channel -Pin $script:pin -Confirm:$false
        $result.Result | Should -Be 'PinRejected'
        $result.AttemptsLeft | Should -Be 2
    }

    It 'sends nothing when <Name>' -ForEach @(
        @{ Name = 'the SIM is not ready'; Command = 'AT+CPIN?'; Answer = @('+CPIN: SIM PIN', 'OK'); Result = 'SimNotReady' }
        @{ Name = 'there is no SIM'; Command = 'AT+CPIN?'; Answer = @('+CME ERROR: 10'); Result = 'SimNotReady' }
        @{ Name = 'the request is already off'; Command = 'AT+CLCK="SC",2'; Answer = @('+CLCK: 0', 'OK'); Result = 'AlreadyOff' }
        @{ Name = 'one attempt is left'; Command = 'AT+CPINR'; Answer = @('+CPINR: SIM PIN,1,3', 'OK'); Result = 'LastAttempt' }
    ) {
        $script:modem.SetAnswer($Command, $Answer)
        (Disable-SimPin -Channel $script:channel -Pin $script:pin -Confirm:$false).Result | Should -Be $Result
        $script:modem.Received | Should -Not -Contain 'AT+CLCK="SC",0,"1234"'
    }

    It 'sends nothing when the PIN request cannot be read' {
        $script:modem.SetAnswer('AT+CLCK="SC",2', @('+CME ERROR: 100'))
        (Disable-SimPin -Channel $script:channel -Pin $script:pin -Confirm:$false).Result | Should -Be 'Failed'
        $script:modem.Received | Should -Not -Contain 'AT+CLCK="SC",0,"1234"'
    }

    It 'refuses a PIN that is not 4 to 8 digits, without sending it or showing it: <Name>' -ForEach @(
        @{ Name = 'a letter outside ASCII'; Pin = "98$([char]0x00E9)7" }
        @{ Name = 'a double quote'; Pin = '12"34' }
        @{ Name = 'too short'; Pin = '987' }
    ) {
        $message = $null
        try {
            [void](Disable-SimPin -Channel $script:channel -Pin (ConvertTo-TestSecret $Pin) -Confirm:$false -ErrorAction Stop)
        }
        catch {
            $message = $_.Exception.Message
        }
        $message | Should -Not -BeNullOrEmpty
        $message | Should -Not -Match ([regex]::Escape($Pin))
        @($script:modem.Received | Where-Object { $_ -like 'AT+CLCK*' }).Count | Should -Be 0
    }

    It 'sends nothing without a confirmation' {
        (Disable-SimPin -Channel $script:channel -Pin $script:pin -WhatIf).Result | Should -Be 'Declined'
        $script:modem.Received | Should -Not -Contain 'AT+CLCK="SC",0,"1234"'
    }

    It 'goes ahead when the modem cannot tell the attempts left' {
        $script:modem.SetAnswer('AT+CPINR', @('+CME ERROR: 100'))
        (Disable-SimPin -Channel $script:channel -Pin $script:pin -Confirm:$false).Result | Should -Be 'Disabled'
    }

    Context 'where +CPINR is absent, as on the FM350' {
        BeforeEach {
            $script:modem.SetAnswer('AT+CPINR', @('+CME ERROR: 100'))
        }

        It 'reports a wrong PIN and the attempts left from +EPINC' {
            $script:modem.SetAnswer('AT+EPINC?', @('+EPINC: 3, 3, 10, 10', 'OK'))
            $script:modem.SetAnswer('AT+CLCK="SC",0,"1234"', @('+CME ERROR: 16'))
            $result = Disable-SimPin -Channel $script:channel -Pin $script:pin -Confirm:$false
            $result.Result | Should -Be 'PinRejected'
            $result.AttemptsLeft | Should -Be 2
        }

        It 'sends nothing with one attempt left on +EPINC' {
            $script:modem.SetAnswer('AT+EPINC?', @('+EPINC: 1, 3, 10, 10', 'OK'))
            (Disable-SimPin -Channel $script:channel -Pin $script:pin -Confirm:$false).Result | Should -Be 'LastAttempt'
            $script:modem.Received | Should -Not -Contain 'AT+CLCK="SC",0,"1234"'
        }
    }
}

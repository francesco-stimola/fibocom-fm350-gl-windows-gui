# Status parsers, fed by documented and captured fixtures played through the simulated modem and
# the channel.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    . "$PSScriptRoot/FixtureAnswer.ps1"
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-AtIdentity' {
    It 'reads manufacturer, model and firmware from quoted answers' {
        $identity = ConvertFrom-AtIdentity -Lines (Get-FixtureAnswer -Name 'identity.txt')
        $identity.Manufacturer | Should -Be 'Fibocom'
        $identity.Model | Should -Be 'FM350-GL'
        $identity.ModelShortName | Should -Be 'FM350'
        $identity.Firmware | Should -Be '81600.0000.00.29.00.00'
        $identity.Package | Should -Be '00.00.00.00_GC'
    }

    It 'accepts the older +GMR: prefix for the firmware' {
        (ConvertFrom-AtIdentity -Lines '+GMR: "81600.0000.00.12.00.00"').Firmware | Should -Be '81600.0000.00.12.00.00'
    }

    It 'leaves out what the answer does not carry, and ignores unknown lines' {
        $identity = ConvertFrom-AtIdentity -Lines 'noise', '+CGMM: "FM350-GL"'
        $identity.Model | Should -Be 'FM350-GL'
        $identity.ModelShortName | Should -BeNullOrEmpty
        $identity.Manufacturer | Should -BeNullOrEmpty
    }

    It 'reads the captured identity: one model value, +GMR: prefix' {
        $identity = ConvertFrom-AtIdentity -Lines (Get-FixtureAnswer -Name 'identity.txt' -Folder device)
        $identity.Manufacturer | Should -Be 'Fibocom Wireless Inc.'
        $identity.Model | Should -Be 'FM350-GL'
        $identity.ModelShortName | Should -BeNullOrEmpty
        $identity.Firmware | Should -Be '81600.0000.00.29.22.06'
        $identity.Package | Should -Be '81600.0000.00.29.22.06_5006.0000.065.006.048_E09'
    }
}

Describe 'ConvertFrom-AtSimState' {
    It 'reads a ready SIM' {
        $sim = ConvertFrom-AtSimState -Lines (Get-FixtureAnswer -Name 'cpin.ready.txt')
        $sim.Ready | Should -BeTrue
        $sim.Waiting | Should -BeNullOrEmpty
    }

    It 'reads a SIM waiting for its PIN' {
        $sim = ConvertFrom-AtSimState -Lines (Get-FixtureAnswer -Name 'cpin.pin.txt')
        $sim.Ready | Should -BeFalse
        $sim.Waiting | Should -Be 'SIM PIN'
    }

    It 'gives nothing without a +CPIN: line' {
        ConvertFrom-AtSimState -Lines @() | Should -BeNullOrEmpty
    }

    It 'leaves a missing SIM to the error code: CME 10 on the device' {
        $answer = Get-FixtureResult -Name 'cpin.nosim.txt' -Folder device
        $answer.Status | Should -Be 'CmeError'
        $answer.ErrorCode | Should -Be 10
        ConvertFrom-AtSimState -Lines @($answer.Lines) | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AtRegistration' {
    It 'reads the documented +CEREG answer' {
        $registration = ConvertFrom-AtRegistration -Line (Get-FixtureAnswer -Name 'cereg.lte.txt')[0]
        $registration.Domain | Should -Be 'EPS'
        $registration.State | Should -Be 'Home'
        $registration.Registered | Should -BeTrue
        $registration.Tac | Should -Be 'ABCD'
        $registration.CellId | Should -Be '0ABCDEF0'
        $registration.Technology | Should -Be 'LTE'
    }

    It 'reads <Line>' -ForEach @(
        @{ Line = '+CEREG: 0,1'; Domain = 'EPS'; Stat = 1; Registered = $true; Tac = $null; AcT = $null; Cause = $null }
        @{ Line = '+CEREG: 1'; Domain = 'EPS'; Stat = 1; Registered = $true; Tac = $null; AcT = $null; Cause = $null }
        @{ Line = '+CEREG: 2'; Domain = 'EPS'; Stat = 2; Registered = $false; Tac = $null; AcT = $null; Cause = $null }
        @{ Line = '+CEREG: 5,"ABCD","0ABCDEF0",13'; Domain = 'EPS'; Stat = 5; Registered = $true; Tac = 'ABCD'; AcT = 13; Cause = $null }
        # The unquoted second argument makes it a read answer (<n> = 3), not a URC with stat 3.
        @{ Line = '+CEREG: 3,3,"ABCD","0ABCDEF0",7,0,15'; Domain = 'EPS'; Stat = 3; Registered = $false; Tac = 'ABCD'; AcT = 7; Cause = 15 }
        @{ Line = '+CEREG: 3,,,,0,15'; Domain = 'EPS'; Stat = 3; Registered = $false; Tac = $null; AcT = $null; Cause = 15 }
        @{ Line = '+CGREG: 2,1,"ABCD","0ABCDEF0",7,"01",0,7'; Domain = 'PS'; Stat = 1; Registered = $true; Tac = 'ABCD'; AcT = 7; Cause = 7 }
        @{ Line = '+C5GREG: 1,"ABCD","0ABCDEF0",11'; Domain = '5GS'; Stat = 1; Registered = $true; Tac = 'ABCD'; AcT = 11; Cause = $null }
        @{ Line = '+CREG: 1'; Domain = 'CS'; Stat = 1; Registered = $true; Tac = $null; AcT = $null; Cause = $null }
        @{ Line = '+CEREG: 7'; Domain = 'EPS'; Stat = 7; Registered = $true; Tac = $null; AcT = $null; Cause = $null }
        @{ Line = '+CEREG: 8'; Domain = 'EPS'; Stat = 8; Registered = $false; Tac = $null; AcT = $null; Cause = $null }
    ) {
        $registration = ConvertFrom-AtRegistration -Line $Line
        $registration.Domain | Should -Be $Domain
        $registration.Stat | Should -Be $Stat
        $registration.Registered | Should -Be $Registered
        $registration.Tac | Should -Be $Tac
        $registration.AcT | Should -Be $AcT
        $registration.RejectCause | Should -Be $Cause
    }

    It 'gives nothing for <Line>' -ForEach @(
        @{ Line = '+CSQ: 20,99' }
        @{ Line = '+CEREG: x' }
        @{ Line = '+CEREG:' }
        @{ Line = 'noise' }
    ) {
        ConvertFrom-AtRegistration -Line $Line | Should -BeNullOrEmpty
    }

    It 'reads the captured registration <Fixture> on LTE, location padded per domain' -ForEach @(
        @{ Fixture = 'creg.lte.txt'; Domain = 'CS'; State = 'HomeSmsOnly'; Tac = 'ABCD'; CellId = '00ABCDEF0' }
        @{ Fixture = 'cgreg.lte.txt'; Domain = 'PS'; State = 'Home'; Tac = 'ABCD'; CellId = '0ABCDEF0' }
        @{ Fixture = 'cereg.lte.txt'; Domain = 'EPS'; State = 'Home'; Tac = 'ABCD'; CellId = '0ABCDEF0' }
        # The FM350 reports the EPS registration in the 5GS domain too, NR disabled or not.
        @{ Fixture = 'c5greg.lte.txt'; Domain = '5GS'; State = 'Home'; Tac = '00ABCD'; CellId = '000ABCDEF0' }
    ) {
        $registration = ConvertFrom-AtRegistration -Line (Get-FixtureAnswer -Name $Fixture -Folder device)[0]
        $registration.Domain | Should -Be $Domain
        $registration.State | Should -Be $State
        $registration.Registered | Should -BeTrue
        $registration.Tac | Should -Be $Tac
        $registration.CellId | Should -Be $CellId
        $registration.AcT | Should -Be 13
    }

    It 'reads the radio switched off (AT+CFUN=4) as state 4, unknown, with no location' {
        $lines = Get-FixtureAnswer -Name 'cereg.radiooff.txt' -Folder device
        $registrations = @($lines | ConvertFrom-AtRegistration)
        $registrations.Domain | Should -Be @('EPS', '5GS')
        $registrations.State | Should -Be @('Unknown', 'Unknown')
        $registrations.Registered | Should -Be @($false, $false)
        @($registrations.Tac | Where-Object { $_ }) | Should -BeNullOrEmpty
        (ConvertFrom-AtOperator -Lines $lines).Operator | Should -BeNullOrEmpty
    }

    It 'reads no location from the not-known pattern of a search: <Line>' -ForEach @(
        @{ Line = '+CREG: 2,"FFFF","00FFFFFFF",0' }
        @{ Line = '+C5GREG: 0,"000000","000FFFFFFF",0' }
    ) {
        $registration = ConvertFrom-AtRegistration -Line $Line
        $registration.Tac | Should -BeNullOrEmpty
        $registration.CellId | Should -BeNullOrEmpty
    }

    It 'reads the captured <Fixture> as not searching' -ForEach @(
        @{ Fixture = 'cereg.nosim.txt'; Domain = 'EPS' }
        # One value only: read as the state, which "not searching" makes right either way.
        @{ Fixture = 'c5greg.nosim.txt'; Domain = '5GS' }
    ) {
        $registration = ConvertFrom-AtRegistration -Line (Get-FixtureAnswer -Name $Fixture -Folder device)[0]
        $registration.Domain | Should -Be $Domain
        $registration.State | Should -Be 'NotSearching'
        $registration.Registered | Should -BeFalse
    }
}

Describe 'ConvertFrom-AtOperator' {
    It 'reads <Fixture> as <Technology>' -ForEach @(
        @{ Fixture = 'cops.lte.txt'; AcT = 7; Technology = 'LTE' }
        @{ Fixture = 'cops.nsa.txt'; AcT = 13; Technology = 'EN-DC' }
        @{ Fixture = 'cops.sa.txt'; AcT = 11; Technology = 'NR-SA' }
    ) {
        $operator = ConvertFrom-AtOperator -Lines (Get-FixtureAnswer -Name $Fixture)
        $operator.Automatic | Should -BeTrue
        $operator.Operator | Should -Be 'Test Operator'
        $operator.AcT | Should -Be $AcT
        $operator.Technology | Should -Be $Technology
    }

    It 'reads an unregistered modem' {
        $operator = ConvertFrom-AtOperator -Lines '+COPS: 0'
        $operator.Mode | Should -Be 0
        $operator.Operator | Should -BeNullOrEmpty
        $operator.Technology | Should -BeNullOrEmpty
    }

    It 'keeps a comma inside the operator name' {
        (ConvertFrom-AtOperator -Lines '+COPS: 1,0,"Op, Inc.",7').Operator | Should -Be 'Op, Inc.'
    }

    It 'reads the captured operator: numeric format, AcT 13' {
        $operator = ConvertFrom-AtOperator -Lines (Get-FixtureAnswer -Name 'cops.lte.txt' -Folder device)
        $operator.Format | Should -Be 2
        $operator.Operator | Should -Be '00101'
        $operator.AcT | Should -Be 13
        $operator.Technology | Should -Be 'EN-DC'
    }

    It 'reads no technology without an operator, as the device answers unregistered' {
        $operator = ConvertFrom-AtOperator -Lines (Get-FixtureAnswer -Name 'cops.nosim.txt' -Folder device)
        $operator.Mode | Should -Be 0
        $operator.Automatic | Should -BeTrue
        $operator.Operator | Should -BeNullOrEmpty
        $operator.Format | Should -BeNullOrEmpty
        $operator.AcT | Should -BeNullOrEmpty
        $operator.Technology | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AtSignalQuality' {
    It 'reads RSSI from +CSQ' {
        $signal = ConvertFrom-AtSignalQuality -Lines (Get-FixtureAnswer -Name 'csq.txt')
        $signal.Rssi.Value | Should -Be -73
        $signal.LteRsrp | Should -BeNullOrEmpty
    }

    It 'reads LTE only from +CESQ on LTE' {
        $signal = ConvertFrom-AtSignalQuality -Lines (Get-FixtureAnswer -Name 'cesq.lte.txt')
        $signal.LteRsrq.Value | Should -Be -10
        $signal.LteRsrp.Value | Should -Be -81
        $signal.NrRsrp | Should -BeNullOrEmpty
        $signal.NrSinr | Should -BeNullOrEmpty
    }

    It 'reads LTE and NR from +CESQ on EN-DC' {
        $signal = ConvertFrom-AtSignalQuality -Lines (Get-FixtureAnswer -Name 'cesq.nsa.txt')
        $signal.LteRsrp.Value | Should -Be -81
        $signal.NrRsrq.Value | Should -Be -13.5
        $signal.NrRsrp.Value | Should -Be -67
        $signal.NrSinr.Value | Should -Be 11.5
    }

    It 'gives no RSSI when it is not known' {
        (ConvertFrom-AtSignalQuality -Lines '+CSQ: 99,99').Rssi | Should -BeNullOrEmpty
    }

    It 'reads the captured LTE signal: +CSQ and +CESQ, no NR' {
        $lines = @(Get-FixtureAnswer -Name 'csq.lte.txt' -Folder device) + @(Get-FixtureAnswer -Name 'cesq.lte.txt' -Folder device)
        $signal = ConvertFrom-AtSignalQuality -Lines $lines
        $signal.Rssi.Value | Should -Be -91
        $signal.LteRsrq.Value | Should -Be -13
        $signal.LteRsrp.Value | Should -Be -97
        $signal.NrRsrp | Should -BeNullOrEmpty
        $signal.NrSinr | Should -BeNullOrEmpty
    }

    It 'reads nothing from the device without a SIM (+CSQ with a space after the comma)' {
        $lines = @(Get-FixtureAnswer -Name 'csq.nosim.txt' -Folder device) + @(Get-FixtureAnswer -Name 'cesq.nosim.txt' -Folder device)
        $signal = ConvertFrom-AtSignalQuality -Lines $lines
        $signal.Rssi | Should -BeNullOrEmpty
        $signal.LteRsrp | Should -BeNullOrEmpty
        $signal.LteRsrq | Should -BeNullOrEmpty
        $signal.NrRsrp | Should -BeNullOrEmpty
        $signal.NrRsrq | Should -BeNullOrEmpty
        $signal.NrSinr | Should -BeNullOrEmpty
    }
}

Describe 'Parsers on odd input' {
    # The channel never delivers an empty line, but a parser must not throw on one.
    It '<Parser> accepts an empty line' -ForEach @(
        @{ Parser = 'ConvertFrom-AtIdentity' }
        @{ Parser = 'ConvertFrom-AtSimState' }
        @{ Parser = 'ConvertFrom-AtOperator' }
        @{ Parser = 'ConvertFrom-AtSignalQuality' }
        @{ Parser = 'ConvertFrom-AtTemperature' }
    ) {
        { & $Parser -Lines @('', 'noise') -ErrorAction Stop } | Should -Not -Throw
    }

    It 'ConvertFrom-AtRegistration gives nothing for an empty line' {
        ConvertFrom-AtRegistration -Line '' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AtTemperature' {
    It 'reads every sensor, in degrees Celsius' {
        $sensors = @(ConvertFrom-AtTemperature -Lines (Get-FixtureAnswer -Name 'gtsenrdtemp.all.txt'))
        $sensors.Sensor | Should -Be @(1, 10, 23)
        $sensors.Name | Should -Be @('SocMax', 'Modem5G', 'Crystal')
        $sensors.Celsius | Should -Be @(48.25, 45, 39.5)
    }

    It 'reports a sensor the manual does not name by number only' {
        $sensor = ConvertFrom-AtTemperature -Lines '+GTSENRDTEMP: 5,40000'
        $sensor.Name | Should -BeNullOrEmpty
        $sensor.Celsius | Should -Be 40
    }

    It 'reads the 23 sensors of the device, with no temperature where a sensor answers 0' {
        $sensors = @(ConvertFrom-AtTemperature -Lines (Get-FixtureAnswer -Name 'gtsenrdtemp.all.txt' -Folder device))
        $sensors.Sensor | Should -Be (1..23)
        ($sensors | Where-Object Sensor -EQ 1).Celsius | Should -Be 35.839
        ($sensors | Where-Object { $null -eq $_.Celsius }).Sensor | Should -Be @(17, 18)
    }
}

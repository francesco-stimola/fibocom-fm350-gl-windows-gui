# The modem's USB functions: which is the AT port, which the network adapter, their driver state,
# and which the app puts on WinUSB: on captured PnP snapshots and on a matrix of made-up ones.
# Reading the PnP records: with PnP mocked, and on a real FM350 (Hardware, read-only).

BeforeDiscovery {
    $script:hardware = $env:FM350_HARDWARE
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force

    # A PnP record as the reader gives it; the composite device of one 7127 modem by default.
    function ConvertTo-PnpRecord {
        param(
            [string] $InstanceId,
            [int] $ProblemCode = 0,
            [string] $Service = 'usb2ser',
            [bool] $Present = $true,
            [string] $Parent = 'USB\VID_0E8D&PID_7127\7&00000000&0&1',
            [string[]] $CompatibleIds = @('USB\Class_ff&SubClass_00&Prot_00'),
            [string[]] $InterfaceGuids,
            [string] $DriverInfPath
        )
        [pscustomobject]@{
            InstanceId = $InstanceId; Present = $Present; ProblemCode = $ProblemCode; Service = $Service; Parent = $Parent
            CompatibleIds = $CompatibleIds; InterfaceGuids = $InterfaceGuids; DriverInfPath = $DriverInfPath
        }
    }

    # The captured modem with its driver, its vendor functions moved to WinUSB as the app moves
    # them: the AT port with the app's interface class.
    function Get-BoundFixture {
        param([string] $Guid = '{4FDE9624-2286-4DC0-9D07-601A3922581A}')
        $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.driver.json" -Raw | ConvertFrom-Json
        foreach ($record in $fixture.Devices) {
            if ($record.Service -eq 'usb2ser_tm') {
                $record.Service = 'WINUSB'
                $record.PortName = $null
                $record.DriverInfPath = 'winusb.inf'
                $record | Add-Member -NotePropertyName InterfaceGuids -NotePropertyValue $(if ($record.InstanceId -like '*&MI_06\*') { @($Guid) } else { $null })
            }
        }
        $fixture.Devices
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Resolve-ModemUsbDevice' {
    Context 'on the captured 7127 modem without the AT-port driver' {
        BeforeAll {
            $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.nodriver.json" -Raw | ConvertFrom-Json
            $script:modems = @(Resolve-ModemUsbDevice -Device $fixture.Devices)
        }

        It 'finds one modem in composition 7127, with its nine functions' {
            $script:modems.Count | Should -Be 1
            $script:modems[0].ProductId | Should -Be '7127'
            $script:modems[0].InstanceId | Should -Be 'USB\VID_0E8D&PID_7127\7&00000000&0&1'
            $script:modems[0].Functions.Interface | Should -Be @(0, 2, 3, 4, 5, 6, 7, 8, 9)
        }

        It 'finds the AT port on MI_06, present without its driver' {
            $atPort = $script:modems[0].AtPort
            $atPort.InstanceId | Should -Be 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006'
            $atPort.State | Should -Be 'NoDriver'
            $atPort.ProblemCode | Should -Be 28
            $atPort.Service | Should -BeNullOrEmpty
        }

        It 'finds the network adapter on MI_00, working on Windows'' RNDIS driver' {
            $network = $script:modems[0].Network
            $network.InstanceId | Should -Be 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000'
            $network.State | Should -Be 'Working'
            $network.Service | Should -Be 'usbrndis6'
        }

        It 'sees every serial function without a driver, and ADB working' {
            $script:modems[0].Functions.State | Should -Be @('Working', 'NoDriver', 'NoDriver', 'NoDriver', 'Working', 'NoDriver', 'NoDriver', 'NoDriver', 'NoDriver')
            $script:modems[0].Functions.Role | Should -Be @('Network', 'Other', 'Other', 'Other', 'Other', 'AtPort', 'Other', 'Other', 'Other')
        }

        It 'tells the vendor functions the app puts on WinUSB: the serial ones, not the network nor ADB' {
            ($script:modems[0].Functions | Where-Object Vendor).Interface | Should -Be @(2, 3, 4, 6, 7, 8, 9)
            ($script:modems[0].Functions | Where-Object WinUsb).Interface | Should -Be @(5)
            $script:modems[0].AtPort.Name | Should -Be 'MdAt'
            $script:modems[0].Functions.Name | Should -Be @($null, 'ApLog', 'ApGnss', 'ApMeta', $null, 'MdAt', 'MdMeta', 'Npt', 'Debug')
        }

        It 'has no COM port yet' {
            $script:modems[0].Functions.PortName | Where-Object { $_ } | Should -BeNullOrEmpty
        }
    }

    Context 'on the captured 7127 modem with the AT-port driver installed' {
        BeforeAll {
            $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.driver.json" -Raw | ConvertFrom-Json
            $script:modems = @(Resolve-ModemUsbDevice -Device $fixture.Devices)
        }

        It 'finds the AT port on MI_06, working, with its COM port' {
            $script:modems.Count | Should -Be 1
            $atPort = $script:modems[0].AtPort
            $atPort.Interface | Should -Be 6
            $atPort.State | Should -Be 'Working'
            $atPort.Service | Should -Be 'usb2ser_tm'
            $atPort.PortName | Should -Be 'COM9'
        }

        It 'sees every function working, a COM port on each serial one' {
            $script:modems[0].Functions.State | Should -Be @('Working', 'Working', 'Working', 'Working', 'Working', 'Working', 'Working', 'Working', 'Working')
            $script:modems[0].Functions.PortName | Should -Be @($null, 'COM3', 'COM5', 'COM7', $null, 'COM9', 'COM4', 'COM6', 'COM8')
            $script:modems[0].Network.PortName | Should -BeNullOrEmpty
        }

        It 'names each function''s driver package: the AT port''s published as an oem INF, the network''s Windows'' own' {
            $script:modems[0].AtPort.Driver.InfPath | Should -Be 'oem24.inf'
            $script:modems[0].Network.Driver.InfPath | Should -Be 'wceisvista.inf'
        }
    }

    Context 'on the captured 7127 modem with its vendor functions on WinUSB, as the app puts them' {
        BeforeAll {
            $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.winusb.json" -Raw | ConvertFrom-Json
            $script:modems = @(Resolve-ModemUsbDevice -Device $fixture.Devices)
        }

        It 'finds the AT port on MI_06, on WinUSB with the app''s interface class, every function read' {
            $atPort = $script:modems[0].AtPort
            $atPort.WinUsb | Should -BeTrue
            $atPort.State | Should -Be 'Working'
            $atPort.InterfaceGuids | Should -Be @('{4FDE9624-2286-4DC0-9D07-601A3922581A}')
            $script:modems[0].Functions.Read | Sort-Object -Unique | Should -Be $true
        }

        It 'sees every vendor function on WinUSB, ADB on its own class, the network function on RNDIS' {
            ($script:modems[0].Functions | Where-Object Vendor).WinUsb | Sort-Object -Unique | Should -Be $true
            ($script:modems[0].Functions | Where-Object Interface -EQ 5).Vendor | Should -BeFalse
            $script:modems[0].Network.Service | Should -Be 'usbrndis6'
        }

        It 'keeps the COM port names the serial driver left in the registry, which say nothing of the driver' {
            ($script:modems[0].Functions | Where-Object Vendor).PortName | Where-Object { $_ } | Should -HaveCount 7
            (Resolve-ModemPresence -Modem $script:modems).Device | Should -Be 'Present'
        }

        It 'has nothing to put on WinUSB' {
            $presence = Resolve-ModemPresence -Modem $script:modems
            $presence.AtInstanceId | Should -BeLike 'USB\VID_0E8D&PID_7127&MI_06\*'
            $plan = Resolve-ModemBinding -Function $presence.Functions
            $plan.Bind | Should -BeNullOrEmpty
            $plan.Left | Should -BeNullOrEmpty
        }
    }
    It 'names no driver for a function without one' {
        $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.nodriver.json" -Raw | ConvertFrom-Json
        (Resolve-ModemUsbDevice -Device $fixture.Devices).AtPort.Driver | Should -BeNullOrEmpty
        (Resolve-ModemUsbDevice -Device @(ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006')).AtPort.Driver | Should -BeNullOrEmpty
    }

    It 'finds the AT port on MI_04 in composition 7126' {
        $parent = 'USB\VID_0E8D&PID_7126\7&00000000&0&2'
        $modem = Resolve-ModemUsbDevice -Device @(
            ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7126&MI_00\8&00000000&0&0000' -Service 'usbrndis6' -Parent $parent
            ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7126&MI_04\8&00000000&0&0004' -Parent $parent
            ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7126&MI_06\8&00000000&0&0006' -Parent $parent
        )
        $modem.ProductId | Should -Be '7126'
        $modem.AtPort.Interface | Should -Be 4
        $modem.Network.Interface | Should -Be 0
        $modem.Functions.Role | Should -Be @('Network', 'AtPort', 'Other')
    }

    It 'reads problem code <Code> with service ''<Service>'' as <State>' -ForEach @(
        @{ Code = 0; Service = 'usb2ser'; State = 'Working' }
        @{ Code = 0; Service = ''; State = 'NoDriver' }
        @{ Code = 1; Service = ''; State = 'NoDriver' }
        @{ Code = 28; Service = ''; State = 'NoDriver' }
        @{ Code = 10; Service = 'usb2ser'; State = 'Problem' }
        @{ Code = 22; Service = 'usb2ser'; State = 'Problem' }
    ) {
        $modem = Resolve-ModemUsbDevice -Device @(ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006' -ProblemCode $Code -Service $Service)
        $modem.AtPort.State | Should -Be $State
        $modem.AtPort.ProblemCode | Should -Be $Code
    }

    It 'tells a function it couldn''t read - never one to give another driver - from one without a driver: <Name>' -ForEach @(
        @{ Name = 'service unread'; Service = $null; Code = 0; Parameters = $true; Read = $false }
        @{ Name = 'service unread, no driver by its problem code'; Service = $null; Code = 28; Parameters = $true; Read = $true }
        @{ Name = 'registry parameters unread'; Service = 'usb2ser_tm'; Code = 0; Parameters = $false; Read = $false }
        @{ Name = 'service read as none'; Service = ''; Code = 0; Parameters = $true; Read = $true }
        @{ Name = 'everything read'; Service = 'WINUSB'; Code = 0; Parameters = $true; Read = $true }
    ) {
        $record = ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003' -ProblemCode $Code
        $record.Service = $Service
        $record | Add-Member -NotePropertyName ParametersRead -NotePropertyValue $Parameters
        (Resolve-ModemUsbDevice -Device @($record)).Functions[0].Read | Should -Be $Read
    }

    It 'reads the captured records whole' {
        foreach ($name in 'driver', 'nodriver', 'uninstalled', 'winusb') {
            $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.$name.json" -Raw | ConvertFrom-Json
            (Resolve-ModemUsbDevice -Device $fixture.Devices).Functions.Read | Sort-Object -Unique | Should -Be $true
        }
    }

    It 'leaves a function whose service couldn''t be read to the opening of its port' {
        $record = ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006'
        $record.Service = $null
        (Resolve-ModemUsbDevice -Device @($record)).AtPort.State | Should -Be 'Working'
    }

    Context 'on the captured 7127 modem right after its AT-port driver was uninstalled' {
        BeforeAll {
            $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.uninstalled.json" -Raw | ConvertFrom-Json
            $script:modems = @(Resolve-ModemUsbDevice -Device $fixture.Devices)
        }

        It 'sees the serial functions without a driver, though Windows gives them no problem code yet' {
            $atPort = $script:modems[0].AtPort
            $atPort.ProblemCode | Should -Be 0
            $atPort.Service | Should -BeNullOrEmpty
            $atPort.State | Should -Be 'NoDriver'
            $atPort.PortName | Should -BeNullOrEmpty
            $atPort.Driver | Should -BeNullOrEmpty
            @($script:modems[0].Functions | Where-Object State -EQ 'NoDriver').Interface | Should -Be @(2, 3, 4, 6, 7, 8, 9)
        }

        It 'says the AT port is not on WinUSB yet' {
            $presence = Resolve-ModemPresence -Modem $script:modems
            $presence.Device | Should -Be 'Unbound'
            $presence.ProductId | Should -Be '7127'
        }
    }

    It 'skips devices left over from an earlier plug-in' {
        $records = @(
            ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006' -Present $false
            ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000' -Present $false
        )
        Resolve-ModemUsbDevice -Device $records | Should -BeNullOrEmpty
    }

    It 'skips the composite device and other MediaTek devices' {
        $records = @(
            ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127\7&00000000&0&1' -Service 'usbccgp' -Parent 'USB\ROOT_HUB30\6&00000000&1&0'
            ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_2000\5&00000000&0&3' -Parent 'USB\ROOT_HUB30\6&00000000&1&0'
            ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7128&MI_06\8&00000000&0&0006'
        )
        Resolve-ModemUsbDevice -Device $records | Should -BeNullOrEmpty
    }

    It 'returns nothing when no modem is attached' {
        Resolve-ModemUsbDevice -Device @() | Should -BeNullOrEmpty
    }

    It 'tells two modems apart by their composite device' {
        $first = 'USB\VID_0E8D&PID_7127\7&00000000&0&1'
        $second = 'USB\VID_0E8D&PID_7127\7&00000000&0&4'
        $modems = @(Resolve-ModemUsbDevice -Device @(
                ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006' -Parent $first
                ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\9&00000000&0&0006' -Parent $second -ProblemCode 28
                ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_00\9&00000000&0&0000' -Parent $second
            ))
        $modems.Count | Should -Be 2
        ($modems | Where-Object InstanceId -EQ $first).AtPort.State | Should -Be 'Working'
        ($modems | Where-Object InstanceId -EQ $second).AtPort.State | Should -Be 'NoDriver'
        ($modems | Where-Object InstanceId -EQ $second).Functions.Count | Should -Be 2
    }

    It 'leaves the AT port empty when that function is not present' {
        $modem = Resolve-ModemUsbDevice -Device @(ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000' -Service 'usbrndis6')
        $modem.AtPort | Should -BeNullOrEmpty
        $modem.Network.State | Should -Be 'Working'
    }
}

Describe 'Resolve-ModemPresence' {
    BeforeAll {
        $script:guid = '{4FDE9624-2286-4DC0-9D07-601A3922581A}'
        # A modem as Resolve-ModemUsbDevice gives it, its AT port in a given state.
        function Get-TestModem {
            param(
                [string] $InstanceId = 'USB\VID_0E8D&PID_7127\7&00000000&0&1',
                [string] $State = 'Working',
                [bool] $WinUsb = $true,
                [string[]] $Guids = @('{4FDE9624-2286-4DC0-9D07-601A3922581A}'),
                [int] $ProblemCode = 0,
                [bool] $Read = $true,
                [switch] $NoNetwork,
                [switch] $NoAtPort
            )
            $atPort = [pscustomobject]@{
                InstanceId = "$InstanceId-at"; Role = 'AtPort'; State = $State; WinUsb = $WinUsb; InterfaceGuids = $Guids; ProblemCode = $ProblemCode; Read = $Read
                Driver = [pscustomobject]@{ InfPath = 'winusb.inf' }
            }
            [pscustomobject]@{
                InstanceId = $InstanceId
                ProductId  = '7127'
                AtPort     = if ($NoAtPort) { $null } else { $atPort }
                Network    = if ($NoNetwork) { $null } else { [pscustomobject]@{ InstanceId = "$InstanceId-net" } }
                Functions  = @($atPort)
            }
        }
    }

    It 'finds the AT port on WinUSB, with the app''s interface class, and the adapter' {
        $presence = Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device (Get-BoundFixture))
        $presence.Device | Should -Be 'Present'
        $presence.AtInstanceId | Should -BeLike 'USB\VID_0E8D&PID_7127&MI_06\*'
        $presence.AdapterInstanceId | Should -BeLike 'USB\VID_0E8D&PID_7127&MI_00\*'
        $presence.InstanceId | Should -Match '^USB\\VID_0E8D&PID_7127\\[^\\]+$' -Because 'the composite device is what R6 restarts'
        $presence.Modems | Should -Be 1
        $presence.ProductId | Should -Be '7127'
        $presence.Functions.Count | Should -Be 9
        $presence.Driver.InfPath | Should -Be 'winusb.inf'
    }

    It 'says the AT port is on another driver: MediaTek''s, with its COM port' {
        $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.driver.json" -Raw | ConvertFrom-Json
        $presence = Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device $fixture.Devices)
        $presence.Device | Should -Be 'Unbound'
        $presence.AtInstanceId | Should -BeLike 'USB\VID_0E8D&PID_7127&MI_06\*'
        $presence.Driver.InfPath | Should -Be 'oem24.inf'
    }

    It 'says the AT port is on no driver on the captured modem without it' {
        $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.nodriver.json" -Raw | ConvertFrom-Json
        $presence = Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device $fixture.Devices)
        $presence.Device | Should -Be 'Unbound'
        $presence.ProductId | Should -Be '7127'
        $presence.Driver | Should -BeNullOrEmpty
    }

    It 'names no modem, no function and no driver without a modem' {
        $presence = Resolve-ModemPresence -Modem @()
        $presence.Device | Should -Be 'Absent'
        $presence.ProductId | Should -BeNullOrEmpty
        $presence.AtInstanceId | Should -BeNullOrEmpty
        $presence.Functions | Should -BeNullOrEmpty
        $presence.Driver | Should -BeNullOrEmpty
    }

    It '<Name>: <Device>' -ForEach @(
        @{ Name = 'no modem'; Modems = @(); Device = 'Absent'; Chosen = $null }
        @{ Name = 'a modem whose AT port is not there'; Modems = @(@{ NoAtPort = $true }); Device = 'Absent'; Chosen = $null }
        @{ Name = 'on WinUSB with the app''s class'; Modems = @(@{}); Device = 'Present'; Chosen = 1 }
        @{ Name = 'the class written in another case, with spaces'; Modems = @(@{ Guids = @(' {4fde9624-2286-4dc0-9d07-601a3922581a} ') }); Device = 'Present'; Chosen = 1 }
        @{ Name = 'on WinUSB with another program''s class besides'; Modems = @(@{ Guids = @('{11111111-2222-3333-4444-555555555555}', '{4FDE9624-2286-4DC0-9D07-601A3922581A}') }); Device = 'Present'; Chosen = 1 }
        @{ Name = 'on WinUSB without the app''s class'; Modems = @(@{ Guids = @('{11111111-2222-3333-4444-555555555555}') }); Device = 'Unbound'; Chosen = 1 }
        @{ Name = 'on WinUSB with no class at all'; Modems = @(@{ Guids = $null }); Device = 'Unbound'; Chosen = 1 }
        @{ Name = 'on another driver'; Modems = @(@{ WinUsb = $false }); Device = 'Unbound'; Chosen = 1 }
        @{ Name = 'on no driver'; Modems = @(@{ WinUsb = $false; State = 'NoDriver'; ProblemCode = 28 }); Device = 'Unbound'; Chosen = 1 }
        @{ Name = 'failing on another driver'; Modems = @(@{ WinUsb = $false; State = 'Problem'; ProblemCode = 10 }); Device = 'Unbound'; Chosen = 1 }
        @{ Name = 'disabled by the user'; Modems = @(@{ WinUsb = $false; State = 'Problem'; ProblemCode = 22 }); Device = 'Problem'; Chosen = 1 }
        @{ Name = 'a problem on WinUSB'; Modems = @(@{ State = 'Problem'; ProblemCode = 10 }); Device = 'Problem'; Chosen = 1 }
        @{ Name = 'one modem not on WinUSB, one on it: the one on it'; Modems = @(@{ WinUsb = $false }, @{ InstanceId = 'USB\VID_0E8D&PID_7127\7&00000000&0&2' }); Device = 'Present'; Chosen = 2 }
        @{ Name = 'two on WinUSB: always the first by instance ID'; Modems = @(@{ InstanceId = 'USB\VID_0E8D&PID_7127\7&00000000&0&2' }, @{}); Device = 'Present'; Chosen = 1 }
        @{ Name = 'an AT port that couldn''t be read: opening its interface tells'; Modems = @(@{ WinUsb = $false; Read = $false }); Device = 'Present'; Chosen = 1 }
        @{ Name = 'none on WinUSB: the first by instance ID'; Modems = @(@{ InstanceId = 'USB\VID_0E8D&PID_7127\7&00000000&0&2'; WinUsb = $false }, @{ WinUsb = $false }); Device = 'Unbound'; Chosen = 1 }
    ) {
        $modems = @(foreach ($change in $Modems) { Get-TestModem @change })
        $presence = Resolve-ModemPresence -Modem $modems -InterfaceGuid $script:guid
        $presence.Device | Should -Be $Device
        $presence.Modems | Should -Be $modems.Count
        if ($Chosen) {
            $presence.InstanceId | Should -Be "USB\VID_0E8D&PID_7127\7&00000000&0&$Chosen"
            $presence.AtInstanceId | Should -Be "USB\VID_0E8D&PID_7127\7&00000000&0&$Chosen-at"
        }
        else {
            $presence.InstanceId | Should -BeNullOrEmpty
        }
    }

    It 'gives no adapter for a modem without its network function' {
        (Resolve-ModemPresence -Modem @(Get-TestModem -NoNetwork)).AdapterInstanceId | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-ModemBinding' {
    BeforeAll {
        $script:guid = '{4FDE9624-2286-4DC0-9D07-601A3922581A}'
        # The captured modem's functions, as Resolve-ModemPresence gives them.
        function Get-FixtureFunction {
            param([string] $Name)
            $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.$Name.json" -Raw | ConvertFrom-Json
            (Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device $fixture.Devices)).Functions
        }
        function Get-TestFunction {
            param([int] $Interface = 6, [string] $Role = 'AtPort', [bool] $Vendor = $true, [bool] $WinUsb = $false, [string] $State = 'Working',
                [int] $ProblemCode = 0, [string[]] $Guids, [string] $PortName = 'COM14', [bool] $Read = $true)
            [pscustomobject]@{
                InstanceId = "USB\VID_0E8D&PID_7127&MI_0$Interface\8&00000000&0&000$Interface"; Interface = $Interface; Role = $Role; Name = "Name$Interface"
                Vendor = $Vendor; WinUsb = $WinUsb; State = $State; ProblemCode = $ProblemCode; InterfaceGuids = $Guids; PortName = $PortName; Read = $Read
            }
        }
    }

    It 'puts every vendor function of the captured modem on WinUSB, the AT port first, never the network one nor ADB' {
        $plan = Resolve-ModemBinding -Function (Get-FixtureFunction -Name driver) -InterfaceGuid $script:guid
        $plan.Bind.Interface | Should -Be @(6, 2, 3, 4, 7, 8, 9)
        $plan.Bind[0].Role | Should -Be 'AtPort'
        $plan.Bind.Why | Sort-Object -Unique | Should -Be 'OtherDriver'
        $plan.Bind[0].PortName | Should -Be 'COM9' -Because 'a COM port held by another program is left alone'
        $plan.Left | Should -BeNullOrEmpty
    }

    It 'puts the functions without a driver on WinUSB too' {
        $plan = Resolve-ModemBinding -Function (Get-FixtureFunction -Name nodriver) -InterfaceGuid $script:guid
        $plan.Bind.Interface | Should -Be @(6, 2, 3, 4, 7, 8, 9)
        $plan.Bind.Why | Sort-Object -Unique | Should -Be 'NoDriver'
        $plan.Bind.PortName | Where-Object { $_ } | Should -BeNullOrEmpty
    }

    It 'puts the functions whose driver was just uninstalled on WinUSB too' {
        (Resolve-ModemBinding -Function (Get-FixtureFunction -Name uninstalled) -InterfaceGuid $script:guid).Bind.Interface | Should -Be @(6, 2, 3, 4, 7, 8, 9)
    }

    It 'has nothing to do once they are on it' {
        $presence = Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device (Get-BoundFixture))
        $plan = Resolve-ModemBinding -Function $presence.Functions -InterfaceGuid $script:guid
        $plan.Bind | Should -BeNullOrEmpty
        $plan.Left | Should -BeNullOrEmpty
    }

    It '<Name>' -ForEach @(
        @{ Name = 'the AT port on WinUSB without the app''s class: given it'; Function = @{ WinUsb = $true; Guids = @('{11111111-2222-3333-4444-555555555555}') }; Bind = 'NoInterface'; Left = $null }
        @{ Name = 'the AT port on WinUSB with no class: given it'; Function = @{ WinUsb = $true }; Bind = 'NoInterface'; Left = $null }
        @{ Name = 'another vendor function on WinUSB with no class: as it is'; Function = @{ Interface = 3; Role = 'Other'; WinUsb = $true }; Bind = $null; Left = $null }
        @{ Name = 'a function disabled by the user: left'; Function = @{ State = 'Problem'; ProblemCode = 22 }; Bind = $null; Left = 'Disabled' }
        @{ Name = 'a problem on WinUSB: left'; Function = @{ WinUsb = $true; Guids = @('{4FDE9624-2286-4DC0-9D07-601A3922581A}'); State = 'Problem'; ProblemCode = 10 }; Bind = $null; Left = 'Problem' }
        @{ Name = 'a driver failing to start: put on WinUSB'; Function = @{ State = 'Problem'; ProblemCode = 10 }; Bind = 'OtherDriver'; Left = $null }
        @{ Name = 'the AT port that couldn''t be read: left, never taken for another driver'; Function = @{ Read = $false }; Bind = $null; Left = 'Unread' }
        @{ Name = 'another function that couldn''t be read, though it reads as disabled: left'; Function = @{ Interface = 3; Role = 'Other'; Read = $false; State = 'Problem'; ProblemCode = 22 }; Bind = $null; Left = 'Unread' }
        @{ Name = 'the network function: never'; Function = @{ Interface = 0; Role = 'Network'; Vendor = $false }; Bind = $null; Left = $null }
        @{ Name = 'a function that is no vendor one (ADB): never'; Function = @{ Interface = 5; Role = 'Other'; Vendor = $false }; Bind = $null; Left = $null }
        @{ Name = 'the network function, even marked vendor: never'; Function = @{ Interface = 0; Role = 'Network'; Vendor = $true }; Bind = $null; Left = $null }
    ) {
        $function = Get-TestFunction @Function
        $plan = Resolve-ModemBinding -Function @($function) -InterfaceGuid $script:guid
        if ($Bind) {
            $plan.Bind.Count | Should -Be 1
            $plan.Bind[0].Why | Should -Be $Bind
        }
        else {
            $plan.Bind | Should -BeNullOrEmpty
        }
        if ($Left) {
            $plan.Left[0].Why | Should -Be $Left
        }
        else {
            $plan.Left | Should -BeNullOrEmpty
        }
    }

    It 'tries a function once per instance: one that failed is left, a new instance is tried' {
        $failed = Get-TestFunction
        $again = Get-TestFunction -Interface 3 -Role 'Other'
        $plan = Resolve-ModemBinding -Function @($failed, $again) -InterfaceGuid $script:guid -Failed @($failed.InstanceId.ToLowerInvariant())
        $plan.Bind.Interface | Should -Be @(3)
        $plan.Left.Interface | Should -Be @(6)
        $plan.Left[0].Why | Should -Be 'Failed'
    }

    It 'has nothing to do without functions' {
        $plan = Resolve-ModemBinding -Function @() -InterfaceGuid $script:guid
        $plan.Bind | Should -BeNullOrEmpty
        $plan.Left | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-ModemRestore' {
    BeforeAll {
        function Get-FixtureModem {
            param([string] $Name)
            $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.$Name.json" -Raw | ConvertFrom-Json
            @(Resolve-ModemUsbDevice -Device $fixture.Devices)
        }
    }

    It 'gives back every vendor function on WinUSB, the AT port first, never the network function nor ADB' {
        $functions = @(Resolve-ModemRestore -Modem (Get-FixtureModem -Name winusb))
        $functions.Interface | Should -Be @(6, 2, 3, 4, 7, 8, 9)
        $functions[0].Role | Should -Be 'AtPort'
        $functions[0].InterfaceGuids | Should -Be @('{4FDE9624-2286-4DC0-9D07-601A3922581A}')
    }

    It 'has nothing to give back on <_>' -ForEach @('driver', 'nodriver', 'uninstalled') {
        Resolve-ModemRestore -Modem (Get-FixtureModem -Name $_) | Should -BeNullOrEmpty
    }

    It 'gives back the functions of every modem present, not only the one the app uses' {
        $first = 'USB\VID_0E8D&PID_7127\7&00000000&0&1'
        $second = 'USB\VID_0E8D&PID_7127\7&00000000&0&2'
        $modems = @(Resolve-ModemUsbDevice -Device @(
                ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&1&0006' -Service 'WINUSB' -Parent $first -DriverInfPath 'winusb.inf'
                ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&2&0003' -Service 'WINUSB' -Parent $second -DriverInfPath 'winusb.inf'
                ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&2&0000' -Service 'WINUSB' -Parent $second -CompatibleIds @('USB\Class_ff&SubClass_00&Prot_00') -DriverInfPath 'winusb.inf'
            ))
        (Resolve-ModemRestore -Modem $modems).Interface | Should -Be @(6, 3)
    }

    It 'leaves a function it couldn''t read' {
        $record = ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003' -Service 'WINUSB' -DriverInfPath 'winusb.inf'
        $record | Add-Member -NotePropertyName ParametersRead -NotePropertyValue $false
        Resolve-ModemRestore -Modem @(Resolve-ModemUsbDevice -Device @($record)) | Should -BeNullOrEmpty
    }

    It 'leaves a function on WinUSB from <Inf>: not the app''s to give back' -ForEach @(
        @{ Inf = 'oem42.inf' }
        @{ Inf = '' }
    ) {
        $record = ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003' -Service 'WINUSB' -DriverInfPath $Inf
        Resolve-ModemRestore -Modem @(Resolve-ModemUsbDevice -Device @($record)) | Should -BeNullOrEmpty
    }

    It 'gives back a function on winusb.inf whatever its case' {
        $record = ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003' -Service 'WINUSB' -DriverInfPath 'WINUSB.INF'
        (Resolve-ModemRestore -Modem @(Resolve-ModemUsbDevice -Device @($record))).Interface | Should -Be 3
    }

    It 'has nothing to give back without a modem' {
        Resolve-ModemRestore -Modem @() | Should -BeNullOrEmpty
    }
}

Describe 'Select-AbsentWinUsbFunction' {
    It 'picks <Count> for <Case>' -ForEach @(
        @{ Case = 'an absent vendor function on winusb.inf'; Count = 1; Id = 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003'; Present = $false; Service = 'WINUSB'; Inf = 'winusb.inf'; Compat = @('USB\Class_ff&SubClass_00&Prot_00') }
        @{ Case = 'an absent AT port of the 7126 composition'; Count = 1; Id = 'USB\VID_0E8D&PID_7126&MI_04\8&00000000&0&0004'; Present = $false; Service = 'WINUSB'; Inf = 'winusb.inf'; Compat = @() }
        @{ Case = 'a present one: given back'; Count = 0; Id = 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003'; Present = $true; Service = 'WINUSB'; Inf = 'winusb.inf'; Compat = @('USB\Class_ff&SubClass_00&Prot_00') }
        @{ Case = 'the network function'; Count = 0; Id = 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000'; Present = $false; Service = 'WINUSB'; Inf = 'winusb.inf'; Compat = @('USB\Class_ff&SubClass_00&Prot_00') }
        @{ Case = 'ADB, which Windows puts on WinUSB'; Count = 0; Id = 'USB\VID_0E8D&PID_7127&MI_05\8&00000000&0&0005'; Present = $false; Service = 'WINUSB'; Inf = 'winusb.inf'; Compat = @('USB\Class_ff&SubClass_42&Prot_01') }
        @{ Case = 'another tool''s INF'; Count = 0; Id = 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003'; Present = $false; Service = 'WINUSB'; Inf = 'oem42.inf'; Compat = @('USB\Class_ff&SubClass_00&Prot_00') }
        @{ Case = 'MediaTek''s driver'; Count = 0; Id = 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003'; Present = $false; Service = 'usb2ser_tm'; Inf = 'oem10.inf'; Compat = @('USB\Class_ff&SubClass_00&Prot_00') }
        @{ Case = 'another MediaTek device'; Count = 0; Id = 'USB\VID_0E8D&PID_2000&MI_03\8&00000000&0&0003'; Present = $false; Service = 'WINUSB'; Inf = 'winusb.inf'; Compat = @('USB\Class_ff&SubClass_00&Prot_00') }
    ) {
        $record = ConvertTo-PnpRecord -InstanceId $Id -Present $Present -Service $Service -DriverInfPath $Inf -CompatibleIds $Compat
        @(Select-AbsentWinUsbFunction -Device @($record)).Count | Should -Be $Count
    }

    It 'picks every absent one, each with its instance and its name, and none without records' {
        $records = foreach ($interface in '02', '03', '06') {
            ConvertTo-PnpRecord -InstanceId "USB\VID_0E8D&PID_7127&MI_$interface\8&00000000&0&00$interface" -Present $false -Service 'WINUSB' -DriverInfPath 'winusb.inf'
        }
        $picked = @(Select-AbsentWinUsbFunction -Device @($records))
        $picked.Interface | Should -Be @(2, 3, 6)
        $picked.Name | Should -Be @('ApLog', 'ApGnss', 'MdAt')
        $picked[2].InstanceId | Should -Be 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006'
        Select-AbsentWinUsbFunction -Device @() | Should -BeNullOrEmpty
    }
}

Describe 'Select-UnreadModemFunction' {
    It 'picks <Count> for <Case>' -ForEach @(
        @{ Case = 'a function whose service couldn''t be read'; Count = 1; Id = 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003'; Present = $true; Service = $null; Parameters = $true; Problem = 0 }
        @{ Case = 'a function whose registry parameters couldn''t be read'; Count = 1; Id = 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006'; Present = $true; Service = 'WINUSB'; Parameters = $false; Problem = 0 }
        @{ Case = 'one not plugged in whose service couldn''t be read'; Count = 1; Id = 'USB\VID_0E8D&PID_7127&MI_02\8&00000000&0&0002'; Present = $false; Service = $null; Parameters = $true; Problem = 0 }
        @{ Case = 'the AT port of the 7126 composition, unread'; Count = 1; Id = 'USB\VID_0E8D&PID_7126&MI_04\8&00000000&0&0004'; Present = $true; Service = $null; Parameters = $true; Problem = 0 }
        @{ Case = 'one read whole'; Count = 0; Id = 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003'; Present = $true; Service = 'WINUSB'; Parameters = $true; Problem = 0 }
        @{ Case = 'one not plugged in, its parameters not read'; Count = 0; Id = 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003'; Present = $false; Service = 'WINUSB'; Parameters = $false; Problem = 0 }
        @{ Case = 'one with no driver by its problem code'; Count = 0; Id = 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003'; Present = $true; Service = $null; Parameters = $false; Problem = 28 }
        @{ Case = 'the network function'; Count = 0; Id = 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000'; Present = $true; Service = $null; Parameters = $true; Problem = 0 }
        @{ Case = 'ADB'; Count = 0; Id = 'USB\VID_0E8D&PID_7127&MI_05\8&00000000&0&0005'; Present = $true; Service = $null; Parameters = $true; Problem = 0 }
        @{ Case = 'another MediaTek device'; Count = 0; Id = 'USB\VID_0E8D&PID_2000&MI_03\8&00000000&0&0003'; Present = $true; Service = $null; Parameters = $true; Problem = 0 }
    ) {
        $record = [pscustomobject]@{ InstanceId = $Id; Present = $Present; ProblemCode = $Problem; Service = $Service; ParametersRead = $Parameters }
        @(Select-UnreadModemFunction -Device @($record)).Count | Should -Be $Count
    }

    It 'gives each its interface, name, role and presence' {
        $record = [pscustomobject]@{ InstanceId = 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006'; Present = $true; ProblemCode = 0; Service = $null; ParametersRead = $true }
        $picked = Select-UnreadModemFunction -Device @($record)
        $picked.Interface | Should -Be 6
        $picked.Name | Should -Be 'MdAt'
        $picked.Role | Should -Be 'AtPort'
        $picked.Present | Should -BeTrue
        Select-UnreadModemFunction -Device @() | Should -BeNullOrEmpty
    }
}

Describe 'Restart-ModemUsbDevice' {
    It 'restarts nothing but an FM350 composite device: <InstanceId>' -ForEach @(
        @{ InstanceId = 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&1&0006' }
        @{ InstanceId = 'USB\VID_8087&PID_0026\5&1&0&14' }
        @{ InstanceId = 'PCI\VEN_14C3&DEV_4D75\4&1&0&00E8' }
        @{ InstanceId = 'USB\VID_0E8D&PID_7127\7&1&0&1\extra' }
    ) {
        { Restart-ModemUsbDevice -InstanceId $InstanceId -WhatIf -ErrorAction Stop } | Should -Throw
    }

    It 'runs nothing with -WhatIf' {
        Restart-ModemUsbDevice -InstanceId 'USB\VID_0E8D&PID_7127\7&00000000&0&1' -WhatIf | Should -BeNullOrEmpty
    }
}

Describe 'Get-ModemPnpRecord' {
    BeforeAll {
        $script:composite = 'USB\VID_0E8D&PID_7127\7&00000000&0&1'
        $script:atPortId = 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006'
        $script:networkId = 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000'
        $script:leftoverId = 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0009'
    }

    BeforeEach {
        Mock -ModuleName FibocomFm350 Get-PnpDevice {
            [pscustomobject]@{ InstanceId = $script:composite; Present = $true }
            [pscustomobject]@{ InstanceId = $script:atPortId; Present = $true }
            [pscustomobject]@{ InstanceId = $script:networkId; Present = $true }
            [pscustomobject]@{ InstanceId = $script:leftoverId; Present = $false }
        }
        Mock -ModuleName FibocomFm350 Get-PnpDeviceProperty -RemoveParameterType InputObject {
            foreach ($device in $InputObject) {
                $service = switch ($device.InstanceId) {
                    $script:networkId { 'usbrndis6' }
                    $script:composite { 'usbccgp' }
                    default { 'usb2ser' }
                }
                $values = @{
                    DEVPKEY_Device_ProblemCode    = 0
                    DEVPKEY_Device_Service        = $service
                    DEVPKEY_Device_Parent         = if ($device.InstanceId -eq $script:composite) { 'USB\ROOT_HUB30\6&00000000&1&0' } else { $script:composite }
                    DEVPKEY_Device_CompatibleIds  = if ($device.InstanceId -eq $script:atPortId) { [string[]]@('USB\COMPAT_VID_0e8d&Class_ff&SubClass_00&Prot_00', 'USB\Class_ff&SubClass_00&Prot_00') } else { $null }
                    DEVPKEY_Device_DriverInfPath  = if ($service -eq 'usb2ser') { 'oem24.inf' } else { $null }
                    DEVPKEY_Device_DriverVersion  = if ($service -eq 'usb2ser') { '3.22.43.1' } else { $null }
                    DEVPKEY_Device_DriverProvider = if ($service -eq 'usb2ser') { 'MediaTek' } else { $null }
                }
                # As the cmdlet does, a key without a value comes back without Data.
                foreach ($key in $KeyName) {
                    if ($null -eq $values[$key]) {
                        [pscustomobject]@{ InstanceId = $device.InstanceId; KeyName = $key; Type = 'Empty' }
                    }
                    else {
                        [pscustomobject]@{ InstanceId = $device.InstanceId; KeyName = $key; Data = $values[$key] }
                    }
                }
            }
        }
        Mock -ModuleName FibocomFm350 Get-ItemProperty { [pscustomobject]@{ PortName = 'COM9' } } -ParameterFilter { $LiteralPath -like '*MI_06*' }
        Mock -ModuleName FibocomFm350 Get-ItemProperty { [pscustomobject]@{ Other = 1 } } -ParameterFilter { $LiteralPath -notlike '*MI_06*' }
    }

    It 'reads the present devices, one property call each, given the device object' {
        $records = @(Get-ModemPnpRecord)
        $records.InstanceId | Should -Be @($script:composite, $script:atPortId, $script:networkId)
        Should -Invoke -ModuleName FibocomFm350 Get-PnpDeviceProperty -Times 3 -Exactly -ParameterFilter { @($InputObject).Count -eq 1 }
    }

    It 'ignores properties labelled with another device''s instance ID' {
        Mock -ModuleName FibocomFm350 Get-PnpDeviceProperty -RemoveParameterType InputObject {
            foreach ($key in $KeyName) {
                [pscustomobject]@{ InstanceId = $script:atPortId; KeyName = $key; Data = $(if ($key -like '*ProblemCode') { 0 } else { 'wrong' }) }
            }
        }
        $network = Get-ModemPnpRecord | Where-Object InstanceId -EQ $script:networkId
        $network.Parent | Should -BeNullOrEmpty
        $network.Service | Should -BeNullOrEmpty
    }

    It 'gives Resolve-ModemUsbDevice what it takes: the AT port on its COM port, the network function' {
        $modem = Resolve-ModemUsbDevice -Device @(Get-ModemPnpRecord)
        $modem.InstanceId | Should -Be $script:composite
        $modem.AtPort.PortName | Should -Be 'COM9'
        $modem.AtPort.State | Should -Be 'Working'
        $modem.Network.InstanceId | Should -Be $script:networkId
        $modem.Network.PortName | Should -BeNullOrEmpty
    }

    It 'reads each device''s driver package, version and provider in the same call' {
        $atPort = Get-ModemPnpRecord | Where-Object InstanceId -EQ $script:atPortId
        $atPort.DriverInfPath | Should -Be 'oem24.inf'
        $atPort.DriverVersion | Should -Be '3.22.43.1'
        $atPort.DriverProvider | Should -Be 'MediaTek'
        (Resolve-ModemUsbDevice -Device @(Get-ModemPnpRecord)).AtPort.Driver.Version | Should -Be '3.22.43.1'
        Should -Invoke -ModuleName FibocomFm350 Get-PnpDeviceProperty -ParameterFilter { 'DEVPKEY_Device_DriverInfPath' -in $KeyName -and 'DEVPKEY_Device_ProblemCode' -in $KeyName }
    }

    It 'tells a service read as none - a driver uninstalled - from one that couldn''t be read' {
        # The AT port's service comes back without a value; the network function's properties not at all.
        Mock -ModuleName FibocomFm350 Get-PnpDeviceProperty -RemoveParameterType InputObject {
            foreach ($device in $InputObject) {
                if ($device.InstanceId -eq $script:atPortId) {
                    [pscustomobject]@{ InstanceId = $device.InstanceId; KeyName = 'DEVPKEY_Device_ProblemCode'; Data = 0 }
                    [pscustomobject]@{ InstanceId = $device.InstanceId; KeyName = 'DEVPKEY_Device_Parent'; Data = $script:composite }
                    [pscustomobject]@{ InstanceId = $device.InstanceId; KeyName = 'DEVPKEY_Device_Service'; Type = 'Empty' }
                }
                elseif ($device.InstanceId -eq $script:composite) {
                    [pscustomobject]@{ InstanceId = $device.InstanceId; KeyName = 'DEVPKEY_Device_Service'; Data = 'usbccgp' }
                }
            }
        }
        $records = @(Get-ModemPnpRecord)
        ($records | Where-Object InstanceId -EQ $script:atPortId).Service | Should -BeExactly ''
        ($records | Where-Object InstanceId -EQ $script:networkId).Service | Should -BeNullOrEmpty
        $null -eq ($records | Where-Object InstanceId -EQ $script:networkId).Service | Should -BeTrue
        (Resolve-ModemUsbDevice -Device $records).AtPort.State | Should -Be 'NoDriver'
    }

    It 'reads each device''s compatible IDs: the AT port a vendor function' {
        $atPort = Get-ModemPnpRecord | Where-Object InstanceId -EQ $script:atPortId
        $atPort.CompatibleIds | Should -Contain 'USB\Class_ff&SubClass_00&Prot_00'
        (Resolve-ModemUsbDevice -Device @(Get-ModemPnpRecord)).AtPort.Vendor | Should -BeTrue
        Should -Invoke -ModuleName FibocomFm350 Get-PnpDeviceProperty -ParameterFilter { 'DEVPKEY_Device_CompatibleIds' -in $KeyName }
    }

    It 'reads a function''s device interface classes from its registry parameters' {
        Mock -ModuleName FibocomFm350 Get-ItemProperty { [pscustomobject]@{ DeviceInterfaceGUIDs = [string[]]@('{4FDE9624-2286-4DC0-9D07-601A3922581A}') } } -ParameterFilter { $LiteralPath -like '*MI_06*' }
        $atPort = Get-ModemPnpRecord | Where-Object InstanceId -EQ $script:atPortId
        $atPort.InterfaceGuids | Should -Be @('{4FDE9624-2286-4DC0-9D07-601A3922581A}')
        $atPort.PortName | Should -BeNullOrEmpty
        (Get-ModemPnpRecord | Where-Object InstanceId -EQ $script:networkId).InterfaceGuids | Should -BeNullOrEmpty
    }

    It 'tells registry parameters it couldn''t read from a key that isn''t there' {
        Mock -ModuleName FibocomFm350 Get-ItemProperty { Write-Error -Exception ([System.UnauthorizedAccessException]::new('denied')) -ErrorAction SilentlyContinue } -ParameterFilter { $LiteralPath -like '*MI_06*' }
        Mock -ModuleName FibocomFm350 Get-ItemProperty { Write-Error -Exception ([System.Management.Automation.ItemNotFoundException]::new('no key')) -ErrorAction SilentlyContinue } -ParameterFilter { $LiteralPath -notlike '*MI_06*' }
        $records = @(Get-ModemPnpRecord)
        ($records | Where-Object InstanceId -EQ $script:atPortId).ParametersRead | Should -BeFalse
        ($records | Where-Object InstanceId -EQ $script:networkId).ParametersRead | Should -BeTrue
        (Resolve-ModemUsbDevice -Device $records).AtPort.Read | Should -BeFalse
    }

    It 'reads nothing more when no MediaTek device is present' {
        Mock -ModuleName FibocomFm350 Get-PnpDevice { }
        Get-ModemPnpRecord | Should -BeNullOrEmpty
        Should -Invoke -ModuleName FibocomFm350 Get-PnpDeviceProperty -Times 0 -Exactly
    }

    It 'reads too the devices Windows remembers but that aren''t plugged in, with -IncludeAbsent' {
        $records = @(Get-ModemPnpRecord -IncludeAbsent)
        $records.InstanceId | Should -Be @($script:composite, $script:atPortId, $script:networkId, $script:leftoverId)
        ($records | Where-Object InstanceId -EQ $script:leftoverId).Present | Should -BeFalse
        ($records | Where-Object InstanceId -EQ $script:atPortId).Present | Should -BeTrue
    }

    Context 'when PnP can''t be read' {
        It 'finds nothing, or throws with -Strict' {
            Mock -ModuleName FibocomFm350 Get-PnpDevice { Write-Error -Message 'WMI down' -Category ResourceUnavailable -ErrorAction SilentlyContinue }
            Get-ModemPnpRecord | Should -BeNullOrEmpty
            { Get-ModemPnpRecord -Strict } | Should -Throw '*WMI down*'
        }

        It 'takes "nothing matched" for no MediaTek device, -Strict too' {
            Mock -ModuleName FibocomFm350 Get-PnpDevice { Write-Error -Message 'No matching objects' -Category ObjectNotFound -ErrorAction SilentlyContinue }
            Get-ModemPnpRecord -Strict | Should -BeNullOrEmpty
        }
    }
}

# Reads PnP only: it doesn't open the AT port, so it may run while this app holds it.
Describe 'PnP records of a real FM350' -Tag Hardware -Skip:(-not $script:hardware) {
    It 'finds the AT port on WinUSB with the app''s interface class, and the network function on RNDIS' {
        $modem = @(Resolve-ModemUsbDevice -Device @(Get-ModemPnpRecord))
        $modem.Count | Should -Be 1
        $modem[0].AtPort.State | Should -Be 'Working'
        $modem[0].AtPort.WinUsb | Should -BeTrue
        $modem[0].Network.State | Should -Be 'Working'
        $modem[0].Network.WinUsb | Should -BeFalse
        (Resolve-ModemPresence -Modem $modem).Device | Should -Be 'Present'
        @(Get-WinUsbInterfacePath -InstanceId $modem[0].AtPort.InstanceId).Count | Should -Be 1
    }
}

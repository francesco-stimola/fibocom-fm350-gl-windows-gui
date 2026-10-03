# The modem's USB functions: which is the AT port, which the network adapter, and their driver
# state: on a captured PnP snapshot and on a matrix of made-up ones. Reading the PnP records:
# with PnP mocked, and on a real FM350 (Hardware, read-only).

BeforeDiscovery {
    $script:atPort = $env:FM350_AT_PORT
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
            [string] $Parent = 'USB\VID_0E8D&PID_7127\7&00000000&0&1'
        )
        [pscustomobject]@{ InstanceId = $InstanceId; Present = $Present; ProblemCode = $ProblemCode; Service = $Service; Parent = $Parent }
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

        It 'says the driver is missing' {
            $presence = Resolve-ModemPresence -Modem $script:modems
            $presence.Device | Should -Be 'NoDriver'
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
        # A modem as Resolve-ModemUsbDevice gives it, its AT port in a given state.
        function Get-TestModem {
            param([string] $InstanceId = 'USB\VID_0E8D&PID_7127\7&00000000&0&1', [string] $State = 'Working', [string] $PortName = 'COM14', [switch] $NoNetwork, [switch] $NoAtPort)
            [pscustomobject]@{
                InstanceId = $InstanceId
                AtPort     = if ($NoAtPort) { $null } else { [pscustomobject]@{ State = $State; PortName = $PortName } }
                Network    = if ($NoNetwork) { $null } else { [pscustomobject]@{ InstanceId = "$InstanceId-net" } }
            }
        }
    }

    It 'finds the AT port and the adapter of the captured modem with its driver' {
        $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.driver.json" -Raw | ConvertFrom-Json
        $presence = Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device $fixture.Devices)
        $presence.Device | Should -Be 'Present'
        $presence.PortName | Should -Be 'COM9'
        $presence.AdapterInstanceId | Should -BeLike 'USB\VID_0E8D&PID_7127&MI_00\*'
        $presence.InstanceId | Should -Match '^USB\\VID_0E8D&PID_7127\\[^\\]+$' -Because 'the composite device is what R6 restarts'
        $presence.Modems | Should -Be 1
        $presence.ProductId | Should -Be '7127'
        $presence.Driver.InfPath | Should -Be 'oem24.inf'
    }

    It 'says the driver is missing on the captured modem without it, and which composition needs it' {
        $fixture = Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.nodriver.json" -Raw | ConvertFrom-Json
        $presence = Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device $fixture.Devices)
        $presence.Device | Should -Be 'NoDriver'
        $presence.PortName | Should -BeNullOrEmpty
        $presence.ProductId | Should -Be '7127'
        $presence.Driver | Should -BeNullOrEmpty
    }

    It 'names no composition and no driver without a modem' {
        $presence = Resolve-ModemPresence -Modem @()
        $presence.ProductId | Should -BeNullOrEmpty
        $presence.Driver | Should -BeNullOrEmpty
    }

    It '<Name>: <Device>' -ForEach @(
        @{ Name = 'no modem'; Modems = @(); Device = 'Absent'; PortName = $null }
        @{ Name = 'a modem whose AT port is not there'; Modems = @(@{ NoAtPort = $true }); Device = 'Absent'; PortName = $null }
        @{ Name = 'an AT port with another problem'; Modems = @(@{ State = 'Problem' }); Device = 'Problem'; PortName = $null }
        @{ Name = 'an AT port that has no COM port'; Modems = @(@{ PortName = '' }); Device = 'Problem'; PortName = $null }
        @{ Name = 'back under another COM number'; Modems = @(@{ PortName = 'COM15' }); Device = 'Present'; PortName = 'COM15' }
        @{ Name = 'one modem without its driver, one working'; Modems = @(@{ InstanceId = 'USB\VID_0E8D&PID_7127\7&00000000&0&2'; State = 'NoDriver'; PortName = '' }, @{}); Device = 'Present'; PortName = 'COM14' }
        @{ Name = 'two working modems: always the first by instance ID'; Modems = @(@{ InstanceId = 'USB\VID_0E8D&PID_7127\7&00000000&0&2'; PortName = 'COM20' }, @{}); Device = 'Present'; PortName = 'COM14' }
    ) {
        $modems = @(foreach ($change in $Modems) { Get-TestModem @change })
        $presence = Resolve-ModemPresence -Modem $modems
        $presence.Device | Should -Be $Device
        $presence.PortName | Should -Be $PortName
        $presence.Modems | Should -Be $modems.Count
        if ($Device -eq 'Present') {
            $presence.InstanceId | Should -Be 'USB\VID_0E8D&PID_7127\7&00000000&0&1'
        }
        else {
            $presence.InstanceId | Should -BeNullOrEmpty
        }
    }

    It 'gives no adapter for a modem without its network function' {
        (Resolve-ModemPresence -Modem @(Get-TestModem -NoNetwork)).AdapterInstanceId | Should -BeNullOrEmpty
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

    It 'reads nothing more when no MediaTek device is present' {
        Mock -ModuleName FibocomFm350 Get-PnpDevice { }
        Get-ModemPnpRecord | Should -BeNullOrEmpty
        Should -Invoke -ModuleName FibocomFm350 Get-PnpDeviceProperty -Times 0 -Exactly
    }
}

# Reads PnP only: it doesn't open the AT port, so it may run while this app holds it.
Describe 'PnP records of a real FM350' -Tag Hardware -Skip:(-not $script:atPort) {
    It 'finds the AT port on the COM port named in FM350_AT_PORT, and the network function' {
        $modem = @(Resolve-ModemUsbDevice -Device @(Get-ModemPnpRecord))
        $modem.Count | Should -Be 1
        $modem[0].AtPort.State | Should -Be 'Working'
        $modem[0].AtPort.PortName | Should -Be $env:FM350_AT_PORT
        $modem[0].Network.State | Should -Be 'Working'
    }
}

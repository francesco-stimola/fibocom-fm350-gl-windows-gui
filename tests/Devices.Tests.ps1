# The modem's USB functions: which is the AT port, which the network adapter, and their driver
# state: on a captured PnP snapshot and on a matrix of made-up ones.

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

    It 'reads problem code <Code> as <State>' -ForEach @(
        @{ Code = 0; State = 'Working' }
        @{ Code = 1; State = 'NoDriver' }
        @{ Code = 28; State = 'NoDriver' }
        @{ Code = 10; State = 'Problem' }
        @{ Code = 22; State = 'Problem' }
    ) {
        $modem = Resolve-ModemUsbDevice -Device @(ConvertTo-PnpRecord -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006' -ProblemCode $Code)
        $modem.AtPort.State | Should -Be $State
        $modem.AtPort.ProblemCode | Should -Be $Code
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

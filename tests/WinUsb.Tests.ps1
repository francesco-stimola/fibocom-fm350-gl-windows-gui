# The Windows calls behind WinUSB, from what can be tried without a modem and without changing
# anything: an interface or a port that isn't there, the checks that keep the network function and
# other devices out of a driver installation, and the wait for an installation run on the pool.
# Installing a driver is never run here: the device sessions do that, on purpose.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Get-WinUsbInterfacePath' {
    It 'finds nothing for a device that isn''t there' {
        Get-WinUsbInterfacePath -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006' | Should -BeNullOrEmpty
    }
}

Describe 'Test-UsbFunctionFree' {
    It 'finds free a port and interfaces that aren''t there' {
        $check = Test-UsbFunctionFree -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006' -PortName 'COM250' -InterfaceGuid @('{4FDE9624-2286-4DC0-9D07-601A3922581A}')
        $check.Free | Should -BeTrue
        $check.Held | Should -BeNullOrEmpty
    }

    It 'skips a class that is no GUID' {
        (Test-UsbFunctionFree -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006' -InterfaceGuid @('not a guid', '')).Free | Should -BeTrue
    }
}

Describe 'Install-WinUsbDriver and Restore-UsbFunctionDriver' {
    It 'never take <InstanceId>' -ForEach @(
        @{ InstanceId = 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000' }
        @{ InstanceId = 'USB\VID_0E8D&PID_7127&MI_01\8&00000000&0&0001' }
        @{ InstanceId = 'USB\VID_0E8D&PID_7127\7&00000000&0&1' }
        @{ InstanceId = 'USB\VID_0E8D&PID_7128&MI_06\8&00000000&0&0006' }
        @{ InstanceId = 'USB\VID_8087&PID_0026&MI_06\5&1&0&14' }
        @{ InstanceId = 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006\extra' }
    ) {
        { Install-WinUsbDriver -InstanceId $InstanceId -WhatIf -ErrorAction Stop } | Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
        { Restore-UsbFunctionDriver -InstanceId $InstanceId -WhatIf -ErrorAction Stop } | Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
    }

    It 'change nothing with -WhatIf' {
        Install-WinUsbDriver -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006' -WhatIf | Should -BeNullOrEmpty
        Restore-UsbFunctionDriver -InstanceId 'USB\VID_0E8D&PID_7126&MI_04\8&00000000&0&0004' -WhatIf | Should -BeNullOrEmpty
    }

    It 'refuse the network function in the code that calls Windows too' {
        { [FibocomFm350.UsbDriverBinding]::InstallWinUsb('USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000', 'x', 'x', 'x', $null) } | Should -Throw
        { [FibocomFm350.UsbDriverBinding]::Restore('USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000', $null) } | Should -Throw
    }
}

Describe 'Waiting for an installation run on the pool' {
    It 'gives the outcome of one that ended' {
        InModuleScope FibocomFm350 {
            $done = [FibocomFm350.UsbBindingResult]::new()
            $done.Done = $true
            $done.NeedReboot = $true
            $done.Step = 'Install'
            $result = Wait-UsbBindingTask -Task ([System.Threading.Tasks.Task]::FromResult($done)) -TimeoutMs 1000
            $result.Done | Should -BeTrue
            $result.NeedReboot | Should -BeTrue
            $result.Step | Should -Be 'Install'
        }
    }

    It 'says an installation that threw, by its step' {
        InModuleScope FibocomFm350 {
            $failed = [System.Threading.Tasks.Task]::FromException([System.ArgumentException]::new('no'))
            $result = Wait-UsbBindingTask -Task $failed -TimeoutMs 1000
            $result.Done | Should -BeFalse
            $result.Step | Should -Be 'Exception'
        }
    }

    It 'gives up after its time, the heartbeat beating meanwhile' {
        InModuleScope FibocomFm350 {
            $script:beats = 0
            $result = Wait-UsbBindingTask -Task ([System.Threading.Tasks.Task]::Delay(30000)) -TimeoutMs 2500 -Beat { $script:beats++ }
            $result.Done | Should -BeFalse
            $result.Step | Should -Be 'TimedOut'
            $script:beats | Should -BeGreaterOrEqual 2
        }
    }
}

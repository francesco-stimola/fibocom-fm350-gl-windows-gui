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

Describe 'Telling a port another program holds' {
    It 'takes Windows'' <Code> to an exclusive open for <Said>' -ForEach @(
        @{ Code = 170; Said = 'held: MediaTek''s serial driver, its port open elsewhere'; Held = $true }
        @{ Code = 5; Said = 'held: WinUSB, its interface open elsewhere'; Held = $true }
        @{ Code = 32; Said = 'held: a sharing violation'; Held = $true }
        @{ Code = 0; Said = 'free: opened'; Held = $false }
        @{ Code = 2; Said = 'free: gone meanwhile'; Held = $false }
        @{ Code = 3; Said = 'free: no such path'; Held = $false }
    ) {
        InModuleScope FibocomFm350 -Parameters @{ Code = $Code; Held = $Held } {
            param($Code, $Held)
            Test-Win32Held -Code $Code | Should -Be $Held
        }
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
        { Remove-AbsentUsbFunction -InstanceId $InstanceId -WhatIf -ErrorAction Stop } | Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
    }

    It 'change nothing with -WhatIf' {
        Install-WinUsbDriver -InstanceId 'USB\VID_0E8D&PID_7127&MI_06\8&00000000&0&0006' -WhatIf | Should -BeNullOrEmpty
        Restore-UsbFunctionDriver -InstanceId 'USB\VID_0E8D&PID_7126&MI_04\8&00000000&0&0004' -WhatIf | Should -BeNullOrEmpty
        Remove-AbsentUsbFunction -InstanceId 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003' -WhatIf | Should -BeNullOrEmpty
    }

    It 'refuse the network function in the code that calls Windows too' {
        { [FibocomFm350.UsbDriverBinding]::InstallWinUsb('USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000', 'x', 'x', 'x', $null) } | Should -Throw
        { [FibocomFm350.UsbDriverBinding]::Restore('USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000', $null) } | Should -Throw
        { [FibocomFm350.UsbDriverBinding]::RemoveAbsent('USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000') } | Should -Throw
    }

    It 'removes nothing that Windows doesn''t know' {
        # A function no device has: not plugged in, so looked for, and not found - nothing removed.
        $result = [FibocomFm350.UsbDriverBinding]::RemoveAbsent('USB\VID_0E8D&PID_7127&MI_03\FM350-TEST-NO-SUCH-DEVICE')
        $result.Done | Should -BeFalse
        $result.Step | Should -BeIn @('Locate', 'Open')
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

Describe 'Restore-ModemUsbFunction' {
    BeforeEach {
        $script:fixture = (Get-Content -LiteralPath "$PSScriptRoot/fixtures/device/pnp.7127.winusb.json" -Raw | ConvertFrom-Json).Devices
        $script:restored = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName FibocomFm350 Get-ModemPnpRecord { $script:fixture }
        Mock -ModuleName FibocomFm350 Test-UsbFunctionFree { [pscustomobject]@{ Free = $InstanceId -notlike '*&MI_03\*'; Held = $null; Error = 0 } }
        # Never the real one: each call recorded, the debug port's refused.
        Mock -ModuleName FibocomFm350 Restore-UsbFunctionDriver {
            $script:restored.Add([pscustomobject]@{ InstanceId = $InstanceId; InterfaceGuid = $InterfaceGuid })
            if ($InstanceId -like '*&MI_09\*') { [pscustomobject]@{ Done = $false; NeedReboot = $false; Step = 'Best'; Error = 5 } }
            elseif ($InstanceId -like '*&MI_08\*') { [pscustomobject]@{ Done = $true; NeedReboot = $true; Step = 'Best'; Error = 0 } }
            else { [pscustomobject]@{ Done = $true; NeedReboot = $false; Step = 'Best'; Error = 0 } }
        }
    }

    It 'gives each function on WinUSB back, the AT port with the app''s interface class taken out, one held left' {
        $outcome = Restore-ModemUsbFunction -Confirm:$false
        $outcome.Modems | Should -Be 1
        $outcome.Functions.Interface | Should -Be @(6, 2, 3, 4, 7, 8, 9)
        $outcome.Functions.Result | Should -Be @('Done', 'Done', 'InUse', 'Done', 'Done', 'RestartNeeded', 'Failed')
        $script:restored[0].InterfaceGuid | Should -Be '{4FDE9624-2286-4DC0-9D07-601A3922581A}'
        @($script:restored | Where-Object InterfaceGuid).Count | Should -Be 1
        $script:restored.InstanceId | Should -Not -Contain 'USB\VID_0E8D&PID_7127&MI_03\8&00000000&0&0003'
    }

    Context 'with a modem not plugged in, its functions on WinUSB' {
        BeforeEach {
            # The same modem's functions under another instance, not present: as a reset can leave them.
            $script:absent = foreach ($record in @($script:fixture | Where-Object { $_.InstanceId -match '&MI_0[2-9]\\' })) {
                $copy = $record.PSObject.Copy()
                $copy.InstanceId = $record.InstanceId -replace '\\8&00000000&0&', '\8&00000000&9&'
                $copy.Present = $false
                $copy
            }
            $script:fixture = @($script:fixture) + @($script:absent)
            $script:removed = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName FibocomFm350 Remove-AbsentUsbFunction {
                $script:removed.Add($InstanceId)
                if ($InstanceId -like '*&MI_07\*') { [pscustomobject]@{ Done = $false; NeedReboot = $false; Step = 'Remove'; Error = 5 } }
                else { [pscustomobject]@{ Done = $true; NeedReboot = $false; Step = 'Remove'; Error = 0 } }
            }
        }

        It 'reads PnP with the modems not plugged in, strictly, and removes their functions on WinUSB from Windows' {
            $outcome = Restore-ModemUsbFunction -Confirm:$false
            Should -Invoke -ModuleName FibocomFm350 Get-ModemPnpRecord -Times 1 -Exactly -ParameterFilter { $IncludeAbsent -and $Strict }
            $outcome.Functions.Count | Should -Be 7
            $script:restored.InstanceId | Should -Not -Contain $script:absent[0].InstanceId
            # The vendor functions on winusb.inf: not ADB (MI_05), which Windows put on WinUSB itself.
            $script:removed | Should -Be @($script:absent | Where-Object { $_.InstanceId -notlike '*&MI_05\*' } | ForEach-Object InstanceId)
            $outcome.Absent.Interface | Should -Be @(2, 3, 4, 6, 7, 8, 9)
            $outcome.Absent.Result | Should -Be @('Removed', 'Removed', 'Removed', 'Removed', 'Failed', 'Removed', 'Removed')
        }

        It 'goes on past a removal that throws' {
            Mock -ModuleName FibocomFm350 Remove-AbsentUsbFunction { throw [System.ArgumentException]::new('no') } -ParameterFilter { $InstanceId -like '*&MI_02\*' }
            $outcome = Restore-ModemUsbFunction -Confirm:$false
            $outcome.Absent[0].Result | Should -Be 'Failed'
            $outcome.Absent[0].Step | Should -Be 'ArgumentException'
            $outcome.Absent.Count | Should -Be 7
        }

        It 'removes nothing with -WhatIf' {
            $outcome = Restore-ModemUsbFunction -WhatIf
            $outcome.Absent | Should -BeNullOrEmpty
            $script:removed | Should -BeNullOrEmpty
        }
    }

    It 'throws, giving nothing back, when PnP can''t be read' {
        Mock -ModuleName FibocomFm350 Get-ModemPnpRecord { throw [System.InvalidOperationException]::new('WMI down') }
        { Restore-ModemUsbFunction -Confirm:$false } | Should -Throw '*WMI down*'
        $script:restored | Should -BeNullOrEmpty
    }

    It 'gives nothing back with -WhatIf' {
        $outcome = Restore-ModemUsbFunction -WhatIf
        $outcome.Functions | Should -BeNullOrEmpty
        $script:restored | Should -BeNullOrEmpty
    }

    It 'says no modem when none is plugged in' {
        Mock -ModuleName FibocomFm350 Get-ModemPnpRecord { }
        $outcome = Restore-ModemUsbFunction -Confirm:$false
        $outcome.Modems | Should -Be 0
        $outcome.Absent | Should -BeNullOrEmpty
        $outcome.Functions | Should -BeNullOrEmpty
    }

    It 'goes on past a function whose restore throws' {
        Mock -ModuleName FibocomFm350 Restore-UsbFunctionDriver { throw [System.InvalidOperationException]::new('no') } -ParameterFilter { $InstanceId -like '*&MI_06\*' }
        $outcome = Restore-ModemUsbFunction -Confirm:$false
        $outcome.Functions[0].Result | Should -Be 'Failed'
        $outcome.Functions[0].Step | Should -Be 'InvalidOperationException'
        $outcome.Functions.Count | Should -Be 7
    }
}
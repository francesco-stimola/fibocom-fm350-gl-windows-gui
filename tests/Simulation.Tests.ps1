# Development mode's simulated device: every scenario builds, the scenario names agree everywhere
# they are listed, the simulated adapter behaves as a real one is configured, and the modem leaves
# USB and comes back as a restart makes it.

BeforeDiscovery {
    $script:scenarios = @((Import-PowerShellDataFile -Path "$PSScriptRoot/../src/FibocomFm350/Data/Simulation.psd1").Scenarios.Keys | Sort-Object)
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    $script:data = Import-PowerShellDataFile -Path "$PSScriptRoot/../src/FibocomFm350/Data/Simulation.psd1"

    # The ValidateSet of a script's -Scenario parameter.
    function Get-ScriptScenario {
        param([string] $Path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Scenario' }
        $set = $parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        @($set.PositionalArguments.Value | Sort-Object)
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'New-SimulatedDevice' {
    It 'lists the scenarios of the data file, and so does the app''s start script' {
        $names = @($script:data.Scenarios.Keys | Sort-Object)
        @((Get-Command New-SimulatedDevice).Parameters['Scenario'].Attributes.ValidValues | Sort-Object) | Should -Be $names
        Get-ScriptScenario -Path "$PSScriptRoot/../src/App/Start-Fm350App.ps1" | Should -Be $names
    }

    It 'builds the <_> scenario' -ForEach $script:scenarios {
        $device = New-SimulatedDevice -Scenario $_
        $device.Scenario | Should -Be $_
        $device.Modem.PortName | Should -Be 'SIMULATED'
        $device.Find().Device | Should -BeIn 'Present', 'Absent', 'NoDriver'
    }

    It 'answers the commands of a connect pass from its base answers' {
        $device = New-SimulatedDevice
        foreach ($command in $script:data.Answers.Keys) {
            $channel = New-AtChannel -Transport $device.Open()
            try {
                $answer = Invoke-AtCommand -Channel $channel -Command $command -TimeoutMs 3000
            }
            finally {
                Close-AtChannel -Channel $channel
            }
            $answer.Status | Should -BeIn 'OK', 'CmeError' -Because "$command has a standing answer"
        }
    }
}

Describe 'The simulated adapter' {
    It 'reads as a copy: what the caller holds never changes under it' {
        $adapter = (New-SimulatedDevice -Scenario Connect).Adapter
        $reading = $adapter.Read()
        $adapter.Dhcp = 'Disabled'
        $reading.Dhcp | Should -Be 'Enabled'
    }

    It 'applies a plan as the real adapter is configured, and is then configured' {
        $adapter = (New-SimulatedDevice -Scenario Connect).Adapter
        $settings = (ConvertTo-AppSetting -InputObject $null).Settings
        $context = [pscustomobject]@{ IPv4Address = '192.0.2.10'; IPv4PrefixLength = $null; IPv4Gateway = $null; Dns = @('192.0.2.53') }
        $plan = Resolve-AdapterConfiguration -Context $context -Adapter $adapter.Read() -Settings $settings
        $results = @($adapter.Apply($plan))
        $results.Action | Should -Be @('DisableDhcp', 'SetAddress', 'SetGateway', 'SetDns', 'SetMetric')
        @($results | Where-Object { -not $_.Done }).Count | Should -Be 0
        (Resolve-AdapterConfiguration -Context $context -Adapter $adapter.Read() -Settings $settings).Configured | Should -BeTrue
    }

    It 'is enabled again' {
        $adapter = (New-SimulatedDevice -Scenario AdapterDisabled).Adapter
        $adapter.Status | Should -Be 'Disabled'
        $adapter.Enable()
        $adapter.Status | Should -Be 'Up'
    }
}

Describe 'The simulated modem on USB' {
    It 'is away for a while after it vanished, then back on the same port' {
        $device = New-SimulatedDevice
        $device.AwayMs = 60000
        $device.Modem.Vanish()
        $device.Find().Device | Should -Be 'Absent'
        $device.AwayMs = 0
        $presence = $device.Find()
        $presence.Device | Should -Be 'Present'
        $presence.PortName | Should -Be 'SIMULATED'
        $device.Modem.Lost | Should -BeFalse
    }

    It 'opens again after a channel closed it, keeping what commands changed' {
        $device = New-SimulatedDevice -Scenario Connect
        $channel = New-AtChannel -Transport $device.Open()
        [void](Invoke-AtCommand -Channel $channel -Command 'AT+CGACT=1,1' -TimeoutMs 3000)
        Close-AtChannel -Channel $channel
        $device.Modem.Closed | Should -BeTrue
        $channel = New-AtChannel -Transport $device.Open()
        try {
            (Invoke-AtCommand -Channel $channel -Command 'AT+CGACT?' -TimeoutMs 3000).Lines | Should -Be @('+CGACT: 1,1')
        }
        finally {
            Close-AtChannel -Channel $channel
        }
    }

    It 'restarts after the FCC unlock, unlocked' {
        $device = New-SimulatedDevice -Scenario FccLocked
        $channel = New-AtChannel -Transport $device.Open()
        try {
            (Invoke-FccUnlock -Channel $channel -Confirm:$false).Result | Should -Be 'Restarted'
            (Invoke-AtCommand -Channel $channel -Command 'AT' -TimeoutMs 1000).Status | Should -Be 'PortLost'
        }
        finally {
            Close-AtChannel -Channel $channel
        }
        $device.AwayMs = 0
        [void]$device.Find()
        $channel = New-AtChannel -Transport $device.Open()
        try {
            $lock = ConvertFrom-AtFccLock -Lines (Invoke-AtCommand -Channel $channel -Command 'AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?' -TimeoutMs 3000).Lines
            $lock.Unlocked | Should -BeTrue
        }
        finally {
            Close-AtChannel -Channel $channel
        }
    }
}

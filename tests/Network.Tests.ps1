# The modem adapter's configuration plan: a matrix of adapters as read and contexts as reported,
# and the plan being empty once the adapter is configured (idempotent).

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    . "$PSScriptRoot/FixtureAnswer.ps1"

    $script:context = ConvertFrom-AtContextParameter -Lines (Get-FixtureAnswer -Name 'cgcontrdp.data.txt')
    $script:settings = (ConvertTo-AppSetting -InputObject $null).Settings

    # The adapter as the modem leaves it with no data context: DHCP on, a link-local address.
    function Get-TestAdapter {
        param([hashtable] $Change = @{})
        $adapter = [ordered]@{
            InterfaceIndex  = 12
            Dhcp            = 'Enabled'
            InterfaceMetric = 25
            AutomaticMetric = $true
            Addresses       = @([pscustomobject]@{ Address = '169.254.10.20'; PrefixLength = 16; Origin = 'WellKnown' })
            Gateways        = @()
            DnsServers      = @()
        }
        foreach ($key in $Change.Keys) {
            $adapter[$key] = $Change[$key]
        }
        [pscustomobject]$adapter
    }

    # The adapter once the plan for $script:context has been applied.
    function Get-TestConfiguredAdapter {
        param([hashtable] $Change = @{})
        $configured = @{
            Dhcp            = 'Disabled'
            InterfaceMetric = 500
            AutomaticMetric = $false
            Addresses       = @([pscustomobject]@{ Address = '198.51.100.23'; PrefixLength = 24; Origin = 'Manual' })
            Gateways        = @('198.51.100.1')
            DnsServers      = @('203.0.113.53', '203.0.113.54', '2001:db8::53')
        }
        foreach ($key in $Change.Keys) {
            $configured[$key] = $Change[$key]
        }
        Get-TestAdapter -Change $configured
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Resolve-AdapterConfiguration' {
    It 'configures a fresh adapter from the context: address, gateway, DNS, metric' {
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestAdapter) -Settings $script:settings
        $plan.Configured | Should -BeFalse
        $plan.Problem | Should -BeNullOrEmpty
        $plan.Actions.Action | Should -Be @('DisableDhcp', 'SetAddress', 'SetGateway', 'SetDns', 'SetMetric')
        $plan.Actions[1].Address | Should -Be '198.51.100.23'
        $plan.Actions[1].PrefixLength | Should -Be 24
        $plan.Actions[2].NextHop | Should -Be '198.51.100.1'
        $plan.Actions[3].Servers | Should -Be @('203.0.113.53', '203.0.113.54', '2001:db8::53')
        $plan.Actions[4].Metric | Should -Be 500
    }

    It 'plans nothing for an adapter already configured: safe to run twice' {
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestConfiguredAdapter) -Settings $script:settings
        $plan.Configured | Should -BeTrue
        $plan.Actions | Should -BeNullOrEmpty
    }

    It 'replaces the address and gateway of an earlier context' {
        $adapter = Get-TestConfiguredAdapter -Change @{
            Addresses = @([pscustomobject]@{ Address = '198.51.100.99'; PrefixLength = 24; Origin = 'Manual' })
            Gateways  = @('198.51.100.254')
        }
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings $script:settings
        $plan.Actions.Action | Should -Be @('RemoveAddress', 'SetAddress', 'RemoveGateway', 'SetGateway')
        $plan.Actions[0].Address | Should -Be '198.51.100.99'
        $plan.Actions[2].NextHop | Should -Be '198.51.100.254'
    }

    It 'replaces an address whose mask changed' {
        $adapter = Get-TestConfiguredAdapter -Change @{ Addresses = @([pscustomobject]@{ Address = '198.51.100.23'; PrefixLength = 16; Origin = 'Manual' }) }
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings $script:settings
        $plan.Actions.Action | Should -Be @('RemoveAddress', 'SetAddress')
    }

    It 'keeps what the modem''s DHCP gave the adapter, and only sets the metric' {
        $adapter = Get-TestAdapter -Change @{
            Addresses  = @([pscustomobject]@{ Address = '192.168.225.20'; PrefixLength = 24; Origin = 'Dhcp' })
            Gateways   = @('192.168.225.1')
            DnsServers = @('192.168.225.1')
        }
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings $script:settings
        $plan.Actions.Action | Should -Be @('SetMetric')
    }

    It 'applies the DNS override over DHCP and over the operator''s servers' {
        $settings = (ConvertTo-AppSetting -InputObject @{ DnsServers = @('203.0.113.99') }).Settings
        $dhcp = Get-TestAdapter -Change @{
            Addresses = @([pscustomobject]@{ Address = '192.168.225.20'; PrefixLength = 24; Origin = 'Dhcp' })
            Gateways  = @('192.168.225.1'); AutomaticMetric = $false; InterfaceMetric = 500
        }
        (Resolve-AdapterConfiguration -Context $script:context -Adapter $dhcp -Settings $settings).Actions.Action | Should -Be @('SetDns')
        $static = Get-TestConfiguredAdapter
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $static -Settings $settings
        $plan.Actions.Action | Should -Be @('SetDns')
        $plan.Actions[0].Servers | Should -Be @('203.0.113.99')
    }

    It 'sets the metric of the settings: <Name>' -ForEach @(
        @{ Name = 'automatic metric'; Change = @{ AutomaticMetric = $true }; Metric = 500; Expected = @('SetMetric') }
        @{ Name = 'another metric'; Change = @{ InterfaceMetric = 10 }; Metric = 500; Expected = @('SetMetric') }
        @{ Name = 'the modem preferred'; Change = @{}; Metric = 5; Expected = @('SetMetric') }
        @{ Name = 'already right'; Change = @{}; Metric = 500; Expected = @() }
    ) {
        $settings = (ConvertTo-AppSetting -InputObject @{ InterfaceMetric = $Metric }).Settings
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestConfiguredAdapter -Change $Change) -Settings $settings
        @($plan.Actions.Action) | Should -Be $Expected
        if ($Expected) { $plan.Actions[-1].Metric | Should -Be $Metric }
    }

    It 'leaves alone the IPv6 servers Windows lists by itself when only IPv4 ones are wanted' {
        $context = $script:context | Select-Object -Property *
        $context.Dns = @('203.0.113.53', '203.0.113.54')
        $adapter = Get-TestConfiguredAdapter -Change @{ DnsServers = @('203.0.113.53', '203.0.113.54', 'fec0:0:0:ffff::1', 'fec0:0:0:ffff::2', 'fec0:0:0:ffff::3') }
        (Resolve-AdapterConfiguration -Context $context -Adapter $adapter -Settings $script:settings).Configured | Should -BeTrue
    }

    It 'still sets the IPv4 servers when only IPv6 ones are listed' {
        $context = $script:context | Select-Object -Property *
        $context.Dns = @('203.0.113.53')
        $adapter = Get-TestConfiguredAdapter -Change @{ DnsServers = @('fec0:0:0:ffff::1') }
        $plan = Resolve-AdapterConfiguration -Context $context -Adapter $adapter -Settings $script:settings
        $plan.Actions.Action | Should -Be @('SetDns')
        $plan.Actions[0].Servers | Should -Be @('203.0.113.53')
    }

    It 'takes an override listed IPv6 first as Windows reads it back: IPv4 first' {
        $settings = (ConvertTo-AppSetting -InputObject @{ DnsServers = @('2001:db8::99', '203.0.113.99') }).Settings
        $fresh = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestConfiguredAdapter) -Settings $settings
        ($fresh.Actions | Where-Object Action -EQ 'SetDns').Servers | Should -Be @('203.0.113.99', '2001:db8::99')
        $after = Get-TestConfiguredAdapter -Change @{ DnsServers = @('203.0.113.99', '2001:db8::99') }
        (Resolve-AdapterConfiguration -Context $script:context -Adapter $after -Settings $settings).Configured | Should -BeTrue
    }

    It 'rewrites DNS servers in the wrong order' {
        $adapter = Get-TestConfiguredAdapter -Change @{ DnsServers = @('203.0.113.54', '203.0.113.53', '2001:db8::53') }
        (Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings $script:settings).Actions.Action | Should -Be @('SetDns')
    }

    It 'gives the address alone, as the FM350 does: a /32 and an on-link default route' {
        $context = ConvertFrom-AtContextParameter -Lines (Get-FixtureAnswer -Name 'cgcontrdp.app.txt' -Folder device)
        $context.IPv4Address = (ConvertFrom-AtContextAddress -Lines (Get-FixtureAnswer -Name 'cgpaddr.app.txt' -Folder device)).IPv4Address
        $plan = Resolve-AdapterConfiguration -Context $context -Adapter (Get-TestAdapter) -Settings $script:settings
        $plan.Problem | Should -BeNullOrEmpty
        $plan.Actions.Action | Should -Be @('DisableDhcp', 'SetAddress', 'SetGateway', 'SetDns', 'SetMetric')
        $plan.Actions[1].Address | Should -Be '192.0.2.53'
        $plan.Actions[1].PrefixLength | Should -Be 32
        $plan.Actions[2].NextHop | Should -Be '0.0.0.0'
        $plan.Actions[3].Servers | Should -Be @('192.0.2.53', '192.0.2.54')
    }

    It 'plans nothing more once the /32 and the on-link route are there' {
        $context = $script:context | Select-Object -Property *
        $context.IPv4PrefixLength = $null
        $context.IPv4Gateway = $null
        $adapter = Get-TestConfiguredAdapter -Change @{
            Addresses = @([pscustomobject]@{ Address = '198.51.100.23'; PrefixLength = 32; Origin = 'Manual' })
            Gateways  = @('0.0.0.0')
        }
        (Resolve-AdapterConfiguration -Context $context -Adapter $adapter -Settings $script:settings).Configured | Should -BeTrue
    }

    It 'replaces a gateway route with an on-link one when the modem reports no gateway' {
        $context = $script:context | Select-Object -Property *
        $context.IPv4Gateway = $null
        $plan = Resolve-AdapterConfiguration -Context $context -Adapter (Get-TestConfiguredAdapter) -Settings $script:settings
        $plan.Actions.Action | Should -Be @('RemoveGateway', 'SetGateway')
        $plan.Actions[1].NextHop | Should -Be '0.0.0.0'
    }

    It 'plans nothing and says why when the modem reports no IPv4 address' {
        $context = $script:context | Select-Object -Property *
        $context.IPv4Address = $null
        $plan = Resolve-AdapterConfiguration -Context $context -Adapter (Get-TestAdapter) -Settings $script:settings
        $plan.Problem | Should -Be 'NoAddress'
        $plan.Configured | Should -BeFalse
        $plan.Actions | Should -BeNullOrEmpty
    }

    It 'says NoAddress without a context' {
        (Resolve-AdapterConfiguration -Context $null -Adapter (Get-TestAdapter) -Settings $script:settings).Problem | Should -Be 'NoAddress'
    }

    It 'does not disable DHCP that is already off' {
        $adapter = Get-TestAdapter -Change @{ Dhcp = 'Disabled'; Addresses = @() }
        (Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings $script:settings).Actions.Action | Should -Not -Contain 'DisableDhcp'
    }

    It 'takes an address Windows is still checking as in place: <State>' -ForEach @(
        @{ State = 'Tentative' }
        @{ State = 'Preferred' }
    ) {
        $adapter = Get-TestConfiguredAdapter -Change @{ Addresses = @([pscustomobject]@{ Address = '198.51.100.23'; PrefixLength = 24; Origin = 'Manual'; State = $State }) }
        (Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings $script:settings).Configured | Should -BeTrue
    }

    It 'sets again an address Windows refused: <State>' -ForEach @(
        @{ State = 'Duplicate' }
        @{ State = 'Invalid' }
    ) {
        $adapter = Get-TestConfiguredAdapter -Change @{ Addresses = @([pscustomobject]@{ Address = '198.51.100.23'; PrefixLength = 24; Origin = 'Manual'; State = $State }) }
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings $script:settings
        $plan.Configured | Should -BeFalse
        $plan.Actions.Action | Should -Be @('RemoveAddress', 'SetAddress')
        @($plan.Actions | ForEach-Object Address) | Should -Be @('198.51.100.23', '198.51.100.23')
    }
}

Describe 'Resolve-AdapterClearing' {
    It 'removes the default routes, then the addresses the app set' {
        $adapter = Get-TestConfiguredAdapter -Change @{ Gateways = @('0.0.0.0', '198.51.100.1') }
        $plan = Resolve-AdapterClearing -Adapter $adapter
        $plan.Configured | Should -BeFalse
        $plan.Actions.Action | Should -Be @('RemoveGateway', 'RemoveGateway', 'RemoveAddress')
        $plan.Actions[0].NextHop | Should -Be '0.0.0.0'
        $plan.Actions[2].Address | Should -Be '198.51.100.23'
    }

    It 'leaves a link-local address and one a DHCP server gave, with its route' {
        $adapter = Get-TestAdapter -Change @{
            Addresses = @(
                [pscustomobject]@{ Address = '169.254.10.20'; PrefixLength = 16; Origin = 'WellKnown' }
                [pscustomobject]@{ Address = '192.0.2.77'; PrefixLength = 24; Origin = 'Dhcp' }
            )
            Gateways  = @('192.0.2.1')
        }
        (Resolve-AdapterClearing -Adapter $adapter).Actions | Should -BeNullOrEmpty
    }

    It 'gives Resolve-AdapterConfiguration a fresh adapter to configure once applied' {
        $adapter = Get-TestConfiguredAdapter
        $cleared = Get-TestAdapter -Change @{ Dhcp = 'Disabled'; InterfaceMetric = 500; AutomaticMetric = $false; Addresses = @(); Gateways = @(); DnsServers = $adapter.DnsServers }
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $cleared -Settings $script:settings
        $plan.Actions.Action | Should -Be @('SetAddress', 'SetGateway')
        (Resolve-AdapterClearing -Adapter $adapter).Actions.Count | Should -Be 2
    }
}

Describe 'Get-ModemAdapterState' {
    BeforeEach {
        $script:instance = 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000'
        Mock -ModuleName FibocomFm350 Get-NetAdapter {
            [pscustomobject]@{ Name = 'Wi-Fi'; ifIndex = 7; Status = 'Up'; PnPDeviceID = 'PCI\VEN_8086&DEV_0000\0' }
            [pscustomobject]@{ Name = 'Ethernet 3'; ifIndex = 12; Status = 'Up'; PnPDeviceID = $script:instance }
        }
        Mock -ModuleName FibocomFm350 Get-NetIPInterface { [pscustomobject]@{ Dhcp = 'Disabled'; InterfaceMetric = 500; AutomaticMetric = 'Disabled' } }
        Mock -ModuleName FibocomFm350 Get-NetIPAddress {
            [pscustomobject]@{ IPAddress = '198.51.100.23'; PrefixLength = 24; PrefixOrigin = 'Manual'; AddressState = 'Tentative' }
        }
        Mock -ModuleName FibocomFm350 Get-NetRoute {
            [pscustomobject]@{ NextHop = '198.51.100.1' }
            [pscustomobject]@{ NextHop = '0.0.0.0' }
        }
        Mock -ModuleName FibocomFm350 Get-DnsClientServerAddress {
            [pscustomobject]@{ AddressFamily = 23; ServerAddresses = @('2001:db8::53') }
            [pscustomobject]@{ AddressFamily = 2; ServerAddresses = @('203.0.113.53', '203.0.113.54') }
        }
    }

    It 'finds the adapter by its instance ID and reads what the plan needs' {
        $state = Get-ModemAdapterState -InstanceId $script:instance
        $state.InterfaceIndex | Should -Be 12
        $state.Dhcp | Should -Be 'Disabled'
        $state.InterfaceMetric | Should -Be 500
        $state.AutomaticMetric | Should -BeFalse
        $state.Addresses[0].Address | Should -Be '198.51.100.23'
        $state.Addresses[0].Origin | Should -Be 'Manual'
        $state.Addresses[0].State | Should -Be 'Tentative'
        $state.Gateways | Should -Be @('198.51.100.1', '0.0.0.0')
        $state.DnsServers | Should -Be @('203.0.113.53', '203.0.113.54', '2001:db8::53')
        Should -Invoke -ModuleName FibocomFm350 Get-NetIPAddress -ParameterFilter { $InterfaceIndex -eq 12 }
    }

    It 'gives nothing when no adapter has that instance ID' {
        Get-ModemAdapterState -InstanceId 'USB\VID_0E8D&PID_7127&MI_00\9&00000000&0&0000' | Should -BeNullOrEmpty
    }

    It 'reads an adapter without IPv4 configuration' {
        Mock -ModuleName FibocomFm350 Get-NetIPInterface { }
        Mock -ModuleName FibocomFm350 Get-NetIPAddress { }
        Mock -ModuleName FibocomFm350 Get-NetRoute { }
        Mock -ModuleName FibocomFm350 Get-DnsClientServerAddress { }
        $state = Get-ModemAdapterState -InstanceId $script:instance
        $state.Dhcp | Should -BeNullOrEmpty
        $state.AutomaticMetric | Should -BeFalse
        @($state.Addresses).Count | Should -Be 0
        @($state.Gateways).Count | Should -Be 0
        @($state.DnsServers).Count | Should -Be 0
    }
}

Describe 'Set-ModemAdapterConfiguration' {
    BeforeEach {
        Mock -ModuleName FibocomFm350 Set-NetIPInterface { }
        Mock -ModuleName FibocomFm350 Remove-NetIPAddress { }
        Mock -ModuleName FibocomFm350 New-NetIPAddress { }
        Mock -ModuleName FibocomFm350 Remove-NetRoute { }
        Mock -ModuleName FibocomFm350 New-NetRoute { }
        Mock -ModuleName FibocomFm350 Set-DnsClientServerAddress { }
        $script:plan = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestAdapter) -Settings $script:settings
    }

    It 'applies every action to that adapter, in the active store' {
        $results = @(Set-ModemAdapterConfiguration -InterfaceIndex 12 -Plan $script:plan -Confirm:$false)
        $results.Action | Should -Be @('DisableDhcp', 'SetAddress', 'SetGateway', 'SetDns', 'SetMetric')
        @($results | Where-Object { -not $_.Done }).Count | Should -Be 0
        Should -Invoke -ModuleName FibocomFm350 New-NetIPAddress -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 12 -and $IPAddress -eq '198.51.100.23' -and $PrefixLength -eq 24 -and $PolicyStore -eq 'ActiveStore'
        }
        Should -Invoke -ModuleName FibocomFm350 New-NetRoute -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 12 -and $DestinationPrefix -eq '0.0.0.0/0' -and $NextHop -eq '198.51.100.1' -and $PolicyStore -eq 'ActiveStore'
        }
        Should -Invoke -ModuleName FibocomFm350 Set-DnsClientServerAddress -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 12 }
        Should -Invoke -ModuleName FibocomFm350 Set-NetIPInterface -Times 3 -Exactly -ParameterFilter { $InterfaceIndex -eq 12 -and $PolicyStore -eq 'ActiveStore' }
    }

    It 'stops at the first action that fails, and says why' {
        Mock -ModuleName FibocomFm350 New-NetIPAddress { throw 'Access is denied.' }
        $results = @(Set-ModemAdapterConfiguration -InterfaceIndex 12 -Plan $script:plan -Confirm:$false)
        $results.Action | Should -Be @('DisableDhcp', 'SetAddress')
        $results[1].Done | Should -BeFalse
        $results[1].Error | Should -Match 'denied'
        Should -Invoke -ModuleName FibocomFm350 New-NetRoute -Times 0 -Exactly
    }

    It 'changes nothing under -WhatIf' {
        @(Set-ModemAdapterConfiguration -InterfaceIndex 12 -Plan $script:plan -WhatIf).Count | Should -Be 0
        Should -Invoke -ModuleName FibocomFm350 New-NetIPAddress -Times 0 -Exactly
        Should -Invoke -ModuleName FibocomFm350 Set-NetIPInterface -Times 0 -Exactly
    }
}

Describe 'Enable-ModemAdapter' {
    BeforeEach {
        $script:modemId = 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0000'
        Mock -ModuleName FibocomFm350 Get-NetAdapter {
            [pscustomobject]@{ Name = 'Ethernet 2'; PnPDeviceID = 'PCI\VEN_8086&DEV_0000\0'; Status = 'Up' }
            [pscustomobject]@{ Name = 'Ethernet 3'; PnPDeviceID = $script:modemId; Status = 'Disabled' }
        }
        Mock -ModuleName FibocomFm350 Enable-NetAdapter { }
    }

    It 'enables the modem''s adapter, found by its instance ID, and no other' {
        Enable-ModemAdapter -InstanceId $script:modemId -Confirm:$false
        Should -Invoke -ModuleName FibocomFm350 Enable-NetAdapter -Times 1 -Exactly -ParameterFilter { $Name -eq 'Ethernet 3' }
    }

    It 'fails when the modem has no adapter' {
        { Enable-ModemAdapter -InstanceId 'USB\VID_0E8D&PID_7127&MI_00\8&00000000&0&0001' -Confirm:$false -ErrorAction Stop } | Should -Throw '*not there*'
        Should -Invoke -ModuleName FibocomFm350 Enable-NetAdapter -Times 0 -Exactly
    }

    It 'passes on Windows'' refusal' {
        Mock -ModuleName FibocomFm350 Enable-NetAdapter { throw 'Access is denied.' }
        { Enable-ModemAdapter -InstanceId $script:modemId -Confirm:$false -ErrorAction Stop } | Should -Throw '*denied*'
    }

    It 'changes nothing under -WhatIf' {
        Enable-ModemAdapter -InstanceId $script:modemId -WhatIf
        Should -Invoke -ModuleName FibocomFm350 Enable-NetAdapter -Times 0 -Exactly
    }
}

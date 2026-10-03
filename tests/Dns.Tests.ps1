# Encrypted DNS (DNS over HTTPS) on the modem's adapter: the plan's matrix - every server of the
# override encrypted with its template, or nothing planned at all -, the changes applied with the
# Windows call mocked, the read of an interface of this computer (read only), the blocked state,
# the whole pass on the simulated modem, and what the window shows.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    Import-Module "$PSScriptRoot/../src/App/FibocomFm350.App.psd1" -Force

    $script:known = @{
        '1.1.1.1'              = 'https://cloudflare-dns.com/dns-query'
        '1.0.0.1'              = 'https://cloudflare-dns.com/dns-query'
        '2606:4700:4700::1111' = 'https://cloudflare-dns.com/dns-query'
    }
    $script:context = [pscustomobject]@{ IPv4Address = '198.51.100.23'; IPv4PrefixLength = $null; IPv4Gateway = $null; Dns = @('203.0.113.53') }

    # An adapter configured for the context, with these DNS servers - static ones unless -Static
    # says which - and DoH properties.
    function Get-TestAdapter {
        param([string[]] $Dns = @(), [object[]] $Doh = @(), [bool] $Supported = $true, [string[]] $Static = $Dns, [bool] $Read = $true)
        [pscustomobject]@{
            InterfaceIndex  = 12
            InterfaceGuid   = [guid]'8D1E3C2A-0B4F-4E6D-9A7C-1F2E3D4C5B6A'
            Dhcp            = 'Disabled'
            InterfaceMetric = 500
            AutomaticMetric = $false
            Addresses       = @([pscustomobject]@{ Address = '198.51.100.23'; PrefixLength = 32; Origin = 'Manual'; State = 'Preferred' })
            Gateways        = @('0.0.0.0')
            DnsServers      = $Dns
            Doh             = [pscustomobject]@{ Supported = $Supported; Read = $Read; NameServers = [string[]]$Static; Servers = [object[]]$Doh }
        }
    }
    function Get-TestDoh {
        param([string] $Address, [string] $Template = $script:known[$Address], [uint64] $Flags = 2)
        [pscustomobject]@{ Address = $Address; Template = $Template; Flags = $Flags }
    }
    function Get-TestSetting {
        param([string[]] $Dns = @(), [bool] $Doh = $false, [string] $Template = '')
        (ConvertTo-AppSetting -InputObject @{ DnsServers = $Dns; DnsOverHttps = $Doh; DohTemplate = $Template }).Settings
    }
}

AfterAll {
    Remove-Module FibocomFm350.App, FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'The adapter plan with encrypted DNS' {
    It 'encrypts each server with the template Windows knows for it, in one change per family' {
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestAdapter -Dns '203.0.113.53') -Settings (Get-TestSetting -Dns '1.1.1.1', '1.0.0.1' -Doh $true) -DohKnown $script:known
        $plan.Problem | Should -BeNullOrEmpty
        $plan.Actions.Action | Should -Be @('SetDoh') -Because 'the servers are set with their encryption, never first in the clear'
        $plan.Actions[0].Family | Should -Be 'IPv4'
        $plan.Actions[0].Servers | Should -Be @('1.1.1.1', '1.0.0.1')
        $plan.Actions[0].Templates | Should -Be @('https://cloudflare-dns.com/dns-query', 'https://cloudflare-dns.com/dns-query')
    }

    It 'takes the template of the settings for every server' {
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestAdapter) -Settings (Get-TestSetting -Dns '203.0.113.53', '203.0.113.54' -Doh $true -Template 'https://dns.example/dns-query') -DohKnown $script:known
        $plan.Actions[0].Templates | Should -Be @('https://dns.example/dns-query', 'https://dns.example/dns-query')
    }

    It 'sets IPv4 and IPv6 servers each in its family' {
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestAdapter) -Settings (Get-TestSetting -Dns '1.1.1.1', '2606:4700:4700::1111' -Doh $true) -DohKnown $script:known
        $plan.Actions.Action | Should -Be @('SetDoh', 'SetDoh')
        $plan.Actions.Family | Should -Be @('IPv4', 'IPv6')
        $plan.Actions[1].Servers | Should -Be @('2606:4700:4700::1111')
    }

    It 'changes nothing on an adapter encrypted as asked' {
        $adapter = Get-TestAdapter -Dns '1.1.1.1', '1.0.0.1' -Doh (Get-TestDoh '1.1.1.1'), (Get-TestDoh '1.0.0.1')
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Dns '1.1.1.1', '1.0.0.1' -Doh $true) -DohKnown $script:known
        $plan.Configured | Should -BeTrue
        $plan.Actions | Should -BeNullOrEmpty
    }

    It 'sets it again when <Name>' -ForEach @(
        @{ Name = 'a server is not encrypted'; Dns = @('1.1.1.1', '1.0.0.1'); Doh = @(@{ Address = '1.1.1.1' }); Wanted = @('1.1.1.1', '1.0.0.1') }
        @{ Name = 'a server has another template'; Dns = @('1.1.1.1'); Doh = @(@{ Address = '1.1.1.1'; Template = 'https://other.example/dns-query' }); Wanted = @('1.1.1.1') }
        @{ Name = 'a server may fall back to the clear'; Dns = @('1.1.1.1'); Doh = @(@{ Address = '1.1.1.1'; Flags = 6 }); Wanted = @('1.1.1.1') }
        @{ Name = 'a server uses the automatic template'; Dns = @('1.1.1.1'); Doh = @(@{ Address = '1.1.1.1'; Template = ''; Flags = 1 }); Wanted = @('1.1.1.1') }
        @{ Name = 'the servers are other ones'; Dns = @('203.0.113.53'); Doh = @(); Wanted = @('1.1.1.1', '1.0.0.1') }
        @{ Name = 'the servers are in another order'; Dns = @('1.0.0.1', '1.1.1.1'); Doh = @(@{ Address = '1.0.0.1' }, @{ Address = '1.1.1.1' }); Wanted = @('1.1.1.1', '1.0.0.1') }
    ) {
        $properties = @($Doh | ForEach-Object {
                $template = if ($_.ContainsKey('Template')) { $_.Template } else { $script:known[$_.Address] }
                $flags = if ($_.ContainsKey('Flags')) { [uint64]$_.Flags } else { [uint64]2 }
                Get-TestDoh -Address $_.Address -Template $template -Flags $flags
            })
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestAdapter -Dns $Dns -Doh $properties) -Settings (Get-TestSetting -Dns $Wanted -Doh $true) -DohKnown $script:known
        $plan.Actions.Action | Should -Be @('SetDoh')
        $plan.Actions[0].Servers | Should -Be $Wanted
    }

    It 'plans nothing at all - not even the address - when <Name>' -ForEach @(
        @{ Name = 'there is no server of the user''s'; Dns = @(); Supported = $true; Problem = 'DohNeedsServers' }
        @{ Name = 'Windows has no per-interface DoH'; Dns = @('1.1.1.1'); Supported = $false; Problem = 'DohUnavailable' }
        @{ Name = 'a server has no template, known or given'; Dns = @('1.1.1.1', '203.0.113.53'); Supported = $true; Problem = 'DohTemplateMissing' }
    ) {
        $fresh = Get-TestAdapter -Supported $Supported
        $fresh.Addresses = @([pscustomobject]@{ Address = '169.254.10.20'; PrefixLength = 16; Origin = 'WellKnown'; State = 'Preferred' })
        $fresh.Gateways = @()
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $fresh -Settings (Get-TestSetting -Dns $Dns -Doh $true) -DohKnown $script:known
        $plan.Problem | Should -Be $Problem
        $plan.Configured | Should -BeFalse
        $plan.Actions | Should -BeNullOrEmpty -Because 'no query may go in the clear for want of encryption'
    }

    It 'takes the encryption off first when it is turned off, then the servers' {
        $adapter = Get-TestAdapter -Dns '1.1.1.1' -Doh (Get-TestDoh '1.1.1.1')
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting) -DohKnown $script:known
        $plan.Actions.Action | Should -Be @('ClearDoh', 'SetDns')
        $plan.Actions[0].Family | Should -Be 'IPv4'
        $plan.Actions[0].Servers | Should -Be @('1.1.1.1')
        $plan.Actions[1].Servers | Should -Be @('203.0.113.53') -Because 'the operator''s servers come back'
    }

    It 'takes the encryption off and keeps the servers of the override' {
        $adapter = Get-TestAdapter -Dns '1.1.1.1' -Doh (Get-TestDoh '1.1.1.1')
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Dns '1.1.1.1') -DohKnown $script:known
        $plan.Actions.Action | Should -Be @('ClearDoh')
    }

    It 'takes every server of a family the override no longer has off the adapter, encrypted ones too, and sets the wanted ones back' {
        $adapter = Get-TestAdapter -Dns '1.1.1.1', '2606:4700:4700::1111' -Doh (Get-TestDoh '1.1.1.1'), (Get-TestDoh '2606:4700:4700::1111')
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Dns '1.1.1.1' -Doh $true) -DohKnown $script:known
        $plan.Actions.Action | Should -Be @('ClearDns', 'SetDoh') -Because 'encryption taken off first would leave the server in the clear, should the reset fail'
        $plan.Actions[1].Family | Should -Be 'IPv4'
        $plan.Actions[1].Servers | Should -Be @('1.1.1.1')
    }

    It 'leaves no server in the clear in a family the override leaves out: <Name>' -ForEach @(
        @{ Name = 'the operator''s IPv4 server, with IPv6 servers wanted'; Dns = @('203.0.113.53', '2001:db8::53'); Doh = @(); Wanted = @('2606:4700:4700::1111'); Family = 'IPv6' }
        @{ Name = 'the operator''s IPv6 server, with IPv4 servers wanted'; Dns = @('1.1.1.1', '2001:db8::53'); Doh = @('1.1.1.1'); Wanted = @('1.1.1.1'); Family = 'IPv4' }
    ) {
        $adapter = Get-TestAdapter -Dns $Dns -Doh @($Doh | ForEach-Object { Get-TestDoh $_ })
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Dns $Wanted -Doh $true) -DohKnown $script:known
        $plan.Actions.Action | Should -Be @('ClearDns', 'SetDoh')
        $plan.Actions[1].Family | Should -Be $Family
        $plan.Actions[1].Servers | Should -Be $Wanted
        # Once applied: the wanted servers alone, encrypted.
        $after = Get-TestAdapter -Dns $Wanted -Doh @($Wanted | ForEach-Object { Get-TestDoh $_ })
        (Resolve-AdapterConfiguration -Context $script:context -Adapter $after -Settings (Get-TestSetting -Dns $Wanted -Doh $true) -DohKnown $script:known).Configured | Should -BeTrue
    }

    It 'never asks a change for the IPv6 servers Windows lists on its own' {
        $adapter = Get-TestAdapter -Dns '1.1.1.1', 'fec0:0:0:ffff::1', 'fec0:0:0:ffff::2' -Static '1.1.1.1' -Doh (Get-TestDoh '1.1.1.1')
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Dns '1.1.1.1' -Doh $true) -DohKnown $script:known
        $plan.Configured | Should -BeTrue
    }

    It 'takes the encryption off the static servers alone when it is turned off' {
        $adapter = Get-TestAdapter -Dns '2606:4700:4700::1111', 'fec0:0:0:ffff::1' -Static '2606:4700:4700::1111' -Doh (Get-TestDoh '2606:4700:4700::1111')
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Dns '2606:4700:4700::1111') -DohKnown $script:known
        $plan.Actions.Action | Should -Be @('ClearDoh')
        $plan.Actions[0].Servers | Should -Be @('2606:4700:4700::1111') -Because 'a server Windows lists on its own is never made a static one'
    }

    It 'compares the servers Windows lists where it has no per-interface read' {
        $adapter = Get-TestAdapter -Dns '1.1.1.1' -Static @() -Supported $false
        (Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Dns '1.1.1.1') -DohKnown $null).Configured | Should -BeTrue -Because 'an empty reading there is no reading'
    }

    It 'leaves encryption as it is, and blocks nothing, when Windows refused part of the read: encrypted DNS <State>' -ForEach @(
        @{ State = 'on'; Doh = $true; Expected = @() }
        @{ State = 'off'; Doh = $false; Expected = @('SetDns') }
    ) {
        $adapter = Get-TestAdapter -Dns '203.0.113.53', '2001:db8::53' -Read $false -Doh (Get-TestDoh '203.0.113.53' -Template 'https://dns.example/dns-query')
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Dns '1.1.1.1' -Doh $Doh) -DohKnown $script:known
        $plan.Problem | Should -BeNullOrEmpty
        $plan.Unread | Should -Be 'Settings'
        @($plan.Actions | ForEach-Object Action | Where-Object { $_ -match 'Dns|Doh' }) | Should -Be $Expected -Because 'turned off, the servers are set even so; the encryption, unknown, is left alone'
    }

    It 'compares the servers Windows lists when it refused part of the read, never an incomplete reading' {
        $adapter = Get-TestAdapter -Dns '1.1.1.1' -Static @() -Read $false
        (Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Dns '1.1.1.1') -DohKnown $script:known).Configured | Should -BeTrue
    }

    It 'sets the context''s servers on a fresh adapter whose read Windows refused, encrypted DNS off' {
        $fresh = Get-TestAdapter -Read $false
        $fresh.Addresses = @()
        $fresh.Gateways = @()
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $fresh -Settings (Get-TestSetting) -DohKnown $null
        $plan.Actions.Action | Should -Contain 'SetDns'
        ($plan.Actions | Where-Object Action -EQ 'SetDns').Servers | Should -Be @('203.0.113.53') -Because 'online with no DNS server, no name would resolve'
    }

    It 'takes the template the adapter already carries when Windows'' list can''t be read' {
        $adapter = Get-TestAdapter -Dns '1.1.1.1' -Doh (Get-TestDoh '1.1.1.1')
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Dns '1.1.1.1' -Doh $true) -DohKnown $null
        $plan.Configured | Should -BeTrue
        $plan.Unread | Should -BeNullOrEmpty
    }

    It 'configures the address, leaves DNS as it is and blocks nothing, for a server whose template is unknown because Windows'' list can''t be read' {
        $fresh = Get-TestAdapter -Dns '203.0.113.53'
        $fresh.Addresses = @()
        $fresh.Gateways = @()
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $fresh -Settings (Get-TestSetting -Dns '1.1.1.1' -Doh $true) -DohKnown $null
        $plan.Problem | Should -BeNullOrEmpty -Because 'the template is unknown, not missing'
        $plan.Unread | Should -Be 'Templates'
        $plan.Actions.Action | Should -Contain 'SetAddress'
        @($plan.Actions | ForEach-Object Action | Where-Object { $_ -match 'Dns|Doh' }) | Should -BeNullOrEmpty
    }

    It 'changes nothing about DNS encryption when it is off and none is set' {
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestAdapter -Dns '203.0.113.53') -Settings (Get-TestSetting) -DohKnown $null
        $plan.Configured | Should -BeTrue
    }
}

Describe 'Applying encrypted DNS' {
    It 'sets each family on the adapter''s interface, and takes it off' {
        Mock -ModuleName FibocomFm350 Set-InterfaceDoh { }
        $guid = [guid]'8D1E3C2A-0B4F-4E6D-9A7C-1F2E3D4C5B6A'
        $plan = [pscustomobject]@{ Actions = @(
                [pscustomobject]@{ Action = 'ClearDoh'; Family = 'IPv6'; Servers = [string[]]@('2001:db8::53') }
                [pscustomobject]@{ Action = 'SetDoh'; Family = 'IPv4'; Servers = [string[]]@('1.1.1.1', '1.0.0.1'); Templates = [string[]]@('https://a.example/q', 'https://a.example/q') }
            )
        }
        $results = @(Set-ModemAdapterConfiguration -InterfaceIndex 12 -InterfaceGuid $guid -Plan $plan -Confirm:$false)
        $results.Done | Should -Be @($true, $true)
        Should -Invoke -ModuleName FibocomFm350 Set-InterfaceDoh -Times 1 -Exactly -ParameterFilter {
            $InterfaceGuid -eq $guid -and $Family -eq 'IPv6' -and ($Servers -join ',') -eq '2001:db8::53' -and @($Templates).Count -eq 0
        }
        Should -Invoke -ModuleName FibocomFm350 Set-InterfaceDoh -Times 1 -Exactly -ParameterFilter {
            $InterfaceGuid -eq $guid -and $Family -eq 'IPv4' -and ($Servers -join ',') -eq '1.1.1.1,1.0.0.1' -and ($Templates -join ',') -eq 'https://a.example/q,https://a.example/q'
        }
    }

    It 'stops at a change Windows refuses, and says why' {
        Mock -ModuleName FibocomFm350 Set-InterfaceDoh { throw [System.ComponentModel.Win32Exception]::new(5) }
        Mock -ModuleName FibocomFm350 Set-NetIPInterface { }
        $plan = [pscustomobject]@{ Actions = @(
                [pscustomobject]@{ Action = 'SetDoh'; Family = 'IPv4'; Servers = [string[]]@('1.1.1.1'); Templates = [string[]]@('https://a.example/q') }
                [pscustomobject]@{ Action = 'SetMetric'; Metric = 500 }
            )
        }
        $results = @(Set-ModemAdapterConfiguration -InterfaceIndex 12 -InterfaceGuid ([guid]::NewGuid()) -Plan $plan -Confirm:$false)
        $results.Count | Should -Be 1
        $results[0].Done | Should -BeFalse
        $results[0].Error | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName FibocomFm350 Set-NetIPInterface -Times 0 -Exactly
    }

    It 'changes nothing under -WhatIf' {
        { Set-InterfaceDoh -InterfaceGuid ([guid]::NewGuid()) -Family IPv4 -Servers '1.1.1.1' -Templates 'https://a.example/q' -WhatIf } | Should -Not -Throw
    }

    It 'writes a DoH property for <Name>' -ForEach @(
        @{ Name = 'each server with a template'; Templates = @('https://a.example/q', 'https://b.example/q'); Expected = '0=https://a.example/q;1=https://b.example/q' }
        @{ Name = 'only the servers with one'; Templates = @($null, 'https://b.example/q'); Expected = '1=https://b.example/q' }
        @{ Name = 'no server when encryption comes off'; Templates = @(); Expected = '' }
        @{ Name = 'no server for an empty template, which Windows refuses (0x2EE6)'; Templates = @('', ' '); Expected = '' }
        @{ Name = 'no server beyond the list'; Templates = @('https://a.example/q', 'https://b.example/q', 'https://c.example/q'); Expected = '0=https://a.example/q;1=https://b.example/q' }
    ) {
        # As Set-InterfaceDoh passes them: a $null in a string array arrives as an empty string.
        $properties = & (Get-Module FibocomFm350) { param($t) Get-DohServerProperty -Servers '1.1.1.1', '1.0.0.1' -Templates $t } ([string[]]$Templates)
        (@($properties | ForEach-Object { "$($_.Index)=$($_.Template)" }) -join ';') | Should -Be $Expected
    }
}

Describe 'Reading encrypted DNS on this computer (read only)' {
    It 'reads an interface''s DoH settings, as the per-interface API gives them' {
        $adapter = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object InterfaceGuid) | Select-Object -First 1
        if (-not $adapter) {
            Set-ItResult -Skipped -Because 'this computer has no network adapter to read'
            return
        }
        $doh = Get-InterfaceDoh -InterfaceGuid ([guid]$adapter.InterfaceGuid)
        $doh.Supported | Should -BeOfType ([bool])
        , $doh.Servers | Should -BeOfType ([object[]])
        , $doh.NameServers | Should -BeOfType ([string[]])
        foreach ($server in $doh.Servers) {
            $doh.NameServers | Should -Contain $server.Address -Because 'a DoH property belongs to a static server'
        }
        if ([Environment]::OSVersion.Version.Build -ge 22000) {
            $doh.Supported | Should -BeTrue -Because 'Windows 11 and Windows Server 2022 have DoH'
        }
    }

    It 'reads the templates Windows knows, by address' {
        $known = Get-DohKnownServer
        if (-not (Get-Command Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue)) {
            $known | Should -BeNullOrEmpty
            return
        }
        $known | Should -BeOfType ([hashtable])
        foreach ($address in $known.Keys) {
            [System.Net.IPAddress]::Parse($address).ToString() | Should -Be $address
            $known[$address] | Should -Match '^https://'
        }
    }

    It 'says a Windows without the API has none, without failing' {
        Mock -ModuleName FibocomFm350 Get-Command { } -ParameterFilter { $Name -eq 'Get-DnsClientDohServerAddress' }
        $doh = Get-InterfaceDoh -InterfaceGuid ([guid]::NewGuid())
        $doh.Supported | Should -BeFalse
        @($doh.Servers).Count | Should -Be 0
        Get-DohKnownServer | Should -BeNullOrEmpty
    }

    Context 'when Windows refuses a read' {
        BeforeEach {
            Mock -ModuleName FibocomFm350 Get-Command { [pscustomobject]@{ Name = 'Get-DnsClientDohServerAddress' } } -ParameterFilter { $Name -eq 'Get-DnsClientDohServerAddress' }
        }

        It 'says the reading is incomplete, never that there is no DoH, and keeps the family it read' {
            Mock -ModuleName FibocomFm350 Read-InterfaceDnsFamily {
                if ($IPv6) { throw [System.ComponentModel.Win32Exception]::new(1168) }
                [pscustomobject]@{ NameServers = [string[]]@('1.1.1.1'); Doh = @([pscustomobject]@{ Address = '1.1.1.1'; Template = 'https://cloudflare-dns.com/dns-query'; Flags = [uint64]2 }) }
            }
            $doh = Get-InterfaceDoh -InterfaceGuid ([guid]::NewGuid())
            $doh.Supported | Should -BeTrue
            $doh.Read | Should -BeFalse
            $doh.NameServers | Should -Be @('1.1.1.1')
            @($doh.Servers | ForEach-Object Address) | Should -Be @('1.1.1.1')
        }

        It 'says there is no DoH only when the function is missing' {
            Mock -ModuleName FibocomFm350 Read-InterfaceDnsFamily { throw [System.EntryPointNotFoundException]::new('GetInterfaceDnsSettings') }
            $doh = Get-InterfaceDoh -InterfaceGuid ([guid]::NewGuid())
            $doh.Supported | Should -BeFalse
            @($doh.Servers).Count | Should -Be 0
        }

        It 'gives no known template, without failing, when Windows can''t give its list' {
            if (-not (Get-Command Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'a cmdlet this Windows lacks can''t be mocked'
                return
            }
            Mock -ModuleName FibocomFm350 Get-DnsClientDohServerAddress { throw 'The CIM server is not available.' }
            { Get-DohKnownServer -ErrorAction Stop } | Should -Not -Throw
            Get-DohKnownServer | Should -BeNullOrEmpty
        }
    }
}

Describe 'The connection with encrypted DNS' {
    It 'waits for the user on <Problem>, and escalates nothing' -ForEach @(
        @{ Problem = 'DohNeedsServers' }
        @{ Problem = 'DohUnavailable' }
        @{ Problem = 'DohTemplateMissing' }
    ) {
        $facts = @{
            Device = 'Present'; PortOpen = $true; Responsive = $true; Sim = [pscustomobject]@{ Action = 'Continue'; Reason = 'Ready' }
            RadioOn = $true; Registered = $true; ContextDefined = $true; ContextActive = $true; ContextRead = $true; ContextAddress = '198.51.100.23'; ContextApn = 'internet'
            Adapter = 'Present'; AdapterConfigured = $false; AdapterProblem = $Problem; Elevated = $true
        }
        $decision = Resolve-ConnectionState -Observation $facts
        $decision.State | Should -Be 'DataActive'
        $decision.Action | Should -Be 'None'
        $decision.Reason | Should -Be $Problem
        $decision.Blocked | Should -BeTrue
    }

    It 'still waits on a missing address without blocking' {
        $facts = @{
            Device = 'Present'; PortOpen = $true; Responsive = $true; Sim = [pscustomobject]@{ Action = 'Continue'; Reason = 'Ready' }
            RadioOn = $true; Registered = $true; ContextDefined = $true; ContextActive = $true; ContextRead = $true; ContextAddress = '198.51.100.23'; ContextApn = 'internet'
            Adapter = 'Present'; AdapterConfigured = $false; AdapterProblem = 'NoAddress'; Elevated = $true
        }
        (Resolve-ConnectionState -Observation $facts).Blocked | Should -BeFalse
    }
}

Describe 'Encrypted DNS on the simulated modem' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
        $script:link = New-ModemWorkerLink
        $script:device = New-SimulatedDevice -Scenario Online
        $script:worker = New-ModemWorker -Link $script:link -Simulation $script:device -DataFolder $script:folder
    }

    AfterEach {
        Close-ModemWorker -Worker $script:worker
        Close-ModemWorkerLink -Link $script:link
    }

    It 'encrypts the servers of the settings at the next pass, says so, and takes it off when turned off' {
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].Dns.Encrypted | Should -BeNullOrEmpty
        $script:link['Snapshot'].Dns.Supported | Should -BeTrue

        $settings = (ConvertTo-AppSetting -InputObject @{ DnsServers = @('1.1.1.1', '9.9.9.9'); DnsOverHttps = $true }).Settings
        [void](Send-ModemCommand -Link $script:link -Kind SaveSettings -Parameter @{ Settings = $settings })
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.State | Should -Be 'Online'
        $snapshot.Dns.Encrypted | Should -Be @('1.1.1.1', '9.9.9.9')
        $script:device.Adapter.DnsServers | Should -Be @('1.1.1.1', '9.9.9.9')
        $script:device.Adapter.DohServers.Template | Should -Be @('https://cloudflare-dns.com/dns-query', 'https://dns.quad9.net/dns-query')
        (ConvertTo-WindowView -Snapshot $snapshot).Dns.Text | Should -Be 'Encrypted DNS is on: 1.1.1.1, 9.9.9.9.'

        $settings.DnsOverHttps = $false
        [void](Send-ModemCommand -Link $script:link -Kind SaveSettings -Parameter @{ Settings = $settings })
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].Dns.Encrypted | Should -BeNullOrEmpty
        $script:device.Adapter.DnsServers | Should -Be @('1.1.1.1', '9.9.9.9') -Because 'the override stays, in the clear as the user now asks'
    }

    It 'goes online, encryption left as it is, and says once that Windows'' list of templates can''t be read' {
        $settings = (ConvertTo-AppSetting -InputObject @{ DnsServers = @('1.1.1.1'); DnsOverHttps = $true }).Settings
        Export-AppSetting -Settings $settings -Path (Join-Path $script:folder 'settings.json') -Confirm:$false
        $script:device.Adapter.KnownDoh = $null
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.State | Should -Be 'Online'
        $snapshot.Blocked | Should -BeFalse
        @($script:device.Adapter.DohServers).Count | Should -Be 0 -Because 'no template, no encryption set'
        $script:worker.PassForced = $true
        Invoke-ModemWorkerCycle -Worker $script:worker
        $written = @(Get-ChildItem -Path (Join-Path $script:folder 'logs') -Filter '*.log' | Get-Content)
        @($written | Where-Object { $_ -match "WARNING.*Encrypted DNS: Windows' list of DoH templates can't be read; left as it is until they can" }).Count | Should -Be 1
        $script:device.Adapter.KnownDoh = @{ '1.1.1.1' = 'https://cloudflare-dns.com/dns-query' }
        $script:worker.PassForced = $true
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.DohServers.Template | Should -Be @('https://cloudflare-dns.com/dns-query') -Because 'once the list reads, encryption is set'
    }

    It 'blocks on a server Windows knows no template for, and the window says what to do' {
        $settings = (ConvertTo-AppSetting -InputObject @{ DnsServers = @('203.0.113.53'); DnsOverHttps = $true }).Settings
        Export-AppSetting -Settings $settings -Path (Join-Path $script:folder 'settings.json') -Confirm:$false
        $script:device.Adapter.Addresses = @([pscustomobject]@{ Address = '169.254.10.20'; PrefixLength = 16; Origin = 'WellKnown'; State = 'Preferred' })
        $script:device.Adapter.Gateways = @()
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.Reason | Should -Be 'DohTemplateMissing'
        $snapshot.Blocked | Should -BeTrue
        @($script:device.Adapter.Addresses | ForEach-Object Address) | Should -Be @('169.254.10.20') -Because 'the adapter is not configured in the clear'
        $view = ConvertTo-WindowView -Snapshot $snapshot
        $view.Blocker.Kind | Should -Be 'Settings'
        $view.Blocker.Message | Should -Match 'no DNS-over-HTTPS template'
    }

    It 'blocks where Windows has no per-interface DoH, and the window can only turn it off' {
        $script:device.Adapter.DohSupported = $false
        $settings = (ConvertTo-AppSetting -InputObject @{ DnsServers = @('1.1.1.1'); DnsOverHttps = $true }).Settings
        Export-AppSetting -Settings $settings -Path (Join-Path $script:folder 'settings.json') -Confirm:$false
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.Reason | Should -Be 'DohUnavailable'
        $view = ConvertTo-WindowView -Snapshot $snapshot
        $view.Dns.CanEnable | Should -BeFalse
        $view.Dns.Text | Should -Match 'not available on this Windows'
    }
}

Describe 'The DoH template''s server' {
    It 'is <Name>' -ForEach @(
        @{ Name = 'the override, when there is one'; Settings = @{ DnsServers = @('1.1.1.1'); DnsOverHttps = $true; DohTemplate = 'https://dns.example.org/q' }; Resolved = @('203.0.113.53'); Servers = '1.1.1.1'; Lookup = $null; Pending = $false }
        @{ Name = 'none while encrypted DNS is off'; Settings = @{ DohTemplate = 'https://dns.example.org/q' }; Resolved = @('203.0.113.53'); Servers = ''; Lookup = $null; Pending = $false }
        @{ Name = 'none without a template'; Settings = @{ DnsOverHttps = $true }; Resolved = @(); Servers = ''; Lookup = $null; Pending = $false }
        @{ Name = 'the address a template names'; Settings = @{ DnsOverHttps = $true; DohTemplate = 'https://203.0.113.53/dns-query' }; Resolved = @(); Servers = '203.0.113.53'; Lookup = $null; Pending = $false }
        @{ Name = 'the IPv6 address a template names'; Settings = @{ DnsOverHttps = $true; DohTemplate = 'https://[2001:db8::53]/dns-query' }; Resolved = @(); Servers = '2001:db8::53'; Lookup = $null; Pending = $false }
        @{ Name = 'a name to look up, pending until it is'; Settings = @{ DnsOverHttps = $true; DohTemplate = 'https://dns.example.org/dns-query' }; Resolved = @(); Servers = ''; Lookup = 'dns.example.org'; Pending = $true }
        @{ Name = 'the addresses the name was looked up to'; Settings = @{ DnsOverHttps = $true; DohTemplate = 'https://dns.example.org/dns-query' }; Resolved = @('203.0.113.53', '203.0.113.54'); Servers = '203.0.113.53,203.0.113.54'; Lookup = 'dns.example.org'; Pending = $false }
    ) {
        $result = Resolve-DohServer -Settings (ConvertTo-AppSetting -InputObject $Settings).Settings -Resolved $Resolved
        ($result.Servers -join ',') | Should -Be $Servers
        $result.Name | Should -Be $Lookup
        $result.Pending | Should -Be $Pending
    }
}

Describe 'The adapter plan with a DoH server named by its template' {
    BeforeAll {
        $script:named = 'https://dns.example.org/dns-query'
    }

    It 'sets the address with no DNS server at all, until the name is looked up' {
        $fresh = Get-TestAdapter -Dns '192.0.2.53', 'fec0:0:0:ffff::1'
        $fresh.Addresses = @([pscustomobject]@{ Address = '169.254.10.20'; PrefixLength = 16; Origin = 'WellKnown'; State = 'Preferred' })
        $fresh.Gateways = @()
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $fresh -Settings (Get-TestSetting -Doh $true -Template $script:named) -DohKnown $script:known
        $plan.Problem | Should -BeNullOrEmpty
        $plan.Actions.Action | Should -Be @('SetAddress', 'SetGateway', 'ClearDns') -Because 'the operator''s servers would answer in the clear'
    }

    It 'takes the servers of before off, encrypted ones too, never first stripped of their encryption' {
        $adapter = Get-TestAdapter -Dns '1.1.1.1' -Doh (Get-TestDoh '1.1.1.1')
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Doh $true -Template $script:named) -DohKnown $script:known
        $plan.Actions.Action | Should -Be @('ClearDns')
    }

    It 'is configured with no IPv4 DNS server: <Name>' -ForEach @(
        @{ Name = 'none at all'; Dns = @() }
        @{ Name = 'Windows'' own IPv6 ones'; Dns = @('fec0:0:0:ffff::1', 'fec0:0:0:ffff::2') }
    ) {
        # Windows' own servers are never static ones.
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestAdapter -Dns $Dns -Static @()) -Settings (Get-TestSetting -Doh $true -Template $script:named) -DohKnown $script:known
        $plan.Configured | Should -BeTrue
        $plan.Problem | Should -BeNullOrEmpty
    }

    It 'takes a static IPv6 server off too, while the name has no address' {
        $adapter = Get-TestAdapter -Dns '2001:db8::53'
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Doh $true -Template $script:named) -DohKnown $script:known
        $plan.Actions.Action | Should -Be @('ClearDns') -Because 'an IPv6 server would answer in the clear too'
    }

    It 'keeps the servers the adapter encrypts with that template: the addresses last looked up' {
        $adapter = Get-TestAdapter -Dns '203.0.113.53' -Doh (Get-TestDoh '203.0.113.53' -Template $script:named)
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $adapter -Settings (Get-TestSetting -Doh $true -Template $script:named) -DohKnown $script:known
        $plan.Configured | Should -BeTrue -Because 'Windows keeps them across a restart, and the name is looked up through them'
    }

    It 'does not keep servers encrypted with another template, or not encrypted' {
        $other = Get-TestAdapter -Dns '203.0.113.53' -Doh (Get-TestDoh '203.0.113.53' -Template 'https://other.example/dns-query')
        (Resolve-AdapterConfiguration -Context $script:context -Adapter $other -Settings (Get-TestSetting -Doh $true -Template $script:named)).Actions.Action | Should -Be @('ClearDns')
        $clear = Get-TestAdapter -Dns '203.0.113.53'
        (Resolve-AdapterConfiguration -Context $script:context -Adapter $clear -Settings (Get-TestSetting -Doh $true -Template $script:named)).Actions.Action | Should -Be @('ClearDns')
    }

    It 'encrypts the addresses the name was looked up to, with the template' {
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestAdapter) -Settings (Get-TestSetting -Dns '203.0.113.54' -Doh $true -Template $script:named) -DohKnown $script:known
        $plan.Actions.Action | Should -Be @('SetDoh')
        $plan.Actions[0].Servers | Should -Be @('203.0.113.54')
        $plan.Actions[0].Templates | Should -Be @($script:named)
    }

    It 'takes the address a template names as its server' {
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter (Get-TestAdapter) -Settings (Get-TestSetting -Doh $true -Template 'https://203.0.113.53/dns-query') -DohKnown $script:known
        $plan.Actions.Action | Should -Be @('SetDoh')
        $plan.Actions[0].Servers | Should -Be @('203.0.113.53')
    }

    It 'leaves an adapter the modem''s DHCP configured as it is, and waits' {
        $dhcp = Get-TestAdapter -Dns '192.0.2.53'
        $dhcp.Dhcp = 'Enabled'
        $dhcp.Addresses = @([pscustomobject]@{ Address = '198.51.100.23'; PrefixLength = 24; Origin = 'Dhcp'; State = 'Preferred' })
        $plan = Resolve-AdapterConfiguration -Context $script:context -Adapter $dhcp -Settings (Get-TestSetting -Doh $true -Template $script:named) -DohKnown $script:known
        $plan.Problem | Should -Be 'DohServerUnresolved'
        $plan.Actions | Should -BeNullOrEmpty -Because 'a reset would bring the DHCP servers back, every pass'
    }

    It 'applies the removal of the servers' {
        Mock -ModuleName FibocomFm350 Set-DnsClientServerAddress { }
        $plan = [pscustomobject]@{ Actions = @([pscustomobject]@{ Action = 'ClearDns' }) }
        $results = @(Set-ModemAdapterConfiguration -InterfaceIndex 12 -Plan $plan -Confirm:$false)
        $results.Done | Should -Be @($true)
        Should -Invoke -ModuleName FibocomFm350 Set-DnsClientServerAddress -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 12 -and $ResetServerAddresses }
    }
}

Describe 'A DNS query of the app''s own (RFC 1035)' {
    BeforeAll {
        $script:dns = Get-Module FibocomFm350
        # The query for dns.example.org, and an answer to a query with -Id for -Asked: the header,
        # the question, then the records named in -Records.
        $script:query = & $script:dns { ConvertTo-DnsQuery -Id 0x1234 -Name 'dns.example.org' }
        function Get-TestAnswer {
            param([int] $Id = 0x1234, [int] $Flags = 0x81, [int] $Code = 0x80, [string[]] $Records = @(), [int] $Cut = 0, [string] $Asked = 'dns.example.org', [int] $Type = 1)
            $wire = & $script:dns { param($n) ConvertTo-DnsQuery -Id 0 -Name $n } $Asked
            $question = [byte[]]@($wire[12..($wire.Count - 1)])
            $question[-3] = $Type
            $parts = @{
                A1    = [byte[]]@(0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 53)
                A2    = [byte[]]@(0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 54)
                # An alias, then the alias's address under its own name, written out in labels.
                Alias = [byte[]]@(0xC0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, 6, 3, 119, 101, 98, 0xC0, 16)
                AliasA = [byte[]]@(3, 119, 101, 98, 0xC0, 16, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 55)
                AAAA  = [byte[]]@(0xC0, 12, 0, 28, 0, 1, 0, 0, 0, 60, 0, 16, 32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 83)
            }
            $answer = [System.Collections.Generic.List[byte]]::new()
            $answer.AddRange([byte[]]@(($Id -shr 8), ($Id -band 0xFF), $Flags, $Code, 0, 1, 0, $Records.Count, 0, 0, 0, 0))
            $answer.AddRange($question)
            foreach ($record in $Records) {
                $answer.AddRange($parts[$record])
            }
            [byte[]]$answer.ToArray()[0..($answer.Count - 1 - $Cut)]
        }
    }

    It 'asks for the IPv4 addresses of a name, recursion desired' {
        $query = & $script:dns { ConvertTo-DnsQuery -Id 0x1234 -Name 'dns.example.org.' }
        ($query | ForEach-Object { $_.ToString('x2') }) -join ' ' | Should -Be '12 34 01 00 00 01 00 00 00 00 00 00 03 64 6e 73 07 65 78 61 6d 70 6c 65 03 6f 72 67 00 00 01 00 01'
    }

    It 'asks for an international name in its ASCII form' {
        $query = & $script:dns { ConvertTo-DnsQuery -Id 1 -Name "b$([char]0xFC)cher.example" }
        [System.Text.Encoding]::ASCII.GetString($query, 13, 13) | Should -Be 'xn--bcher-kva'
    }

    It 'refuses a name DNS can''t carry: <Name>' -ForEach @(
        @{ Name = 'an empty label'; Value = 'dns..example.org' }
        @{ Name = 'a label of 64 characters'; Value = ('a' * 64) + '.example' }
        @{ Name = 'a name of 254 characters'; Value = ((1..4 | ForEach-Object { 'a' * 62 }) -join '.') + '.abcde' }
    ) {
        { & $script:dns { param($n) ConvertTo-DnsQuery -Id 1 -Name $n } $Value } | Should -Throw
    }

    It 'reads <Name>' -ForEach @(
        @{ Name = 'an address'; Records = @('A1'); Addresses = '203.0.113.53'; Failure = $null }
        @{ Name = 'two addresses, in order'; Records = @('A1', 'A2'); Addresses = '203.0.113.53,203.0.113.54'; Failure = $null }
        @{ Name = 'an alias''s address'; Records = @('Alias', 'AliasA'); Addresses = '203.0.113.55'; Failure = $null }
        @{ Name = 'an IPv4 address among IPv6 ones'; Records = @('AAAA', 'A1'); Addresses = '203.0.113.53'; Failure = $null }
        @{ Name = 'a name with no IPv4 address'; Records = @('AAAA'); Addresses = ''; Failure = 'The name has no IPv4 address.' }
        @{ Name = 'a name that does not exist'; Code = 0x83; Addresses = ''; Failure = 'No such host is known.' }
        @{ Name = 'a server that failed'; Code = 0x82; Addresses = ''; Failure = 'The DNS server answered with error 2.' }
        @{ Name = 'an answer to another query'; Id = 0x4321; Records = @('A1'); Addresses = ''; Failure = 'The answer is not one to this query.' }
        @{ Name = 'an answer to another name'; Asked = 'dns.example.net'; Records = @('A1'); Addresses = ''; Failure = 'The answer is not one to this query.' }
        @{ Name = 'an answer to another type'; Type = 28; Records = @('A1'); Addresses = ''; Failure = 'The answer is not one to this query.' }
        @{ Name = 'an answer that writes the name in other letters'; Asked = 'DNS.Example.ORG'; Records = @('A1'); Addresses = '203.0.113.53'; Failure = $null }
        @{ Name = 'a query, not an answer'; Flags = 0x01; Records = @('A1'); Addresses = ''; Failure = 'The answer is not one to this query.' }
        @{ Name = 'an answer cut short'; Flags = 0x83; Records = @('A1'); Addresses = ''; Failure = 'The answer was cut short.' }
        @{ Name = 'a record past the end'; Records = @('A1'); Cut = 2; Addresses = ''; Failure = 'The answer is malformed.' }
        @{ Name = 'a name past the end'; Records = @('A1'); Cut = 16; Addresses = ''; Failure = 'The answer is malformed.' }
    ) {
        $options = @{ Records = $Records }
        foreach ($key in 'Id', 'Flags', 'Code', 'Cut', 'Asked', 'Type') {
            if ($_.ContainsKey($key)) {
                $options[$key] = $_[$key]
            }
        }
        $result = & $script:dns { param($d, $q) ConvertFrom-DnsResponse -Data $d -Query $q } (Get-TestAnswer @options) $script:query
        ($result.Addresses -join ',') | Should -Be $Addresses
        $result.Failure | Should -Be $Failure
    }

    It 'reads no answer from a message too short to be one' {
        (& $script:dns { param($q) ConvertFrom-DnsResponse -Data ([byte[]]@(0x12, 0x34, 0x81)) -Query $q } $script:query).Failure | Should -Be 'The answer is not one to this query.'
    }
}

Describe 'Looking a DoH server''s name up' {
    It 'asks the operator''s DNS from the modem''s address, and reads its answer (loopback)' {
        $server = [System.Net.Sockets.UdpClient]::new([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, 0))
        try {
            $server.Client.ReceiveTimeout = 5000
            $lookup = Start-DohNameLookup -Name 'dns.example.org' -Servers '127.0.0.1' -Source '127.0.0.1' -Port $server.Client.LocalEndPoint.Port
            $lookup.Via | Should -Be 'Operator'
            $from = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $query = $server.Receive([ref]$from)
            $from.Address.ToString() | Should -Be '127.0.0.1' -Because 'the query leaves from the address it was bound to'
            $answer = [byte[]]@($query[0], $query[1], 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0) + [byte[]]$query[12..($query.Count - 1)] + [byte[]]@(0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 53)
            [void]$server.Send($answer, $answer.Count, $from)
            [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($lookup.Task), 5000)
            $result = Receive-DohNameLookup -Lookup $lookup
            $result.Addresses | Should -Be @('203.0.113.53')
            $result.Failure | Should -BeNullOrEmpty
            $lookup.Client | Should -BeNullOrEmpty -Because 'the socket is closed once read'
        }
        finally {
            $server.Dispose()
        }
    }

    It 'fails, without throwing, from an address this computer doesn''t have' {
        $lookup = Start-DohNameLookup -Name 'dns.example.org' -Servers '192.0.2.53' -Source '192.0.2.1'
        $lookup.Client | Should -BeNullOrEmpty
        $result = Receive-DohNameLookup -Lookup $lookup
        @($result.Addresses).Count | Should -Be 0
        $result.Failure | Should -Not -BeNullOrEmpty
    }

    It 'takes no answer from an address it didn''t ask' {
        $answer = [System.Net.Sockets.UdpReceiveResult]::new([byte[]]@(0, 1, 0x81, 0x80, 0, 0, 0, 0, 0, 0, 0, 0), [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse('192.0.2.99'), 53))
        $lookup = [pscustomobject]@{ Name = 'dns.example.org'; Via = 'Operator'; Task = [System.Threading.Tasks.Task]::FromResult($answer); Client = $null; Query = [byte[]]@(0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0); Servers = [string[]]@('192.0.2.53') }
        (Receive-DohNameLookup -Lookup $lookup).Failure | Should -Be 'The answer came from another address.'
    }

    It 'reads Windows'' answer: <Name>' -ForEach @(
        @{ Name = 'its IPv4 addresses'; Kind = 'Result'; Addresses = '203.0.113.53'; Failure = $null }
        @{ Name = 'a failure'; Kind = 'Fault'; Addresses = ''; Failure = 'No such host is known.' }
        @{ Name = 'a cancelled lookup'; Kind = 'Cancel'; Addresses = ''; Failure = 'The lookup was cancelled.' }
    ) {
        $task = switch ($Kind) {
            'Result' { [System.Threading.Tasks.Task]::FromResult([System.Net.IPAddress[]]@([System.Net.IPAddress]::Parse('203.0.113.53'), [System.Net.IPAddress]::Parse('2001:db8::53'))) }
            'Fault' { [System.Threading.Tasks.Task]::FromException([System.Net.Sockets.SocketException]::new(11001)) }
            'Cancel' { [System.Threading.Tasks.Task]::FromCanceled([System.Threading.CancellationToken]::new($true)) }
        }
        $result = Receive-DohNameLookup -Lookup ([pscustomobject]@{ Name = 'dns.example.org'; Via = 'Windows'; Task = $task; Client = $null; Query = $null; Servers = $null })
        ($result.Addresses -join ',') | Should -Be $Addresses
        if ($Failure) {
            $result.Failure | Should -Not -BeNullOrEmpty
        }
        else {
            $result.Failure | Should -BeNullOrEmpty
        }
    }

    It 'reads nothing while the lookup runs' {
        $pending = [System.Threading.Tasks.TaskCompletionSource[object]]::new()
        Receive-DohNameLookup -Lookup ([pscustomobject]@{ Via = 'Windows'; Task = $pending.Task; Client = $null }) | Should -BeNullOrEmpty
    }

    It 'closes the socket of a lookup it drops' {
        $lookup = Start-DohNameLookup -Name 'dns.example.org' -Servers '127.0.0.1' -Source '127.0.0.1' -Port 9
        $client = $lookup.Client
        $client | Should -Not -BeNullOrEmpty
        Stop-DohNameLookup -Lookup $lookup
        $lookup.Client | Should -BeNullOrEmpty
        { $client.Send([byte[]]@(0), 1, '127.0.0.1', 9) } | Should -Throw
    }
}

Describe 'The worker and a DoH server named by its template' {
    BeforeAll {
        $script:dns = Get-Module FibocomFm350
    }

    BeforeEach {
        $script:now = [long]10000000
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
        $script:link = New-ModemWorkerLink
        $script:device = New-SimulatedDevice -Scenario Online
        $settings = (ConvertTo-AppSetting -InputObject @{ DnsOverHttps = $true; DohTemplate = 'https://dns.example.org/dns-query' }).Settings
        Export-AppSetting -Settings $settings -Path (Join-Path $script:folder 'settings.json') -Confirm:$false
        $script:worker = New-ModemWorker -Link $script:link -Simulation $script:device -DataFolder $script:folder -Clock { $script:now }
        function Get-TestLog {
            @(Get-ChildItem -Path (Join-Path $script:folder 'logs') -Filter '*.log' | Get-Content)
        }
    }

    AfterEach {
        Close-ModemWorker -Worker $script:worker
        Close-ModemWorkerLink -Link $script:link
    }

    It 'looks the name up at the start, and encrypts the addresses it finds with the template' {
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.State | Should -Be 'Online'
        $script:device.Adapter.DnsServers | Should -Be @('203.0.113.53')
        $script:device.Adapter.DohServers.Template | Should -Be @('https://dns.example.org/dns-query')
        $snapshot.Dns.Name.Host | Should -Be 'dns.example.org'
        $snapshot.Dns.Name.Addresses | Should -Be @('203.0.113.53')
        $snapshot.Dns.Name.Via | Should -Be 'Windows'
        $snapshot.Dns.Name.Next | Should -BeOfType ([DateTimeOffset])
        @(Get-TestLog) -match "DoH server's name looked up: 1 address\(es\), new" | Should -Not -BeNullOrEmpty
        (ConvertTo-WindowView -Snapshot $snapshot).Dns.Text | Should -Match '^Encrypted DNS is on: 203\.0\.113\.53\. Its server, dns\.example\.org, was looked up at \d\d:\d\d; again at \d\d:\d\d\.$'
    }

    It 'looks it up again only every DohRefreshMinutes, and sets a new address at once' {
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.Names['dns.example.org'] = [string[]]@('203.0.113.54')
        $script:now += 59 * 60000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.DnsServers | Should -Be @('203.0.113.53') -Because 'an hour has not gone by'
        $script:now += 60001
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.DnsServers | Should -Be @('203.0.113.54')
        @($script:device.Adapter.DohServers | ForEach-Object Address) | Should -Be @('203.0.113.54')
    }

    It 'asks the operator''s DNS, in the clear, only when Windows can''t look the name up' {
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.Names = @{}
        $script:device.Adapter.OperatorNames['dns.example.org'] = [string[]]@('203.0.113.54')
        $script:now += 61 * 60000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.DnsServers | Should -Be @('203.0.113.54')
        $snapshot = $script:link['Snapshot']
        $snapshot.Dns.Name.Via | Should -Be 'Operator'
        @(Get-TestLog) -match "DoH server's name looked up through the operator's DNS, in the clear: 1 address\(es\), new" | Should -Not -BeNullOrEmpty
        (ConvertTo-WindowView -Snapshot $snapshot).Dns.Text | Should -Match 'through the operator''s DNS, in the clear'
    }

    It 'sets no DNS server while the name has no address, tries again every 30 s, and says why once' {
        $script:device.Adapter.Names = @{}
        $script:device.Adapter.OperatorNames = @{}
        $script:device.Adapter.DnsServers = @('192.0.2.53')
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.State | Should -Be 'Online' -Because 'the connection is up; only its DNS waits'
        @($script:device.Adapter.DnsServers).Count | Should -Be 0 -Because 'the operator''s servers would answer in the clear'
        @($snapshot.Dns.Name.Addresses).Count | Should -Be 0
        $snapshot.Dns.Name.Failure | Should -Be 'No such host is known.'
        (ConvertTo-WindowView -Snapshot $snapshot).Dns.Text | Should -Match '^Encrypted DNS waits for its server''s address: no DNS server is set meanwhile\. dns\.example\.org can''t be looked up'
        $script:now += 29000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:now += 2000
        Invoke-ModemWorkerCycle -Worker $script:worker
        @(Get-TestLog | Where-Object { $_ -match "DoH server's name can't be looked up" }).Count | Should -Be 1 -Because 'the same failure is logged once'
        $script:device.Adapter.Names['dns.example.org'] = [string[]]@('203.0.113.53')
        $script:now += 30000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.DnsServers | Should -Be @('203.0.113.53')
        $script:link['Snapshot'].Dns.Name.Failure | Should -BeNullOrEmpty
    }

    It 'asks the operator''s DNS as soon as the adapter has its address, when Windows can''t' {
        $script:device.Adapter.Names = @{}
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:worker.DohName.Next | Should -BeNullOrEmpty -Because 'the lookup failed before the adapter had its address'
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.DnsServers | Should -Be @('203.0.113.53')
        $script:link['Snapshot'].Dns.Name.Via | Should -Be 'Operator'
    }

    It 'keeps the last addresses while a lookup fails' {
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.Names = @{}
        $script:device.Adapter.OperatorNames = @{}
        $script:now += 61 * 60000
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.DnsServers | Should -Be @('203.0.113.53')
        $snapshot = $script:link['Snapshot']
        $snapshot.Dns.Name.Addresses | Should -Be @('203.0.113.53')
        $snapshot.Dns.Name.Failure | Should -Not -BeNullOrEmpty
    }

    It 'starts over for another name' {
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.Names['dns2.example.org'] = [string[]]@('203.0.113.77')
        $settings = (ConvertTo-AppSetting -InputObject @{ DnsOverHttps = $true; DohTemplate = 'https://dns2.example.org/dns-query' }).Settings
        [void](Send-ModemCommand -Link $script:link -Kind SaveSettings -Parameter @{ Settings = $settings })
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.DnsServers | Should -Be @('203.0.113.77')
        $script:device.Adapter.DohServers.Template | Should -Be @('https://dns2.example.org/dns-query')
        $script:link['Snapshot'].Dns.Name.Host | Should -Be 'dns2.example.org'
    }

    It 'carries the addresses over to the worker that replaces it' {
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        Close-ModemWorker -Worker $script:worker
        $script:device.Adapter.Names = @{}
        $script:device.Adapter.OperatorNames = @{}
        $script:worker = New-ModemWorker -Link $script:link -Simulation $script:device -DataFolder $script:folder -Clock { $script:now } -Previous $snapshot -Generation 2
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.DnsServers | Should -Be @('203.0.113.53') -Because 'the lookup at its start failed, and the last addresses stay'
        $script:link['Snapshot'].Dns.Name.Addresses | Should -Be @('203.0.113.53')
    }

    It 'keeps the servers Windows kept across a restart before any lookup' {
        $script:device.Adapter.Names = @{}
        $script:device.Adapter.OperatorNames = @{}
        $script:device.Adapter.DnsServers = @('203.0.113.53')
        $script:device.Adapter.DohServers = @([pscustomobject]@{ Address = '203.0.113.53'; Template = 'https://dns.example.org/dns-query'; Flags = [uint64]2 })
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.Adapter.DnsServers | Should -Be @('203.0.113.53')
        $script:link['Snapshot'].State | Should -Be 'Online'
    }

    It 'fails a lookup with no answer in time, closes it, and then asks the operator''s DNS' {
        Mock -ModuleName FibocomFm350 Start-DohNameLookup { [pscustomobject]@{ Name = $Name; Via = 'Windows'; Task = [System.Threading.Tasks.Task]::CompletedTask; Client = $null } }
        Mock -ModuleName FibocomFm350 Receive-DohNameLookup { }
        Mock -ModuleName FibocomFm350 Stop-DohNameLookup { }
        $worker = @{
            Settings = (ConvertTo-AppSetting -InputObject @{ DnsOverHttps = $true; DohTemplate = 'https://dns.example.org/dns-query' }).Settings
            DohName  = & $script:dns { Get-WorkerDohNameState }
            Clock    = { $script:now }
            Simulation = $null
            Facts    = [pscustomobject]@{ ContextAddress = '198.51.100.23'; ContextDns = [string[]]@('192.0.2.53', '2001:db8::53') }
            Paths    = @{ Log = Join-Path $script:folder 'logs' }
        }
        & $script:dns { param($w) Update-WorkerDohName -Worker $w } $worker | Should -BeFalse
        $worker.DohName.Lookup.Via | Should -Be 'Windows'
        $script:now += 15000
        & $script:dns { param($w) Update-WorkerDohName -Worker $w } $worker | Should -BeFalse
        Should -Invoke -ModuleName FibocomFm350 Stop-DohNameLookup -Times 1 -Exactly
        Should -Invoke -ModuleName FibocomFm350 Start-DohNameLookup -Times 1 -Exactly -ParameterFilter {
            ($Servers -join ',') -eq '192.0.2.53' -and $Source -eq '198.51.100.23'
        }
        $worker.DohName.Lookup.Via | Should -Be 'Operator'
    }

    It 'waits between cycles while a lookup that fell due is under way' {
        Mock -ModuleName FibocomFm350 Receive-DohNameLookup { }
        Mock -ModuleName FibocomFm350 Stop-DohNameLookup { }
        Invoke-ModemWorkerCycle -Worker $script:worker
        # An hourly lookup fell due and is still waiting for its answer: no simulated adapter
        # answers late, so the lookup under way is set here.
        $never = [System.Threading.Tasks.TaskCompletionSource[object]]::new()
        $script:now += 61 * 60000
        $script:worker.DohName.Lookup = @{ Via = 'Windows'; Started = $script:now; Pending = [pscustomobject]@{ Task = $never.Task; Client = $null }; Result = $null }
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:worker.DohName.Lookup | Should -Not -BeNullOrEmpty
        $script:worker.WaitMs | Should -BeGreaterThan 0 -Because 'a cycle with nothing to wait for would run again at once, a core at 100%'
        $script:worker.WaitMs | Should -BeLessOrEqual 1000 -Because 'the answer is looked for every second'
    }

    It 'drops a lookup under way when it closes' {
        $client = [System.Net.Sockets.UdpClient]::new([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, 0))
        $script:worker.DohName.Lookup = @{ Via = 'Operator'; Started = $script:now; Pending = [pscustomobject]@{ Client = $client }; Result = $null }
        Close-ModemWorker -Worker $script:worker
        $script:worker.DohName.Lookup | Should -BeNullOrEmpty
        { $client.Send([byte[]]@(0), 1, '127.0.0.1', 9) } | Should -Throw
    }
}

Describe 'What the window shows' {
    It 'says <Name>' -ForEach @(
        @{ Name = 'nothing before the adapter is read'; Dns = $null; Text = $null; CanEnable = $true }
        @{ Name = 'off'; Dns = @{ Supported = $true; Encrypted = @(); Known = @('1.1.1.1') }; Text = 'Encrypted DNS is off.'; CanEnable = $true }
        @{ Name = 'on, and for which servers'; Dns = @{ Supported = $true; Encrypted = @('1.1.1.1'); Known = @('1.1.1.1') }; Text = 'Encrypted DNS is on: 1.1.1.1.'; CanEnable = $true }
        @{ Name = 'that this Windows can''t'; Dns = @{ Supported = $false; Encrypted = @(); Known = @() }; Text = 'Encrypted DNS is not available on this Windows: DNS over HTTPS on one adapter needs Windows 11.'; CanEnable = $false }
    ) {
        $snapshot = if ($Dns) { [pscustomobject]@{ Dns = [pscustomobject]$Dns } } else { $null }
        $view = & (Get-Module FibocomFm350.App) { param($s) Get-DnsView -Snapshot $s } $snapshot
        $view.Text | Should -Be $Text
        $view.CanEnable | Should -Be $CanEnable
    }
}

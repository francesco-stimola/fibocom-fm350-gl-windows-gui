# Data-context parsers, fed by documented and captured fixtures played through the simulated modem
# and the channel, and by a matrix of odd lines.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    . "$PSScriptRoot/FixtureAnswer.ps1"
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-AtContextDefinition' {
    It 'reads the modem''s context 0 and the app''s context 1' {
        $contexts = @(ConvertFrom-AtContextDefinition -Lines (Get-FixtureAnswer -Name 'cgdcont.app.txt'))
        $contexts.Cid | Should -Be @(0, 1)
        $contexts[1].PdpType | Should -Be 'IPV4V6'
        $contexts[1].Apn | Should -Be ''
    }

    It 'reads the captured attach context' {
        $context = ConvertFrom-AtContextDefinition -Lines (Get-FixtureAnswer -Name 'cgdcont.attached.txt' -Folder device)
        $context.Cid | Should -Be 0
        $context.PdpType | Should -Be 'IPV4V6'
        $context.Apn | Should -Be ''
    }

    It 'gives nothing for the captured empty answer' {
        ConvertFrom-AtContextDefinition -Lines (Get-FixtureAnswer -Name 'cgdcont.empty.txt' -Folder device) | Should -BeNullOrEmpty
    }

    It 'reads an APN and normalizes the PDP type''s case' {
        $context = ConvertFrom-AtContextDefinition -Lines '+CGDCONT: 1,"ipv4v6","Internet.Example"'
        $context.PdpType | Should -Be 'IPV4V6'
        $context.Apn | Should -Be 'Internet.Example'
    }

    It 'skips <Line>' -ForEach @(
        @{ Line = '+CGDCONT: x,"IP",""' }
        @{ Line = '+CGDCONT: 1' }
        @{ Line = '+CGACT: 1,1' }
    ) {
        ConvertFrom-AtContextDefinition -Lines $Line | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AtContextActivation' {
    It 'reads an active context' {
        $context = ConvertFrom-AtContextActivation -Lines (Get-FixtureAnswer -Name 'cgact.active.txt')
        $context.Cid | Should -Be 1
        $context.Active | Should -BeTrue
    }

    It 'reads <Line>' -ForEach @(
        @{ Line = '+CGACT: 1,0'; Cid = 1; Active = $false }
        @{ Line = '+CGACT: 2, 1'; Cid = 2; Active = $true }
    ) {
        $context = ConvertFrom-AtContextActivation -Lines $Line
        $context.Cid | Should -Be $Cid
        $context.Active | Should -Be $Active
    }

    It 'skips <Line>' -ForEach @(
        @{ Line = '+CGACT: 1' }
        @{ Line = '+CGACT: ,1' }
        @{ Line = 'OK' }
    ) {
        ConvertFrom-AtContextActivation -Lines $Line | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AtContextParameter' {
    It 'reads a dual-stack context: address and mask, gateway, DNS of both families' {
        $context = ConvertFrom-AtContextParameter -Lines (Get-FixtureAnswer -Name 'cgcontrdp.data.txt')
        $context.Cid | Should -Be 1
        $context.BearerId | Should -Be 6
        $context.Apn | Should -Be 'internet'
        $context.IPv4Address | Should -Be '198.51.100.23'
        $context.IPv4PrefixLength | Should -Be 24
        $context.IPv4Gateway | Should -Be '198.51.100.1'
        $context.IPv6Address | Should -Be '2001:db8::17'
        $context.IPv6PrefixLength | Should -Be 64
        $context.IPv6Gateway | Should -BeNullOrEmpty
        $context.Dns | Should -Be @('203.0.113.53', '203.0.113.54', '2001:db8::53')
        $context.Mtu | Should -Be 1500
    }

    It 'reads the captured attach bearer: no address for the host, its DNS, the IMS APN' {
        $context = ConvertFrom-AtContextParameter -Lines (Get-FixtureAnswer -Name 'cgcontrdp.ims.txt' -Folder device)
        $context.Cid | Should -Be 0
        $context.BearerId | Should -Be 5
        $context.Apn | Should -Be 'ims.mnc001.mcc001.gprs'
        $context.IPv4Address | Should -BeNullOrEmpty
        $context.IPv6Address | Should -BeNullOrEmpty
        # The IPv6 line carries only P-CSCF addresses, which are not DNS servers.
        $context.Dns | Should -Be @('192.0.2.53')
        $context.Mtu | Should -Be 1500
    }

    It 'reads the captured app context the network put on the IMS APN: no IPv4 address' {
        $context = ConvertFrom-AtContextParameter -Lines (Get-FixtureAnswer -Name 'cgcontrdp.app-ims.txt' -Folder device)
        $context.Cid | Should -Be 1
        $context.Apn | Should -Be 'ims.mnc001.mcc001.gprs'
        $context.IPv4Address | Should -BeNullOrEmpty
        $context.Dns | Should -Be @('192.0.2.53')
    }

    It 'reads the captured app context on its internet APN: DNS servers, no address' {
        $context = ConvertFrom-AtContextParameter -Lines (Get-FixtureAnswer -Name 'cgcontrdp.app.txt' -Folder device)
        $context.Apn | Should -Be 'internet.mnc001.mcc001.gprs'
        $context.IPv4Address | Should -BeNullOrEmpty
        $context.IPv4PrefixLength | Should -BeNullOrEmpty
        $context.IPv4Gateway | Should -BeNullOrEmpty
        $context.Dns | Should -Be @('192.0.2.53', '192.0.2.54')
    }

    It 'gathers DNS servers from extra lines, without repeating one' {
        $context = ConvertFrom-AtContextParameter -Lines @(
            '+CGCONTRDP: 1,5,"apn","198.51.100.23.255.255.255.255","198.51.100.1","203.0.113.53","203.0.113.54"'
            '+CGCONTRDP: 1,5,"apn","","","203.0.113.55","203.0.113.53"'
        )
        $context.IPv4PrefixLength | Should -Be 32
        $context.Dns | Should -Be @('203.0.113.53', '203.0.113.54', '203.0.113.55')
    }

    It 'gives one object per context, in the order they come' {
        $contexts = @(ConvertFrom-AtContextParameter -Lines @(
                '+CGCONTRDP: 1,5,"a","198.51.100.23.255.255.255.0","","",""'
                '+CGCONTRDP: 2,6,"b","198.51.100.24.255.255.255.0","","",""'
            ))
        $contexts.Cid | Should -Be @(1, 2)
        $contexts.IPv4Address | Should -Be @('198.51.100.23', '198.51.100.24')
    }

    It 'reads <Name>' -ForEach @(
        @{ Name = 'an address without a mask'; Field = '198.51.100.23'; Address = '198.51.100.23'; Prefix = $null }
        @{ Name = 'a mask that is not contiguous'; Field = '198.51.100.23.255.0.255.0'; Address = '198.51.100.23'; Prefix = $null }
        @{ Name = 'a /0 mask'; Field = '198.51.100.23.0.0.0.0'; Address = '198.51.100.23'; Prefix = 0 }
        @{ Name = 'a /30 mask'; Field = '198.51.100.23.255.255.255.252'; Address = '198.51.100.23'; Prefix = 30 }
    ) {
        $context = ConvertFrom-AtContextParameter -Lines "+CGCONTRDP: 1,5,""apn"",""$Field"","""",""203.0.113.53"""
        $context.IPv4Address | Should -Be $Address
        $context.IPv4PrefixLength | Should -Be $Prefix
    }

    It 'reads an IPv6 address written in text form' {
        $context = ConvertFrom-AtContextParameter -Lines '+CGCONTRDP: 1,5,"apn","2001:DB8::17","","2001:db8::53",""'
        $context.IPv6Address | Should -Be '2001:db8::17'
        $context.Dns | Should -Be @('2001:db8::53')
    }

    It 'leaves out an address field it cannot read: <Field>' -ForEach @(
        @{ Field = '198.51.100' }
        @{ Field = '198.51.100.300' }
        @{ Field = 'not.an.address.x' }
        @{ Field = '1.2.3.4.5' }
    ) {
        $context = ConvertFrom-AtContextParameter -Lines "+CGCONTRDP: 1,5,""apn"",""$Field"","""",""203.0.113.53"""
        $context.IPv4Address | Should -BeNullOrEmpty
        $context.Dns | Should -Be @('203.0.113.53')
    }

    It 'skips <Line>' -ForEach @(
        @{ Line = '+CGCONTRDP: x,5,"apn"' }
        @{ Line = '+CGDCONT: 1,"IP","apn"' }
    ) {
        ConvertFrom-AtContextParameter -Lines $Line | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AtContextAuthentication' {
    It 'reads PAP with a user, and says a password is set without returning it' {
        $contexts = @(ConvertFrom-AtContextAuthentication -Lines (Get-FixtureAnswer -Name 'cgauth.pap.txt'))
        $contexts.Cid | Should -Be @(0, 1)
        $contexts[1].Protocol | Should -Be 'PAP'
        $contexts[1].User | Should -Be 'user'
        $contexts[1].PasswordSet | Should -BeTrue
        ($contexts[1] | Out-String) | Should -Not -Match 'secret'
        $contexts[1].PSObject.Properties.Name | Should -Not -Contain 'Password'
    }

    It 'never returns the password the device gives back in clear' {
        $contexts = @(ConvertFrom-AtContextAuthentication -Lines (Get-FixtureAnswer -Name 'cgauth.probe.txt' -Folder device))
        $probe = $contexts | Where-Object Cid -EQ 1
        $probe.Protocol | Should -Be 'PAP'
        $probe.User | Should -Be 'probe'
        $probe.PasswordSet | Should -BeTrue
        $probe.PSObject.Properties.Name | Should -Not -Contain 'Password'
    }

    It 'reads the captured attach context: no authentication' {
        $context = ConvertFrom-AtContextAuthentication -Lines (Get-FixtureAnswer -Name 'cgauth.read.txt' -Folder device)
        $context.Cid | Should -Be 0
        $context.ProtocolCode | Should -Be 0
        $context.Protocol | Should -Be 'None'
        $context.User | Should -Be ''
        $context.PasswordSet | Should -BeFalse
    }

    It 'reads <Line>' -ForEach @(
        @{ Line = '+CGAUTH: 1,2,"u"'; Protocol = 'CHAP'; Code = 2; User = 'u'; PasswordSet = $false }
        @{ Line = '+CGAUTH: 1,3,"",""'; Protocol = $null; Code = 3; User = ''; PasswordSet = $false }
        @{ Line = '+CGAUTH: 1,0'; Protocol = 'None'; Code = 0; User = ''; PasswordSet = $false }
    ) {
        $context = ConvertFrom-AtContextAuthentication -Lines $Line
        $context.Protocol | Should -Be $Protocol
        $context.ProtocolCode | Should -Be $Code
        $context.User | Should -Be $User
        $context.PasswordSet | Should -Be $PasswordSet
    }

    It 'skips <Line>' -ForEach @(
        @{ Line = '+CGAUTH: 1' }
        @{ Line = '+CGAUTH: x,1' }
    ) {
        ConvertFrom-AtContextAuthentication -Lines $Line | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AtContextAddress' {
    It 'reads the captured IPv4 address of the app''s context' {
        $address = ConvertFrom-AtContextAddress -Lines (Get-FixtureAnswer -Name 'cgpaddr.app.txt' -Folder device)
        $address.Cid | Should -Be 1
        $address.IPv4Address | Should -Be '192.0.2.53'
        $address.IPv6Address | Should -BeNullOrEmpty
    }

    It 'reads <Line>' -ForEach @(
        # A context with IPv6 alone gives it first: the family comes from the address.
        @{ Line = '+CGPADDR: 1,"0.0.0.0.0.0.0.0.32.1.13.184.0.0.0.1",""'; IPv4 = $null; IPv6 = '::2001:db8:0:1' }
        @{ Line = '+CGPADDR: 1,"198.51.100.23","32.1.13.184.0.0.0.0.0.0.0.0.0.0.0.23"'; IPv4 = '198.51.100.23'; IPv6 = '2001:db8::17' }
        @{ Line = '+CGPADDR: 1,198.51.100.23'; IPv4 = '198.51.100.23'; IPv6 = $null }
        @{ Line = '+CGPADDR: 1,"",""'; IPv4 = $null; IPv6 = $null }
    ) {
        $address = ConvertFrom-AtContextAddress -Lines $Line
        $address.IPv4Address | Should -Be $IPv4
        $address.IPv6Address | Should -Be $IPv6
    }

    It 'skips a line without a context number' {
        ConvertFrom-AtContextAddress -Lines '+CGPADDR: x,"198.51.100.23"' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AtDnsServer' {
    It 'reads the documented answer' {
        $answer = ConvertFrom-AtDnsServer -Lines (Get-FixtureAnswer -Name 'gtdns.txt')
        $answer.Cid | Should -Be 1
        $answer.Dns | Should -Be @('203.0.113.53', '203.0.113.54')
    }

    It 'reads <Line>' -ForEach @(
        @{ Line = '+GTDNS: 1,203.0.113.53,203.0.113.54'; Dns = @('203.0.113.53', '203.0.113.54') }
        @{ Line = '+GTDNS: 1,"203.0.113.53",""'; Dns = @('203.0.113.53') }
        @{ Line = '+GTDNS: 1,"32.1.13.184.0.0.0.0.0.0.0.0.0.0.0.83","203.0.113.53"'; Dns = @('203.0.113.53', '2001:db8::53') }
        @{ Line = '+GTDNS: 1,"",""'; Dns = @() }
    ) {
        (ConvertFrom-AtDnsServer -Lines $Line).Dns | Should -Be $Dns
    }

    It 'merges the lines of one context' {
        $answer = @(ConvertFrom-AtDnsServer -Lines '+GTDNS: 1,"203.0.113.53",""', '+GTDNS: 1,"2001:db8::53","203.0.113.53"')
        $answer.Count | Should -Be 1
        $answer[0].Dns | Should -Be @('203.0.113.53', '2001:db8::53')
    }
}

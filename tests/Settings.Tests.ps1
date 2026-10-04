# Settings: defaults, validation of every value, the file round trip, and the APN password kept
# apart and encrypted.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-AppSetting' {
    It 'gives the decided defaults for nothing' {
        $result = ConvertTo-AppSetting -InputObject $null
        $result.Problems | Should -BeNullOrEmpty
        $result.Settings.Apn | Should -Be ''
        $result.Settings.PdpType | Should -Be 'IPV4V6'
        $result.Settings.ApnAuthentication | Should -Be 'None'
        $result.Settings.ApnUser | Should -Be ''
        @($result.Settings.DnsServers).Count | Should -Be 0
        $result.Settings.InterfaceMetric | Should -Be 500
        $result.Settings.NetworkMode | Should -Be '' -Because 'the app leaves the modem''s mode alone until the user picks one'
        @($result.Settings.LteBands).Count | Should -Be 0
        @($result.Settings.NrBands).Count | Should -Be 0
        $result.Settings.DnsOverHttps | Should -BeFalse
        $result.Settings.DohTemplate | Should -Be ''
        $result.Settings.DohRefreshMinutes | Should -Be 60 -Because 'a DoH server named by its template is looked up again every hour'
        $result.Settings.CheckForUpdates | Should -BeTrue
        $result.Settings.UsageCycleDay | Should -Be 1 -Because 'the billing cycle is the calendar month until the user says otherwise'
        $result.Settings.UsageQuotaGB | Should -Be 0 -Because 'no quota until the user sets one'
    }

    It 'takes valid values from a hashtable and from an object' {
        $values = @{ Apn = 'internet.example'; PdpType = 'ipv4v6'; ApnAuthentication = 'chap'; ApnUser = 'me'; DnsServers = @('203.0.113.53', '2001:DB8::53'); InterfaceMetric = 10 }
        foreach ($source in $values, [pscustomobject]$values) {
            $result = ConvertTo-AppSetting -InputObject $source
            $result.Problems | Should -BeNullOrEmpty
            $result.Settings.Apn | Should -Be 'internet.example'
            $result.Settings.PdpType | Should -Be 'IPV4V6'
            $result.Settings.ApnAuthentication | Should -Be 'CHAP'
            $result.Settings.ApnUser | Should -Be 'me'
            $result.Settings.DnsServers | Should -Be @('203.0.113.53', '2001:db8::53')
            $result.Settings.InterfaceMetric | Should -Be 10
        }
    }

    It 'replaces an invalid <Name> with its default and says so' -ForEach @(
        @{ Name = 'Apn'; Value = 'bad"apn' }
        @{ Name = 'Apn'; Value = ' padded' }
        @{ Name = 'Apn'; Value = "line`nbreak" }
        @{ Name = 'Apn'; Value = "citt$([char]0xE0)" }
        @{ Name = 'Apn'; Value = 42 }
        @{ Name = 'PdpType'; Value = 'PPP' }
        @{ Name = 'PdpType'; Value = 'IPV6' }
        @{ Name = 'ApnAuthentication'; Value = 'MSCHAP' }
        @{ Name = 'ApnUser'; Value = 'a"b' }
        @{ Name = 'DnsServers'; Value = @('203.0.113.53', 'dns.example') }
        @{ Name = 'DnsServers'; Value = 53 }
        @{ Name = 'InterfaceMetric'; Value = 0 }
        @{ Name = 'InterfaceMetric'; Value = 10000 }
        @{ Name = 'InterfaceMetric'; Value = 2.5 }
        @{ Name = 'InterfaceMetric'; Value = '1,000' }
        @{ Name = 'InterfaceMetric'; Value = $true }
        @{ Name = 'NetworkMode'; Value = 'FiveG' }
        @{ Name = 'NetworkMode'; Value = 20 }
        @{ Name = 'LteBands'; Value = @(3, 100) }
        @{ Name = 'LteBands'; Value = @(0) }
        @{ Name = 'LteBands'; Value = @(3, 3) }
        @{ Name = 'LteBands'; Value = @('B3') }
        @{ Name = 'NrBands'; Value = @(78, 513) }
        @{ Name = 'NrBands'; Value = @($true) }
        @{ Name = 'DnsOverHttps'; Value = 'yes' }
        @{ Name = 'DnsOverHttps'; Value = 1 }
        @{ Name = 'CheckForUpdates'; Value = 'false' }
        @{ Name = 'DohTemplate'; Value = 'http://dns.example/dns-query' }
        @{ Name = 'DohTemplate'; Value = 'dns.example/dns-query' }
        @{ Name = 'DohTemplate'; Value = 'https://dns.example/dns query' }
        @{ Name = 'DohTemplate'; Value = 'https://user:secret@dns.example/dns-query' }
        @{ Name = 'DohTemplate'; Value = 'https://dns.example/"q"' }
        @{ Name = 'DohTemplate'; Value = 'https://dns.example/' + ('a' * 2048) }
        @{ Name = 'DohTemplate'; Value = 42 }
        @{ Name = 'DohRefreshMinutes'; Value = 4 }
        @{ Name = 'DohRefreshMinutes'; Value = 1441 }
        @{ Name = 'DohRefreshMinutes'; Value = 7.5 }
        @{ Name = 'DohRefreshMinutes'; Value = 'hourly' }
        @{ Name = 'DohRefreshMinutes'; Value = $true }
        @{ Name = 'UsageCycleDay'; Value = 0 }
        @{ Name = 'UsageCycleDay'; Value = 32 }
        @{ Name = 'UsageCycleDay'; Value = 1.5 }
        @{ Name = 'UsageCycleDay'; Value = $true }
        @{ Name = 'UsageQuotaGB'; Value = -1 }
        @{ Name = 'UsageQuotaGB'; Value = 10001 }
        @{ Name = 'UsageQuotaGB'; Value = '2,5' }
        @{ Name = 'UsageQuotaGB'; Value = 'NaN' }
        @{ Name = 'UsageQuotaGB'; Value = 'ten' }
        @{ Name = 'UsageQuotaGB'; Value = $true }
    ) {
        $result = ConvertTo-AppSetting -InputObject @{ $Name = $Value }
        $result.Problems.Count | Should -Be 1
        $result.Problems[0] | Should -Match "^$Name "
        $defaults = (ConvertTo-AppSetting -InputObject $null).Settings
        "$($result.Settings.$Name)" | Should -Be "$($defaults.$Name)"
    }

    It 'says which values a rule allows: <Setting>' -ForEach @(
        @{ Setting = 'InterfaceMetric'; Value = 0; Problem = 'InterfaceMetric must be a whole number from 1 to 9999; the default is used.' }
        @{ Setting = 'DohRefreshMinutes'; Value = 2; Problem = 'DohRefreshMinutes must be a whole number of minutes from 5 to 1440; the default is used.' }
        @{ Setting = 'LteBands'; Value = @(0); Problem = 'LteBands must be a list of distinct band numbers from 1 to 99; the default is used.' }
        @{ Setting = 'PdpType'; Value = 'PPP'; Problem = 'PdpType must be one of IP, IPV4V6; the default is used.' }
        @{ Setting = 'UsageCycleDay'; Value = 40; Problem = 'UsageCycleDay must be a whole number from 1 to 31; the default is used.' }
        @{ Setting = 'UsageQuotaGB'; Value = -2; Problem = 'UsageQuotaGB must be a number of gigabytes from 0 to 10000, 0 for none; the default is used.' }
    ) {
        $result = ConvertTo-AppSetting -InputObject @{ $Setting = $Value }
        $result.Problems | Should -Be @($Problem)
        $result.Issues[0].Setting | Should -Be $Setting
    }

    It 'ignores an unknown setting and says so, keeping the others' {
        $result = ConvertTo-AppSetting -InputObject @{ Apn = 'internet'; Colour = 'blue' }
        $result.Problems | Should -Be @("Unknown setting 'Colour' is ignored.")
        $result.Settings.Apn | Should -Be 'internet'
    }

    It 'takes a network mode by its name, in any case, and bands sorted' {
        $result = ConvertTo-AppSetting -InputObject @{ NetworkMode = 'lteonly'; LteBands = @(20, 3, 7); NrBands = 78 }
        $result.Problems | Should -BeNullOrEmpty
        $result.Settings.NetworkMode | Should -Be 'LteOnly'
        $result.Settings.LteBands | Should -Be @(3, 7, 20)
        $result.Settings.NrBands | Should -Be @(78)
        (ConvertTo-AppSetting -InputObject @{ NetworkMode = 'NrOnly'; NrBands = @('78', 512) }).Settings.NrBands | Should -Be @(78, 512)
    }

    It 'takes a quota in gigabytes with decimals, read in the invariant culture: <Value>' -ForEach @(
        @{ Value = 0.5; Expected = 0.5 }
        @{ Value = '2.5'; Expected = 2.5 }
        @{ Value = 10; Expected = 10 }
        @{ Value = '10000'; Expected = 10000 }
        @{ Value = 0; Expected = 0 }
    ) {
        $result = ConvertTo-AppSetting -InputObject @{ UsageQuotaGB = $Value; UsageCycleDay = '31' }
        $result.Problems | Should -BeNullOrEmpty
        $result.Settings.UsageQuotaGB | Should -Be $Expected
        $result.Settings.UsageCycleDay | Should -Be 31
    }

    It 'accepts a metric written as text, read in the invariant culture' {
        (ConvertTo-AppSetting -InputObject @{ InterfaceMetric = '25' }).Settings.InterfaceMetric | Should -Be 25
    }

    It 'takes encrypted DNS for the servers of the override, with a template or without' {
        $result = ConvertTo-AppSetting -InputObject @{ DnsServers = @('1.1.1.1', '1.0.0.1'); DnsOverHttps = $true }
        $result.Problems | Should -BeNullOrEmpty
        $result.Settings.DnsOverHttps | Should -BeTrue
        $template = 'https://dns.example/dns-query{?dns}'
        $result = ConvertTo-AppSetting -InputObject @{ DnsServers = @('203.0.113.53'); DnsOverHttps = $true; DohTemplate = $template; CheckForUpdates = $false }
        $result.Problems | Should -BeNullOrEmpty
        $result.Settings.DohTemplate | Should -Be $template
        $result.Settings.CheckForUpdates | Should -BeFalse
    }

    It 'keeps encrypted DNS without servers, and says it needs them: no server is set in the clear' {
        $result = ConvertTo-AppSetting -InputObject @{ DnsOverHttps = $true }
        $result.Settings.DnsOverHttps | Should -BeTrue -Because 'falling back to the operator''s servers would send queries in the clear'
        $result.Problems | Should -HaveCount 1
        $result.Problems[0] | Should -Match '^DnsOverHttps needs DnsServers'
        { Export-AppSetting -Settings @{ DnsOverHttps = $true } -Path (Join-Path $TestDrive 'never.json') -Confirm:$false -ErrorAction Stop } | Should -Throw
    }

    It 'takes encrypted DNS without servers when the template names its server' {
        $result = ConvertTo-AppSetting -InputObject @{ DnsOverHttps = $true; DohTemplate = 'https://dns.example.org/dns-query'; DohRefreshMinutes = '5' }
        $result.Problems | Should -BeNullOrEmpty
        @($result.Settings.DnsServers).Count | Should -Be 0
        $result.Settings.DohRefreshMinutes | Should -Be 5
        (ConvertTo-AppSetting -InputObject @{ DohRefreshMinutes = 1440 }).Settings.DohRefreshMinutes | Should -Be 1440
    }

    It 'takes a template naming an IP address for that server alone' {
        $alone = ConvertTo-AppSetting -InputObject @{ DnsServers = @('203.0.113.53'); DnsOverHttps = $true; DohTemplate = 'https://203.0.113.53/dns-query' }
        $alone.Problems | Should -BeNullOrEmpty
        $alone.Settings.DohTemplate | Should -Be 'https://203.0.113.53/dns-query'
        $more = ConvertTo-AppSetting -InputObject @{ DnsServers = @('203.0.113.53', '203.0.113.54'); DnsOverHttps = $true; DohTemplate = 'https://203.0.113.53/dns-query' }
        $more.Settings.DohTemplate | Should -Be ''
        $more.Problems | Should -HaveCount 1
        $more.Problems[0] | Should -Match '^DohTemplate names the address 203\.0\.113\.53'
    }

    It 'takes a single DNS server for a list of one, and null for none' {
        (ConvertTo-AppSetting -InputObject @{ DnsServers = '203.0.113.53' }).Settings.DnsServers | Should -Be @('203.0.113.53')
        @((ConvertTo-AppSetting -InputObject @{ DnsServers = $null }).Settings.DnsServers).Count | Should -Be 0
    }
}

Describe 'Settings file' {
    BeforeEach {
        $script:path = Join-Path $TestDrive "settings-$([guid]::NewGuid()).json"
    }

    It 'gives the defaults without a problem when the file is missing' {
        $result = Import-AppSetting -Path $script:path
        $result.Problems | Should -BeNullOrEmpty
        $result.Settings.InterfaceMetric | Should -Be 500
        $result.Settings.NetworkMode | Should -Be '' -Because 'the app leaves the modem''s mode alone until the user picks one'
        @($result.Settings.LteBands).Count | Should -Be 0
        @($result.Settings.NrBands).Count | Should -Be 0
    }

    It 'reads back what it wrote' {
        Export-AppSetting -Path $script:path -Settings ([pscustomobject]@{ Apn = 'internet'; DnsServers = @('203.0.113.53'); InterfaceMetric = 20 })
        $result = Import-AppSetting -Path $script:path
        $result.Problems | Should -BeNullOrEmpty
        $result.Settings.Apn | Should -Be 'internet'
        $result.Settings.DnsServers | Should -Be @('203.0.113.53')
        $result.Settings.InterfaceMetric | Should -Be 20
        $result.Settings.PdpType | Should -Be 'IPV4V6'
    }

    It 'reads back a network mode with one band, and with none' {
        Export-AppSetting -Path $script:path -Settings @{ NetworkMode = 'Automatic'; LteBands = @(20); NrBands = @() }
        $result = Import-AppSetting -Path $script:path
        $result.Problems | Should -BeNullOrEmpty
        $result.Settings.NetworkMode | Should -Be 'Automatic'
        $result.Settings.LteBands | Should -Be @(20)
        , $result.Settings.LteBands | Should -BeOfType ([int[]])
        @($result.Settings.NrBands).Count | Should -Be 0
    }

    It 'refuses to write an invalid setting, and leaves the file as it was' {
        Export-AppSetting -Path $script:path -Settings @{ Apn = 'internet' }
        { Export-AppSetting -Path $script:path -Settings @{ Apn = 'bad"apn' } -ErrorAction Stop } | Should -Throw '*Apn*'
        (Import-AppSetting -Path $script:path).Settings.Apn | Should -Be 'internet'
    }

    It 'falls back to the defaults on a damaged file, and says so' {
        Set-Content -LiteralPath $script:path -Value '{ "Apn": "intern'
        $result = Import-AppSetting -Path $script:path
        $result.Problems.Count | Should -Be 1
        $result.Problems[0] | Should -Match "can't be read"
        $result.Settings.Apn | Should -Be ''
    }

    It 'creates the folder it writes into, and leaves no temporary file' {
        $nested = Join-Path $TestDrive "new-folder-$([guid]::NewGuid())/settings.json"
        Export-AppSetting -Path $nested -Settings @{ }
        Test-Path -LiteralPath $nested | Should -BeTrue
        Test-Path -LiteralPath "$nested.tmp" | Should -BeFalse
    }
}

Describe 'APN password' {
    BeforeEach {
        $script:path = Join-Path $TestDrive "apn-$([guid]::NewGuid()).dat"
        $script:secret = [securestring]::new()
        foreach ($character in 'pa ss!word'.ToCharArray()) { $script:secret.AppendChar($character) }
    }

    It 'stores it encrypted and gives it back' {
        Save-ApnPassword -Password $script:secret -Path $script:path
        Get-Content -LiteralPath $script:path -Raw | Should -Not -Match 'pa ss!word'
        [System.Net.NetworkCredential]::new('', (Get-ApnPassword -Path $script:path)).Password | Should -Be 'pa ss!word'
    }

    It 'gives nothing when none is stored, or once removed' {
        Get-ApnPassword -Path $script:path | Should -BeNullOrEmpty
        Save-ApnPassword -Password $script:secret -Path $script:path
        Remove-ApnPassword -Path $script:path
        Get-ApnPassword -Path $script:path | Should -BeNullOrEmpty
    }

    It 'gives nothing for a file it cannot decrypt' {
        Set-Content -LiteralPath $script:path -Value 'not-a-dpapi-blob'
        Get-ApnPassword -Path $script:path | Should -BeNullOrEmpty
    }

    It 'refuses a password that cannot travel in an AT command' {
        $quoted = [securestring]::new()
        foreach ($character in 'a"b'.ToCharArray()) { $quoted.AppendChar($character) }
        { Save-ApnPassword -Password $quoted -Path $script:path -ErrorAction Stop } | Should -Throw '*printable ASCII*'
        Test-Path -LiteralPath $script:path | Should -BeFalse
    }
}

Describe 'Settings kept for each SIM' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive "sims-$([guid]::NewGuid())"
        [void](New-Item -ItemType Directory -Path $script:folder)
        $script:path = Join-Path $script:folder 'sim-settings.json'
        $script:settingsPath = Join-Path $script:folder 'settings.json'
        $script:secretPath = Join-Path $script:folder 'apn-password.dat'
        # Two SIMs' fingerprints (Get-SimFingerprint's: 64 hexadecimal digits).
        $script:one = 'A' * 64
        $script:two = 'B' * 64
        $script:secret = [securestring]::new()
        foreach ($character in 'pa ss!word'.ToCharArray()) { $script:secret.AppendChar($character) }
    }

    It 'has no file and no SIM at first' {
        $read = Import-SimSetting -Path $script:path
        $read.Exists | Should -BeFalse
        @($read.Sims).Count | Should -Be 0
    }

    It 'keeps each SIM''s APN settings apart, and gives them back' {
        $first = Save-SimSetting -Fingerprint $script:one -Setting @{ Apn = 'internet'; PdpType = 'IP' } -Path $script:path
        $second = Save-SimSetting -Fingerprint $script:two -Setting @{ Apn = 'truphone.com'; ApnAuthentication = 'PAP'; ApnUser = 'user' } -Path $script:path
        $first.Id | Should -Match '^[0-9a-f]{32}$'
        $second.Id | Should -Not -Be $first.Id
        $read = Import-SimSetting -Path $script:path
        $read.Exists | Should -BeTrue
        $one = $read.Sims | Where-Object Fingerprint -EQ $script:one
        $one.Id | Should -Be $first.Id
        $one.Apn | Should -Be 'internet'
        $one.PdpType | Should -Be 'IP'
        $one.ApnAuthentication | Should -Be 'None'
        $two = $read.Sims | Where-Object Fingerprint -EQ $script:two
        $two.Apn | Should -Be 'truphone.com'
        $two.ApnAuthentication | Should -Be 'PAP'
        $two.ApnUser | Should -Be 'user'
    }

    It 'replaces a SIM''s settings, its Id kept' {
        $first = Save-SimSetting -Fingerprint $script:one -Setting @{ Apn = 'internet' } -Path $script:path
        $again = Save-SimSetting -Fingerprint $script:one -Setting ([pscustomobject]@{ Apn = 'web'; InterfaceMetric = 20 }) -Path $script:path
        $again.Id | Should -Be $first.Id
        $read = Import-SimSetting -Path $script:path
        @($read.Sims).Count | Should -Be 1
        $read.Sims[0].Apn | Should -Be 'web'
        $read.Sims[0].PSObject.Properties['InterfaceMetric'] | Should -BeNullOrEmpty -Because 'only the APN settings are a SIM''s'
    }

    It 'keeps no fingerprint in the clear' {
        [void](Save-SimSetting -Fingerprint $script:one -Setting @{ Apn = 'internet' } -Path $script:path)
        Get-Content -LiteralPath $script:path -Raw | Should -Not -Match $script:one
    }

    It 'refuses settings that are not valid, and writes nothing' {
        { Save-SimSetting -Fingerprint $script:one -Setting @{ Apn = 'a"b' } -Path $script:path -ErrorAction Stop } | Should -Throw '*not saved*'
        Test-Path -LiteralPath $script:path | Should -BeFalse
    }

    It 'leaves out an entry it cannot decrypt, or whose values are not valid' {
        [void](Save-SimSetting -Fingerprint $script:one -Setting @{ Apn = 'internet' } -Path $script:path)
        $content = Get-Content -LiteralPath $script:path -Raw | ConvertFrom-Json
        $sim = $content.Sims[0].Sim
        $content.Sims = @(
            $content.Sims[0]
            [pscustomobject]@{ Sim = 'not-a-dpapi-blob'; Id = '0' * 32; Apn = 'x'; PdpType = 'IP'; ApnAuthentication = 'None'; ApnUser = '' }
            [pscustomobject]@{ Sim = $sim; Id = 'not-an-id'; Apn = 'x'; PdpType = 'IP'; ApnAuthentication = 'None'; ApnUser = '' }
            [pscustomobject]@{ Sim = $sim; Id = '1' * 32; Apn = 'x'; PdpType = 'IPV6'; ApnAuthentication = 'None'; ApnUser = '' }
        )
        $content | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:path
        $read = Import-SimSetting -Path $script:path
        @($read.Sims).Count | Should -Be 1
        $read.Sims[0].Apn | Should -Be 'internet'
    }

    It 'holds no SIM in a file it cannot read' {
        Set-Content -LiteralPath $script:path -Value '{ not json'
        $read = Import-SimSetting -Path $script:path
        $read.Exists | Should -BeTrue
        @($read.Sims).Count | Should -Be 0
    }

    It 'forgets one SIM''s settings and its password, the others kept' {
        $first = Save-SimSetting -Fingerprint $script:one -Setting @{ Apn = 'internet' } -Path $script:path
        [void](Save-SimSetting -Fingerprint $script:two -Setting @{ Apn = 'web' } -Path $script:path)
        $password = Get-SimApnSecretPath -ApnSecretPath $script:secretPath -Id $first.Id
        Save-ApnPassword -Password $script:secret -Path $password
        Remove-SimSetting -Fingerprint $script:one -Path $script:path -ApnSecretPath $script:secretPath
        Test-Path -LiteralPath $password | Should -BeFalse
        @((Import-SimSetting -Path $script:path).Sims | ForEach-Object Fingerprint) | Should -Be @($script:two)
    }

    It 'forgets nothing for a SIM without settings of its own' {
        [void](Save-SimSetting -Fingerprint $script:one -Setting @{ Apn = 'internet' } -Path $script:path)
        Remove-SimSetting -Fingerprint $script:two -Path $script:path -ApnSecretPath $script:secretPath
        @((Import-SimSetting -Path $script:path).Sims).Count | Should -Be 1
    }

    It 'keeps a SIM''s password beside the old one, named by its Id alone' {
        $id = '0' * 32
        Get-SimApnSecretPath -ApnSecretPath 'C:\data\apn-password.dat' -Id $id | Should -Be "C:\data\apn-password-$id.dat"
        Get-SimApnSecretPath -ApnSecretPath 'C:\data\apn-password.dat' -Id $null | Should -Be 'C:\data\apn-password.dat'
    }

    It 'tells a SIM by its ICCID with or without the filler F' {
        InModuleScope FibocomFm350 {
            Get-SimSettingFingerprint -Iccid '8900100000000000000f' | Should -Be (Get-SimSettingFingerprint -Iccid '8900100000000000000')
            Get-SimSettingFingerprint -Iccid '8900100000000000000' | Should -Not -Be (Get-SimSettingFingerprint -Iccid '8900100000000000001')
        }
    }

    Context 'the APN settings saved before each SIM had its own' {
        It 'go to the SIM in use, password too, and leave the settings file' {
            Export-AppSetting -Settings @{ Apn = 'internet'; ApnAuthentication = 'CHAP'; ApnUser = 'me'; InterfaceMetric = 30 } -Path $script:settingsPath
            Save-ApnPassword -Password $script:secret -Path $script:secretPath
            $entry = Move-ApnSettingToSim -Fingerprint $script:one -SettingsPath $script:settingsPath -Path $script:path -ApnSecretPath $script:secretPath
            $entry.Apn | Should -Be 'internet'
            $read = Import-SimSetting -Path $script:path
            @($read.Sims).Count | Should -Be 1
            $read.Sims[0].Fingerprint | Should -Be $script:one
            $read.Sims[0].ApnAuthentication | Should -Be 'CHAP'
            $read.Sims[0].ApnUser | Should -Be 'me'
            Test-Path -LiteralPath $script:secretPath | Should -BeFalse
            $moved = Get-ApnPassword -Path (Get-SimApnSecretPath -ApnSecretPath $script:secretPath -Id $entry.Id)
            [System.Net.NetworkCredential]::new('', $moved).Password | Should -Be 'pa ss!word'
            $settings = (Import-AppSetting -Path $script:settingsPath).Settings
            $settings.Apn | Should -Be ''
            $settings.ApnAuthentication | Should -Be 'None'
            $settings.ApnUser | Should -Be ''
            $settings.InterfaceMetric | Should -Be 30 -Because 'the other settings are every SIM''s'
        }

        It 'copy a password that cannot be decrypted as it is: never an empty one' {
            Set-Content -LiteralPath $script:secretPath -Value 'not-a-dpapi-blob' -NoNewline
            $entry = Move-ApnSettingToSim -Fingerprint $script:one -SettingsPath $script:settingsPath -Path $script:path -ApnSecretPath $script:secretPath
            Get-Content -LiteralPath (Get-SimApnSecretPath -ApnSecretPath $script:secretPath -Id $entry.Id) -Raw | Should -Be 'not-a-dpapi-blob'
        }

        It 'go once: a SIM''s settings saved since are never replaced' {
            Export-AppSetting -Settings @{ Apn = 'internet'; ApnAuthentication = 'CHAP'; ApnUser = 'me' } -Path $script:settingsPath
            $first = Move-ApnSettingToSim -Fingerprint $script:one -SettingsPath $script:settingsPath -Path $script:path -ApnSecretPath $script:secretPath
            $saved = Save-SimSetting -Fingerprint $script:one -Setting @{ Apn = 'new.apn'; ApnAuthentication = 'CHAP'; ApnUser = 'u2' } -Path $script:path
            Save-ApnPassword -Password $script:secret -Path (Get-SimApnSecretPath -ApnSecretPath $script:secretPath -Id $saved.Id)
            $again = Move-ApnSettingToSim -Fingerprint $script:one -SettingsPath $script:settingsPath -Path $script:path -ApnSecretPath $script:secretPath
            $again.Id | Should -Be $first.Id
            $again.Apn | Should -Be 'new.apn'
            $read = Import-SimSetting -Path $script:path
            @($read.Sims).Count | Should -Be 1
            $read.Sims[0].Apn | Should -Be 'new.apn'
            $read.Sims[0].ApnUser | Should -Be 'u2'
            Test-Path -LiteralPath (Get-SimApnSecretPath -ApnSecretPath $script:secretPath -Id $first.Id) | Should -BeTrue
            Move-ApnSettingToSim -Fingerprint $script:two -SettingsPath $script:settingsPath -Path $script:path -ApnSecretPath $script:secretPath | Should -BeNullOrEmpty -Because 'another SIM takes nothing'
        }

        It 'stay where they are while the settings file can''t be read, to be tried again' {
            Set-Content -LiteralPath $script:settingsPath -Value '{ not json'
            { Move-ApnSettingToSim -Fingerprint $script:one -SettingsPath $script:settingsPath -Path $script:path -ApnSecretPath $script:secretPath -ErrorAction Stop } |
                Should -Throw '*can''t be read*'
            Test-Path -LiteralPath $script:path | Should -BeFalse
            Get-Content -LiteralPath $script:settingsPath -Raw | Should -Match 'not json' -Because 'the file is left as it is'
        }

        It 'are the defaults when none were saved' {
            $entry = Move-ApnSettingToSim -Fingerprint $script:one -SettingsPath $script:settingsPath -Path $script:path -ApnSecretPath $script:secretPath
            $entry.Apn | Should -Be ''
            $entry.PdpType | Should -Be 'IPV4V6'
            (Import-SimSetting -Path $script:path).Exists | Should -BeTrue
            @(Get-ChildItem -LiteralPath $script:folder -Filter 'apn-password*').Count | Should -Be 0
        }
    }
}

Describe 'Resolve-SimSetting' {
    BeforeAll {
        $script:settings = (ConvertTo-AppSetting -InputObject @{ Apn = 'old'; ApnAuthentication = 'PAP'; ApnUser = 'u'; InterfaceMetric = 20 }).Settings
        $script:kept = [pscustomobject]@{
            Exists = $true
            Sims   = @([pscustomobject]@{ Fingerprint = 'A' * 64; Id = '1' * 32; Apn = 'truphone.com'; PdpType = 'IP'; ApnAuthentication = 'None'; ApnUser = '' })
        }
    }

    It '<Name>' -ForEach @(
        @{ Name = 'a SIM with settings of its own connects with them'; Kept = $true; Fingerprint = 'A' * 64; Source = 'Sim'; Apn = 'truphone.com'; Authentication = 'None'; Id = '1' * 32 }
        @{ Name = 'a SIM without settings of its own gets the subscription''s APN'; Kept = $true; Fingerprint = 'B' * 64; Source = 'New'; Apn = ''; Authentication = 'None'; Id = $null }
        @{ Name = 'before any SIM has its own, a SIM gets the settings file''s'; Kept = $false; Fingerprint = 'B' * 64; Source = 'Legacy'; Apn = 'old'; Authentication = 'PAP'; Id = $null }
        @{ Name = 'with no SIM identified, the settings file''s stay'; Kept = $true; Fingerprint = $null; Source = 'Unknown'; Apn = 'old'; Authentication = 'PAP'; Id = $null }
    ) {
        $sims = if ($Kept) { $script:kept } else { [pscustomobject]@{ Exists = $false; Sims = @() } }
        $own = Resolve-SimSetting -Settings $script:settings -SimSettings $sims -Fingerprint $Fingerprint
        $own.Source | Should -Be $Source
        $own.Id | Should -Be $Id
        $own.Settings.Apn | Should -Be $Apn
        $own.Settings.ApnAuthentication | Should -Be $Authentication
        $own.Settings.InterfaceMetric | Should -Be 20 -Because 'the other settings are every SIM''s'
    }

    It 'takes the settings as a dictionary too, and changes none of them' {
        $own = Resolve-SimSetting -Settings @{ Apn = 'old'; PdpType = 'IPV4V6'; ApnAuthentication = 'None'; ApnUser = '' } -SimSettings $script:kept -Fingerprint ('A' * 64)
        $own.Settings.Apn | Should -Be 'truphone.com'
        $script:settings.Apn | Should -Be 'old'
    }
}

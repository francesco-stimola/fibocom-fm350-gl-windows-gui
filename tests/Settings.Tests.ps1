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
    ) {
        $result = ConvertTo-AppSetting -InputObject @{ $Name = $Value }
        $result.Problems.Count | Should -Be 1
        $result.Problems[0] | Should -Match "^$Name "
        $defaults = (ConvertTo-AppSetting -InputObject $null).Settings
        "$($result.Settings.$Name)" | Should -Be "$($defaults.$Name)"
    }

    It 'ignores an unknown setting and says so, keeping the others' {
        $result = ConvertTo-AppSetting -InputObject @{ Apn = 'internet'; Colour = 'blue' }
        $result.Problems | Should -Be @("Unknown setting 'Colour' is ignored.")
        $result.Settings.Apn | Should -Be 'internet'
    }

    It 'accepts a metric written as text, read in the invariant culture' {
        (ConvertTo-AppSetting -InputObject @{ InterfaceMetric = '25' }).Settings.InterfaceMetric | Should -Be 25
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

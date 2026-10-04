# Data usage (src/FibocomFm350/Usage.ps1): the adapter's counters accumulated across their resets,
# today and the billing cycle, the quota's thresholds said once per cycle, and the file.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    $script:guid = '0b95759a-67d5-43f0-95d7-4717af8c4171'
    $script:other = 'c1a0e3d2-0000-4000-8000-000000000001'

    function Get-TestSample {
        param([uint64] $Received, [uint64] $Sent, [string] $Interface = $script:guid, [string] $At = '2026-10-04T12:00:00')

        [pscustomobject]@{ Interface = $Interface; Received = $Received; Sent = $Sent; Time = [DateTimeOffset]::new([datetime]::Parse($At, [cultureinfo]::InvariantCulture)) }
    }

    function Get-TestUsage {
        # Totals with the given days ('yyyy-MM-dd' = @(received, sent)).
        param([hashtable] $Days = @{}, [uint64] $Received = 0, [uint64] $Sent = 0, [string] $Interface = $script:guid)

        $ordered = [ordered]@{}
        foreach ($key in $Days.Keys | Sort-Object) {
            $ordered[$key] = [pscustomobject]@{ Received = [uint64]$Days[$key][0]; Sent = [uint64]$Days[$key][1] }
        }
        [pscustomobject]@{ Interface = $Interface; Received = $Received; Sent = $Sent; Days = $ordered }
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Update-DataUsage' {
    It 'starts counting at the first sample, adding nothing' {
        $usage = Update-DataUsage -State $null -Sample (Get-TestSample -Received 5000 -Sent 700)

        $usage.Days.Count | Should -Be 0
        $usage.Received | Should -Be 5000
        $usage.Sent | Should -Be 700
        $usage.Interface | Should -Be $script:guid
    }

    It 'adds <Name>' -ForEach @(
        @{ Name = 'what the counters grew by'; Last = @(1000, 100); Now = @(1600, 150); Interface = 'same'; Added = @(600, 50) }
        @{ Name = 'a counter that restarted, its whole value'; Last = @(1000, 100); Now = @(300, 40); Interface = 'same'; Added = @(300, 40) }
        @{ Name = 'each counter on its own'; Last = @(1000, 100); Now = @(200, 150); Interface = 'same'; Added = @(200, 50) }
        @{ Name = 'another adapter''s whole values'; Last = @(1000, 100); Now = @(1500, 200); Interface = 'other'; Added = @(1500, 200) }
    ) {
        $state = Get-TestUsage -Received $Last[0] -Sent $Last[1] -Days @{ '2026-10-04' = @(10, 1) }
        $interface = if ($Interface -eq 'same') { $script:guid } else { $script:other }
        $usage = Update-DataUsage -State $state -Sample (Get-TestSample -Received $Now[0] -Sent $Now[1] -Interface $interface)

        $usage.Days['2026-10-04'].Received | Should -Be (10 + $Added[0])
        $usage.Days['2026-10-04'].Sent | Should -Be (1 + $Added[1])
        $usage.Received | Should -Be $Now[0]
        $usage.Sent | Should -Be $Now[1]
        $usage.Interface | Should -Be $interface
    }

    It 'adds no day when nothing moved' {
        $usage = Update-DataUsage -State (Get-TestUsage -Received 10 -Sent 10) -Sample (Get-TestSample -Received 10 -Sent 10)

        $usage.Days.Count | Should -Be 0
    }

    It 'puts what a sample adds on its own local day' {
        $state = Get-TestUsage -Received 0 -Sent 0
        $state = Update-DataUsage -State $state -Sample (Get-TestSample -Received 100 -Sent 0 -At '2026-10-04T23:59:00')
        $state = Update-DataUsage -State $state -Sample (Get-TestSample -Received 250 -Sent 0 -At '2026-10-05T00:01:00')

        $state.Days['2026-10-04'].Received | Should -Be 100
        $state.Days['2026-10-05'].Received | Should -Be 150
    }

    It 'keeps the last 100 days' {
        $days = @{}
        $first = [datetime]'2026-01-01'
        foreach ($i in 0..99) { $days[$first.AddDays($i).ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)] = @(1, 1) }
        $usage = Update-DataUsage -State (Get-TestUsage -Days $days) -Sample (Get-TestSample -Received 5 -Sent 0 -At '2026-10-04T12:00:00')

        $usage.Days.Count | Should -Be 100
        $usage.Days.Contains('2026-01-01') | Should -BeFalse
        $usage.Days.Contains('2026-10-04') | Should -BeTrue
    }

    It 'changes nothing it is given' {
        $state = Get-TestUsage -Received 100 -Sent 0 -Days @{ '2026-10-04' = @(1, 1) }
        $null = Update-DataUsage -State $state -Sample (Get-TestSample -Received 900 -Sent 0)

        $state.Received | Should -Be 100
        $state.Days['2026-10-04'].Received | Should -Be 1
    }
}

Describe 'Get-UsageCycleStart' {
    It 'starts the cycle of <Date> with day <Day> on <Start>' -ForEach @(
        @{ Date = '2026-10-04'; Day = 1; Start = '2026-10-01' }
        @{ Date = '2026-10-01'; Day = 1; Start = '2026-10-01' }
        @{ Date = '2026-10-04'; Day = 15; Start = '2026-09-15' }
        @{ Date = '2026-10-15'; Day = 15; Start = '2026-10-15' }
        @{ Date = '2026-01-10'; Day = 15; Start = '2025-12-15' }
        @{ Date = '2026-03-01'; Day = 31; Start = '2026-02-28' }
        @{ Date = '2026-02-28'; Day = 31; Start = '2026-02-28' }
        @{ Date = '2026-02-27'; Day = 31; Start = '2026-01-31' }
        @{ Date = '2028-02-29'; Day = 30; Start = '2028-02-29' }
        @{ Date = '2026-12-31'; Day = 31; Start = '2026-12-31' }
        @{ Date = '2026-05-30'; Day = 31; Start = '2026-04-30' }
    ) {
        $start = Get-UsageCycleStart -Date ([datetime]::ParseExact($Date, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)) -Day $Day

        $start.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) | Should -Be $Start
    }

    It 'refuses a day of <Day>' -ForEach @(@{ Day = 0 }, @{ Day = 32 }) {
        { Get-UsageCycleStart -Date ([datetime]'2026-10-04') -Day $Day -ErrorAction Stop } | Should -Throw
    }
}

Describe 'Measure-DataUsage' {
    BeforeAll {
        $script:state = Get-TestUsage -Days @{
            '2026-08-31' = @(5000, 500)
            '2026-09-01' = @(1000, 100)
            '2026-09-30' = @(2000, 200)
            '2026-10-04' = @(300, 30)
            # The next cycle's first day, once the clock was set back: never in this cycle.
            '2026-11-01' = @(7000, 700)
        }
        $script:now = [DateTimeOffset]::new([datetime]'2026-10-04T15:00:00')
    }

    It 'sums today and the cycle that started on day <Day>' -ForEach @(
        @{ Day = 1; CycleTotal = 330; Start = '2026-10-01'; End = '2026-11-01' }
        @{ Day = 30; CycleTotal = 2530; Start = '2026-09-30'; End = '2026-10-30' }
        @{ Day = 31; CycleTotal = 2530; Start = '2026-09-30'; End = '2026-10-31' }
    ) {
        # Day 31: September has no 31st, so its cycle began on its last day.
        $usage = Measure-DataUsage -State $script:state -Now $script:now -CycleDay $Day

        $usage.Today.Received | Should -Be 300
        $usage.Today.Sent | Should -Be 30
        $usage.Today.Total | Should -Be 330
        $usage.CycleStart.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) | Should -Be $Start
        $usage.CycleEnd.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) | Should -Be $End
        $usage.Cycle.Total | Should -Be $CycleTotal
    }

    It 'measures the quota: <Name>' -ForEach @(
        @{ Name = 'none'; Quota = 0; Used = 5e9; Percent = $null; Threshold = $null }
        @{ Name = 'below the first threshold'; Quota = 10; Used = 7.99e9; Percent = 79.9; Threshold = $null }
        @{ Name = 'at 80%'; Quota = 10; Used = 8e9; Percent = 80; Threshold = 80 }
        @{ Name = 'used up'; Quota = 10; Used = 10e9; Percent = 100; Threshold = 100 }
        @{ Name = 'past it'; Quota = 10; Used = 12e9; Percent = 120; Threshold = 100 }
        @{ Name = 'half a gigabyte'; Quota = 0.5; Used = 4.5e8; Percent = 90; Threshold = 80 }
    ) {
        $state = Get-TestUsage -Days @{ '2026-10-02' = @([uint64]$Used, 0) }
        $usage = Measure-DataUsage -State $state -Now $script:now -CycleDay 1 -QuotaGB $Quota

        if ($null -eq $Percent) {
            $usage.Quota | Should -BeNullOrEmpty
            $usage.Percent | Should -BeNullOrEmpty
        }
        else {
            $usage.Quota | Should -Be ([uint64]($Quota * 1e9))
            [Math]::Round($usage.Percent, 6) | Should -Be $Percent
        }
        $usage.Threshold | Should -Be $Threshold
    }

    It 'gives zeros for no totals' {
        $usage = Measure-DataUsage -State $null -Now $script:now

        $usage.Today.Total | Should -Be 0
        $usage.Cycle.Total | Should -Be 0
        $usage.Threshold | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-UsageWarning' {
    BeforeAll {
        function Get-TestMeasure {
            param([Nullable[int]] $Threshold, [string] $Start = '2026-10-01', [Nullable[uint64]] $Quota = 10000000000)
            [pscustomobject]@{ CycleStart = [datetime]$Start; Quota = $Quota; Threshold = $Threshold }
        }
    }

    It 'says nothing below the thresholds' {
        $result = Resolve-UsageWarning -Usage (Get-TestMeasure -Threshold $null) -Said $null

        $result.Warn | Should -BeNullOrEmpty
        $result.Said.Thresholds | Should -BeNullOrEmpty
    }

    It 'says each threshold once per cycle' {
        $first = Resolve-UsageWarning -Usage (Get-TestMeasure -Threshold 80) -Said $null
        $again = Resolve-UsageWarning -Usage (Get-TestMeasure -Threshold 80) -Said $first.Said
        $full = Resolve-UsageWarning -Usage (Get-TestMeasure -Threshold 100) -Said $again.Said
        $still = Resolve-UsageWarning -Usage (Get-TestMeasure -Threshold 100) -Said $full.Said

        $first.Warn | Should -Be 80
        $again.Warn | Should -BeNullOrEmpty
        $full.Warn | Should -Be 100
        $still.Warn | Should -BeNullOrEmpty
        $still.Said.Thresholds | Should -Be @(80, 100)
    }

    It 'says only the highest of two reached at once' {
        $result = Resolve-UsageWarning -Usage (Get-TestMeasure -Threshold 100) -Said $null

        $result.Warn | Should -Be 100
        $result.Said.Thresholds | Should -Be @(80, 100)
    }

    It 'starts over with <Name>' -ForEach @(
        @{ Name = 'a new cycle'; Start = '2026-11-01'; Quota = 10000000000 }
        @{ Name = 'another quota'; Start = '2026-10-01'; Quota = 20000000000 }
    ) {
        $said = (Resolve-UsageWarning -Usage (Get-TestMeasure -Threshold 100) -Said $null).Said
        $result = Resolve-UsageWarning -Usage (Get-TestMeasure -Threshold 80 -Start $Start -Quota $Quota) -Said $said

        $result.Warn | Should -Be 80
        $result.Said.Thresholds | Should -Be @(80)
    }

    It 'says nothing without a quota' {
        (Resolve-UsageWarning -Usage (Get-TestMeasure -Threshold $null -Quota $null) -Said $null).Warn | Should -BeNullOrEmpty
    }
}

Describe 'The usage file' {
    It 'reads back what it wrote, the thresholds said included' {
        $path = Join-Path $TestDrive 'usage.json'
        $state = Get-TestUsage -Received 18000000000 -Sent 42 -Days @{ '2026-10-03' = @(7, 8); '2026-10-04' = @(9000000000, 10) }
        $said = [pscustomobject]@{ CycleStart = [datetime]'2026-10-01'; Quota = [uint64]10000000000; Thresholds = [int[]]@(80) }
        Export-DataUsage -State $state -Warned $said -Path $path -Confirm:$false
        $read = Import-DataUsage -Path $path

        $read.Interface | Should -Be $script:guid
        $read.Received | Should -Be 18000000000
        $read.Sent | Should -Be 42
        @($read.Days.Keys) | Should -Be @('2026-10-03', '2026-10-04')
        $read.Days['2026-10-04'].Received | Should -Be 9000000000
        $read.Warned.CycleStart | Should -Be ([datetime]'2026-10-01')
        $read.Warned.Quota | Should -Be 10000000000
        $read.Warned.Thresholds | Should -Be @(80)
        (Resolve-UsageWarning -Usage ([pscustomobject]@{ CycleStart = [datetime]'2026-10-01'; Quota = [uint64]10000000000; Threshold = 80 }) -Said $read.Warned).Warn | Should -BeNullOrEmpty
    }

    It 'writes no threshold when none was said' {
        $path = Join-Path $TestDrive 'nothing-said.json'
        Export-DataUsage -State (Get-TestUsage) -Warned $null -Path $path -Confirm:$false

        (Import-DataUsage -Path $path).Warned | Should -BeNullOrEmpty
    }

    It 'gives nothing without a file' {
        Import-DataUsage -Path (Join-Path $TestDrive 'missing.json') | Should -BeNullOrEmpty
    }

    It 'gives nothing, with a warning, for <Name>' -ForEach @(
        @{ Name = 'a damaged file'; Content = '{ not json' }
        @{ Name = 'a day that is no date'; Content = '{ "Interface": "x", "Received": 1, "Sent": 1, "Days": { "yesterday": { "Received": 1, "Sent": 1 } } }' }
    ) {
        $path = Join-Path $TestDrive 'damaged.json'
        Set-Content -LiteralPath $path -Value $Content
        $warnings = $null
        $read = Import-DataUsage -Path $path -WarningVariable warnings -WarningAction SilentlyContinue

        $read | Should -BeNullOrEmpty
        $warnings.Count | Should -Be 1
        "$warnings" | Should -Not -Match ([regex]::Escape($TestDrive))
    }

    It 'reads a file without days as none counted' {
        $path = Join-Path $TestDrive 'nodays.json'
        Set-Content -LiteralPath $path -Value '{ "Interface": "x", "Received": 5, "Sent": 6 }'

        (Import-DataUsage -Path $path).Days.Count | Should -Be 0
    }
}

Describe 'Get-ModemAdapterCounter' {
    It 'reads the counters of the adapter with that instance ID' {
        Mock -ModuleName FibocomFm350 Get-NetAdapter {
            [pscustomobject]@{ Name = 'Ethernet'; PnPDeviceID = 'OTHER'; InterfaceGuid = '{c1a0e3d2-0000-4000-8000-000000000001}' }
            [pscustomobject]@{ Name = 'Ethernet 3'; PnPDeviceID = 'USB\MODEM'; InterfaceGuid = '{0b95759a-67d5-43f0-95d7-4717af8c4171}' }
        }
        Mock -ModuleName FibocomFm350 Get-NetAdapterStatistics { [pscustomobject]@{ ReceivedBytes = [uint64]123; SentBytes = [uint64]45 } } -ParameterFilter { $Name -eq 'Ethernet 3' }
        Mock -ModuleName FibocomFm350 Get-NetAdapterStatistics { throw "another adapter: $Name" }

        $counter = Get-ModemAdapterCounter -InstanceId 'USB\MODEM'

        $counter.Interface | Should -Be $script:guid
        $counter.Received | Should -Be 123
        $counter.Sent | Should -Be 45
        $counter.Time | Should -BeOfType ([DateTimeOffset])
    }

    It 'gives nothing when no adapter has that instance ID' {
        Mock -ModuleName FibocomFm350 Get-NetAdapter { [pscustomobject]@{ PnPDeviceID = 'OTHER'; InterfaceGuid = '{c1a0e3d2-0000-4000-8000-000000000001}' } }
        Mock -ModuleName FibocomFm350 Get-NetAdapterStatistics { throw 'not to be read' }

        Get-ModemAdapterCounter -InstanceId 'USB\MODEM' | Should -BeNullOrEmpty
    }
}

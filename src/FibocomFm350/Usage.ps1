# Data usage: the modem adapter's byte counters, accumulated across their resets, per day; today,
# the billing cycle and an optional quota. Design: docs/ARCHITECTURE.md -> SMS, USSD and data usage;
# facts: docs/AT-COMMANDS.md section 10. The decisions are pure functions; reading the counters and
# the file around them is thin.

# Days of totals kept: today, this cycle and the one before, with room.
$script:UsageDaysKept = 100

# Quota thresholds, in percent of the quota, each said once per cycle (decided 2026-10-04).
$script:UsageWarnings = @(80, 100)

function Get-UsageDayKey {
    # The local calendar day a time falls on, as the totals name it.
    param([DateTimeOffset] $Time)

    $Time.LocalDateTime.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
}

function Get-UsageCycleDate {
    # The cycle's first day in a month: -Day, or the month's last day when it has no such day.
    param([int] $Year, [int] $Month, [int] $Day)

    [datetime]::new($Year, $Month, [Math]::Min($Day, [datetime]::DaysInMonth($Year, $Month)))
}

function Update-DataUsage {
    <#
    .SYNOPSIS
        Adds a sample of the modem adapter's byte counters to the usage totals.
    .DESCRIPTION
        A pure function: the totals in, new totals out. -State: Update-DataUsage's last result,
        or $null. -Sample: Interface (the adapter's GUID), Received, Sent (its counters) and Time.

        A counter below its last value restarted from zero - the adapter was created anew, the
        modem reset, the computer restarted -, so its value is what came since; above, the
        difference is. An adapter other than the last one counts its whole value: its counters
        started with it. The very first sample, with nothing before it, only sets where counting
        starts. What a sample adds goes to the local day of its time; traffic while the app was
        closed lands on the day it next samples, unless the counters restarted meanwhile - the
        totals are approximate. The last 100 days are kept.

        Returns Interface, Received and Sent (the counters last seen) and Days: an ordered table of
        'yyyy-MM-dd' to Received and Sent, the bytes counted that day.
    .EXAMPLE
        $usage = Update-DataUsage -State $usage -Sample $sample
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure: returns new totals and changes nothing.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $State,

        [Parameter(Mandatory)]
        [object] $Sample
    )

    $days = [ordered]@{}
    if ($State -and $State.Days) {
        foreach ($key in $State.Days.Keys) {
            $day = $State.Days[$key]
            $days[$key] = [pscustomobject]@{ Received = [uint64]$day.Received; Sent = [uint64]$day.Sent }
        }
    }
    $received = [uint64]$Sample.Received
    $sent = [uint64]$Sample.Sent
    if ($State -and $null -ne $State.Interface) {
        $same = [string]$State.Interface -eq [string]$Sample.Interface
        $addReceived = if ($same -and $received -ge [uint64]$State.Received) { $received - [uint64]$State.Received } else { $received }
        $addSent = if ($same -and $sent -ge [uint64]$State.Sent) { $sent - [uint64]$State.Sent } else { $sent }
        if ($addReceived -or $addSent) {
            $key = Get-UsageDayKey -Time $Sample.Time
            $today = if ($days.Contains($key)) { $days[$key] } else { [pscustomobject]@{ Received = [uint64]0; Sent = [uint64]0 } }
            $days[$key] = [pscustomobject]@{ Received = $today.Received + $addReceived; Sent = $today.Sent + $addSent }
        }
    }
    $kept = [ordered]@{}
    foreach ($key in @($days.Keys | Sort-Object | Select-Object -Last $script:UsageDaysKept)) {
        $kept[$key] = $days[$key]
    }
    [pscustomobject]@{
        Interface = [string]$Sample.Interface
        Received  = $received
        Sent      = $sent
        Days      = $kept
    }
}

function Get-UsageCycleStart {
    <#
    .SYNOPSIS
        Returns the first day of the billing cycle a day falls in.
    .DESCRIPTION
        A pure function. The cycle starts on -Day of each month (1-31); in a month without that
        day, on its last day. Returns the date (time 00:00) as a DateTime of kind Unspecified.
    .EXAMPLE
        Get-UsageCycleStart -Date ([datetime]'2026-10-04') -Day 15
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)]
        [datetime] $Date,

        [Parameter(Mandatory)]
        [ValidateRange(1, 31)]
        [int] $Day
    )

    $date = $Date.Date
    $start = Get-UsageCycleDate -Year $date.Year -Month $date.Month -Day $Day
    if ($date -lt $start) {
        $previous = $date.AddMonths(-1)
        $start = Get-UsageCycleDate -Year $previous.Year -Month $previous.Month -Day $Day
    }
    $start
}

function Measure-DataUsage {
    <#
    .SYNOPSIS
        Sums the usage totals for today and the current billing cycle, against an optional quota.
    .DESCRIPTION
        A pure function. -State: Update-DataUsage's; -Now: the time it is; -CycleDay: the cycle's
        first day of the month (Get-UsageCycleStart); -QuotaGB: the quota in gigabytes (10^9
        bytes), 0 for none.

        Returns Today and Cycle - each Received, Sent, Total in bytes -, CycleStart and CycleEnd
        (the cycle's first day and the day after its last), Quota (bytes, or $null), Percent of
        the quota used (or $null) and Threshold: the highest quota threshold reached (80 or 100),
        or $null.
    .EXAMPLE
        Measure-DataUsage -State $usage -Now ([DateTimeOffset]::Now) -CycleDay 1 -QuotaGB 10
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $State,

        [Parameter(Mandatory)]
        [DateTimeOffset] $Now,

        [ValidateRange(1, 31)]
        [int] $CycleDay = 1,

        [ValidateRange(0, [double]::MaxValue)]
        [double] $QuotaGB = 0
    )

    $today = $Now.LocalDateTime.Date
    $start = Get-UsageCycleStart -Date $today -Day $CycleDay
    # The next cycle's first day: the same day of the next month, or its last day.
    $next = $start.AddMonths(1)
    $end = Get-UsageCycleDate -Year $next.Year -Month $next.Month -Day $CycleDay
    $todayKey = $today.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    $sum = { [pscustomobject]@{ Received = [uint64]0; Sent = [uint64]0; Total = [uint64]0 } }
    $day = & $sum
    $cycle = & $sum
    if ($State -and $State.Days) {
        foreach ($key in $State.Days.Keys) {
            $entry = $State.Days[$key]
            $date = [datetime]::ParseExact($key, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
            if ($key -eq $todayKey) {
                $day = [pscustomobject]@{ Received = [uint64]$entry.Received; Sent = [uint64]$entry.Sent; Total = [uint64]$entry.Received + [uint64]$entry.Sent }
            }
            if ($date -ge $start -and $date -lt $end) {
                $cycle = [pscustomobject]@{ Received = $cycle.Received + [uint64]$entry.Received; Sent = $cycle.Sent + [uint64]$entry.Sent; Total = $cycle.Total + [uint64]$entry.Received + [uint64]$entry.Sent }
            }
        }
    }
    $quota = if ($QuotaGB -gt 0) { [uint64][Math]::Round($QuotaGB * 1e9) } else { $null }
    $percent = if ($quota) { 100.0 * $cycle.Total / $quota } else { $null }
    $threshold = if ($null -ne $percent) { $script:UsageWarnings | Where-Object { $percent -ge $_ } | Select-Object -Last 1 } else { $null }
    [pscustomobject]@{
        Today      = $day
        Cycle      = $cycle
        CycleStart = $start
        CycleEnd   = $end
        Quota      = $quota
        Percent    = $percent
        Threshold  = $threshold
    }
}

function Resolve-UsageWarning {
    <#
    .SYNOPSIS
        Decides whether a quota threshold is to be said now, once per cycle.
    .DESCRIPTION
        A pure function. -Usage: Measure-DataUsage's; -Said: what was said so far (this
        function's last Said, or $null). A threshold is said once per cycle and quota: a new
        cycle or another quota starts over. When two are reached at once, only the highest is
        said. Returns Warn (the threshold to say now, or $null) and Said (CycleStart, Quota and
        the Thresholds said), to keep for the next time.
    .EXAMPLE
        $warning = Resolve-UsageWarning -Usage $measure -Said $warning.Said
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Usage,

        [AllowNull()]
        [object] $Said
    )

    $fresh = -not $Said -or $Said.CycleStart -ne $Usage.CycleStart -or $Said.Quota -ne $Usage.Quota
    $before = if ($fresh) { [int[]]@() } else { [int[]]@($Said.Thresholds) }
    $reached = [int[]]@(if ($null -ne $Usage.Threshold) { $script:UsageWarnings | Where-Object { $_ -le $Usage.Threshold } })
    $new = @($reached | Where-Object { $_ -notin $before })
    [pscustomobject]@{
        Warn = if ($new.Count) { $new[-1] } else { $null }
        Said = [pscustomobject]@{
            CycleStart = $Usage.CycleStart
            Quota      = $Usage.Quota
            Thresholds = [int[]]@(@($before) + @($new) | Sort-Object -Unique)
        }
    }
}

function Get-ModemAdapterCounter {
    <#
    .SYNOPSIS
        Reads the byte counters of the modem's network adapter.
    .DESCRIPTION
        The adapter is found by its PnP instance ID, as Get-ModemAdapterState finds it. Reads
        only; needs no administrator rights (docs/AT-COMMANDS.md section 10). Returns Interface
        (its GUID), Received and Sent (bytes) and Time; nothing when no adapter has that ID.
    .EXAMPLE
        Get-ModemAdapterCounter -InstanceId $worker.AdapterInstanceId
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $InstanceId
    )

    $adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object PnPDeviceID -EQ $InstanceId | Select-Object -First 1
    if (-not $adapter) {
        return
    }
    $statistics = Get-NetAdapterStatistics -Name $adapter.Name -IncludeHidden -ErrorAction Stop
    [pscustomobject]@{
        Interface = ([guid]$adapter.InterfaceGuid).ToString()
        Received  = [uint64]$statistics.ReceivedBytes
        Sent      = [uint64]$statistics.SentBytes
        Time      = [DateTimeOffset]::Now
    }
}

function Import-DataUsage {
    <#
    .SYNOPSIS
        Reads the usage totals from their file.
    .DESCRIPTION
        Returns what Update-DataUsage returns, with Warned: the quota thresholds said this cycle
        (Resolve-UsageWarning's Said), or $null. No file gives $null; a file that can't be read,
        or is damaged, gives $null too, with a warning: counting starts again.
    .EXAMPLE
        $usage = Import-DataUsage -Path $path
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $days = [ordered]@{}
        $source = if ($content['Days']) { $content['Days'] } else { @{} }
        foreach ($key in @($source.Keys | Sort-Object)) {
            [void][datetime]::ParseExact($key, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
            $days[$key] = [pscustomobject]@{ Received = [uint64]$source[$key]['Received']; Sent = [uint64]$source[$key]['Sent'] }
        }
        $warned = $content['Warned']
        [pscustomobject]@{
            Interface = if ($content['Interface']) { [string]$content['Interface'] } else { $null }
            Received  = [uint64]$content['Received']
            Sent      = [uint64]$content['Sent']
            Days      = $days
            Warned    = if ($warned) {
                [pscustomobject]@{
                    CycleStart = [datetime]::ParseExact([string]$warned['CycleStart'], 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
                    Quota      = if ($null -ne $warned['Quota']) { [uint64]$warned['Quota'] } else { $null }
                    Thresholds = [int[]]@($warned['Thresholds'])
                }
            }
            else {
                $null
            }
        }
    }
    catch {
        # The exception's type only: its message may name the user's folder.
        Write-Warning "The data usage file can't be read ($($_.Exception.GetType().Name)); counting starts again."
        $null
    }
}

function Export-DataUsage {
    <#
    .SYNOPSIS
        Writes the usage totals to their file.
    .DESCRIPTION
        -State: Update-DataUsage's; -Warned: Resolve-UsageWarning's Said, or $null. The file is
        replaced whole (a temporary file, then a move): a crash never leaves it half written.
        Numbers and dates are written in the invariant culture.
    .EXAMPLE
        Export-DataUsage -State $usage -Path $path
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object] $State,

        [AllowNull()]
        [object] $Warned,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $days = [ordered]@{}
    foreach ($key in $State.Days.Keys) {
        $days[$key] = [ordered]@{ Received = [uint64]$State.Days[$key].Received; Sent = [uint64]$State.Days[$key].Sent }
    }
    $said = if ($Warned) {
        [ordered]@{
            CycleStart = $Warned.CycleStart.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
            Quota      = $Warned.Quota
            Thresholds = [int[]]@($Warned.Thresholds)
        }
    }
    else {
        $null
    }
    $content = [ordered]@{ Interface = $State.Interface; Received = [uint64]$State.Received; Sent = [uint64]$State.Sent; Days = $days; Warned = $said }
    if ($PSCmdlet.ShouldProcess($Path, 'Write the data usage')) {
        Write-AppFile -Path $Path -Content ($content | ConvertTo-Json -Depth 4)
    }
}

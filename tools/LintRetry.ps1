# When Invoke-Lint.ps1 starts another analyzer process, and when it gives a file up: a pure
# decision, tested in tests/Lint.Tests.ps1. Why the linter needs it: the help of Invoke-Lint.ps1.

function Resolve-LintRetry {
    <#
    .SYNOPSIS
        Decides what the next analyzer process gets, after the last one ended.
    .DESCRIPTION
        A pure function: the state before the last process and what it reported in, the new
        state out. Each process analyzes its files in order and stops at the first analyzer
        failure, so the file it broke on is the first one it was given and didn't report as
        analyzed - a process that died without a word included. That file counts one failed
        attempt; it goes first in the next process, a new one.

        A file is given up once -MaxFileAttempts processes have failed on it, and no process
        starts once -MaxProcesses have run: the time a run takes stays bounded. Diagnostics play
        no part here - a file reported as analyzed is done, whatever it was found to contain.

        -Pending: the files not analyzed yet, in order, before the last process ran; -Sent: the
        files that process was given, -Analyzed: those it reported as analyzed (both empty before
        the first process); -Failures: failed attempts per file before it; -Processes: the
        processes run, the last one included.

        Returns Pending (the files still not analyzed), Failures (a new table), Broken (the file
        the last process broke on, or $null), GivenUp (the pending files given up) and Next (the
        files the next process gets, in order; empty when no process should start).
    .EXAMPLE
        Resolve-LintRetry -Pending 'a.ps1', 'b.ps1' -Sent 'a.ps1', 'b.ps1' -Analyzed 'a.ps1' -Processes 1 -MaxFileAttempts 20 -MaxProcesses 80
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [string[]] $Pending = @(),

        [AllowEmptyCollection()]
        [string[]] $Sent = @(),

        [AllowEmptyCollection()]
        [string[]] $Analyzed = @(),

        [hashtable] $Failures = @{},

        [ValidateRange(0, [int]::MaxValue)]
        [int] $Processes = 0,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $MaxFileAttempts,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $MaxProcesses
    )

    $done = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Analyzed | Where-Object { $_ }), [System.StringComparer]::OrdinalIgnoreCase)
    $left = [string[]]@($Pending | Where-Object { -not $done.Contains($_) })
    $counts = @{}
    foreach ($file in $Failures.Keys) {
        $counts[$file] = [int]$Failures[$file]
    }
    $broken = $Sent | Where-Object { -not $done.Contains($_) } | Select-Object -First 1
    if ($broken) {
        $counts[$broken] = [int]$counts[$broken] + 1
    }
    $givenUp = [string[]]@($left | Where-Object { [int]$counts[$_] -ge $MaxFileAttempts })
    $next = if ($Processes -lt $MaxProcesses) {
        $rest = @($left | Where-Object { $_ -notin $givenUp })
        # The file the last process broke on goes first: it is the one a new process is for.
        [string[]]@(@($rest | Where-Object { $_ -eq $broken }) + @($rest | Where-Object { $_ -ne $broken }))
    }
    else {
        [string[]]@()
    }

    [pscustomobject]@{
        Pending  = $left
        Failures = $counts
        Broken   = $broken
        GivenUp  = $givenUp
        Next     = $next
    }
}

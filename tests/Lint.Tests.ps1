# The linter's retry decision (tools/LintRetry.ps1): which files the next analyzer process gets,
# which file the last one broke on, when a file is given up and when no process starts.

BeforeAll {
    . (Join-Path $PSScriptRoot '../tools/LintRetry.ps1')
    $script:limits = @{ MaxFileAttempts = 3; MaxProcesses = 10 }
}

Describe 'Resolve-LintRetry' {
    It '<Name>' -ForEach @(
        @{
            Name = 'before the first process: every file, in order'
            Pending = @('a', 'b', 'c'); Sent = @(); Analyzed = @(); Failures = @{}; Processes = 0
            Left = @('a', 'b', 'c'); Broken = $null; Counts = @{}; GivenUp = @(); Next = @('a', 'b', 'c')
        }
        @{
            Name = 'every file analyzed: nothing more'
            Pending = @('a', 'b'); Sent = @('a', 'b'); Analyzed = @('a', 'b'); Failures = @{}; Processes = 1
            Left = @(); Broken = $null; Counts = @{}; GivenUp = @(); Next = @()
        }
        @{
            Name = 'broken on the third file: that file counts one attempt and goes first'
            Pending = @('a', 'b', 'c', 'd'); Sent = @('a', 'b', 'c', 'd'); Analyzed = @('a', 'b'); Failures = @{}; Processes = 1
            Left = @('c', 'd'); Broken = 'c'; Counts = @{ c = 1 }; GivenUp = @(); Next = @('c', 'd')
        }
        @{
            Name = 'a process that died without a word: its first file is the one it broke on'
            Pending = @('a', 'b'); Sent = @('a', 'b'); Analyzed = @(); Failures = @{}; Processes = 1
            Left = @('a', 'b'); Broken = 'a'; Counts = @{ a = 1 }; GivenUp = @(); Next = @('a', 'b')
        }
        @{
            Name = 'the file retried first, failing again: before the files that come earlier'
            Pending = @('a', 'b', 'c'); Sent = @('c', 'a', 'b'); Analyzed = @(); Failures = @{ c = 1 }; Processes = 2
            Left = @('a', 'b', 'c'); Broken = 'c'; Counts = @{ c = 2 }; GivenUp = @(); Next = @('c', 'a', 'b')
        }
        @{
            Name = 'the file retried first, analyzed: its count stays, the next file broken counts its own'
            Pending = @('a', 'b', 'c'); Sent = @('c', 'a', 'b'); Analyzed = @('c', 'a'); Failures = @{ c = 2 }; Processes = 3
            Left = @('b'); Broken = 'b'; Counts = @{ c = 2; b = 1 }; GivenUp = @(); Next = @('b')
        }
        @{
            Name = 'failures of other files never add up to a file''s'
            Pending = @('a', 'b', 'c'); Sent = @('b', 'c'); Analyzed = @(); Failures = @{ a = 2; c = 2 }; Processes = 4
            Left = @('a', 'b', 'c'); Broken = 'b'; Counts = @{ a = 2; b = 1; c = 2 }; GivenUp = @(); Next = @('b', 'a', 'c')
        }
        @{
            Name = 'a file given up at its last attempt: the others go on'
            Pending = @('c', 'd'); Sent = @('c', 'd'); Analyzed = @(); Failures = @{ c = 2 }; Processes = 3
            Left = @('c', 'd'); Broken = 'c'; Counts = @{ c = 3 }; GivenUp = @('c'); Next = @('d')
        }
        @{
            Name = 'only files given up left: no process'
            Pending = @('c', 'd'); Sent = @('d'); Analyzed = @('d'); Failures = @{ c = 3 }; Processes = 4
            Left = @('c'); Broken = $null; Counts = @{ c = 3 }; GivenUp = @('c'); Next = @()
        }
        @{
            Name = 'the limit of processes reached: no process, files left'
            Pending = @('a', 'b'); Sent = @('a', 'b'); Analyzed = @('a'); Failures = @{}; Processes = 10
            Left = @('b'); Broken = 'b'; Counts = @{ b = 1 }; GivenUp = @(); Next = @()
        }
        @{
            Name = 'one process below the limit: one more'
            Pending = @('a', 'b'); Sent = @('a', 'b'); Analyzed = @('a'); Failures = @{}; Processes = 9
            Left = @('b'); Broken = 'b'; Counts = @{ b = 1 }; GivenUp = @(); Next = @('b')
        }
        @{
            Name = 'paths compared without case, as Windows does'
            Pending = @('C:\Repo\A.ps1', 'C:\Repo\b.ps1'); Sent = @('C:\Repo\A.ps1', 'C:\Repo\b.ps1'); Analyzed = @('c:\repo\a.ps1', 'C:\REPO\B.PS1'); Failures = @{}; Processes = 1
            Left = @(); Broken = $null; Counts = @{}; GivenUp = @(); Next = @()
        }
    ) {
        $state = Resolve-LintRetry -Pending $Pending -Sent $Sent -Analyzed $Analyzed -Failures $Failures -Processes $Processes @script:limits

        $state.Pending | Should -Be $Left
        $state.Broken | Should -Be $Broken
        $state.GivenUp | Should -Be $GivenUp
        $state.Next | Should -Be $Next
        $state.Failures.Count | Should -Be $Counts.Count
        foreach ($file in $Counts.Keys) {
            $state.Failures[$file] | Should -Be $Counts[$file] -Because "the attempts of $file"
        }
    }

    It 'changes nothing it is given' {
        $failures = @{ c = 1 }
        $null = Resolve-LintRetry -Pending 'c', 'd' -Sent 'c', 'd' -Analyzed @() -Failures $failures -Processes 2 @script:limits

        $failures.Count | Should -Be 1
        $failures['c'] | Should -Be 1
    }
}

Describe 'A lint run driven by Resolve-LintRetry' {
    BeforeAll {
        # Runs the linter's loop against a made-up analyzer: -Breaks says how many times in a row
        # it fails on each file before analyzing it (a file it always fails on: a large number).
        function Invoke-FakeLint {
            param([string[]] $Files, [hashtable] $Breaks, [int] $MaxFileAttempts, [int] $MaxProcesses)

            $left = @{}
            foreach ($file in $Breaks.Keys) {
                $left[$file] = $Breaks[$file]
            }
            $processes = 0
            $state = Resolve-LintRetry -Pending $Files -MaxFileAttempts $MaxFileAttempts -MaxProcesses $MaxProcesses
            while ($state.Next.Count -gt 0) {
                $sent = $state.Next
                $processes++
                $analyzed = foreach ($file in $sent) {
                    if ([int]$left[$file] -gt 0) {
                        $left[$file]--
                        break
                    }
                    $file
                }
                $state = Resolve-LintRetry -Pending $state.Pending -Sent $sent -Analyzed @($analyzed) -Failures $state.Failures -Processes $processes `
                    -MaxFileAttempts $MaxFileAttempts -MaxProcesses $MaxProcesses
            }
            [pscustomobject]@{ Processes = $processes; Unanalyzed = $state.Pending; GivenUp = $state.GivenUp }
        }
    }

    It 'analyzes everything when the analyzer never fails, in one process' {
        $run = Invoke-FakeLint -Files 'a', 'b', 'c' -Breaks @{} -MaxFileAttempts 20 -MaxProcesses 80

        $run.Processes | Should -Be 1
        $run.Unanalyzed | Should -BeNullOrEmpty
    }

    It 'analyzes everything when one file fails nineteen times in a row' {
        $run = Invoke-FakeLint -Files 'a', 'big', 'c' -Breaks @{ big = 19 } -MaxFileAttempts 20 -MaxProcesses 80

        $run.Processes | Should -Be 20
        $run.Unanalyzed | Should -BeNullOrEmpty
    }

    It 'analyzes everything when several files fail in turn, more processes in a row analyzing nothing than files' {
        # Three in a row analyzed nothing ended the run before this decision.
        $run = Invoke-FakeLint -Files 'a', 'b', 'c', 'd' -Breaks @{ b = 4; c = 5; d = 6 } -MaxFileAttempts 20 -MaxProcesses 80

        $run.Processes | Should -Be 16
        $run.Unanalyzed | Should -BeNullOrEmpty
    }

    It 'gives up a file that always fails, and analyzes the others' {
        $run = Invoke-FakeLint -Files 'a', 'bad', 'c' -Breaks @{ bad = 1000 } -MaxFileAttempts 20 -MaxProcesses 80

        $run.Processes | Should -Be 21
        $run.Unanalyzed | Should -Be 'bad'
        $run.GivenUp | Should -Be 'bad'
    }

    It 'stops at the limit of processes when the analyzer fails on everything' {
        $files = 1..10 | ForEach-Object { "f$_" }
        $breaks = @{}
        foreach ($file in $files) { $breaks[$file] = 1000 }
        $run = Invoke-FakeLint -Files $files -Breaks $breaks -MaxFileAttempts 20 -MaxProcesses 80

        $run.Processes | Should -Be 80
        $run.Unanalyzed.Count | Should -Be 10
    }
}

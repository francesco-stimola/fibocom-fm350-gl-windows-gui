#Requires -Version 7.6
<#
.SYNOPSIS
    Runs PSScriptAnalyzer on every PowerShell file of the repository.
.DESCRIPTION
    Prints the diagnostics and exits with 1 if there are any, or if a file could not be analyzed;
    0 otherwise.

    PSScriptAnalyzer (1.24 and 1.25 on PowerShell 7.6) intermittently fails its own command
    lookups ("the term 'Get-Command' is not recognized", or "Object reference not set to an
    instance of an object") - an error of the analyzer, not a finding about the file - and once it
    happens, every later lookup in the same process fails too. The odds depend on the file:
    analyzed first in a new process, the largest files of this repository made it fail about one
    time in two, a small one never (12 tries each); limiting the process to one processor changed
    nothing.

    So the files are analyzed one at a time in a child process that stops at the first analyzer
    failure, and what is left goes to a new process, the file it broke on first. Each failure
    counts against that file alone: a file is given up only after -MaxFileAttempts processes in a
    row failed on it - at one chance in two, twenty failures in a row happen about once in a
    million -, and a file given up fails the run. No process starts after -MaxProcesses in all, so
    a run that can't succeed - an analyzer that fails on everything - still ends within minutes.
    Counting failures per file replaces a limit on processes in a row that analyzed nothing,
    which one large file could reach on its own once in eight runs. The decision is
    Resolve-LintRetry (LintRetry.ps1), a pure function with its tests.

    Diagnostics are never retried: a file reported as analyzed is done, whatever it was found to
    contain. A PSScriptAnalyzer that can't be loaded ends the run at once. The list of files
    reaches the child process in a temporary file: on the command line it outgrows Windows' limit
    in a deep folder. The same rules apply on a developer's computer and in CI.

    Under GitHub Actions every diagnostic, and every file left unanalyzed, is also written as an
    annotation: the run then says what failed without its log.
.EXAMPLE
    ./tools/Invoke-Lint.ps1
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int] $MaxFileAttempts = 20,

    [ValidateRange(1, 500)]
    [int] $MaxProcesses = 80
)

. (Join-Path -Path $PSScriptRoot -ChildPath 'LintRetry.ps1')

$root = Split-Path -Parent $PSScriptRoot
$settings = Join-Path -Path $root -ChildPath 'PSScriptAnalyzerSettings.psd1'
$pending = [string[]]@(Get-ChildItem -Path $root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' | ForEach-Object FullName)
$diagnostics = [System.Collections.Generic.List[object]]::new()
$annotate = $env:GITHUB_ACTIONS -eq 'true'

# Runs in the child process: analyzes the listed files until the analyzer itself fails.
$analyze = {
    param([string] $ListPath, [string] $Settings)

    try {
        Import-Module -Name PSScriptAnalyzer -ErrorAction Stop
    }
    catch {
        [pscustomobject]@{ Fatal = "PSScriptAnalyzer can't be loaded: $($_.Exception.Message)" }
        return
    }
    $broken = $false
    foreach ($file in Get-Content -LiteralPath $ListPath) {
        if ($broken) {
            [pscustomobject]@{ Path = $file; Analyzed = $false; Problem = $null; Diagnostics = @() }
            continue
        }
        $analyzerErrors = $null
        $found = @(Invoke-ScriptAnalyzer -Path $file -Settings $Settings -ErrorVariable analyzerErrors -ErrorAction SilentlyContinue)
        if ($analyzerErrors) {
            $broken = $true
            [pscustomobject]@{ Path = $file; Analyzed = $false; Problem = $analyzerErrors[0].Exception.Message; Diagnostics = @() }
        }
        else {
            $records = @($found | Select-Object RuleName, @{ Name = 'Severity'; Expression = { "$($_.Severity)" } }, ScriptName, ScriptPath, Line, Message)
            [pscustomobject]@{ Path = $file; Analyzed = $true; Problem = $null; Diagnostics = $records }
        }
    }
}

$list = New-TemporaryFile
$processes = 0
try {
    $state = Resolve-LintRetry -Pending $pending -MaxFileAttempts $MaxFileAttempts -MaxProcesses $MaxProcesses
    while ($state.Next.Count -gt 0) {
        $sent = $state.Next
        Set-Content -LiteralPath $list -Value $sent -Encoding utf8NoBOM
        $results = @(pwsh -NoProfile -NonInteractive -Command $analyze -args $list.FullName, $settings)
        $processes++
        $fatal = @($results | Where-Object { $_.PSObject.Properties['Fatal'] })
        if ($fatal) {
            Write-Output $fatal[0].Fatal
            exit 1
        }
        $done = @($results | Where-Object Analyzed)
        foreach ($result in $done) {
            $diagnostics.AddRange([object[]]@($result.Diagnostics))
        }
        # Whatever wasn't reported as analyzed stays pending - a child that died silently included.
        $state = Resolve-LintRetry -Pending $state.Pending -Sent $sent -Analyzed @($done | ForEach-Object Path) -Failures $state.Failures `
            -Processes $processes -MaxFileAttempts $MaxFileAttempts -MaxProcesses $MaxProcesses
        if ($state.Broken) {
            $problem = @($results | Where-Object { $_.Path -eq $state.Broken -and $_.Problem } | ForEach-Object Problem) | Select-Object -First 1
            $why = if ($problem) { $problem } else { 'the analyzer process ended early' }
            Write-Warning ("Process ${processes}: the analyzer failed on $([System.IO.Path]::GetRelativePath($root, $state.Broken)) ($why) - " +
                "attempt $($state.Failures[$state.Broken]) of $MaxFileAttempts for that file; $($done.Count) file(s) done, $($state.Pending.Count) left.")
        }
    }
}
finally {
    Remove-Item -LiteralPath $list -Force -ErrorAction SilentlyContinue
}

$unanalyzed = $state.Pending
if ($diagnostics.Count) {
    $diagnostics | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 200 | Write-Output
}
Write-Output ('{0} diagnostic(s); {1} file(s) the analyzer could not finish; {2} process(es).' -f $diagnostics.Count, $unanalyzed.Count, $processes)
if ($unanalyzed.Count) {
    $why = if ($state.GivenUp.Count) { "given up after $MaxFileAttempts failed attempts each: $(($state.GivenUp | ForEach-Object { [System.IO.Path]::GetRelativePath($root, $_) }) -join ', ')" } else { '' }
    $limit = if ($processes -ge $MaxProcesses) { "the limit of $MaxProcesses processes was reached" } else { '' }
    Write-Output "Not analyzed: $(($unanalyzed | ForEach-Object { [System.IO.Path]::GetRelativePath($root, $_) }) -join ', ')"
    Write-Output "Why: $((@($why, $limit) | Where-Object { $_ }) -join '; ')."
}
if ($annotate) {
    # GitHub workflow commands: one annotation per finding, readable on the run's page and its API.
    $escape = { param([string] $text) $text -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A' }
    foreach ($diagnostic in $diagnostics) {
        $file = if ($diagnostic.ScriptPath) { [System.IO.Path]::GetRelativePath($root, $diagnostic.ScriptPath) -replace '\\', '/' } else { $diagnostic.ScriptName }
        Write-Output "::error file=$file,line=$($diagnostic.Line),title=$($diagnostic.RuleName)::$(& $escape $diagnostic.Message)"
    }
    foreach ($file in $unanalyzed) {
        Write-Output "::error file=$([System.IO.Path]::GetRelativePath($root, $file) -replace '\\', '/')::The analyzer could not finish this file."
    }
}
exit [int]($diagnostics.Count -gt 0 -or $unanalyzed.Count -gt 0)

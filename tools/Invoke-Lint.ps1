#Requires -Version 7.6
<#
.SYNOPSIS
    Runs PSScriptAnalyzer on every PowerShell file of the repository.
.DESCRIPTION
    Prints the diagnostics and exits with 1 if there are any, 0 otherwise.

    PSScriptAnalyzer (1.24 and 1.25 on PowerShell 7.6) intermittently fails its own command
    lookups ("the term 'Get-Command' is not recognized") - an error of the analyzer, not a finding
    about the file - and once it happens, every later lookup in the same process fails too. So the
    files are analyzed one at a time in a child process that stops at the first analyzer error,
    and the files left over go to a fresh process, as long as each process gets at least one file
    done: only -StalledAttempts processes in a row that analyze nothing end the run, and a file
    that can't be analyzed then fails it. Diagnostics are never retried away. The list of files
    reaches the child process in a temporary file: on the command line it outgrows Windows' limit
    in a deep folder.

    Under GitHub Actions every diagnostic, and every file left unanalyzed, is also written as an
    annotation: the run then says what failed without its log.
.EXAMPLE
    ./tools/Invoke-Lint.ps1
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int] $StalledAttempts = 3
)

$root = Split-Path -Parent $PSScriptRoot
$settings = Join-Path -Path $root -ChildPath 'PSScriptAnalyzerSettings.psd1'
$pending = @(Get-ChildItem -Path $root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' | ForEach-Object FullName)
$diagnostics = [System.Collections.Generic.List[object]]::new()
$annotate = $env:GITHUB_ACTIONS -eq 'true'

# Runs in the child process: analyzes the listed files until the analyzer itself fails.
$analyze = {
    param([string] $ListPath, [string] $Settings)

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
try {
    $attempt = 0
    $stalled = 0
    while ($pending.Count -gt 0 -and $stalled -lt $StalledAttempts) {
        $attempt++
        Set-Content -LiteralPath $list -Value $pending -Encoding utf8NoBOM
        $results = @(pwsh -NoProfile -NonInteractive -Command $analyze -args $list.FullName, $settings)
        foreach ($result in $results | Where-Object Analyzed) {
            $diagnostics.AddRange([object[]]@($result.Diagnostics))
        }
        # Whatever wasn't reported as analyzed stays pending - a child that died silently included.
        $analyzed = @($results | Where-Object Analyzed | ForEach-Object Path)
        $pending = @($pending | Where-Object { $_ -notin $analyzed })
        $stalled = if ($analyzed.Count -gt 0) { 0 } else { $stalled + 1 }
        if ($pending.Count -eq 0) {
            break
        }
        $failed = @($results | Where-Object { -not $_.Analyzed -and $_.Problem })
        $why = if ($failed) {
            "the analyzer failed on $([System.IO.Path]::GetRelativePath($root, $failed[0].Path)) ($($failed[0].Problem))"
        }
        else {
            'the analyzer process ended early'
        }
        Write-Warning "Attempt ${attempt}: $why; $($analyzed.Count) file(s) done, $($pending.Count) left for a new process."
    }
}
finally {
    Remove-Item -LiteralPath $list -Force -ErrorAction SilentlyContinue
}

if ($diagnostics.Count) {
    $diagnostics | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 200 | Write-Output
}
Write-Output ('{0} diagnostic(s); {1} file(s) the analyzer could not finish.' -f $diagnostics.Count, $pending.Count)
if ($pending.Count) {
    Write-Output "Not analyzed: $(($pending | ForEach-Object { [System.IO.Path]::GetRelativePath($root, $_) }) -join ', ')"
}
if ($annotate) {
    # GitHub workflow commands: one annotation per finding, readable on the run's page and its API.
    $escape = { param([string] $text) $text -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A' }
    foreach ($diagnostic in $diagnostics) {
        $file = if ($diagnostic.ScriptPath) { [System.IO.Path]::GetRelativePath($root, $diagnostic.ScriptPath) -replace '\\', '/' } else { $diagnostic.ScriptName }
        Write-Output "::error file=$file,line=$($diagnostic.Line),title=$($diagnostic.RuleName)::$(& $escape $diagnostic.Message)"
    }
    foreach ($file in $pending) {
        Write-Output "::error file=$([System.IO.Path]::GetRelativePath($root, $file) -replace '\\', '/')::The analyzer could not finish this file."
    }
}
exit [int]($diagnostics.Count -gt 0 -or $pending.Count -gt 0)

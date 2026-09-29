#Requires -Version 7.6
<#
.SYNOPSIS
    Runs PSScriptAnalyzer on every PowerShell file of the repository.
.DESCRIPTION
    Prints the diagnostics and exits with 1 if there are any, 0 otherwise.

    PSScriptAnalyzer (1.24 and 1.25 on PowerShell 7.6) intermittently fails its own command
    lookups ("the term 'Get-Command' is not recognized") - an error of the analyzer, not a finding
    about the file - and once it happens, every later lookup in the same process fails too. So the
    files are analyzed one at a time in a child process that stops at the first analyzer error;
    the files left over go to a fresh process, up to -Attempts times. Only a file that can't be
    analyzed in any attempt fails the run. Diagnostics are never retried away.
.EXAMPLE
    ./tools/Invoke-Lint.ps1
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int] $Attempts = 5
)

$root = Split-Path -Parent $PSScriptRoot
$settings = Join-Path -Path $root -ChildPath 'PSScriptAnalyzerSettings.psd1'
$pending = @(Get-ChildItem -Path $root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' | ForEach-Object FullName)
$diagnostics = [System.Collections.Generic.List[object]]::new()

# Runs in the child process: analyzes files until the analyzer itself fails.
$analyze = {
    param([string[]] $Files, [string] $Settings)

    $broken = $false
    foreach ($file in $Files) {
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
            $records = @($found | Select-Object RuleName, @{ Name = 'Severity'; Expression = { "$($_.Severity)" } }, ScriptName, Line, Message)
            [pscustomobject]@{ Path = $file; Analyzed = $true; Problem = $null; Diagnostics = $records }
        }
    }
}

for ($attempt = 1; $attempt -le $Attempts -and $pending.Count -gt 0; $attempt++) {
    $results = @(pwsh -NoProfile -NonInteractive -Command $analyze -args $pending, $settings)
    foreach ($result in $results | Where-Object Analyzed) {
        $diagnostics.AddRange([object[]]@($result.Diagnostics))
    }
    $failed = @($results | Where-Object { -not $_.Analyzed -and $_.Problem })
    if ($failed) {
        $relative = [System.IO.Path]::GetRelativePath($root, $failed[0].Path)
        Write-Warning "Attempt $attempt of ${Attempts}: the analyzer failed on $relative ($($failed[0].Problem)); retrying the rest in a new process."
    }
    $pending = @($results | Where-Object { -not $_.Analyzed } | ForEach-Object Path)
}

if ($diagnostics.Count) {
    $diagnostics | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 200 | Write-Output
}
Write-Output ('{0} diagnostic(s); {1} file(s) the analyzer could not finish.' -f $diagnostics.Count, $pending.Count)
if ($pending.Count) {
    Write-Output "Not analyzed: $(($pending | ForEach-Object { [System.IO.Path]::GetRelativePath($root, $_) }) -join ', ')"
}
exit [int]($diagnostics.Count -gt 0 -or $pending.Count -gt 0)

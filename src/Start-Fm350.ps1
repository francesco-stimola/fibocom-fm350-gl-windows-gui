#Requires -Version 5.1
<#
.SYNOPSIS
    Starts the FM350-GL app, its installer or its uninstaller with PowerShell 7, found where only
    administrators can write.
.DESCRIPTION
    Runs in Windows PowerShell 5.1, which every supported Windows has at a fixed place in the
    system folder: the logon task, the task the Start-menu shortcut runs, install.cmd and
    uninstall.cmd start this script, never pwsh itself. PowerShell 7 has no fixed path to name: its
    MSIX package - what winget and the Microsoft Store install - lives in a folder named after its
    version, which every update replaces, and its one stable name, the app execution alias, is in
    the user's profile, which the user can write (docs/AT-COMMANDS.md section 11.2). So at every
    start this script looks for it - the MSI's folder and the current user's MSIX package - and
    takes the newest pwsh.exe at version 7.6 or later that is under Program Files and signed by
    Microsoft.

    -Mode App (the default) starts the app (App\Start-Fm350App.ps1) with no console window, and
    returns at once; -Hidden starts it in the tray. -Mode Install and -Mode Uninstall run the
    installer (Installer\Invoke-Fm350Setup.ps1) with administrator rights - one UAC prompt -, wait
    for it and return its exit code. -Mode Install first refuses a Windows the app can't run on:
    only 64-bit Windows on an x64 processor can (docs/AT-COMMANDS.md section 11.2).

    Written for Windows PowerShell 5.1: no syntax or member that PowerShell 7 added.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Start-Fm350.ps1 -Mode Install
#>
[CmdletBinding()]
param(
    [ValidateSet('App', 'Install', 'Uninstall')]
    [string] $Mode = 'App',

    [switch] $Hidden
)

# Only Windows' own modules, set before any command could load one: the user's module folder is
# theirs to write (invariant 10). .NET calls only, until then.
$script:SystemFolder = [Environment]::GetFolderPath('System')
$env:PSModulePath = [IO.Path]::Combine($script:SystemFolder, 'WindowsPowerShell\v1.0\Modules')

# The oldest PowerShell the app runs on (the modules' manifests say the same).
$script:MinimumPwsh = [version]'7.6.0'

# The texts it says, the installer's (Get-SetupText): English until Set-SetupLanguage.
. ([IO.Path]::Combine($PSScriptRoot, 'Installer\Texts.ps1'))

function ConvertTo-LauncherCommandLine {
    # Arguments as one command line, as Windows splits it again: an argument with a blank is
    # quoted, a trailing backslash doubled before the closing quote. No argument here carries a
    # double quote: a path can't.
    param([string[]] $Argument)

    $parts = foreach ($item in $Argument) {
        if ($item.Contains('"')) {
            throw [System.ArgumentException]::new("An argument can't carry a double quote: $item")
        }
        if ($item -eq '' -or $item -match '\s') {
            '"' + ($item -replace '(\\+)$', '$1$1') + '"'
        }
        else {
            $item
        }
    }
    $parts -join ' '
}

function Select-LauncherPwsh {
    # Picks the pwsh to run from -Candidate (Path, Version, SignatureValid, Signer): the newest at
    # -Minimum or later whose file is under -ProgramFiles and carries a valid signature of
    # Microsoft. A pure decision. Returns Path, or Problem: 'NotFound' (no candidate), 'TooOld'
    # (only older ones) or 'Untrusted' (none under Program Files with Microsoft's signature).
    param([object[]] $Candidate, [string] $ProgramFiles, [version] $Minimum)

    $root = $ProgramFiles.TrimEnd('\') + '\'
    $trusted = @($Candidate | Where-Object {
            $_ -and $_.Path -and $_.Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -and $_.Path -notmatch '\\\.\.?\\' -and
            $_.SignatureValid -eq $true -and [string]$_.Signer -match '(^|,\s*)O=Microsoft Corporation(,|$)'
        })
    $usable = @($trusted | Where-Object { $_.Version -ge $Minimum } | Sort-Object -Property Version -Descending)
    if ($usable.Count -gt 0) {
        return New-Object -TypeName psobject -Property @{ Path = $usable[0].Path; Problem = $null }
    }
    $problem = if (@($Candidate | Where-Object { $_ }).Count -eq 0) { 'NotFound' } elseif ($trusted.Count -gt 0) { 'TooOld' } else { 'Untrusted' }
    New-Object -TypeName psobject -Property @{ Path = $null; Problem = $problem }
}

function Get-LauncherPwshCandidate {
    # Where PowerShell 7 is installed: the MSI's folder under Program Files, and the MSIX package
    # of the current user. Each with its version and signature.
    $paths = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $msi = [IO.Path]::Combine([Environment]::GetFolderPath('ProgramFiles'), 'PowerShell\7\pwsh.exe')
    if ([IO.File]::Exists($msi)) {
        $paths.Add($msi)
    }
    try {
        Import-Module -Name ([IO.Path]::Combine($script:SystemFolder, 'WindowsPowerShell\v1.0\Modules\Appx\Appx.psd1')) -ErrorAction Stop
        foreach ($package in @(Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction Stop)) {
            $path = [IO.Path]::Combine([IO.Path]::GetFullPath($package.InstallLocation), 'pwsh.exe')
            if ([IO.File]::Exists($path)) {
                $paths.Add($path)
            }
        }
    }
    catch {
        # No package for this user, or no Appx module: the MSI's folder alone.
        Write-Verbose "No MSIX package of PowerShell: $($_.Exception.Message)"
    }
    foreach ($path in $paths) {
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
        New-Object -TypeName psobject -Property @{
            Path           = $path
            Version        = New-Object -TypeName version -ArgumentList $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart
            SignatureValid = [string]$signature.Status -eq 'Valid'
            Signer         = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
        }
    }
}

function Test-LauncherPlatform {
    # Whether this Windows can run the app, from Win32_Processor's Architecture and AddressWidth:
    # only 64-bit Windows on an x64 processor can - PowerShell 7.6 is published for x64 and Arm64
    # alone, and Windows on Arm loads only Arm64 kernel drivers, which the modem's driver package
    # doesn't have (docs/AT-COMMANDS.md section 11.2). A pure decision. Returns $null when it can -
    # or when they couldn't be read: the check only explains early what would fail later -, else
    # the problem: 'Arm' or 'NotX64'.
    param([object] $Architecture, [object] $AddressWidth)

    if ($null -eq $Architecture -or $null -eq $AddressWidth -or ([int]$Architecture -eq 9 -and [int]$AddressWidth -eq 64)) {
        return $null
    }
    if ([int]$Architecture -in 5, 12) {
        return 'Arm'
    }
    'NotX64'
}

function Get-LauncherProblemText {
    # What the user reads when the app can't run here, or no PowerShell 7 can be used.
    param([string] $Problem)

    switch ($Problem) {
        'Arm' { return Get-SetupText 'Launcher.Arm' }
        'NotX64' { return Get-SetupText 'Launcher.NotX64' }
        'TooOld' { $what = Get-SetupText 'Launcher.TooOld' }
        'Untrusted' { $what = Get-SetupText 'Launcher.Untrusted' }
        default { $what = Get-SetupText 'Launcher.NotFound' }
    }
    Get-SetupText 'Launcher.GetPwsh' $what
}

# Dot-sourced (the tests): the functions alone.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

# Windows' display language, when the installer has it.
[void](Set-SetupLanguage)

if ($Mode -eq 'Install') {
    $processor = $null
    try {
        $processor = Get-CimInstance -ClassName Win32_Processor -Property Architecture, AddressWidth -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        Write-Verbose "The processor can't be read: $($_.Exception.Message)"
    }
    $platform = if ($processor) { Test-LauncherPlatform -Architecture $processor.Architecture -AddressWidth $processor.AddressWidth } else { $null }
    if ($platform) {
        Write-Output (Get-LauncherProblemText -Problem $platform)
        exit 1
    }
}

$choice = Select-LauncherPwsh -Candidate @(Get-LauncherPwshCandidate) -ProgramFiles ([Environment]::GetFolderPath('ProgramFiles')) -Minimum $script:MinimumPwsh
if (-not $choice.Path) {
    $text = Get-LauncherProblemText -Problem $choice.Problem
    if ($Mode -eq 'App') {
        # Started by a task, with no console to write to.
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show((Get-SetupText 'Launcher.CantStart' $text), 'Fibocom FM350-GL Windows GUI', 'OK', 'Error')
    }
    else {
        Write-Output $text
    }
    exit 1
}

if ($Mode -eq 'App') {
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', [IO.Path]::Combine($PSScriptRoot, 'App\Start-Fm350App.ps1'))
    if ($Hidden) {
        $arguments += '-Hidden'
    }
    $start = New-Object -TypeName System.Diagnostics.ProcessStartInfo -ArgumentList $choice.Path
    $start.Arguments = ConvertTo-LauncherCommandLine -Argument $arguments
    $start.UseShellExecute = $false
    # No console window: a console program would get one, which nothing hides under Windows
    # Terminal (docs/AT-COMMANDS.md section 11.2).
    $start.CreateNoWindow = $true
    $start.WorkingDirectory = $script:SystemFolder
    $process = [System.Diagnostics.Process]::Start($start)
    $process.Dispose()
    exit 0
}

$user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', [IO.Path]::Combine($PSScriptRoot, 'Installer\Invoke-Fm350Setup.ps1'), '-Action', $Mode, '-UserSid', $user)
try {
    $process = Start-Process -FilePath $choice.Path -ArgumentList (ConvertTo-LauncherCommandLine -Argument $arguments) -Verb RunAs -WorkingDirectory $script:SystemFolder -Wait -PassThru -ErrorAction Stop
}
catch {
    Write-Output (Get-SetupText 'Launcher.NoAdmin' $_.Exception.Message)
    exit 1
}
exit $process.ExitCode

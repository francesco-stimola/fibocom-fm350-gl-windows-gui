#Requires -Version 7.6
<#
.SYNOPSIS
    Installs, updates or uninstalls the FM350-GL app, with administrator rights.
.DESCRIPTION
    Started by Start-Fm350.ps1 - from install.cmd or uninstall.cmd - in an elevated PowerShell 7
    window, after the one UAC prompt. -Action Install installs the package this script is part of
    (Install-Fm350App); -Action Uninstall removes the installed app (Uninstall-Fm350App) and asks
    whether to delete the settings, the stored secrets and the logs too.

    -UserSid is the account that ran the .cmd. The app runs as the account that installs it, which
    must be an administrator: when the UAC prompt was answered with another account's credentials,
    this window runs as that other account, and nothing is done. The window waits for Enter before
    it closes, unless -NoPause. It speaks Windows' display language, when the installer has it.
.EXAMPLE
    pwsh -NoProfile -File Invoke-Fm350Setup.ps1 -Action Install -UserSid S-1-5-21-1-2-3-1001
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Uninstall')]
    [string] $Action,

    [Parameter(Mandatory)]
    [string] $UserSid,

    [switch] $NoPause
)

# Only the modules of this PowerShell and of Windows, set before any command loads one: the user's
# module folder is theirs to write (invariant 10).
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules') + [IO.Path]::PathSeparator + [IO.Path]::Combine([Environment]::GetFolderPath('System'), 'WindowsPowerShell\v1.0\Modules')
$ErrorActionPreference = 'Stop'
$code = 0
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'FibocomFm350.Installer.psd1')
    [void](Set-SetupLanguage)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not [System.Security.Principal.WindowsPrincipal]::new($identity).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw (Get-SetupText 'Setup.NeedsAdmin')
    }
    if ($identity.User.Value -ne $UserSid) {
        throw (Get-SetupText 'Setup.OtherAccount')
    }
    if ($Action -eq 'Install') {
        Get-SetupText 'Setup.Installing' (Split-Path -Parent $PSScriptRoot)
        Install-Fm350App -Source (Split-Path -Parent $PSScriptRoot) -UserSid $UserSid | ForEach-Object { "  $_" }
    }
    else {
        Get-SetupText 'Setup.Uninstalling'
        $answer = Read-Host (Get-SetupText 'Setup.AskUserData')
        Uninstall-Fm350App -RemoveUserData:($answer -match "^\s*(y|yes|$(Get-SetupText 'Setup.Yes'))\s*$") | ForEach-Object { "  $_" }
    }
    Get-SetupText 'Setup.Done'
}
catch {
    $code = 1
    # In English when the installer itself couldn't be loaded.
    $said = Get-Command -Name Get-SetupText -ErrorAction SilentlyContinue
    if ($said) { Get-SetupText 'Setup.Failed' $_.Exception.Message } else { "Failed: $($_.Exception.Message)" }
}
if (-not $NoPause) {
    [void](Read-Host $(if (Get-Command -Name Get-SetupText -ErrorAction SilentlyContinue) { Get-SetupText 'Setup.PressEnter' } else { 'Press Enter to close this window' }))
}
exit $code

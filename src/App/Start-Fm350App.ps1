#Requires -Version 7.6
<#
.SYNOPSIS
    Starts the FM350-GL tray app.
.DESCRIPTION
    Keeps the Fibocom FM350-GL online from the system tray: a second launch brings the running
    app's window to the front. Configuring the modem's network adapter needs administrator rights:
    once installed, the logon task runs this script elevated, through Start-Fm350.ps1.

    Modules load only from this PowerShell's folder and Windows' own: the user's module folder is
    theirs to write, and this script may run elevated (invariant 10).

    -Simulated runs against a simulated modem (-Scenario): no device, no administrator rights,
    nothing changed on the system. -ObserveOnly reads and never writes. -Hidden starts in the
    tray, without the window.
.EXAMPLE
    pwsh -NoProfile -File src/App/Start-Fm350App.ps1 -Simulated -Scenario PinRequired
#>
[CmdletBinding()]
param(
    [switch] $Simulated,

    [ValidateSet('Online', 'Connect', 'ApnNeeded', 'PinRequired', 'FccLocked', 'AdapterDisabled', 'NoDevice', 'Unbound',
        'Settling', 'DataPathDown', 'IcmpDropped', 'RegistrationLost', 'ModemHung', 'Unrecoverable', 'LteOnlyMode', 'NrOnlyMode', 'Standalone',
        'EsimEmpty', 'Esim')]
    [string] $Scenario = 'Online',

    [switch] $ObserveOnly,

    [switch] $Hidden
)

# Before any command could load a module; .NET calls only until then. The app keeps it so as its
# worker runspaces are opened (Start-WorkerRunspace).
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules') + [IO.Path]::PathSeparator + [IO.Path]::Combine([Environment]::GetFolderPath('System'), 'WindowsPowerShell\v1.0\Modules')
$ErrorActionPreference = 'Stop'
$code = 0
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'FibocomFm350.App.psd1')
    Start-Fm350App @PSBoundParameters
}
catch {
    $code = 1
    Write-Error -ErrorRecord $_ -ErrorAction Continue
}
# A worker stuck in a call that never returns keeps its thread - and the process, with the AT port
# - alive after the app has closed everything else. The process ends here, whatever is left.
[Environment]::Exit($code)

#Requires -Version 7.6
<#
.SYNOPSIS
    Starts the FM350-GL tray app.
.DESCRIPTION
    Keeps the Fibocom FM350-GL online from the system tray: a second launch brings the running
    app's window to the front. Configuring the modem's network adapter needs administrator rights;
    the app installer (ROADMAP M7) runs this script elevated at logon.

    -Simulated runs against a simulated modem (-Scenario): no device, no administrator rights,
    nothing changed on the system. -ObserveOnly reads and never writes. -Hidden starts in the
    tray, without the window.
.EXAMPLE
    pwsh -NoProfile -File src/App/Start-Fm350App.ps1 -Simulated -Scenario PinRequired
#>
[CmdletBinding()]
param(
    [switch] $Simulated,

    [ValidateSet('Online', 'Connect', 'ApnNeeded', 'PinRequired', 'FccLocked', 'AdapterDisabled', 'NoDevice', 'NoDriver')]
    [string] $Scenario = 'Online',

    [switch] $ObserveOnly,

    [switch] $Hidden
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'FibocomFm350.App.psd1')
Start-Fm350App @PSBoundParameters

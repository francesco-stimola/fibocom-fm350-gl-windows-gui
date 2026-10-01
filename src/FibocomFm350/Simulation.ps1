# Development mode: a simulated FM350 and network adapter that the worker drives instead of real
# ones - no device, no administrator rights, nothing changed on the system (ARCHITECTURE ->
# Process model). The scenarios are in Data/Simulation.psd1.
#
# [NoRunspaceAffinity()]: the app creates the device and its worker runspace uses it, so methods
# must run in whichever runspace calls them; for the same reason the classes call no module
# function.

[NoRunspaceAffinity()]
class SimulatedAdapter {
    # The properties Get-ModemAdapterState reads from a real adapter.
    [int] $InterfaceIndex = 99
    [string] $Name = 'Simulated'
    [string] $Status = 'Up'
    [string] $Dhcp = 'Enabled'
    [int] $InterfaceMetric = 25
    [bool] $AutomaticMetric = $true
    [object[]] $Addresses = @([pscustomobject]@{ Address = '169.254.10.20'; PrefixLength = 16; Origin = 'WellKnown' })
    [string[]] $Gateways = @()
    [string[]] $DnsServers = @()

    # A copy, as Get-ModemAdapterState returns a reading: what the caller holds never changes.
    [object] Read() {
        return [pscustomobject]@{
            InterfaceIndex  = $this.InterfaceIndex
            Name            = $this.Name
            Status          = $this.Status
            Dhcp            = $this.Dhcp
            InterfaceMetric = $this.InterfaceMetric
            AutomaticMetric = $this.AutomaticMetric
            Addresses       = [object[]]@($this.Addresses)
            Gateways        = [string[]]@($this.Gateways)
            DnsServers      = [string[]]@($this.DnsServers)
        }
    }

    # Applies a Resolve-AdapterConfiguration plan as Set-ModemAdapterConfiguration applies it to
    # a real adapter, and returns its results.
    [object[]] Apply([object] $plan) {
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($step in @($plan.Actions)) {
            switch ($step.Action) {
                'DisableDhcp' { $this.Dhcp = 'Disabled' }
                'RemoveAddress' { $this.Addresses = @($this.Addresses | Where-Object Address -NE $step.Address) }
                'SetAddress' { $this.Addresses = @($this.Addresses) + [pscustomobject]@{ Address = $step.Address; PrefixLength = $step.PrefixLength; Origin = 'Manual' } }
                'RemoveGateway' { $this.Gateways = @($this.Gateways | Where-Object { $_ -ne $step.NextHop }) }
                'SetGateway' { $this.Gateways = @($this.Gateways) + $step.NextHop }
                'SetDns' { $this.DnsServers = $step.Servers }
                'SetMetric' {
                    $this.InterfaceMetric = $step.Metric
                    $this.AutomaticMetric = $false
                }
            }
            $results.Add([pscustomobject]@{ Action = $step.Action; Done = $true; Error = $null })
        }
        return $results.ToArray()
    }

    [void] Enable() {
        $this.Status = 'Up'
    }
}

[NoRunspaceAffinity()]
class SimulatedDevice {
    [string] $Scenario
    [object] $Modem
    [object] $Adapter
    # How PnP sees the modem: 'Present', 'Absent' or 'NoDriver'.
    [string] $Presence = 'Present'
    # How long the modem stays off USB once it vanished (a restart).
    [int] $AwayMs = 5000
    hidden [long] $LostAt = 0

    # The modem as PnP would report it, shaped as Resolve-ModemPresence's result. A modem that
    # vanished is away for AwayMs, then back on the same port.
    [object] Find() {
        $device = $this.Presence
        if ($device -eq 'Present' -and $this.Modem.Lost) {
            $now = [Environment]::TickCount64
            if ($this.LostAt -eq 0) {
                $this.LostAt = $now
            }
            if ($now - $this.LostAt -lt $this.AwayMs) {
                $device = 'Absent'
            }
            else {
                $this.LostAt = 0
                $this.Modem.Reappear($this.Modem.PortName)
            }
        }
        return [pscustomobject]@{
            Device            = $device
            PortName          = if ($device -eq 'Present') { $this.Modem.PortName } else { $null }
            AdapterInstanceId = $null
            Modems            = if ($device -eq 'Absent') { 0 } else { 1 }
        }
    }

    # The modem's AT port, for a new channel.
    [object] Open() {
        $this.Modem.Reopen()
        return $this.Modem
    }
}

function New-SimulatedDevice {
    <#
    .SYNOPSIS
        Creates the simulated modem and network adapter of development mode.
    .DESCRIPTION
        The worker drives it instead of a real device (Invoke-ModemWorker -Simulation): its modem
        answers from Data/Simulation.psd1, its adapter is configured in memory, and nothing on the
        system changes. Scenarios:
        - Online: the app attaches and changes nothing.
        - Connect: registered, no context yet; the app defines and activates it, then configures
          the adapter.
        - ApnNeeded: the network puts an empty APN on the IMS APN; it takes the APN 'internet'.
        - PinRequired: the SIM waits for its PIN, 1234; 0000 is refused.
        - FccLocked: locked by a laptop's maker; the unlock restarts it, online.
        - AdapterDisabled: the modem's adapter disabled by the user.
        - NoDevice, NoDriver: no modem on USB; its AT port without a driver.

        Returns an object with Scenario, Modem (New-SimulatedModem's), Adapter, Presence, and
        the methods the worker calls: Find() (the modem as PnP would report it) and Open() (its
        port, for a new channel).
    .EXAMPLE
        Invoke-ModemWorker -Link $link -Simulation (New-SimulatedDevice -Scenario PinRequired)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates in-memory objects; changes no system state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [ValidateSet('Online', 'Connect', 'ApnNeeded', 'PinRequired', 'FccLocked', 'AdapterDisabled', 'NoDevice', 'NoDriver')]
        [string] $Scenario = 'Online',

        [string] $PortName = 'SIMULATED'
    )

    $data = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'Data/Simulation.psd1')
    $base = $data.Answers
    $chosen = $data.Scenarios[$Scenario]
    $setting = { param($name, $default) if ($chosen.ContainsKey($name)) { $chosen[$name] } else { $default } }

    $modem = New-SimulatedModem -PortName $PortName
    foreach ($command in $base.Keys) {
        $modem.SetAnswer($command, [string[]]$base[$command])
    }
    $answers = & $setting 'Answers' @{}
    foreach ($command in $answers.Keys) {
        $modem.SetAnswer($command, [string[]]$answers[$command])
    }
    $changes = & $setting 'Then' @{}
    $vanish = @(& $setting 'Vanish' @())
    foreach ($command in $changes.Keys) {
        $then = @{}
        if ($changes[$command] -eq 'Base') {
            foreach ($changed in $base.Keys) {
                $then[$changed] = [string[]]$base[$changed]
            }
        }
        else {
            foreach ($changed in $changes[$command].Keys) {
                $value = $changes[$command][$changed]
                $then[$changed] = if ($value -eq 'Base') { [string[]]$base[$changed] } else { [string[]]$value }
            }
        }
        $modem.SetAnswer($command, @('OK'))
        $modem.Script($command, @{ Then = $then; Vanish = $command -in $vanish })
    }

    $adapter = [SimulatedAdapter]::new()
    switch (& $setting 'Adapter' 'Configured') {
        'Configured' {
            $adapter.Dhcp = 'Disabled'
            $adapter.Addresses = @([pscustomobject]@{ Address = '192.0.2.10'; PrefixLength = 32; Origin = 'Manual' })
            $adapter.Gateways = @('0.0.0.0')
            $adapter.DnsServers = @('192.0.2.53', '192.0.2.54')
            $adapter.InterfaceMetric = 500
            $adapter.AutomaticMetric = $false
        }
        'Disabled' {
            $adapter.Status = 'Disabled'
        }
    }

    $device = [SimulatedDevice]::new()
    $device.Scenario = $Scenario
    $device.Modem = $modem
    $device.Adapter = $adapter
    $device.Presence = & $setting 'Presence' 'Present'
    $device
}

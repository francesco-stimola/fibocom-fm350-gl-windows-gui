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
    [object[]] $Addresses = @([pscustomobject]@{ Address = '169.254.10.20'; PrefixLength = 16; Origin = 'WellKnown'; State = 'Preferred' })
    [string[]] $Gateways = @()
    [string[]] $DnsServers = @()
    # How many probes find an address just set still 'Tentative': Windows checks that no other
    # host has it before it can be used.
    [int] $DadChecks = 0
    hidden [int] $Tentative = 0

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
                'SetAddress' {
                    $this.Tentative = $this.DadChecks
                    $state = if ($this.DadChecks -gt 0) { 'Tentative' } else { 'Preferred' }
                    $this.Addresses = @($this.Addresses) + [pscustomobject]@{ Address = $step.Address; PrefixLength = $step.PrefixLength; Origin = 'Manual'; State = $state }
                }
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

    # The state of one of its addresses, as a probe finds it: 'Missing', 'Tentative' for the
    # first DadChecks probes after it was set, then 'Preferred'.
    [string] AddressState([string] $address) {
        $found = @($this.Addresses | Where-Object Address -EQ $address)
        if ($found.Count -eq 0) {
            return 'Missing'
        }
        if ($found[0].State -ne 'Tentative') {
            return $found[0].State
        }
        if ($this.Tentative -gt 0) {
            $this.Tentative--
            return 'Tentative'
        }
        $this.Addresses = @(foreach ($item in $this.Addresses) {
                if ($item.Address -eq $address) {
                    [pscustomobject]@{ Address = $item.Address; PrefixLength = $item.PrefixLength; Origin = $item.Origin; State = 'Preferred' }
                }
                else {
                    $item
                }
            })
        return 'Preferred'
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
    # Probe rounds lost once the address is usable: a path still settling.
    [int] $LostRounds = 0
    # Probe rounds that pass before a path that is down shows it: proven once, then down.
    [int] $PassedRounds = 0
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
            InstanceId        = if ($device -eq 'Present') { 'USB\VID_0E8D&PID_7127\SIMULATED' } else { $null }
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

    # A probe round from $source, shaped as Test-ModemDataPath's result: traffic gets through
    # unless the modem's DataPath flag is 'Down', or the round is one of the LostRounds.
    [object] Probe([string] $source) {
        $state = $this.Adapter.AddressState($source)
        if ($state -ne 'Preferred') {
            return [pscustomobject]@{ Result = 'NotReady'; Sent = 0; Status = $null; AddressState = $state }
        }
        $passed = -not $this.Modem.Lost -and -not $this.Modem.Hung -and -not ($this.Modem.Flags.ContainsKey('DataPath') -and $this.Modem.Flags['DataPath'] -eq 'Down')
        if (-not $passed -and $this.PassedRounds -gt 0) {
            $this.PassedRounds--
            $passed = $true
        }
        if ($passed -and $this.LostRounds -gt 0) {
            $this.LostRounds--
            $passed = $false
        }
        return [pscustomobject]@{
            Result       = if ($passed) { 'Passed' } else { 'Failed' }
            Sent         = if ($passed) { 1 } else { 3 }
            Status       = if ($passed) { 0 } else { 11010 }
            AddressState = $state
        }
    }

    # Windows restarts the modem's USB device (R6): it leaves USB, and comes back after AwayMs
    # with its power-on defaults - a hung modem answers again.
    [void] Restart() {
        $this.Modem.Vanish()
    }
}

function New-SimulatedDevice {
    <#
    .SYNOPSIS
        Creates the simulated modem and network adapter of development mode.
    .DESCRIPTION
        The worker drives it instead of a real device (Invoke-ModemWorker -Simulation): its modem
        answers from Data/Simulation.psd1, its adapter is configured in memory, and nothing on the
        system changes. The recovery steps act on it as on a real modem: deactivating the context
        mends a data path that is down, re-registering and the radio off and on register again, a
        reset or a USB restart takes it off USB for a few seconds. Scenarios:
        - Online: the app attaches and changes nothing.
        - Connect: registered, no context yet; the app defines and activates it, then configures
          the adapter.
        - ApnNeeded: the network puts an empty APN on the IMS APN; it takes the APN 'internet'.
        - PinRequired: the SIM waits for its PIN, 1234; 0000 is refused.
        - FccLocked: locked by a laptop's maker; the unlock restarts it, online.
        - AdapterDisabled: the modem's adapter disabled by the user.
        - NoDevice, NoDriver: no modem on USB; its AT port without a driver.
        - Settling: as Connect, and the new address is not usable for two probes, then one round
          is lost: a path that settles, which is no failure.
        - DataPathDown: online, the path proven once, then no traffic gets through until the
          context is restarted (R2).
        - IcmpDropped: online, and no probe ever answered - a network that drops ICMP: nothing
          is escalated.
        - RegistrationLost: not registered; re-registering doesn't help, the radio off and on
          (R4) does.
        - ModemHung: the AT port answers nothing until the USB device is restarted (R6).
        - Unrecoverable: the network refuses the registration whatever is done: the ladder runs
          its cycles, then the slow cadence.

        Returns an object with Scenario, Modem (New-SimulatedModem's), Adapter, Presence, and
        the methods the worker calls: Find() (the modem as PnP would report it), Open() (its
        port, for a new channel), Probe() (a data-path round) and Restart() (its USB device).
    .EXAMPLE
        Invoke-ModemWorker -Link $link -Simulation (New-SimulatedDevice -Scenario PinRequired)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates in-memory objects; changes no system state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [ValidateSet('Online', 'Connect', 'ApnNeeded', 'PinRequired', 'FccLocked', 'AdapterDisabled', 'NoDevice', 'NoDriver',
            'Settling', 'DataPathDown', 'IcmpDropped', 'RegistrationLost', 'ModemHung', 'Unrecoverable')]
        [string] $Scenario = 'Online',

        [string] $PortName = 'SIMULATED'
    )

    $data = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'Data/Simulation.psd1')
    $base = $data.Answers
    $chosen = @{}
    $own = $data.Scenarios[$Scenario]
    if ($own.ContainsKey('Like')) {
        foreach ($key in $data.Scenarios[$own['Like']].Keys) {
            $chosen[$key] = $data.Scenarios[$own['Like']][$key]
        }
    }
    foreach ($key in $own.Keys) {
        $chosen[$key] = $own[$key]
    }
    $setting = { param($name, $default) if ($chosen.ContainsKey($name)) { $chosen[$name] } else { $default } }
    # Answers that change: 'Base' is the base answer; a command mapped to 'Base' itself brings
    # every answer back to the base.
    $resolve = {
        param($changes)
        $then = @{}
        if ($changes -eq 'Base') {
            foreach ($changed in $base.Keys) {
                $then[$changed] = [string[]]$base[$changed]
            }
        }
        else {
            foreach ($changed in $changes.Keys) {
                $value = $changes[$changed]
                $then[$changed] = if ($value -eq 'Base') { [string[]]$base[$changed] } else { [string[]]$value }
            }
        }
        $then
    }

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
        $modem.SetAnswer($command, @('OK'))
        $modem.Script($command, @{ Then = (& $resolve $changes[$command]); Vanish = $command -in $vanish })
    }
    # What the recovery steps do, every time: the base's, unless the scenario says otherwise.
    # Queued after the one-shot changes above, which come first.
    $transitions = @{}
    foreach ($source in @($data.Transitions, (& $setting 'Transitions' @{}))) {
        foreach ($command in $source.Keys) {
            $transitions[$command] = $source[$command]
        }
    }
    foreach ($command in $transitions.Keys) {
        $transition = $transitions[$command]
        $modem.Script($command, @{
                Keep   = $true
                Then   = if ($transition.ContainsKey('Answers')) { & $resolve $transition['Answers'] } else { @{} }
                Flags  = if ($transition.ContainsKey('Flags')) { $transition['Flags'] } else { @{} }
                Vanish = [bool]$transition['Vanish']
            })
    }
    $flags = & $setting 'Flags' @{}
    foreach ($flag in $flags.Keys) {
        $modem.Flags[$flag] = [string]$flags[$flag]
    }
    $modem.Hung = [bool](& $setting 'Hung' $false)

    $adapter = [SimulatedAdapter]::new()
    $adapter.DadChecks = & $setting 'DadChecks' 0
    switch (& $setting 'Adapter' 'Configured') {
        'Configured' {
            $adapter.Dhcp = 'Disabled'
            $adapter.Addresses = @([pscustomobject]@{ Address = '192.0.2.10'; PrefixLength = 32; Origin = 'Manual'; State = 'Preferred' })
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
    $device.LostRounds = & $setting 'LostRounds' 0
    $device.PassedRounds = & $setting 'PassedRounds' 0
    $device
}

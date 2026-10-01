# The modem's network adapter: what its IP configuration should be, from the data context and the
# settings. Design: docs/ARCHITECTURE.md -> Network configuration.

function Test-UsableIPv4Address {
    # Not a link-local address (169.254.0.0/16, what Windows gives an adapter nobody configured)
    # and not the unspecified one.
    param([string] $Address)

    $Address -and $Address -notmatch '^169\.254\.' -and $Address -ne '0.0.0.0'
}

function Resolve-AdapterConfiguration {
    <#
    .SYNOPSIS
        Plans the IP configuration of the modem's network adapter: what to change so that it
        carries the data context.
    .DESCRIPTION
        A pure decision. -Context is ConvertFrom-AtContextParameter's object for the app's
        context; -Adapter the adapter as read: InterfaceIndex, Dhcp ('Enabled' or 'Disabled'),
        InterfaceMetric, AutomaticMetric, Addresses (IPv4, each with Address, PrefixLength and
        Origin: 'Manual', 'Dhcp', 'WellKnown'...), Gateways (next hops of the adapter's IPv4
        default routes) and DnsServers; -Settings the app's settings (DnsServers,
        InterfaceMetric).

        - An address the modem handed out by DHCP is kept as it is, with its gateway and DNS.
        - Otherwise the adapter gets the context's IPv4 address and mask, a default route
          through its gateway, and its DNS servers. Manual addresses and default routes left on
          the adapter from an earlier context are removed.
        - The DNS override, when set, replaces whichever DNS servers the adapter would have.
        - The interface metric is the settings' one, never automatic.

        Returns Configured ($true when nothing needs to change), Actions - in order, each with
        Action ('DisableDhcp', 'RemoveAddress', 'SetAddress', 'RemoveGateway', 'SetGateway',
        'SetDns', 'SetMetric') and its values - and Problem: 'NoAddress', 'NoMask' or 'NoGateway'
        when the modem doesn't report what a manual configuration needs (no action is planned
        then).
    .EXAMPLE
        Resolve-AdapterConfiguration -Context $context -Adapter $adapter -Settings $settings
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Context,

        [Parameter(Mandatory)]
        [object] $Adapter,

        [Parameter(Mandatory)]
        [object] $Settings
    )

    $actions = [System.Collections.Generic.List[object]]::new()
    $plan = {
        param($problem)
        [pscustomobject]@{
            Configured = -not $problem -and $actions.Count -eq 0
            Actions    = if ($problem) { [object[]]@() } else { [object[]]$actions.ToArray() }
            Problem    = $problem
        }
    }
    $addresses = @($Adapter.Addresses | Where-Object { Test-UsableIPv4Address -Address $_.Address })
    $dhcp = @($addresses | Where-Object Origin -EQ 'Dhcp')
    $manual = @($addresses | Where-Object Origin -NE 'Dhcp')
    $gateways = @($Adapter.Gateways | Where-Object { $_ })
    $wanted = if ($null -ne $Context) { $Context.IPv4Address }

    $dnsWanted = $null
    if ($dhcp.Count -gt 0 -and $manual.Count -eq 0) {
        # The modem's DHCP configured the adapter: keep it.
    }
    else {
        if (-not $wanted) {
            return & $plan 'NoAddress'
        }
        if ($null -eq $Context.IPv4PrefixLength) {
            return & $plan 'NoMask'
        }
        $gateway = $Context.IPv4Gateway
        if (-not $gateway -and $gateways.Count -eq 0) {
            return & $plan 'NoGateway'
        }
        foreach ($address in $manual) {
            if ($address.Address -ne $wanted -or $address.PrefixLength -ne $Context.IPv4PrefixLength) {
                $actions.Add([pscustomobject]@{ Action = 'RemoveAddress'; Address = $address.Address })
            }
        }
        if (-not ($manual | Where-Object { $_.Address -eq $wanted -and $_.PrefixLength -eq $Context.IPv4PrefixLength })) {
            if ($Adapter.Dhcp -eq 'Enabled') {
                $actions.Insert(0, [pscustomobject]@{ Action = 'DisableDhcp' })
            }
            $actions.Add([pscustomobject]@{ Action = 'SetAddress'; Address = $wanted; PrefixLength = $Context.IPv4PrefixLength })
        }
        if ($gateway) {
            foreach ($other in @($gateways | Where-Object { $_ -ne $gateway })) {
                $actions.Add([pscustomobject]@{ Action = 'RemoveGateway'; NextHop = $other })
            }
            if ($gateway -notin $gateways) {
                $actions.Add([pscustomobject]@{ Action = 'SetGateway'; NextHop = $gateway })
            }
        }
        $dnsWanted = @($Context.Dns | Where-Object { $_ })
    }

    $override = @($Settings.DnsServers | Where-Object { $_ })
    if ($override.Count -gt 0) {
        $dnsWanted = $override
    }
    if ($null -ne $dnsWanted -and $dnsWanted.Count -gt 0 -and (@($Adapter.DnsServers) -join ',') -ne ($dnsWanted -join ',')) {
        $actions.Add([pscustomobject]@{ Action = 'SetDns'; Servers = [string[]]$dnsWanted })
    }

    if ($Adapter.AutomaticMetric -or $Adapter.InterfaceMetric -ne $Settings.InterfaceMetric) {
        $actions.Add([pscustomobject]@{ Action = 'SetMetric'; Metric = $Settings.InterfaceMetric })
    }
    & $plan $null
}

function Get-ModemAdapterState {
    <#
    .SYNOPSIS
        Reads the IP configuration of the modem's network adapter.
    .DESCRIPTION
        The adapter is found by its PnP instance ID - the modem's RNDIS function, from
        Resolve-ModemUsbDevice - never by name or index. Reads only; needs no administrator
        rights. Returns what Resolve-AdapterConfiguration takes: InterfaceIndex, Name, Status,
        Dhcp, InterfaceMetric, AutomaticMetric, Addresses (IPv4: Address, PrefixLength, Origin),
        Gateways (next hops of its IPv4 default routes) and DnsServers (IPv4, then IPv6). Returns
        nothing when no adapter has that instance ID.
    .EXAMPLE
        Get-ModemAdapterState -InstanceId $modem.Network.InstanceId
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $InstanceId
    )

    $adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object PnPDeviceID -EQ $InstanceId | Select-Object -First 1
    if (-not $adapter) {
        return
    }
    $index = [int]$adapter.ifIndex
    $interface = Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    $addresses = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $routes = @(Get-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $dns = @(Get-DnsClientServerAddress -InterfaceIndex $index -ErrorAction SilentlyContinue)

    [pscustomobject]@{
        InterfaceIndex  = $index
        Name            = [string]$adapter.Name
        Status          = [string]$adapter.Status
        Dhcp            = if ($interface) { [string]$interface.Dhcp } else { $null }
        InterfaceMetric = if ($interface) { [int]$interface.InterfaceMetric } else { $null }
        AutomaticMetric = $interface -and [string]$interface.AutomaticMetric -eq 'Enabled'
        Addresses       = [object[]]@($addresses | ForEach-Object {
                [pscustomobject]@{ Address = [string]$_.IPAddress; PrefixLength = [int]$_.PrefixLength; Origin = [string]$_.PrefixOrigin }
            })
        Gateways        = [string[]]@($routes | ForEach-Object { [string]$_.NextHop } | Where-Object { $_ -and $_ -ne '0.0.0.0' })
        DnsServers      = [string[]]@(
            @($dns | Where-Object AddressFamily -EQ 2 | ForEach-Object { $_.ServerAddresses })
            @($dns | Where-Object AddressFamily -EQ 23 | ForEach-Object { $_.ServerAddresses })
        )
    }
}

function Set-ModemAdapterConfiguration {
    <#
    .SYNOPSIS
        Applies a Resolve-AdapterConfiguration plan to the modem's network adapter.
    .DESCRIPTION
        Every change is scoped to the adapter with -InterfaceIndex, and written to the active
        store where Windows has one - addresses, routes, DHCP, metric - so it vanishes at the next
        reboot instead of lingering. DNS servers have no active store: they are set on the
        adapter, and rewritten from the context at every connect. Needs administrator rights.

        Runs the actions in order and stops at the first that fails, since the later ones build
        on it (a gateway on an address). Returns one result per action run: Action, Done, and
        Error (the message, when it failed). The plan is computed again at the next pass, so a
        failed change is retried then, not here.
    .EXAMPLE
        Set-ModemAdapterConfiguration -InterfaceIndex 12 -Plan $plan
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [int] $InterfaceIndex,

        [Parameter(Mandatory)]
        [object] $Plan
    )

    foreach ($step in @($Plan.Actions)) {
        if (-not $PSCmdlet.ShouldProcess("network adapter $InterfaceIndex", $step.Action)) {
            continue
        }
        $failure = $null
        try {
            switch ($step.Action) {
                'DisableDhcp' {
                    Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -Dhcp Disabled -PolicyStore ActiveStore -ErrorAction Stop
                }
                'RemoveAddress' {
                    Remove-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $step.Address -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop
                }
                'SetAddress' {
                    [void](New-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -IPAddress $step.Address -PrefixLength $step.PrefixLength -PolicyStore ActiveStore -ErrorAction Stop)
                }
                'RemoveGateway' {
                    Remove-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix '0.0.0.0/0' -NextHop $step.NextHop -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop
                }
                'SetGateway' {
                    [void](New-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix '0.0.0.0/0' -NextHop $step.NextHop -PolicyStore ActiveStore -ErrorAction Stop)
                }
                'SetDns' {
                    Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $step.Servers -ErrorAction Stop
                }
                'SetMetric' {
                    # Both families: IPv6 traffic must not prefer the modem either.
                    Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric $step.Metric -PolicyStore ActiveStore -ErrorAction Stop
                    Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv6 -AutomaticMetric Disabled -InterfaceMetric $step.Metric -PolicyStore ActiveStore -ErrorAction SilentlyContinue
                }
                default {
                    throw "Unknown adapter action '$($step.Action)'."
                }
            }
        }
        catch {
            $failure = $_.Exception.Message
        }
        [pscustomobject]@{ Action = $step.Action; Done = -not $failure; Error = $failure }
        if ($failure) {
            break
        }
    }
}

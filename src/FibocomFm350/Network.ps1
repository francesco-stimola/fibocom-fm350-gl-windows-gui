# The modem's network adapter: what its IP configuration should be, from the data context and the
# settings. Design: docs/ARCHITECTURE.md -> Network configuration.

function Test-AppElevation {
    # Whether this process has administrator rights, which configuring or enabling the adapter
    # needs.
    $principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-UsableIPv4Address {
    # Not a link-local address (169.254.0.0/16, what Windows gives an adapter nobody configured)
    # and not the unspecified one.
    param([string] $Address)

    $Address -and $Address -notmatch '^169\.254\.' -and $Address -ne '0.0.0.0'
}

function Test-FailedIPv4Address {
    # An address Windows refused: another host answered for it while Windows checked it
    # ('Duplicate'), or it is no longer valid. Set again, it is checked again.
    param([object] $Address)

    $Address.PSObject.Properties['State'] -and $Address.State -in 'Duplicate', 'Invalid'
}

function Test-DohEnabled {
    # Whether a server's DoH property encrypts it as the app sets it: a template of its own, no
    # fallback to unencrypted DNS (docs/AT-COMMANDS.md section 11.1).
    param([object] $Server)

    $flags = [uint64]$Server.Flags
    ($flags -band [uint64]2) -ne 0 -and ($flags -band [uint64]4) -eq 0
}

function Resolve-AdapterConfiguration {
    <#
    .SYNOPSIS
        Plans the IP configuration of the modem's network adapter: what to change so that it
        carries the data context.
    .DESCRIPTION
        A pure decision. -Context is ConvertFrom-AtContextParameter's object for the app's
        context; -Adapter the adapter as read: InterfaceIndex, Dhcp ('Enabled' or 'Disabled'),
        InterfaceMetric, AutomaticMetric, Addresses (IPv4, each with Address, PrefixLength,
        Origin: 'Manual', 'Dhcp', 'WellKnown'..., and State: 'Preferred', 'Tentative',
        'Duplicate'...), Gateways (next hops of the adapter's IPv4 default routes), DnsServers
        and Doh (Get-InterfaceDoh's: Supported, and the Servers carrying a DoH property); -Settings
        the app's settings (DnsServers, DnsOverHttps, DohTemplate, InterfaceMetric); -DohKnown the
        DoH templates Windows knows, by server address (Get-DohKnownServer).

        - An address the modem handed out by DHCP is kept as it is, with its gateway and DNS.
        - Otherwise the adapter gets the context's IPv4 address and mask, a default route
          through its gateway, and its DNS servers. The FM350 reports neither mask nor gateway
          for a data context, and answers ARP for every destination on its adapter: without a
          mask the address is a /32, without a gateway the default route is on-link (next hop
          0.0.0.0) - the configuration that carried traffic on the device. Manual addresses and
          default routes left on the adapter from an earlier context are removed. An address
          Windows refused ('Duplicate', 'Invalid') is removed and set again; one it is still
          checking ('Tentative') is in place.
        - The DNS override, when set, replaces whichever DNS servers the adapter would have.
          Servers are compared per family, IPv4 then IPv6, and a family only when servers of it
          are wanted: the IPv6 servers Windows lists on its own never ask for a change.
        - Encrypted DNS (DnsOverHttps): each server of the override with the template the
          settings give, or else the one Windows knows for it, set on this interface alone and
          compared with what it carries. Without the override, the DoH template's server
          (Resolve-DohServer): its address; for a name the worker has not looked up yet - it then
          puts the addresses in the override -, the servers the adapter already encrypts with
          that template, else no DNS server at all until it has (the adapter's are taken off).
          Without any server, without the per-interface API, or with a server that has no
          template, nothing is planned at all - no query in the clear for want of encryption.
          A family the servers leave out keeps no static server of its own: they would answer
          in the clear. Turned off, the DoH properties come off the servers first. Servers are
          compared with the static ones the per-interface read gives (Doh.NameServers). When
          Windows refused part of that read (Doh.Read $false), or its list of templates
          couldn't be read (-DohKnown $null) for a server that needs it, encryption is left as
          it is at this pass and nothing is blocked - turned off, the servers are still set;
          Unread says which.
        - The interface metric is the settings' one, never automatic.

        Returns Unread ('Settings', 'Templates' or $null), Configured ($true when nothing needs to
        change), Actions - in order, each with
        Action ('DisableDhcp', 'RemoveAddress', 'SetAddress', 'RemoveGateway', 'SetGateway',
        'SetDns', 'ClearDns', 'SetDoh', 'ClearDoh', 'SetMetric') and its values; a gateway of
        0.0.0.0 is an on-link route - and Problem, when no action is planned at all: 'NoAddress'
        (the modem reports no IPv4 address for the context), 'DohNeedsServers',
        'DohServerUnresolved' (the DoH template's server is a name not looked up yet, on an
        adapter the modem's DHCP configured), 'DohUnavailable' or 'DohTemplateMissing'.
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
        [object] $Settings,

        [hashtable] $DohKnown
    )

    $actions = [System.Collections.Generic.List[object]]::new()
    # What Windows wouldn't read, when DNS is left as it is for that reason: 'Settings' (the
    # adapter's) or 'Templates' (its list of DoH templates).
    $unreadWhat = $null
    $plan = {
        param($problem)
        [pscustomobject]@{
            Configured = -not $problem -and $actions.Count -eq 0
            # Always an array: an if statement would unroll an empty one to $null, one action to itself.
            Actions    = [object[]]@(if (-not $problem) { $actions })
            Problem    = $problem
            Unread     = $unreadWhat
        }
    }
    $addresses = @($Adapter.Addresses | Where-Object { Test-UsableIPv4Address -Address $_.Address })
    $dhcp = @($addresses | Where-Object Origin -EQ 'Dhcp')
    $manual = @($addresses | Where-Object Origin -NE 'Dhcp')
    $gateways = @($Adapter.Gateways | Where-Object { $_ })
    $wanted = if ($null -ne $Context) { $Context.IPv4Address }

    $dnsWanted = $null
    $kept = $dhcp.Count -gt 0 -and $manual.Count -eq 0
    if ($kept) {
        # The modem's DHCP configured the adapter: keep it.
    }
    else {
        if (-not $wanted) {
            return & $plan 'NoAddress'
        }
        $prefixLength = if ($null -ne $Context.IPv4PrefixLength) { $Context.IPv4PrefixLength } else { 32 }
        $gateway = if ($Context.IPv4Gateway) { $Context.IPv4Gateway } else { '0.0.0.0' }
        foreach ($address in $manual) {
            if ($address.Address -ne $wanted -or $address.PrefixLength -ne $prefixLength -or (Test-FailedIPv4Address -Address $address)) {
                $actions.Add([pscustomobject]@{ Action = 'RemoveAddress'; Address = $address.Address })
            }
        }
        if (-not ($manual | Where-Object { $_.Address -eq $wanted -and $_.PrefixLength -eq $prefixLength -and -not (Test-FailedIPv4Address -Address $_) })) {
            if ($Adapter.Dhcp -eq 'Enabled') {
                $actions.Insert(0, [pscustomobject]@{ Action = 'DisableDhcp' })
            }
            $actions.Add([pscustomobject]@{ Action = 'SetAddress'; Address = $wanted; PrefixLength = $prefixLength })
        }
        foreach ($other in @($gateways | Where-Object { $_ -ne $gateway })) {
            $actions.Add([pscustomobject]@{ Action = 'RemoveGateway'; NextHop = $other })
        }
        if ($gateway -notin $gateways) {
            $actions.Add([pscustomobject]@{ Action = 'SetGateway'; NextHop = $gateway })
        }
        $dnsWanted = @($Context.Dns | Where-Object { $_ })
    }

    $override = @($Settings.DnsServers | Where-Object { $_ })
    if ($override.Count -gt 0) {
        $dnsWanted = $override
    }
    $inFamily = { param($address, $family) [bool]($address -match ':') -eq ($family -eq 'IPv6') }
    $doh = $Settings.PSObject.Properties['DnsOverHttps'] -and $Settings.DnsOverHttps -eq $true
    $encryption = if ($Adapter.PSObject.Properties['Doh']) { $Adapter.Doh } else { $null }
    $encrypted = @(if ($encryption) { $encryption.Servers | Where-Object { $_ } })
    # A read Windows refused in part says nothing for sure about encryption - never "none": it
    # is left as it is at this pass, and nothing is blocked for it.
    $unread = [bool]($encryption -and $encryption.PSObject.Properties['Read'] -and $encryption.Read -eq $false)
    if ($unread) {
        $unreadWhat = 'Settings'
    }
    # The adapter's static servers, as the per-interface read gives them: never the IPv6 ones
    # Windows lists on its own, nor DHCP's. Without that read (Windows 10, or refused), the
    # servers it lists.
    $static = @(if ($encryption -and $encryption.Supported -and -not $unread -and $encryption.PSObject.Properties['NameServers']) { $encryption.NameServers | Where-Object { $_ } } else { $Adapter.DnsServers | Where-Object { $_ } })
    if ($doh) {
        # Every server of the override, encrypted with its template - or nothing at all.
        $given = if ($Settings.PSObject.Properties['DohTemplate']) { [string]$Settings.DohTemplate } else { '' }
        $pending = $false
        if ($override.Count -eq 0) {
            # The template's server: its address, when it names one.
            $named = Resolve-DohServer -Settings $Settings
            $override = @($named.Servers)
            if ($named.Name) {
                # A name not looked up yet: the servers the adapter encrypts with this template are
                # the ones it was last looked up to - Windows keeps them across restarts.
                $override = @($encrypted | Where-Object { $_.Address -notmatch ':' -and $_.Template -eq $given -and (Test-DohEnabled -Server $_) } | ForEach-Object Address)
                $pending = $override.Count -eq 0
            }
            if ($override.Count -eq 0 -and -not $pending) {
                return & $plan 'DohNeedsServers'
            }
        }
        if (-not $encryption -or -not $encryption.Supported) {
            return & $plan 'DohUnavailable'
        }
        if ($pending -and $kept) {
            # An adapter the modem's DHCP configured keeps the DHCP servers: it waits, unchanged.
            return & $plan 'DohServerUnresolved'
        }
        $templates = @{}
        foreach ($server in $override) {
            $template = if ($given) { $given } elseif ($DohKnown -and $DohKnown[$server]) { $DohKnown[$server] } elseif ($null -eq $DohKnown) {
                # Windows' list couldn't be read: the template the adapter already encrypts this
                # server with, if any.
                $encrypted | Where-Object { $_.Address -eq $server -and $_.Template -and (Test-DohEnabled -Server $_) } | ForEach-Object Template | Select-Object -First 1
            }
            if (-not $template) {
                if ($null -eq $DohKnown) {
                    # Unknown, not missing: encryption is left as it is at this pass.
                    $unread = $true
                    if (-not $unreadWhat) {
                        $unreadWhat = 'Templates'
                    }
                    break
                }
                return & $plan 'DohTemplateMissing'
            }
            $templates[$server] = $template
        }
        # No server at all until the name is looked up - never the operator's, in the clear.
        $clear = $pending -and @($static | Where-Object { $_ -notmatch ':' }).Count -gt 0
        $sets = [System.Collections.Generic.List[object]]::new()
        foreach ($family in @(if (-not $unread) { 'IPv4', 'IPv6' })) {
            $wanted = @($override | Where-Object { & $inFamily $_ $family })
            $have = @($static | Where-Object { & $inFamily $_ $family })
            $carried = @($encrypted | Where-Object { & $inFamily $_.Address $family })
            if ($wanted.Count -eq 0) {
                # A family with no server of the override keeps none at all: its servers would
                # answer in the clear. They all go, encrypted or not - never first stripped of
                # their encryption, which a failed reset would leave in the clear -, and the
                # wanted ones come back, encrypted, right after.
                if ($have.Count -gt 0) {
                    $clear = $true
                }
                continue
            }
            $missing = @($wanted | Where-Object {
                    $server = $_
                    -not ($carried | Where-Object { $_.Address -eq $server -and $_.Template -eq $templates[$server] -and (Test-DohEnabled -Server $_) })
                })
            $sets.Add([pscustomobject]@{
                    Differs = ($have -join ',') -ne ($wanted -join ',') -or $carried.Count -ne $wanted.Count -or $missing.Count -gt 0
                    Action  = [pscustomobject]@{ Action = 'SetDoh'; Family = $family; Servers = [string[]]$wanted; Templates = [string[]]@($wanted | ForEach-Object { $templates[$_] }) }
                })
        }
        if ($clear -and -not $unread) {
            # Both families' servers go; the wanted ones come back, encrypted, right after.
            $actions.Add([pscustomobject]@{ Action = 'ClearDns' })
        }
        foreach ($set in $sets) {
            if ($set.Differs -or $clear) {
                $actions.Add($set.Action)
            }
        }
    }
    else {
        # Turned off: the DoH properties come off the servers that carry them, before anything
        # else changes the servers - when the read says which. The servers are set either way:
        # an adapter left with no DNS server would be online with no name resolving.
        foreach ($family in @(if (-not $unread) { 'IPv4', 'IPv6' })) {
            if (@($encrypted | Where-Object { & $inFamily $_.Address $family }).Count -gt 0) {
                $actions.Add([pscustomobject]@{ Action = 'ClearDoh'; Family = $family; Servers = [string[]]@($static | Where-Object { & $inFamily $_ $family }) })
            }
        }
        if ($null -ne $dnsWanted -and $dnsWanted.Count -gt 0) {
            # Compared per family, and a family only when servers of it are wanted: Windows reads
            # the IPv4 servers before the IPv6 ones, and lists IPv6 servers nobody set
            # (fec0:0:0:ffff::1 to 3, or ones from router advertisements) - a list compared whole
            # would never match.
            $wanted4 = @($dnsWanted | Where-Object { $_ -notmatch ':' })
            $wanted6 = @($dnsWanted | Where-Object { $_ -match ':' })
            $have4 = @($static | Where-Object { $_ -notmatch ':' })
            $have6 = @($static | Where-Object { $_ -match ':' })
            $differs4 = $wanted4.Count -gt 0 -and ($have4 -join ',') -ne ($wanted4 -join ',')
            $differs6 = $wanted6.Count -gt 0 -and ($have6 -join ',') -ne ($wanted6 -join ',')
            if ($differs4 -or $differs6) {
                $actions.Add([pscustomobject]@{ Action = 'SetDns'; Servers = [string[]]($wanted4 + $wanted6) })
            }
        }
    }

    if ($Adapter.AutomaticMetric -or $Adapter.InterfaceMetric -ne $Settings.InterfaceMetric) {
        $actions.Add([pscustomobject]@{ Action = 'SetMetric'; Metric = $Settings.InterfaceMetric })
    }
    & $plan $null
}

function Resolve-AdapterClearing {
    <#
    .SYNOPSIS
        Plans the removal of the configuration the app gives the modem's network adapter.
    .DESCRIPTION
        A pure decision, for the recovery step R1: from -Adapter as Get-ModemAdapterState reads
        it, the actions that remove its IPv4 default routes, then its usable IPv4 addresses that
        no DHCP server gave - what Resolve-AdapterConfiguration sets. The next connect pass sets
        them again from scratch. An adapter with no such address is left alone: a DHCP server
        configured it, routes included. Returns a plan Set-ModemAdapterConfiguration applies:
        Configured ($false), Actions and Problem ($null).
    .EXAMPLE
        Set-ModemAdapterConfiguration -InterfaceIndex 12 -Plan (Resolve-AdapterClearing -Adapter $adapter)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Adapter
    )

    $manual = @($Adapter.Addresses | Where-Object { $_.Origin -ne 'Dhcp' -and (Test-UsableIPv4Address -Address $_.Address) })
    # An adapter the modem's DHCP configured, as Resolve-AdapterConfiguration keeps it, carries
    # nothing of the app's: its routes are DHCP's. No action is an empty array, never $null: a
    # plan is walked with @($plan.Actions).
    $actions = @(
        if ($manual.Count -gt 0) {
            # Routes first: a route stands on an address.
            foreach ($gateway in @($Adapter.Gateways | Where-Object { $_ })) {
                [pscustomobject]@{ Action = 'RemoveGateway'; NextHop = $gateway }
            }
            foreach ($address in $manual) {
                [pscustomobject]@{ Action = 'RemoveAddress'; Address = $address.Address }
            }
        }
    )
    [pscustomobject]@{ Configured = $false; Actions = [object[]]$actions; Problem = $null }
}

function Get-ModemAdapterState {
    <#
    .SYNOPSIS
        Reads the IP configuration of the modem's network adapter.
    .DESCRIPTION
        The adapter is found by its PnP instance ID - the modem's RNDIS function, from
        Resolve-ModemUsbDevice - never by name or index. Reads only; needs no administrator
        rights. Returns what Resolve-AdapterConfiguration takes: InterfaceIndex, InterfaceGuid,
        Name, Status, Dhcp, InterfaceMetric, AutomaticMetric, Addresses (IPv4: Address,
        PrefixLength, Origin, State), Gateways (next hops of its IPv4 default routes, 0.0.0.0 for
        an on-link one), DnsServers (IPv4, then IPv6) and Doh (Get-InterfaceDoh's). Returns
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

    $guid = [guid]$adapter.InterfaceGuid
    [pscustomobject]@{
        InterfaceIndex  = $index
        InterfaceGuid   = $guid
        Name            = [string]$adapter.Name
        Status          = [string]$adapter.Status
        Dhcp            = if ($interface) { [string]$interface.Dhcp } else { $null }
        InterfaceMetric = if ($interface) { [int]$interface.InterfaceMetric } else { $null }
        AutomaticMetric = $interface -and [string]$interface.AutomaticMetric -eq 'Enabled'
        Addresses       = [object[]]@($addresses | ForEach-Object {
                [pscustomobject]@{ Address = [string]$_.IPAddress; PrefixLength = [int]$_.PrefixLength; Origin = [string]$_.PrefixOrigin; State = [string]$_.AddressState }
            })
        Gateways        = [string[]]@($routes | ForEach-Object { [string]$_.NextHop } | Where-Object { $_ })
        DnsServers      = [string[]]@(
            @($dns | Where-Object AddressFamily -EQ 2 | ForEach-Object { $_.ServerAddresses })
            @($dns | Where-Object AddressFamily -EQ 23 | ForEach-Object { $_.ServerAddresses })
        )
        Doh             = Get-InterfaceDoh -InterfaceGuid $guid
    }
}

function Set-ModemAdapterConfiguration {
    <#
    .SYNOPSIS
        Applies a Resolve-AdapterConfiguration plan to the modem's network adapter.
    .DESCRIPTION
        Every change is scoped to the adapter with -InterfaceIndex - -InterfaceGuid for its
        encrypted DNS -, and written to the active store where Windows has one - addresses,
        routes, metric - so it vanishes at the next reboot instead of lingering. DHCP's setting
        lives in the active store alone and persists across reboots (docs/AT-COMMANDS.md section
        11.1). DNS servers and their encryption have no active store: they are set on the adapter,
        kept across reboots, and compared at every connect. Needs administrator rights.

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

        [guid] $InterfaceGuid,

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
                'ClearDns' {
                    Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                }
                'SetDoh' {
                    Set-InterfaceDoh -InterfaceGuid $InterfaceGuid -Family $step.Family -Servers $step.Servers -Templates $step.Templates -Confirm:$false
                }
                'ClearDoh' {
                    Set-InterfaceDoh -InterfaceGuid $InterfaceGuid -Family $step.Family -Servers $step.Servers -Templates @() -Confirm:$false
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

function Enable-ModemAdapter {
    <#
    .SYNOPSIS
        Enables the modem's network adapter after the user disabled it.
    .DESCRIPTION
        Only when the user asks for it - the window's Enable button: a disabled adapter is the
        user's choice, and the app never enables it on its own (ARCHITECTURE -> Network
        configuration). The adapter is found by its PnP instance ID, as Get-ModemAdapterState
        finds it. Needs administrator rights. Throws when no adapter has that instance ID or
        Windows refuses.
    .EXAMPLE
        Enable-ModemAdapter -InstanceId $modem.Network.InstanceId
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $InstanceId
    )

    $adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object PnPDeviceID -EQ $InstanceId | Select-Object -First 1
    if (-not $adapter) {
        throw [System.InvalidOperationException]::new("The modem's network adapter is not there.")
    }
    if ($PSCmdlet.ShouldProcess("network adapter $($adapter.Name)", 'Enable')) {
        # By the name it has now: the adapter was found by its instance ID just above.
        Enable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop
    }
}

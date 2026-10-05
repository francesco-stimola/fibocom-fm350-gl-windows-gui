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
    # IPv6 DNS servers the network gives (router advertisements): listed, never static.
    [string[]] $AdvertisedDns = @()
    # Encrypted DNS: whether this Windows has the per-interface API, the servers carrying a DoH
    # property, and the templates it knows - Cloudflare's and Quad9's, from Windows' own list.
    [bool] $DohSupported = $true
    [object[]] $DohServers = @()
    # The names a DoH template may name, and the addresses a lookup finds for them: through
    # Windows, and through the operator's DNS.
    [hashtable] $Names = @{ 'dns.example.org' = [string[]]@('203.0.113.53') }
    [hashtable] $OperatorNames = @{ 'dns.example.org' = [string[]]@('203.0.113.53') }
    [hashtable] $KnownDoh = @{
        '1.1.1.1'         = 'https://cloudflare-dns.com/dns-query'
        '1.0.0.1'         = 'https://cloudflare-dns.com/dns-query'
        '9.9.9.9'         = 'https://dns.quad9.net/dns-query'
        '149.112.112.112' = 'https://dns.quad9.net/dns-query'
    }
    # How many probes find an address just set still 'Tentative': Windows checks that no other
    # host has it before it can be used.
    [int] $DadChecks = 0
    hidden [int] $Tentative = 0
    # Its byte counters, as Get-ModemAdapterCounter reads a real adapter's: while it carries an
    # address the app set, each reading finds TrafficPerRead bytes more received, a tenth of it
    # sent.
    [uint64] $ReceivedBytes = 0
    [uint64] $SentBytes = 0
    [uint64] $TrafficPerRead = 2000000

    # A copy, as Get-ModemAdapterState returns a reading: what the caller holds never changes.
    [object] Read() {
        return [pscustomobject]@{
            InterfaceIndex  = $this.InterfaceIndex
            InterfaceGuid   = [guid]::Empty
            Name            = $this.Name
            Status          = $this.Status
            Dhcp            = $this.Dhcp
            InterfaceMetric = $this.InterfaceMetric
            AutomaticMetric = $this.AutomaticMetric
            Addresses       = [object[]]@($this.Addresses)
            Gateways        = [string[]]@($this.Gateways)
            DnsServers      = [string[]]@(@($this.DnsServers) + @($this.AdvertisedDns))
            # The simulated adapter's DNS servers are all static ones, but the network's; a DoH property is read with
            # its server, as Windows reads it by the server's position.
            Doh             = [pscustomobject]@{ Supported = $this.DohSupported; Read = $true; NameServers = [string[]]@($this.DnsServers); Servers = [object[]]@($this.DohServers | Where-Object { $_.Address -in $this.DnsServers }) }
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
                'ClearDns' { $this.DnsServers = @() }
                'SetDoh' {
                    # One family's servers, each encrypted with its template; the other family's
                    # stay as they are.
                    $ipv6 = $step.Family -eq 'IPv6'
                    $others = @($this.DnsServers | Where-Object { [bool]($_ -match ':') -ne $ipv6 })
                    $this.DnsServers = if ($ipv6) { @($others) + @($step.Servers) } else { @($step.Servers) + @($others) }
                    $kept = @($this.DohServers | Where-Object { [bool]($_.Address -match ':') -ne $ipv6 })
                    $set = for ($i = 0; $i -lt $step.Servers.Count; $i++) {
                        [pscustomobject]@{ Address = $step.Servers[$i]; Template = $step.Templates[$i]; Flags = [uint64]2 }
                    }
                    $this.DohServers = @($kept) + @($set)
                }
                'ClearDoh' {
                    $ipv6 = $step.Family -eq 'IPv6'
                    $this.DohServers = @($this.DohServers | Where-Object { [bool]($_.Address -match ':') -ne $ipv6 })
                }
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

    # Looks a name up as Receive-DohNameLookup reports it: Addresses, or Failure. Through Windows
    # ($source empty), the names in Names; through the operator's DNS, asked from the modem's
    # address $source - which the adapter must carry -, those in OperatorNames.
    [object] Lookup([string] $name, [string] $source) {
        $table = $this.Names
        if ($source) {
            if (-not @($this.Addresses | Where-Object Address -EQ $source)) {
                return [pscustomobject]@{ Addresses = [string[]]@(); Failure = 'The requested address is not valid in its context.' }
            }
            $table = $this.OperatorNames
        }
        if ($table.ContainsKey($name)) {
            return [pscustomobject]@{ Addresses = [string[]]@($table[$name]); Failure = $null }
        }
        return [pscustomobject]@{ Addresses = [string[]]@(); Failure = 'No such host is known.' }
    }

    [void] Enable() {
        $this.Status = 'Up'
    }

    # A reading of its byte counters, shaped as Get-ModemAdapterCounter's.
    [object] ReadCounters() {
        if (@($this.Addresses | Where-Object Origin -EQ 'Manual').Count -gt 0) {
            $this.ReceivedBytes += $this.TrafficPerRead
            $this.SentBytes += [uint64][Math]::Floor($this.TrafficPerRead / 10)
        }
        return [pscustomobject]@{ Interface = '00000000-0000-0000-0000-000000000099'; Received = $this.ReceivedBytes; Sent = $this.SentBytes; Time = [DateTimeOffset]::Now }
    }

    # Created anew, as a real adapter is when its USB device restarts: its counters start over.
    [void] ResetCounters() {
        $this.ReceivedBytes = 0
        $this.SentBytes = 0
    }
}

# lpac in development mode, with the shape Invoke-LpacOperation takes (ReadLine, WriteLine,
# Ended, ExitCode, Stop, Dispose). It speaks lpac's stdio protocol (AT-COMMANDS section 8) for one
# operation - connect, a channel on the ISD-R, the operation's ES10 requests as STORE DATA, the
# channel closed, disconnect - and gives lpac's result from what the simulated eUICC holds. Its
# APDUs change the eUICC as lpac's do, so the simulated modem resets the SIM after a profile
# switch as the device does; a download adds its profile at the end. A matching ID that starts
# with FAIL is refused by the server.
[NoRunspaceAffinity()]
class SimulatedLpac {
    [bool] $Ended = $false
    hidden [object] $Euicc
    hidden [string[]] $Arguments
    hidden [string] $Operation
    hidden [System.Collections.Generic.List[hashtable]] $Plan = [System.Collections.Generic.List[hashtable]]::new()
    hidden [int] $Step = 0
    hidden [string] $Pending
    hidden [int] $Channel = 0
    hidden [System.Collections.Generic.List[string]] $Responses = [System.Collections.Generic.List[string]]::new()
    hidden [string] $Failure
    hidden [string] $Detail
    hidden [bool] $ResultGiven = $false

    SimulatedLpac([string[]] $arguments, [object] $euicc) {
        $this.Arguments = $arguments
        $this.Euicc = $euicc
        $this.Operation = "$($arguments[0]) $($arguments[1])"
        $this.Plan.Add(@{ Kind = 'connect' })
        $this.Plan.Add(@{ Kind = 'logic_channel_open' })
        $requests = switch ($this.Operation) {
            'chip info' { 'BF3E035C015A', 'BF2200' }
            'profile list' { 'BF2D00' }
            'profile enable' { $this.Toggle('BF31') }
            'profile disable' { $this.Toggle('BF32') }
            'profile delete' { $this.Wrap('BF33', '4F10' + $arguments[2]) }
            'profile nickname' { $this.Nickname() }
            'profile download' { $this.Download() }
            'notification list' { 'BF2800' }
            'notification process' { 'BF2800' }
        }
        foreach ($request in @($requests)) {
            if ($request -like 'progress:*') {
                $this.Plan.Add(@{ Kind = 'progress'; Step = $request.Substring(9) })
            }
            else {
                $this.Plan.Add(@{ Kind = 'transmit'; Body = $request })
            }
        }
        $this.Plan.Add(@{ Kind = 'logic_channel_close' })
        $this.Plan.Add(@{ Kind = 'disconnect' })
    }

    [string] ReadLine([int] $timeoutMs) {
        if ($this.Ended -or $this.Pending) {
            return $null
        }
        if ($this.Step -lt $this.Plan.Count) {
            $entry = $this.Plan[$this.Step]
            if ($entry.Kind -eq 'progress') {
                $this.Step++
                return '{"type":"progress","payload":{"code":0,"message":"' + $entry.Step + '","data":"smdp.example.com"}}'
            }
            $this.Pending = $entry.Kind
            $parameter = switch ($entry.Kind) {
                'logic_channel_open' { '"A0000005591010FFFFFFFF8900000100"' }
                'logic_channel_close' { '"{0:X2}"' -f $this.Channel }
                'transmit' { '"{0:X2}E29100{1:X2}{2}"' -f (0x80 -bor ($this.Channel -band 0x0F)), ($entry.Body.Length / 2), $entry.Body }
                default { 'null' }
            }
            return '{"type":"apdu","payload":{"func":"' + $entry.Kind + '","param":' + $parameter + '}}'
        }
        if (-not $this.ResultGiven) {
            $this.ResultGiven = $true
            return $this.Result()
        }
        $this.Ended = $true
        return $null
    }

    [void] WriteLine([string] $text) {
        $code = if ($text -match '"ecode":(-?\d+)') { [int]$Matches[1] } else { -1 }
        $data = if ($text -match '"data":"([0-9A-Fa-f]*)"') { $Matches[1].ToUpperInvariant() } else { '' }
        $kind = $this.Pending
        $this.Pending = $null
        $this.Step++
        switch ($kind) {
            'connect' {
                if ($code -lt 0) {
                    $this.Fail('euicc_init', $null, $this.Plan.Count)
                }
            }
            'logic_channel_open' {
                if ($code -lt 0) {
                    $this.Fail('euicc_init', $null, $this.Plan.Count - 1)
                }
                else {
                    $this.Channel = $code
                }
            }
            'transmit' {
                if ($code -lt 0 -or $data.Length -lt 4 -or $data.Substring($data.Length - 4, 1) -ne '9') {
                    $this.Fail($this.StepName(), $null, $this.Plan.Count - 2)
                }
                else {
                    $this.Responses.Add($data)
                }
            }
        }
    }

    [Nullable[int]] ExitCode([int] $timeoutMs) {
        return $(if ($this.Failure) { 255 } else { 0 })
    }

    [void] Stop() {
        $this.Ended = $true
    }

    [void] Dispose() {
        $this.Ended = $true
    }

    # A failed step: lpac closes its channel (from step $resume on) and says why.
    hidden [void] Fail([string] $name, [string] $detail, [int] $resume) {
        if (-not $this.Failure) {
            $this.Failure = $name
            $this.Detail = $detail
        }
        $this.Step = [Math]::Max($this.Step, $resume)
    }

    hidden [string] StepName() {
        $names = @{
            'chip info' = 'es10c_get_eid'; 'profile list' = 'es10c_get_profiles_info'; 'profile enable' = 'es10c_enable_profile'
            'profile disable' = 'es10c_disable_profile'; 'profile delete' = 'es10c_delete_profile'; 'profile nickname' = 'es10c_set_nickname'
            'profile download' = 'es10b_load_bound_profile_package'; 'notification list' = 'es10b_list_notification'; 'notification process' = 'es10b_list_notification'
        }
        return $names[$this.Operation]
    }

    hidden [string] Wrap([string] $tag, [string] $body) {
        return '{0}{1:X2}{2}' -f $tag, ($body.Length / 2), $body
    }

    hidden [string] Toggle([string] $tag) {
        $refresh = if ($this.Arguments.Count -gt 3 -and $this.Arguments[3] -eq '1') { 'FF' } else { '00' }
        return $this.Wrap($tag, $this.Wrap('A0', '4F10' + $this.Arguments[2]) + '8101' + $refresh)
    }

    hidden [string] Nickname() {
        $digits = $this.Arguments[2].PadRight(20, 'F')
        $bcd = -join @(for ($i = 0; $i -lt 20; $i += 2) { $digits[$i + 1]; $digits[$i] })
        $name = if ($this.Arguments.Count -gt 3) { $this.Arguments[3] } else { '' }
        $text = [Convert]::ToHexString([System.Text.Encoding]::UTF8.GetBytes($name))
        return $this.Wrap('BF29', '5A0A' + $bcd + ('90{0:X2}' -f ($text.Length / 2)) + $text)
    }

    # A download's progress and requests; a code lpac would refuse fails before them.
    hidden [string[]] Download() {
        $code = ''
        $confirmation = ''
        for ($i = 2; $i -lt $this.Arguments.Count - 1; $i++) {
            if ($this.Arguments[$i] -eq '-a') { $code = $this.Arguments[$i + 1] }
            if ($this.Arguments[$i] -eq '-c') { $confirmation = $this.Arguments[$i + 1] }
        }
        $fields = $code -replace '^LPA:', '' -split '\$'
        if ($fields.Count -lt 3 -or $fields[0] -ne '1') {
            $this.Fail('activation_code', 'invalid', 0)
            return @()
        }
        if ($fields[2] -notmatch '^[A-Za-z0-9-]*$') {
            $this.Fail('matching_id', 'invalid format, contains character not alphanumeric or dash', 0)
            return @()
        }
        if ($fields.Count -gt 4 -and $fields[4] -eq '1' -and -not $confirmation) {
            $this.Fail('confirmation_code', 'required', 0)
            return @()
        }
        if ($fields[2] -like 'FAIL*') {
            $this.Fail('es9p_initiate_authentication', 'Profile not available', 0)
            return @('progress:es10b_get_euicc_challenge_and_info', 'BF2E00', 'progress:es9p_initiate_authentication')
        }
        return @('progress:es10b_get_euicc_challenge_and_info', 'BF2E00', 'progress:es9p_initiate_authentication', 'progress:es10b_authenticate_server',
            'BF3800', 'progress:es9p_authenticate_client', 'progress:es10b_prepare_download', 'BF2100', 'progress:es9p_get_bound_profile_package',
            'progress:es10b_load_bound_profile_package', 'BF3600')
    }

    # lpac's result line, from what the eUICC holds once the requests are done.
    hidden [string] Result() {
        $data = $null
        if (-not $this.Failure) {
            $answer = @($this.Responses | Where-Object { $_ -match '^BF(31|32|33|29)038001([0-9A-F]{2})' }) | Select-Object -First 1
            $result = if ($answer -and $answer -match '^BF(?:31|32|33|29)038001([0-9A-F]{2})') { [Convert]::ToInt32($Matches[1], 16) } else { 0 }
            if ($result -ne 0) {
                $reasons = @{
                    'profile enable'   = @{ 1 = 'iccid or aid not found'; 2 = 'profile not in disabled state'; 3 = 'disallowed by policy' }
                    'profile disable'  = @{ 1 = 'iccid or aid not found'; 2 = 'profile not in enabled state'; 3 = 'disallowed by policy' }
                    'profile delete'   = @{ 1 = 'iccid or aid not found'; 2 = 'profile not in disabled state'; 3 = 'disallowed by policy' }
                    'profile nickname' = @{ 1 = 'iccid not found' }
                }
                $reason = $reasons[$this.Operation][$result]
                $this.Failure = $this.StepName()
                $this.Detail = if ($reason) { $reason } else { 'unknown' }
            }
        }
        if ($this.Failure) {
            return [ordered]@{ type = 'lpa'; payload = [ordered]@{ code = -1; message = $this.Failure; data = [string]$this.Detail } } | ConvertTo-Json -Compress -Depth 4
        }
        $chip = $this.Euicc
        switch ($this.Operation) {
            'chip info' {
                $data = [ordered]@{
                    eidValue                 = $chip.Eid
                    EuiccConfiguredAddresses = [ordered]@{ defaultDpAddress = $null; rootDsAddress = 'lpa.ds.example.com' }
                    EUICCInfo2               = [ordered]@{
                        profileVersion                 = '2.3.1'
                        svn                            = '2.2.2'
                        euiccFirmwareVer               = '1.0.0'
                        extCardResource                = [ordered]@{ installedApplication = 0; freeNonVolatileMemory = 391000; freeVolatileMemory = 5970 }
                        euiccCiPKIdListForVerification = @('81370f5125d0b1d408d4c3b232e6d25e795bebfb')
                    }
                }
            }
            'profile list' {
                $data = @(foreach ($each in $chip.Profiles) {
                        [ordered]@{
                            iccid = $each.Iccid; isdpAid = $each.Aid; profileState = $each.State.ToLowerInvariant(); profileNickname = $each.Nickname
                            serviceProviderName = $each.Provider; profileName = $each.Name; iconType = 'none'; icon = $null; profileClass = $each.Class.ToLowerInvariant()
                        }
                    })
            }
            'profile download' {
                $number = $chip.Profiles.Count + 1
                $iccid = '89001000000000000{0:D3}' -f $number
                $chip.Profiles.Add([pscustomobject]@{
                        Aid = 'A0000005591010FFFFFFFF89000010{0:X2}' -f $number; Iccid = $iccid; State = 'Disabled'; Nickname = $null
                        Provider = 'Example Mobile'; Name = "Example plan $number"; Class = 'Operational'
                    })
                $chip.Notify('install', $iccid)
                $data = [ordered]@{ seqNumber = 0; bppCommandId = 'undefined'; errorReason = 'undefined' }
            }
            'notification list' {
                $data = @(foreach ($each in $chip.Notifications) {
                        [ordered]@{ seqNumber = $each.Sequence; profileManagementOperation = $each.Operation; notificationAddress = $each.Address; iccid = $each.Iccid }
                    })
            }
            'notification process' {
                $chip.Notifications.Clear()
            }
        }
        return [ordered]@{ type = 'lpa'; payload = [ordered]@{ code = 0; message = 'success'; data = $data } } | ConvertTo-Json -Compress -Depth 6
    }
}

[NoRunspaceAffinity()]
class SimulatedDevice {
    [string] $Scenario
    [object] $Modem
    [object] $Adapter
    # How PnP sees the modem: 'Present' (its vendor functions on WinUSB, as the app puts them),
    # 'Unbound' (on MediaTek's driver: the app puts them on WinUSB) or 'Absent'.
    [string] $Presence = 'Present'
    # The app's interface class, which a bound AT port carries.
    [string] $InterfaceGuid
    # The interfaces on WinUSB.
    [System.Collections.Generic.HashSet[int]] $Bound = [System.Collections.Generic.HashSet[int]]::new()
    # The interfaces whose COM port another program holds: the app leaves them on their driver.
    [System.Collections.Generic.HashSet[int]] $HeldPorts = [System.Collections.Generic.HashSet[int]]::new()
    # What putting a function on WinUSB does: 'Done', 'Failed', or 'RestartNeeded' (Windows
    # finishes it at the next restart).
    [string] $BindResult = 'Done'
    # How many functions were put on WinUSB, and given back to their best driver.
    [int] $Binds = 0
    [int] $Restores = 0
    # A modem back from a reset comes back as a new device instance, on MediaTek's driver (a
    # re-enumeration, AT-COMMANDS section 1): the app puts it on WinUSB again.
    [bool] $NewInstanceOnReturn = $false
    # Its instance: the tail of its devices' instance IDs.
    [int] $Instance = 1
    # How long the modem stays off USB once it vanished (a restart).
    [int] $AwayMs = 5000
    # Probe rounds lost once the address is usable: a path still settling.
    [int] $LostRounds = 0
    # Probe rounds that pass before a path that is down shows it: proven once, then down.
    [int] $PassedRounds = 0
    # The installer's logon task, as Get-AppLogonTask reads it: none in development mode - the
    # app is not installed -; $false or $true to play an installed one.
    [object] $LogonTask = $null
    hidden [long] $LostAt = 0

    # The modem's functions as PnP would report them, shaped as Get-ModemPnpRecord's: none while
    # it is off USB - it vanished, for AwayMs; then it is back, on the same port, or as a new
    # instance on MediaTek's driver.
    [object[]] PnpRecords() {
        if ($this.Presence -eq 'Absent') {
            return @()
        }
        if ($this.Modem.Lost) {
            $now = [Environment]::TickCount64
            if ($this.LostAt -eq 0) {
                $this.LostAt = $now
            }
            if ($now - $this.LostAt -lt $this.AwayMs) {
                return @()
            }
            $this.LostAt = 0
            if ($this.NewInstanceOnReturn) {
                $this.Instance++
                $this.Bound.Clear()
                $this.Presence = 'Unbound'
            }
            $this.Modem.Reappear($this.Modem.PortName)
        }
        $parent = "USB\VID_0E8D&PID_7127\SIMULATED$($this.Instance)"
        $records = [System.Collections.Generic.List[object]]::new()
        $records.Add([pscustomobject]@{
                InstanceId = "USB\VID_0E8D&PID_7127&MI_00\SIMULATED$($this.Instance)&0000"; Present = $true; ProblemCode = 0; Service = 'usbrndis6'; Parent = $parent
                CompatibleIds = @('USB\Class_e0&SubClass_01&Prot_03'); PortName = $null; InterfaceGuids = $null
            })
        $records.Add([pscustomobject]@{
                InstanceId = "USB\VID_0E8D&PID_7127&MI_05\SIMULATED$($this.Instance)&0005"; Present = $true; ProblemCode = 0; Service = 'WINUSB'; Parent = $parent
                CompatibleIds = @('USB\Class_ff&SubClass_42&Prot_01'); PortName = $null; InterfaceGuids = $null
            })
        # Composition 7127's vendor serial functions (AT-COMMANDS section 1).
        foreach ($interface in @(2, 3, 4, 6, 7, 8, 9)) {
            $onWinUsb = $this.Bound.Contains($interface)
            $records.Add([pscustomobject]@{
                    InstanceId     = "USB\VID_0E8D&PID_7127&MI_0$interface\SIMULATED$($this.Instance)&000$interface"; Present = $true; ProblemCode = 0
                    Service        = if ($onWinUsb) { 'WINUSB' } else { 'usb2ser_tm' }
                    Parent         = $parent
                    CompatibleIds  = @('USB\Class_ff&SubClass_00&Prot_00')
                    PortName       = if ($onWinUsb) { $null } else { "COM$(20 + $interface)" }
                    InterfaceGuids = if ($onWinUsb -and $interface -eq 6) { @($this.InterfaceGuid) } else { $null }
                })
        }
        return $records.ToArray()
    }

    # Whether a COM port can be opened, as Test-UsbFunctionFree finds it: held by another program
    # (ERROR_BUSY, MediaTek's driver's answer: AT-COMMANDS section 2), or free.
    [int] TryPort([string] $portName) {
        foreach ($interface in $this.HeldPorts) {
            if ($portName -eq "COM$(20 + $interface)") {
                return 170
            }
        }
        return 0
    }

    # A function put on WinUSB, shaped as Install-WinUsbDriver's result.
    [object] Bind([string] $instanceId) {
        $interface = [Convert]::ToInt32(($instanceId -replace '^.*&MI_([0-9A-F]{2})\\.*$', '$1'), 16)
        switch ($this.BindResult) {
            'Failed' {
                return [pscustomobject]@{ Done = $false; NeedReboot = $false; Step = 'Install'; Error = 0xE0000203 }
            }
            'RestartNeeded' {
                return [pscustomobject]@{ Done = $true; NeedReboot = $true; Step = 'Install'; Error = 0 }
            }
        }
        [void]$this.Bound.Add($interface)
        $this.Binds++
        if ($interface -eq 6) {
            $this.Presence = 'Present'
        }
        return [pscustomobject]@{ Done = $true; NeedReboot = $false; Step = 'Install'; Error = 0 }
    }

    # A function given back to its best driver, MediaTek's, shaped as Restore-UsbFunctionDriver's
    # result.
    [object] Restore([string] $instanceId) {
        $interface = [Convert]::ToInt32(($instanceId -replace '^.*&MI_([0-9A-F]{2})\\.*$', '$1'), 16)
        [void]$this.Bound.Remove($interface)
        $this.Restores++
        if ($interface -eq 6) {
            $this.Presence = 'Unbound'
        }
        return [pscustomobject]@{ Done = $true; NeedReboot = $false; Step = 'Best'; Error = 0 }
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

    # lpac, for one operation on the modem's eUICC (SimulatedLpac).
    [object] StartLpac([string[]] $arguments) {
        return [SimulatedLpac]::new($arguments, $this.Modem.Euicc)
    }

    # Windows restarts the modem's USB device (R6): it leaves USB, and comes back after AwayMs
    # with its power-on defaults - a hung modem answers again -, its adapter created anew.
    [void] Restart() {
        $this.Modem.Vanish()
        $this.Adapter.ResetCounters()
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
        - NoDevice: no modem on USB.
        - Unbound: its vendor functions on MediaTek's driver, as before the app: the app puts them
          on WinUSB (Bind()), then goes online.
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
        - LteOnlyMode: online, the modem in LTE-only mode, set before the app.
        - NrOnlyMode: the modem in NR-only mode where no 5G SA network is offered: it finds no
          network until another mode is chosen.
        - Standalone: online, in a network that offers 5G SA: NR-only mode registers on it.
        - EsimEmpty: the eUICC's slot in use, no profile enabled (+CPIN: EMPTY_EUICC).
        - Esim: the eUICC's slot in use, an operational profile enabled, online.
        Every scenario's modem keeps a network mode (AT+GTACT): a change registers it again, in a
        network with LTE on B1, B3, B7 and B20 and NR on n78 (EN-DC; 5G SA in Standalone). And
        messages on its SIM - one read, two unread, one of them in two parts -, one more coming
        in a minute after it starts (none in Connect); sending one succeeds. And two SIM slots, as
        our module has them: the physical SIM on slot 0, in use; an eUICC on slot 1 holding a
        test profile, disabled (SimulatedEuicc), which lpac reaches in development mode too
        (StartLpac).

        Returns an object with Scenario, Modem (New-SimulatedModem's), Adapter, Presence, and
        the methods the worker calls: PnpRecords() (its functions as PnP would report them),
        TryPort() (a COM port held or free), Bind() and Restore() (a function put on WinUSB, or given
        back to MediaTek's driver), Open() (its port, for a new channel), Probe() (a data-path
        round), Restart() (its USB device), and StartLpac() (lpac for one operation on the eUICC:
        SimulatedLpac).
    .EXAMPLE
        Invoke-ModemWorker -Link $link -Simulation (New-SimulatedDevice -Scenario PinRequired)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates in-memory objects; changes no system state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [ValidateSet('Online', 'Connect', 'ApnNeeded', 'PinRequired', 'FccLocked', 'AdapterDisabled', 'NoDevice', 'Unbound',
            'Settling', 'DataPathDown', 'IcmpDropped', 'RegistrationLost', 'ModemHung', 'Unrecoverable', 'LteOnlyMode', 'NrOnlyMode', 'Standalone',
            'EsimEmpty', 'Esim')]
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

    $modem = New-SimulatedModem -PortName $PortName -Messaging -Euicc
    # Its SIM slots and eUICC, as the scenario changes the base ones.
    $esim = @{}
    foreach ($source in @($data.Esim, (& $setting 'Esim' @{}))) {
        foreach ($key in $source.Keys) {
            $esim[$key] = $source[$key]
        }
    }
    $modem.Euicc.Slot = [int]$esim['Slot']
    foreach ($entry in @($esim['Profiles'])) {
        $modem.Euicc.Profiles.Add([pscustomobject]@{
                Aid = $entry.Aid; Iccid = $entry.Iccid; State = $entry.State; Nickname = if ($entry.Nickname) { $entry.Nickname } else { $null }
                Provider = $entry.Provider; Name = $entry.Name; Class = $entry.Class
            })
    }
    $messages = & $setting 'Messages' $data.Messages
    foreach ($stored in $messages.Stored) {
        [void]$modem.Messaging.Store($stored.Status, $stored.Pdu)
    }
    foreach ($arrival in $messages.Arrivals) {
        $modem.Messaging.Arrivals.Add([pscustomobject]@{ AtMs = $arrival.AfterMs; Pdu = $arrival.Pdu })
    }
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

    # Its network mode, as the scenario changes the base one; its radio on EN-DC is the base's.
    $description = @{}
    foreach ($source in @($data.NetworkMode, (& $setting 'NetworkMode' @{}))) {
        foreach ($key in $source.Keys) {
            $description[$key] = $source[$key]
        }
    }
    $radio = @{ Endc = @{} }
    foreach ($read in 'AT+CESQ', 'AT+GTCCINFO?;+GTCAINFO?') {
        $radio['Endc'][$read] = [string[]]$base[$read]
    }
    foreach ($situation in $description['Radio'].Keys) {
        $radio[$situation] = $description['Radio'][$situation]
    }
    $description['Radio'] = $radio
    $modem.NetworkMode = New-SimulatedNetworkMode -Description $description
    # The registration it starts with, made to match its mode.
    $modem.NetworkMode.Settle($modem)

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
    $device.InterfaceGuid = $script:AppInterfaceGuid
    if ($device.Presence -eq 'Present') {
        foreach ($interface in 2, 3, 4, 6, 7, 8, 9) {
            [void]$device.Bound.Add($interface)
        }
    }
    $device.LostRounds = & $setting 'LostRounds' 0
    $device.PassedRounds = & $setting 'PassedRounds' 0
    $device
}

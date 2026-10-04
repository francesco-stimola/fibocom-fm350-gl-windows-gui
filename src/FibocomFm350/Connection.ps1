# The connection state machine: from what the worker observed to the state the connection is in
# and the next step that brings it closer to online. Design: docs/ARCHITECTURE.md -> Connection
# state machine, Startup reconciliation.

# The states, in order: each one needs the ones before it.
$script:ConnectionStates = @('NoDevice', 'PortOpen', 'Identified', 'SimReady', 'Registered', 'DataActive', 'Online')

# The data context the app defines and activates. Context 0 is the modem's own attach context
# (AT-COMMANDS section 3).
$script:DataContextId = 1

# The IMS APN as +CGCONTRDP names it: the network identifier 'ims', with or without the operator
# identifier 'mnc<MNC>.mcc<MCC>.gprs' (AT-COMMANDS section 3). It carries no internet traffic.
$script:ImsApnPattern = '^ims(\.mnc\d{3}\.mcc\d{3}\.gprs)?$'

function Resolve-ConnectionState {
    <#
    .SYNOPSIS
        Decides the connection's state and its next step from what was observed.
    .DESCRIPTION
        A pure transition function (ARCHITECTURE -> Connection state machine). The state is the
        furthest one the facts support, so starting up on a connection that is already up finds it
        Online and does nothing: the app attaches, it never re-dials by reflex. The action is the
        first missing step. Facts not observed are $null.

        -Observation carries:
        - Device: 'Present', 'Absent', 'NoDriver' or 'Problem' (the AT port, from PnP).
        - PortOpen, Responsive: the AT port is open; the modem answers on it. PortError: why it
          couldn't be opened - 'InUse' (another program holds it) or 'Failed'.
        - Sim: Resolve-SimPinAction's decision.
        - Fcc: Resolve-FccLock's diagnosis.
        - RadioOn: +CFUN is 1. OperatorMode: +COPS's mode (2: deregistered by a command).
        - Registered, RegistrationState: from +CEREG / +C5GREG.
        - ContextDefined: the app's context is defined as the settings say. ContextActive,
          ContextAddress, ContextApn: it is active, with this IPv4 address, on this APN (as the
          network reports it); ContextActive $null: its activation couldn't be read.
          ContextRead: $false when the active context's parameters couldn't be read. ApnSet: the
          settings name an APN (empty: the subscription's own). ApnPasswordUnreadable: the
          settings ask for APN credentials and a stored password exists but can't be read (no
          stored password is an empty one, which some operators expect).
        - Adapter: 'Present', 'Disabled' (by the user) or 'Absent' (the modem's network
          adapter). AdapterConfigured: its
          configuration matches the context and the settings. AdapterProblem: why it can't be
          configured from what the modem reports or the settings ask (Resolve-AdapterConfiguration's
          Problem; an encrypted-DNS one blocks). Elevated: $false when the app has no
          administrator rights to configure it. DohSupported, DohServers (encrypted now) and
          DohKnown (the servers Windows has a template for): for display. DnsUnread: what
          Windows wouldn't read, when encryption is left as it is for it (the plan's Unread).
          DnsAdvertised: the IPv6 DNS servers the network gives, encrypted DNS on (the plan's).
        - DataPath: the last data-path probe passed ($null: not probed).
        - NetworkMode: Resolve-NetworkMode's decision on the modem's mode and bands.

        Returns:
        - State: 'NoDevice', 'PortOpen', 'Identified', 'SimReady', 'Registered', 'DataActive' or
          'Online'.
        - Action: the next step - 'OpenPort', 'Initialize', 'EnterPin', 'RadioOn',
          'AutoRegister', 'ApplyNetworkMode', 'DefineContext', 'ActivateContext',
          'DeactivateContext', 'ConfigureAdapter' - or 'None'. The network mode the settings ask
          is written once the SIM is ready and the radio on, before the context's steps - it
          registers the modem again - and on a connection that is up too: the state stays the
          one the facts support.
        - Reason: why there is no step to take, or $null.
        - Blocked: $true when what stops the connection is out of the app's reach - no device or
          driver, a SIM waiting for the user, an FCC lock, an APN or an APN password the user
          must give, an adapter missing or disabled, no administrator rights to configure it,
          encrypted DNS the settings ask and Windows can't set: no recovery step changes it, so
          none is escalated (ARCHITECTURE -> Health checks).

        A context that is active without an IPv4 address, or on the IMS APN, carries no internet
        traffic. With an empty APN in the settings, the network chose the APN - on some networks
        the IMS one, with or without an address: the reason is then 'ApnNeeded'. When it differs
        from the settings, it is deactivated, to be defined and activated as they say: nothing
        that works is broken.
        - Dropped: $true when -Previous was a further state than this one.
        - SettingsPending: the context is active but not as the settings say; it is left as it
          is - the new settings apply at the next connect.
    .EXAMPLE
        Resolve-ConnectionState -Observation $facts -Previous 'Online'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Observation,

        [ValidateSet('NoDevice', 'PortOpen', 'Identified', 'SimReady', 'Registered', 'DataActive', 'Online')]
        [string] $Previous
    )

    $facts = @{}
    if ($Observation -is [System.Collections.IDictionary]) {
        foreach ($key in $Observation.Keys) {
            $facts[[string]$key] = $Observation[$key]
        }
    }
    else {
        foreach ($property in $Observation.PSObject.Properties) {
            $facts[$property.Name] = $property.Value
        }
    }
    $fact = { param($name) $facts[$name] }
    $previousIndex = if ($Previous) { $script:ConnectionStates.IndexOf($Previous) } else { -1 }
    $mode = & $fact 'NetworkMode'
    $outcome = {
        param($state, $action, $reason, $blocked)
        $settingsPending = (& $fact 'ContextActive') -eq $true -and (& $fact 'ContextDefined') -eq $false
        # The network mode, when the modem's differs from the settings: written once the SIM is
        # ready and the radio on, ahead of the context's steps, whatever else waits. The reason
        # and the block stay: they still say what the connection waits for.
        if ($mode -and $mode.Command -and $state -notin 'NoDevice', 'PortOpen', 'Identified' -and $reason -ne 'FccLocked' -and
            $action -in 'None', 'DefineContext', 'ActivateContext', 'DeactivateContext', 'ConfigureAdapter') {
            $action = 'ApplyNetworkMode'
        }
        [pscustomobject]@{
            State           = $state
            Action          = $action
            Reason          = $reason
            Blocked         = [bool]$blocked
            Dropped         = $previousIndex -gt $script:ConnectionStates.IndexOf($state)
            SettingsPending = $settingsPending
        }
    }

    $device = & $fact 'Device'
    if ($device -ne 'Present') {
        $reason = switch ($device) { 'NoDriver' { 'NoDriver' } 'Problem' { 'DeviceProblem' } default { 'NoDevice' } }
        return & $outcome 'NoDevice' 'None' $reason $true
    }
    if ((& $fact 'PortOpen') -ne $true) {
        $reason = switch (& $fact 'PortError') { 'InUse' { 'PortInUse' } 'Failed' { 'PortFailed' } default { $null } }
        return & $outcome 'NoDevice' 'OpenPort' $reason $false
    }
    if ((& $fact 'Responsive') -ne $true) {
        return & $outcome 'PortOpen' 'Initialize' $null $false
    }

    $sim = & $fact 'Sim'
    if ($null -eq $sim) {
        return & $outcome 'Identified' 'None' 'SimUnknown' $false
    }
    switch ($sim.Action) {
        'Continue' { }
        'SendPin' { return & $outcome 'Identified' 'EnterPin' $null $false }
        'Wait' { return & $outcome 'Identified' 'None' $sim.Reason $false }
        { $_ -in 'AskUser', 'Report' } { return & $outcome 'Identified' 'None' $sim.Reason $true }
        default { return & $outcome 'Identified' 'None' 'SimUnknown' $false }
    }

    $registered = (& $fact 'Registered') -eq $true
    $fcc = & $fact 'Fcc'
    if (-not $registered -and $null -ne $fcc -and $fcc.Diagnosis -eq 'Locked') {
        return & $outcome 'SimReady' 'None' 'FccLocked' $true
    }
    if ((& $fact 'RadioOn') -eq $false) {
        return & $outcome 'SimReady' 'RadioOn' $null $false
    }
    if ((& $fact 'OperatorMode') -eq 2) {
        return & $outcome 'SimReady' 'AutoRegister' $null $false
    }
    # Written only over a context known to be inactive: what the modem does with a definition
    # written under an active context is not known.
    if ((& $fact 'ContextDefined') -eq $false -and (& $fact 'ContextActive') -eq $false) {
        return & $outcome 'SimReady' 'DefineContext' $null $false
    }
    if (-not $registered) {
        $state = & $fact 'RegistrationState'
        return & $outcome 'SimReady' 'None' $(if ($state) { $state } else { 'NotRegistered' }) $false
    }

    # A context whose activation or parameters couldn't be read is neither activated nor
    # replaced: the next pass reads it again.
    if ($null -eq (& $fact 'ContextActive')) {
        return & $outcome 'Registered' 'None' 'ContextUnknown' $false
    }
    if ((& $fact 'ContextActive') -eq $false) {
        # A stored APN password that can't be read is never replaced by an empty one: the user
        # gives it again (decided 2026-10-01).
        if ((& $fact 'ApnPasswordUnreadable') -eq $true) {
            return & $outcome 'Registered' 'None' 'ApnPasswordUnreadable' $true
        }
        return & $outcome 'Registered' 'ActivateContext' $null $false
    }
    if ((& $fact 'ContextRead') -eq $false) {
        return & $outcome 'Registered' 'None' 'ContextUnknown' $false
    }
    # -match compares without case: APNs are not case-sensitive.
    if (-not (& $fact 'ContextAddress') -or [string](& $fact 'ContextApn') -match $script:ImsApnPattern) {
        if ((& $fact 'ContextDefined') -eq $false) {
            return & $outcome 'Registered' 'DeactivateContext' $null $false
        }
        if ((& $fact 'ApnSet') -eq $false) {
            return & $outcome 'Registered' 'None' 'ApnNeeded' $true
        }
        return & $outcome 'Registered' 'None' 'NoAddress' $false
    }

    if ((& $fact 'Adapter') -eq 'Disabled') {
        return & $outcome 'DataActive' 'None' 'AdapterDisabled' $true
    }
    if ((& $fact 'Adapter') -ne 'Present') {
        return & $outcome 'DataActive' 'None' 'NoAdapter' $true
    }
    if ((& $fact 'AdapterConfigured') -ne $true) {
        $problem = & $fact 'AdapterProblem'
        if ($problem) {
            # Encrypted DNS that can't be set waits for the user: no step changes it.
            return & $outcome 'DataActive' 'None' $problem ($problem -like 'Doh*')
        }
        # Configuring the adapter needs administrator rights: without them the step can only fail.
        if ((& $fact 'Elevated') -eq $false) {
            return & $outcome 'DataActive' 'None' 'NotElevated' $true
        }
        return & $outcome 'DataActive' 'ConfigureAdapter' $null $false
    }
    if ((& $fact 'DataPath') -eq $false) {
        return & $outcome 'DataActive' 'None' 'DataPathFailed' $false
    }
    & $outcome 'Online' 'None' $null $false
}

function Get-ModemObservation {
    <#
    .SYNOPSIS
        Reads, on an open AT channel, what Resolve-ConnectionState needs.
    .DESCRIPTION
        The thin I/O in front of the state machine: it reads the modem's state and the adapter's,
        and changes nothing. It reads only as far as the state allows: the SIM, then - with the
        SIM ready - the radio, the registration, the network mode and its bands, the context's
        definition and activation, and - while not registered - the operator selection and the
        FCC lock; once registered, the active context's parameters, and the adapter. A read that
        fails leaves its fact unknown.

        Returns Facts (the observation for Resolve-ConnectionState; also SimState, the SIM's
        state, PinAttemptsLeft, read while the SIM waits for its PIN, NetworkModeRead and
        NetworkModeSupport, the modem's mode setting and what it supports, ContextDns, the
        operator's DNS servers for the context), and what the steps
        need: Context (the app's context parameters), AdapterState and AdapterPlan, Settings and
        ApnSecretPath (the SIM's own, with -SimSettings). The ICCID is read to match the stored
        PIN and, with -SimSettings, to tell the SIM in use at every pass - a SIM can change
        without the port closing -, and kept nowhere: Sim carries its fingerprint, with the Id
        and Source of Resolve-SimSetting - $null when the SIM was not read, or its ICCID couldn't
        be: then the context is not read either, and stays unknown.
    .EXAMPLE
        $observation = Get-ModemObservation -Channel $channel -Settings $settings -AdapterInstanceId $modem.Network.InstanceId
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AtChannel] $Channel,

        [Parameter(Mandatory)]
        [object] $Settings,

        # The modem's network function (Resolve-ModemUsbDevice's Network.InstanceId).
        [string] $AdapterInstanceId,

        # Development mode: the in-memory adapter of New-SimulatedDevice, read instead of a real
        # one.
        [object] $SimulatedAdapter,

        [string] $SimPinPath = (Get-AppDataPath -Name 'sim-pin.json'),

        [string] $ApnSecretPath = (Get-AppDataPath -Name 'apn-password.dat'),

        # The settings kept for each SIM (Import-SimSetting's): the SIM in use connects with its
        # own APN settings. Without them, -Settings are every SIM's.
        [object] $SimSettings,

        # The data-path probes' verdict: Address (the one they were sent from) and Healthy
        # (Resolve-DataPathHealth's). It counts only for the context's address.
        [object] $DataPath,

        # What the modem supports of AT+GTACT (ConvertFrom-AtNetworkModeSupport's), when the
        # caller has it already: it is read only when not given.
        [object] $NetworkModeSupport,

        # The app's last write of the network mode (Resolve-NetworkMode's -LastWrite).
        [object] $NetworkModeLastWrite
    )

    if ($Channel.State -eq 'Closed') {
        throw [System.InvalidOperationException]::new('The AT channel is closed.')
    }
    $facts = [ordered]@{
        Device = 'Present'; PortOpen = $true; Responsive = $null; Sim = $null; SimState = $null; PinAttemptsLeft = $null; Fcc = $null
        RadioOn = $null; OperatorMode = $null; Registered = $null; RegistrationState = $null
        NetworkMode = $null; NetworkModeRead = $null; NetworkModeSupport = $null
        ContextDefined = $null; ContextActive = $null; ContextAddress = $null; ContextApn = $null; ContextDns = $null; ContextRead = $null; ApnSet = [bool]$Settings.Apn
        ApnPasswordUnreadable = $Settings.ApnAuthentication -ne 'None' -and (Test-Path -LiteralPath $ApnSecretPath -PathType Leaf) -and -not (Get-ApnPassword -Path $ApnSecretPath)
        Adapter = $null; AdapterConfigured = $null; AdapterProblem = $null; Elevated = $null; DataPath = $null
        DohSupported = $null; DohServers = $null; DohKnown = $null; DnsUnread = $null; DnsAdvertised = $null
    }
    $result = [pscustomobject]@{ Facts = $null; Context = $null; AdapterState = $null; AdapterPlan = $null; Settings = $Settings; ApnSecretPath = $ApnSecretPath; Sim = $null }
    $finish = {
        $result.Facts = [pscustomobject]$facts
        $result
    }
    $ask = {
        param($command)
        $answer = Invoke-AtCommand -Channel $Channel -Command $command
        if ($answer.Status -eq 'PortLost') {
            $facts.PortOpen = $false
        }
        elseif ($answer.Status -eq 'Timeout') {
            $facts.Responsive = $false
        }
        $answer
    }
    $stopped = { -not $facts.PortOpen -or $facts.Responsive -eq $false }

    # The SIM, and whether the stored PIN may be entered.
    $cpin = & $ask 'AT+CPIN?'
    if (& $stopped) {
        return & $finish
    }
    $facts.Responsive = $true
    $sim = ConvertFrom-AtSimState -Lines $cpin.Lines -ErrorCode $cpin.ErrorCode
    if ($null -eq $sim) {
        return & $finish
    }
    $facts.SimState = $sim.State
    $stored = Get-SimPin -Path $SimPinPath
    # Read whenever the SIM waits for its PIN: the rules need it, and so does the user typing it.
    $attemptsLeft = if ($sim.State -eq 'PinRequired') { Get-SimPinAttemptsLeft -Ask $ask }
    $facts.PinAttemptsLeft = $attemptsLeft
    # The SIM is identified when a PIN may be sent to it, and when a ready SIM could confirm a
    # pending attempt - only the stored PIN's SIM does.
    $iccid = $null
    if ($stored -and ($sim.State -eq 'PinRequired' -or ($sim.State -eq 'Ready' -and $stored.Attempted))) {
        $iccid = ConvertFrom-AtIccid -Lines (& $ask 'AT+ICCID').Lines
        $stored = Get-SimPin -Path $SimPinPath -Iccid $iccid
    }
    if (& $stopped) {
        return & $finish
    }
    $pinForThisSim = if ($stored) { $stored.ForThisSim } else { $null }
    $facts.Sim = Resolve-SimPinAction -SimState $sim.State -PinStored:([bool]$stored) -PinForThisSim $pinForThisSim `
        -PinAttempted:([bool]$stored -and $stored.Attempted) -AttemptsLeft $attemptsLeft
    if ($facts.Sim.Action -ne 'Continue') {
        if ($SimSettings) {
            # No SIM ready: none to connect with.
            $result.Sim = [pscustomobject]@{ Fingerprint = $null; Id = $null; Source = 'Unknown' }
        }
        return & $finish
    }

    # The SIM in use, and its own APN settings (ARCHITECTURE -> Settings and logs).
    if ($SimSettings) {
        if (-not $iccid) {
            $iccid = ConvertFrom-AtIccid -Lines (& $ask 'AT+ICCID').Lines
            if (& $stopped) {
                return & $finish
            }
        }
        if ($iccid) {
            $fingerprint = Get-SimSettingFingerprint -Iccid $iccid
            $own = Resolve-SimSetting -Settings $Settings -SimSettings $SimSettings -Fingerprint $fingerprint
            $Settings = $own.Settings
            $ApnSecretPath = Get-SimApnSecretPath -ApnSecretPath $ApnSecretPath -Id $own.Id
            $result.Settings = $Settings
            $result.ApnSecretPath = $ApnSecretPath
            $result.Sim = [pscustomobject]@{ Fingerprint = $fingerprint; Id = $own.Id; Source = $own.Source }
            $facts.ApnSet = [bool]$Settings.Apn
            $facts.ApnPasswordUnreadable = $Settings.ApnAuthentication -ne 'None' -and (Test-Path -LiteralPath $ApnSecretPath -PathType Leaf) -and -not (Get-ApnPassword -Path $ApnSecretPath)
        }
    }

    # Radio and registration.
    $cfun = & $ask 'AT+CFUN?'
    $fun = ConvertTo-AtInteger -Text (Get-AtArgument -Lines $cfun.Lines -Prefix '+CFUN' -Position 0)
    if ($null -ne $fun) {
        $facts.RadioOn = $fun -eq 1
    }
    $registrations = @((& $ask 'AT+CEREG?;+C5GREG?').Lines | ConvertFrom-AtRegistration -ReadAnswer)
    if (& $stopped) {
        return & $finish
    }
    $facts.Registered = @($registrations | Where-Object Registered).Count -gt 0
    $eps = @($registrations | Where-Object Domain -EQ 'EPS') + $registrations | Select-Object -First 1
    $facts.RegistrationState = if ($eps) { $eps.State } else { $null }
    if (-not $facts.Registered) {
        $operator = ConvertFrom-AtOperator -Lines (& $ask 'AT+COPS?').Lines
        if ($operator) {
            $facts.OperatorMode = $operator.Mode
        }
        $read = & $ask $script:FccReadCommand
        $lock = if ($read.Status -eq 'OK') { ConvertFrom-AtFccLock -Lines $read.Lines } else { $null }
        $facts.Fcc = Resolve-FccLock -Fcc $lock -Registered:$false
    }

    # The network mode and its bands: read at every pass - it is cheap - and what the modem
    # supports once per channel (the caller keeps it).
    $support = $NetworkModeSupport
    if (-not $support -and -not (& $stopped)) {
        $test = & $ask 'AT+GTACT=?'
        $support = if ($test.Status -eq 'OK') { ConvertFrom-AtNetworkModeSupport -Lines $test.Lines } else { $null }
    }
    if (-not (& $stopped)) {
        $setting = & $ask 'AT+GTACT?'
        $facts.NetworkModeRead = if ($setting.Status -eq 'OK') { ConvertFrom-AtNetworkMode -Lines $setting.Lines } else { $null }
    }
    $facts.NetworkModeSupport = $support
    $facts.NetworkMode = Resolve-NetworkMode -Settings $Settings -Current $facts.NetworkModeRead -Support $support -LastWrite $NetworkModeLastWrite

    # The app's data context: its definition and whether it is active, read together, so a
    # definition is never written over a context whose activation is not known. A read that
    # fails leaves its fact unknown ($null), never "no" - and so does a SIM whose settings are not
    # known: its ICCID couldn't be read.
    if ($SimSettings -and -not $result.Sim) {
        return & $finish
    }
    $definitions = & $ask 'AT+CGDCONT?'
    $activations = & $ask 'AT+CGACT?'
    if (& $stopped) {
        return & $finish
    }
    if ($definitions.Status -eq 'OK') {
        $ours = ConvertFrom-AtContextDefinition -Lines $definitions.Lines | Where-Object Cid -EQ $script:DataContextId | Select-Object -First 1
        # -eq compares text without case: APNs are not case-sensitive.
        $facts.ContextDefined = [bool]$ours -and $ours.PdpType -eq $Settings.PdpType -and $ours.Apn -eq $Settings.Apn
    }
    if ($activations.Status -eq 'OK') {
        $activation = ConvertFrom-AtContextActivation -Lines $activations.Lines | Where-Object Cid -EQ $script:DataContextId | Select-Object -First 1
        $facts.ContextActive = [bool]$activation -and $activation.Active
    }
    if (-not $facts.Registered -or $facts.ContextActive -ne $true) {
        return & $finish
    }
    $parameters = & $ask "AT+CGCONTRDP=$script:DataContextId"
    $context = if ($parameters.Status -eq 'OK') {
        ConvertFrom-AtContextParameter -Lines $parameters.Lines | Where-Object Cid -EQ $script:DataContextId | Select-Object -First 1
    }
    if ($context -and -not $context.IPv4Address) {
        # The FM350 leaves the address out of +CGCONTRDP for a data context; +CGPADDR has it
        # (AT-COMMANDS section 3).
        $addresses = & $ask "AT+CGPADDR=$script:DataContextId"
        if ($addresses.Status -eq 'OK') {
            $address = ConvertFrom-AtContextAddress -Lines $addresses.Lines | Where-Object Cid -EQ $script:DataContextId | Select-Object -First 1
            if ($address) {
                $context.IPv4Address = $address.IPv4Address
            }
        }
        else {
            $context = $null
        }
    }
    $facts.ContextRead = [bool]$context
    if (-not $context -or (& $stopped)) {
        return & $finish
    }
    if (@($context.Dns).Count -eq 0) {
        $servers = ConvertFrom-AtDnsServer -Lines (& $ask "AT+GTDNS=$script:DataContextId").Lines | Where-Object Cid -EQ $script:DataContextId | Select-Object -First 1
        if ($servers) {
            $context.Dns = $servers.Dns
        }
    }
    $result.Context = $context
    $facts.ContextAddress = if ($context) { $context.IPv4Address } else { $null }
    $facts.ContextApn = if ($context) { $context.Apn } else { $null }
    $facts.ContextDns = if ($context) { [string[]]@($context.Dns | Where-Object { $_ }) } else { $null }

    # The adapter.
    $adapter = if ($SimulatedAdapter) { $SimulatedAdapter.Read() } elseif ($AdapterInstanceId) { Get-ModemAdapterState -InstanceId $AdapterInstanceId } else { $null }
    $facts.Adapter = if (-not $adapter -or $adapter.Status -eq 'Not Present') { 'Absent' } elseif ($adapter.Status -eq 'Disabled') { 'Disabled' } else { 'Present' }
    if ($facts.Adapter -eq 'Present') {
        # Encrypted DNS: what the adapter carries, and the templates Windows knows.
        $encryption = if ($adapter.PSObject.Properties['Doh']) { $adapter.Doh } else { $null }
        $known = if ($SimulatedAdapter) { $SimulatedAdapter.KnownDoh } elseif ($encryption -and $encryption.Supported) { Get-DohKnownServer } else { $null }
        $facts.DohSupported = if ($encryption) { [bool]$encryption.Supported } else { $null }
        $facts.DohServers = [string[]]@(if ($encryption) { $encryption.Servers | Where-Object { Test-DohEnabled -Server $_ } | ForEach-Object Address })
        $facts.DohKnown = if ($known) { [string[]]@($known.Keys | Sort-Object) } else { [string[]]@() }
        $plan = Resolve-AdapterConfiguration -Context $context -Adapter $adapter -Settings $Settings -DohKnown $known
        $result.AdapterState = $adapter
        $result.AdapterPlan = $plan
        $facts.AdapterConfigured = $plan.Configured
        $facts.AdapterProblem = $plan.Problem
        $facts.DnsUnread = $plan.Unread
        $facts.DnsAdvertised = [string[]]@($plan.Advertised)
        # The simulated adapter needs no rights.
        $facts.Elevated = [bool]$SimulatedAdapter -or (Test-AppElevation)
        if ($DataPath -and $DataPath.Address -and $DataPath.Address -eq $facts.ContextAddress) {
            $facts.DataPath = $DataPath.Healthy
        }
    }
    & $finish
}

function Invoke-ConnectionStep {
    # Runs one step of the connect sequence. Returns Action, Result ('Done', 'Failed',
    # 'PinRejected', 'PinUnconfirmed'), and Commands: each command sent - redacted, never with a
    # secret - with its Status and ErrorCode.
    param(
        [AtChannel] $Channel,
        [string] $Action,
        [object] $Observation,
        [object] $Settings,
        [string] $SimPinPath,
        [string] $ApnSecretPath,
        [int] $InitializeTimeoutMs,
        [object] $SimulatedAdapter
    )

    $commands = [System.Collections.Generic.List[object]]::new()
    $send = {
        param($command)
        $answer = Invoke-AtCommand -Channel $Channel -Command $command
        $commands.Add([pscustomobject]@{ Command = ConvertTo-RedactedText -Text $command; Status = $answer.Status; ErrorCode = $answer.ErrorCode })
        $answer
    }
    $cid = $script:DataContextId
    $result = 'Failed'
    switch ($Action) {
        'Initialize' {
            $timeout = @{}
            if ($InitializeTimeoutMs -gt 0) {
                $timeout['TimeoutMs'] = $InitializeTimeoutMs
            }
            $answer = Initialize-AtChannel -Channel $Channel @timeout
            $commands.Add([pscustomobject]@{ Command = 'ATE1;+CMEE=1'; Status = $answer.Status; ErrorCode = $answer.ErrorCode })
            if ($answer.Status -eq 'OK') { $result = 'Done' }
        }
        'EnterPin' {
            $stored = Get-SimPin -Path $SimPinPath
            # Recorded before sending, and read back: an answer that never comes is never
            # followed by a second attempt, and a PIN whose attempt can't be recorded is not sent.
            $recorded = $false
            if ($stored) {
                try {
                    Set-SimPinAttempt -Attempted $true -Path $SimPinPath -Confirm:$false -ErrorAction Stop
                    $check = Get-SimPin -Path $SimPinPath
                    $recorded = [bool]$check -and $check.Attempted
                }
                catch {
                    $recorded = $false
                }
            }
            if ($recorded) {
                $answer = & $send ('AT+CPIN="{0}"' -f [System.Net.NetworkCredential]::new('', $stored.Pin).Password)
                if ($answer.Status -eq 'OK') {
                    $result = 'Done'
                    try {
                        Set-SimPinAttempt -Attempted $false -Path $SimPinPath -Confirm:$false -ErrorAction Stop
                    }
                    catch {
                        # Left pending: the SIM seen ready by a later observation clears it.
                        Write-Verbose "The accepted PIN couldn't be recorded: $($_.Exception.Message)"
                    }
                }
                elseif ($answer.Status -eq 'CmeError' -and $answer.ErrorCode -eq 16) {
                    # Wrong: never tried again.
                    Remove-SimPin -Path $SimPinPath -Confirm:$false
                    $result = 'PinRejected'
                }
                else {
                    $result = 'PinUnconfirmed'
                }
            }
        }
        'RadioOn' {
            if ((& $send 'AT+CFUN=1').Status -eq 'OK') { $result = 'Done' }
        }
        'AutoRegister' {
            if ((& $send 'AT+COPS=0').Status -eq 'OK') { $result = 'Done' }
        }
        'ApplyNetworkMode' {
            if ((& $send $Observation.Facts.NetworkMode.Command).Status -eq 'OK') { $result = 'Done' }
        }
        'DefineContext' {
            if ((& $send ('AT+CGDCONT={0},"{1}","{2}"' -f $cid, $Settings.PdpType, $Settings.Apn)).Status -eq 'OK') { $result = 'Done' }
        }
        'DeactivateContext' {
            if ((& $send "AT+CGACT=0,$cid").Status -eq 'OK') { $result = 'Done' }
        }
        'ActivateContext' {
            $authenticated = $true
            if ($Settings.ApnAuthentication -ne 'None') {
                $code = if ($Settings.ApnAuthentication -eq 'PAP') { 1 } else { 2 }
                $secret = Get-ApnPassword -Path $ApnSecretPath
                if (-not $secret -and (Test-Path -LiteralPath $ApnSecretPath -PathType Leaf)) {
                    # Stored but unreadable: never sent as an empty one.
                    $authenticated = $false
                }
                else {
                    $password = if ($secret) { [System.Net.NetworkCredential]::new('', $secret).Password } else { '' }
                    $authenticated = (& $send ('AT+CGAUTH={0},{1},"{2}","{3}"' -f $cid, $code, $Settings.ApnUser, $password)).Status -eq 'OK'
                }
            }
            else {
                $current = ConvertFrom-AtContextAuthentication -Lines (& $send 'AT+CGAUTH?').Lines | Where-Object Cid -EQ $cid | Select-Object -First 1
                if ($current -and $current.ProtocolCode -ne 0) {
                    $authenticated = (& $send "AT+CGAUTH=$cid,0").Status -eq 'OK'
                }
            }
            if ($authenticated -and (& $send "AT+CGACT=1,$cid").Status -eq 'OK') { $result = 'Done' }
        }
        'ConfigureAdapter' {
            $applied = if ($SimulatedAdapter) {
                @($SimulatedAdapter.Apply($Observation.AdapterPlan))
            }
            else {
                @(Set-ModemAdapterConfiguration -InterfaceIndex $Observation.AdapterState.InterfaceIndex -InterfaceGuid $Observation.AdapterState.InterfaceGuid -Plan $Observation.AdapterPlan -Confirm:$false)
            }
            foreach ($change in $applied) {
                $commands.Add([pscustomobject]@{ Command = $change.Action; Status = $(if ($change.Done) { 'OK' } else { 'Error' }); ErrorCode = $null })
            }
            if (@($applied | Where-Object { -not $_.Done }).Count -eq 0) { $result = 'Done' }
        }
    }
    [pscustomobject]@{ Action = $Action; Result = $result; Commands = [object[]]$commands.ToArray() }
}

function Invoke-ModemConnect {
    <#
    .SYNOPSIS
        Runs one pass of the connect sequence on an open AT channel: observes, then takes the
        missing steps toward online.
    .DESCRIPTION
        Startup reconciliation and connect sequence in one (ARCHITECTURE -> Connection state
        machine): initialize the channel, observe, let Resolve-ConnectionState pick the next
        missing step, run it, observe again - until there is nothing left to do, or a step would
        run a second time in the same pass (it didn't take: the next pass, on the worker's
        cadence, tries again). On a connection that is already up it changes nothing.

        The steps: enter the stored SIM PIN (once, under Resolve-SimPinAction's rules); turn the
        radio on; automatic operator selection; write the network mode and bands the settings
        ask, when the modem's differ (Resolve-NetworkMode: the modem keeps it, so a mode that
        works is never written again for nothing); define the app's context (written only when
        it differs from the settings: it is persistent); deactivate it when it is active without
        an address and differs from the settings; set its authentication and activate it;
        configure the adapter (administrator rights).

        With -SimSettings (Import-SimSetting's), the SIM in use connects with its own APN
        settings: its context is defined and activated as they say.

        Returns State, Action (the step still missing), Reason, Blocked, Dropped,
        SettingsPending (as Resolve-ConnectionState), Steps (the steps run, their commands
        redacted), Observation (the last facts), Written (the network mode written: Command,
        Before - the setting's text as read before it - and Status, the modem's answer; or
        $null) and Sim (Get-ModemObservation's: the SIM in use's fingerprint - an identifier's,
        for the caller alone -, Id and Source; $null when not read). With -LogFolder, the steps
        and the state change go to the redacted log there.
    .EXAMPLE
        $pass = Invoke-ModemConnect -Channel $channel -Settings $settings -AdapterInstanceId $modem.Network.InstanceId -Previous $last.State
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AtChannel] $Channel,

        [Parameter(Mandatory)]
        [object] $Settings,

        [string] $AdapterInstanceId,

        # Development mode: the in-memory adapter of New-SimulatedDevice, configured instead of a
        # real one.
        [object] $SimulatedAdapter,

        [ValidateSet('NoDevice', 'PortOpen', 'Identified', 'SimReady', 'Registered', 'DataActive', 'Online')]
        [string] $Previous,

        [string] $SimPinPath = (Get-AppDataPath -Name 'sim-pin.json'),

        [string] $ApnSecretPath = (Get-AppDataPath -Name 'apn-password.dat'),

        # The settings kept for each SIM, as Get-ModemObservation takes them.
        [object] $SimSettings,

        [string] $LogFolder,

        # How long Initialize-AtChannel waits for each of its commands; their documented worst
        # case by default.
        [int] $InitializeTimeoutMs = 0,

        # The data-path probes' verdict, as Get-ModemObservation takes it.
        [object] $DataPath,

        # What the modem supports of AT+GTACT, and the app's last write of it, as
        # Get-ModemObservation takes them.
        [object] $NetworkModeSupport,

        [object] $NetworkModeLastWrite
    )

    $steps = [System.Collections.Generic.List[object]]::new()
    $written = $null
    $done = [System.Collections.Generic.HashSet[string]]::new()
    # A log that can't be written (a full disk) never stops the pass.
    $log = if ($LogFolder) {
        {
            param($level, $message)
            try {
                Write-AppLog -Folder $LogFolder -Level $level -Message $message -ErrorAction Stop
            }
            catch {
                Write-Verbose "The log can't be written: $($_.Exception.Message)"
            }
        }
    }
    else {
        { }
    }
    $previousState = @{}
    if ($Previous) {
        $previousState['Previous'] = $Previous
    }

    # The worker initializes every channel it opens (ARCHITECTURE -> AT channel).
    $initialized = Invoke-ConnectionStep -Channel $Channel -Action 'Initialize' -InitializeTimeoutMs $InitializeTimeoutMs
    $steps.Add($initialized)
    [void]$done.Add('Initialize')

    while ($true) {
        $observation = Get-ModemObservation -Channel $Channel -Settings $Settings -AdapterInstanceId $AdapterInstanceId -SimulatedAdapter $SimulatedAdapter `
            -SimPinPath $SimPinPath -ApnSecretPath $ApnSecretPath -SimSettings $SimSettings -DataPath $DataPath -NetworkModeSupport $NetworkModeSupport `
            -NetworkModeLastWrite $NetworkModeLastWrite
        if (-not $NetworkModeSupport -and $observation.Facts.NetworkModeSupport) {
            $NetworkModeSupport = $observation.Facts.NetworkModeSupport
        }
        if ($observation.Facts.Sim -and $observation.Facts.Sim.Reason -eq 'PinAccepted') {
            try {
                Set-SimPinAttempt -Attempted $false -Path $SimPinPath -Confirm:$false -ErrorAction Stop
            }
            catch {
                # Still pending: cleared at a later pass.
                Write-Verbose "The accepted PIN couldn't be recorded: $($_.Exception.Message)"
            }
        }
        $decision = Resolve-ConnectionState -Observation $observation.Facts @previousState
        # Opening the port is the worker's, before a pass.
        if ($decision.Action -in 'None', 'OpenPort' -or $done.Contains($decision.Action) -or -not $PSCmdlet.ShouldProcess('the modem', $decision.Action)) {
            break
        }
        [void]$done.Add($decision.Action)
        # The SIM in use's own settings, as the observation found them.
        $step = Invoke-ConnectionStep -Channel $Channel -Action $decision.Action -Observation $observation -Settings $observation.Settings `
            -SimPinPath $SimPinPath -ApnSecretPath $observation.ApnSecretPath -InitializeTimeoutMs $InitializeTimeoutMs -SimulatedAdapter $SimulatedAdapter
        $steps.Add($step)
        if ($step.Action -eq 'ApplyNetworkMode') {
            # A write refused is remembered as one not kept: never written again over the same
            # setting. One that got no answer may have landed.
            $status = @($step.Commands | Select-Object -First 1 | ForEach-Object Status)
            $written = [pscustomobject]@{ Command = $observation.Facts.NetworkMode.Command; Before = $observation.Facts.NetworkModeRead.Text; Status = [string]$status }
            $NetworkModeLastWrite = $written
        }
        $commands = ($step.Commands | ForEach-Object { "$($_.Command) $($_.Status)$(if ($null -ne $_.ErrorCode) { " $($_.ErrorCode)" })" }) -join '; '
        & $log $(if ($step.Result -eq 'Done') { 'Info' } else { 'Warning' }) "$($step.Action): $($step.Result) - $commands"
    }
    if ($decision.State -ne $Previous) {
        $from = if ($Previous) { $Previous } else { '(start)' }
        $why = if ($decision.Reason) { " ($($decision.Reason))" } else { '' }
        & $log $(if ($decision.Dropped) { 'Warning' } else { 'Info' }) "State $from -> $($decision.State)$why"
    }

    [pscustomobject]@{
        State           = $decision.State
        Action          = $decision.Action
        Reason          = $decision.Reason
        Blocked         = $decision.Blocked
        Dropped         = $decision.Dropped
        SettingsPending = $decision.SettingsPending
        Steps           = [object[]]$steps.ToArray()
        Observation     = $observation.Facts
        Written         = $written
        Sim             = $observation.Sim
    }
}

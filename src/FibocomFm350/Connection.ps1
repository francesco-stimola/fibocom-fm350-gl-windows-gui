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
        - PortOpen, Responsive: the AT port is open; the modem answers on it.
        - Sim: Resolve-SimPinAction's decision.
        - Fcc: Resolve-FccLock's diagnosis.
        - RadioOn: +CFUN is 1. OperatorMode: +COPS's mode (2: deregistered by a command).
        - Registered, RegistrationState: from +CEREG / +C5GREG.
        - ContextDefined: the app's context is defined as the settings say. ContextActive,
          ContextAddress, ContextApn: it is active, with this IPv4 address, on this APN (as the
          network reports it). ApnSet: the settings name an APN (empty: the subscription's own).
        - Adapter: 'Present' or 'Absent' (the modem's network adapter). AdapterConfigured: its
          configuration matches the context and the settings. AdapterProblem: why it can't be
          configured from what the modem reports.
        - DataPath: the last data-path probe passed ($null: not probed).

        Returns:
        - State: 'NoDevice', 'PortOpen', 'Identified', 'SimReady', 'Registered', 'DataActive' or
          'Online'.
        - Action: the next step - 'OpenPort', 'Initialize', 'EnterPin', 'RadioOn',
          'AutoRegister', 'DefineContext', 'ActivateContext', 'DeactivateContext',
          'ConfigureAdapter' - or 'None'.
        - Reason: why there is no step to take, or $null.
        - Blocked: $true when what stops the connection is out of the app's reach - no device or
          driver, a SIM waiting for the user, an FCC lock, an APN the user must give: no
          recovery step changes it, so none is escalated (ARCHITECTURE -> Health checks).

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
    $outcome = {
        param($state, $action, $reason, $blocked)
        $settingsPending = (& $fact 'ContextActive') -eq $true -and (& $fact 'ContextDefined') -eq $false
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
        return & $outcome 'NoDevice' 'OpenPort' $null $false
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
    $contextActive = (& $fact 'ContextActive') -eq $true
    if ((& $fact 'ContextDefined') -eq $false -and -not $contextActive) {
        return & $outcome 'SimReady' 'DefineContext' $null $false
    }
    if (-not $registered) {
        $state = & $fact 'RegistrationState'
        return & $outcome 'SimReady' 'None' $(if ($state) { $state } else { 'NotRegistered' }) $false
    }

    if (-not $contextActive) {
        return & $outcome 'Registered' 'ActivateContext' $null $false
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

    if ((& $fact 'Adapter') -ne 'Present') {
        return & $outcome 'DataActive' 'None' 'NoAdapter' $true
    }
    if ((& $fact 'AdapterConfigured') -ne $true) {
        $problem = & $fact 'AdapterProblem'
        if ($problem) {
            return & $outcome 'DataActive' 'None' $problem $false
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
        SIM ready - the radio, the registration, the context definition, and - while not
        registered - the operator selection and the FCC lock; once registered, the context's
        activation and parameters, and the adapter.

        Returns Facts (the observation for Resolve-ConnectionState), and what the steps need:
        Context (the app's context parameters), AdapterState and AdapterPlan. The ICCID is read
        only to match the stored PIN, and kept nowhere.
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

        [string] $SimPinPath = (Get-AppDataPath -Name 'sim-pin.json')
    )

    if ($Channel.State -eq 'Closed') {
        throw [System.InvalidOperationException]::new('The AT channel is closed.')
    }
    $facts = [ordered]@{
        Device = 'Present'; PortOpen = $true; Responsive = $null; Sim = $null; Fcc = $null
        RadioOn = $null; OperatorMode = $null; Registered = $null; RegistrationState = $null
        ContextDefined = $null; ContextActive = $null; ContextAddress = $null; ContextApn = $null; ApnSet = [bool]$Settings.Apn
        Adapter = $null; AdapterConfigured = $null; AdapterProblem = $null; DataPath = $null
    }
    $result = [pscustomobject]@{ Facts = $null; Context = $null; AdapterState = $null; AdapterPlan = $null }
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
    $stored = Get-SimPin -Path $SimPinPath
    $attemptsLeft = $null
    if ($sim.State -eq 'PinRequired' -and $stored) {
        $iccid = ConvertFrom-AtIccid -Lines (& $ask 'AT+ICCID').Lines
        $stored = Get-SimPin -Path $SimPinPath -Iccid $iccid
        $attemptsLeft = Get-SimPinAttemptsLeft -Ask $ask
        if (& $stopped) {
            return & $finish
        }
    }
    $pinForThisSim = if ($stored) { $stored.ForThisSim } else { $null }
    $facts.Sim = Resolve-SimPinAction -SimState $sim.State -PinStored:([bool]$stored) -PinForThisSim $pinForThisSim `
        -PinAttempted:([bool]$stored -and $stored.Attempted) -AttemptsLeft $attemptsLeft
    if ($facts.Sim.Action -ne 'Continue') {
        return & $finish
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

    # The app's data context.
    $definitions = & $ask 'AT+CGDCONT?'
    if (& $stopped) {
        return & $finish
    }
    if ($definitions.Status -eq 'OK') {
        $ours = ConvertFrom-AtContextDefinition -Lines $definitions.Lines | Where-Object Cid -EQ $script:DataContextId | Select-Object -First 1
        # -eq compares text without case: APNs are not case-sensitive.
        $facts.ContextDefined = [bool]$ours -and $ours.PdpType -eq $Settings.PdpType -and $ours.Apn -eq $Settings.Apn
    }
    if (-not $facts.Registered) {
        return & $finish
    }
    $activation = ConvertFrom-AtContextActivation -Lines (& $ask 'AT+CGACT?').Lines | Where-Object Cid -EQ $script:DataContextId | Select-Object -First 1
    $facts.ContextActive = [bool]$activation -and $activation.Active
    if (-not $facts.ContextActive -or (& $stopped)) {
        return & $finish
    }
    $context = ConvertFrom-AtContextParameter -Lines (& $ask "AT+CGCONTRDP=$script:DataContextId").Lines | Where-Object Cid -EQ $script:DataContextId | Select-Object -First 1
    if ($context -and -not $context.IPv4Address) {
        # The FM350 leaves the address out of +CGCONTRDP for a data context; +CGPADDR has it
        # (AT-COMMANDS section 3).
        $address = ConvertFrom-AtContextAddress -Lines (& $ask "AT+CGPADDR=$script:DataContextId").Lines | Where-Object Cid -EQ $script:DataContextId | Select-Object -First 1
        if ($address) {
            $context.IPv4Address = $address.IPv4Address
        }
    }
    if ($context -and @($context.Dns).Count -eq 0) {
        $servers = ConvertFrom-AtDnsServer -Lines (& $ask "AT+GTDNS=$script:DataContextId").Lines | Where-Object Cid -EQ $script:DataContextId | Select-Object -First 1
        if ($servers) {
            $context.Dns = $servers.Dns
        }
    }
    $result.Context = $context
    $facts.ContextAddress = if ($context) { $context.IPv4Address } else { $null }
    $facts.ContextApn = if ($context) { $context.Apn } else { $null }

    # The adapter.
    $adapter = if ($AdapterInstanceId) { Get-ModemAdapterState -InstanceId $AdapterInstanceId } else { $null }
    $facts.Adapter = if ($adapter) { 'Present' } else { 'Absent' }
    if ($adapter) {
        $plan = Resolve-AdapterConfiguration -Context $context -Adapter $adapter -Settings $Settings
        $result.AdapterState = $adapter
        $result.AdapterPlan = $plan
        $facts.AdapterConfigured = $plan.Configured
        $facts.AdapterProblem = $plan.Problem
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
        [int] $InitializeTimeoutMs
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
            if ($stored) {
                # Recorded before sending: an answer that never comes is never followed by a
                # second attempt.
                Set-SimPinAttempt -Attempted $true -Path $SimPinPath -Confirm:$false
                $answer = & $send ('AT+CPIN="{0}"' -f [System.Net.NetworkCredential]::new('', $stored.Pin).Password)
                if ($answer.Status -eq 'OK') {
                    Set-SimPinAttempt -Attempted $false -Path $SimPinPath -Confirm:$false
                    $result = 'Done'
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
                $password = if ($secret) { [System.Net.NetworkCredential]::new('', $secret).Password } else { '' }
                $authenticated = (& $send ('AT+CGAUTH={0},{1},"{2}","{3}"' -f $cid, $code, $Settings.ApnUser, $password)).Status -eq 'OK'
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
            $applied = @(Set-ModemAdapterConfiguration -InterfaceIndex $Observation.AdapterState.InterfaceIndex -Plan $Observation.AdapterPlan -Confirm:$false)
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
        radio on; automatic operator selection; define the app's context (written only when it
        differs from the settings: it is persistent); deactivate it when it is active without an
        address and differs from the settings; set its authentication and activate it; configure
        the adapter (administrator rights).

        Returns State, Action (the step still missing), Reason, Blocked, Dropped,
        SettingsPending (as Resolve-ConnectionState), Steps (the steps run, their commands
        redacted) and Observation (the last facts). With -LogFolder, the steps and the state
        change go to the redacted log there.
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

        [ValidateSet('NoDevice', 'PortOpen', 'Identified', 'SimReady', 'Registered', 'DataActive', 'Online')]
        [string] $Previous,

        [string] $SimPinPath = (Get-AppDataPath -Name 'sim-pin.json'),

        [string] $ApnSecretPath = (Get-AppDataPath -Name 'apn-password.dat'),

        [string] $LogFolder,

        # How long Initialize-AtChannel waits for each of its commands; their documented worst
        # case by default.
        [int] $InitializeTimeoutMs = 0
    )

    $steps = [System.Collections.Generic.List[object]]::new()
    $done = [System.Collections.Generic.HashSet[string]]::new()
    $log = if ($LogFolder) {
        { param($level, $message) Write-AppLog -Folder $LogFolder -Level $level -Message $message }
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
        $observation = Get-ModemObservation -Channel $Channel -Settings $Settings -AdapterInstanceId $AdapterInstanceId -SimPinPath $SimPinPath
        if ($observation.Facts.Sim -and $observation.Facts.Sim.Reason -eq 'PinAccepted') {
            Set-SimPinAttempt -Attempted $false -Path $SimPinPath -Confirm:$false
        }
        $decision = Resolve-ConnectionState -Observation $observation.Facts @previousState
        # Opening the port is the worker's, before a pass.
        if ($decision.Action -in 'None', 'OpenPort' -or $done.Contains($decision.Action) -or -not $PSCmdlet.ShouldProcess('the modem', $decision.Action)) {
            break
        }
        [void]$done.Add($decision.Action)
        $step = Invoke-ConnectionStep -Channel $Channel -Action $decision.Action -Observation $observation -Settings $Settings `
            -SimPinPath $SimPinPath -ApnSecretPath $ApnSecretPath -InitializeTimeoutMs $InitializeTimeoutMs
        $steps.Add($step)
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
    }
}

# The modem's USB functions as Windows sees them: which one is the AT port, which one the network
# adapter, which driver each has, and which the app puts on WinUSB. Facts and sources:
# docs/AT-COMMANDS.md sections 1 and 1.2; design: docs/ARCHITECTURE.md -> USB functions.

# The "MD AT" interface of each USB composition, by product ID.
$script:AtPortInterfaces = @{ '7126' = 4; '7127' = 6 }

# The RNDIS network function, in both compositions.
$script:NetworkInterface = 0

# What each function of a composition is, by interface: the names MediaTek's INF gives their COM
# ports (AT-COMMANDS section 1), as codes the window turns into words.
$script:FunctionNames = @{
    '7126' = @{ 4 = 'MdAt' }
    '7127' = @{ 2 = 'ApLog'; 3 = 'ApGnss'; 4 = 'ApMeta'; 6 = 'MdAt'; 7 = 'MdMeta'; 8 = 'Npt'; 9 = 'Debug' }
}

# The vendor class of the modem's serial functions (ff/00/00): those the app puts on WinUSB.
$script:VendorFunctionId = 'USB\Class_ff&SubClass_00&Prot_00'

# Windows problem codes that mean "no driver": 1 not configured, 28 drivers not installed.
$script:NoDriverProblemCodes = @(1, 28)

# CM_PROB_DISABLED: the user disabled the device. The app leaves it as it is.
$script:DisabledProblemCode = 22

function Get-ModemPnpRecord {
    <#
    .SYNOPSIS
        Reads the PnP records of the present MediaTek USB devices, as Resolve-ModemUsbDevice
        takes them.
    .DESCRIPTION
        The thin I/O around Resolve-ModemUsbDevice: Get-PnpDevice for the instance IDs under
        USB\VID_0E8D, then for each device one Get-PnpDeviceProperty call given the device object
        (about 50 ms; given its instance ID, about a second), and its registry parameters (Device
        Parameters: PortName and DeviceInterfaceGUIDs, the same in every Windows language). One
        call per device: given several devices at once, Get-PnpDeviceProperty now and then labels
        one device's properties with another's instance ID. Reads only; needs no administrator
        rights and never opens a port.

        Returns one record per present device: InstanceId, Present, ProblemCode, Service ('' when
        the device has none; $null when it couldn't be read), Parent, CompatibleIds, PortName (its
        COM port, $null when it has none) and InterfaceGuids (its DeviceInterfaceGUIDs, $null
        when none) - ParametersRead $false when those couldn't be read -, and its driver: DriverInfPath (the name its package has in the driver store),
        DriverVersion, DriverProvider - $null without one.
    .EXAMPLE
        Resolve-ModemUsbDevice -Device @(Get-ModemPnpRecord)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $devices = @(Get-PnpDevice -InstanceId 'USB\VID_0E8D*' -ErrorAction SilentlyContinue | Where-Object Present)
    if ($devices.Count -eq 0) {
        return
    }
    $keys = 'DEVPKEY_Device_ProblemCode', 'DEVPKEY_Device_Service', 'DEVPKEY_Device_Parent', 'DEVPKEY_Device_CompatibleIds',
    'DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_DriverProvider'
    foreach ($device in $devices) {
        $own = @(Get-PnpDeviceProperty -InputObject $device -KeyName $keys -ErrorAction SilentlyContinue |
                Where-Object InstanceId -EQ $device.InstanceId)
        # A key the device has no value for comes back with no Data at all: no service, no driver.
        $value = {
            param($key)
            $property = $own | Where-Object KeyName -EQ $key | Select-Object -First 1
            if ($property -and $property.PSObject.Properties['Data']) { $property.Data }
        }
        $unread = $null
        $parameters = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)\Device Parameters" -ErrorAction SilentlyContinue -ErrorVariable unread
        # A key that isn't there holds nothing; any other failure leaves the parameters unknown.
        $parametersRead = @($unread | Where-Object { $_.Exception -isnot [System.Management.Automation.ItemNotFoundException] }).Count -eq 0
        $parameter = { param($name) if ($parameters -and $parameters.PSObject.Properties[$name]) { $parameters.$name } }
        $serviceRead = @($own | Where-Object KeyName -EQ 'DEVPKEY_Device_Service').Count -gt 0
        $service = & $value 'DEVPKEY_Device_Service'
        $guids = & $parameter 'DeviceInterfaceGUIDs'
        [pscustomobject]@{
            InstanceId     = [string]$device.InstanceId
            Present        = $true
            ProblemCode    = [int]((& $value 'DEVPKEY_Device_ProblemCode') -as [int])
            # '' when read and empty - no driver -, $null when it couldn't be read.
            Service        = if (-not $serviceRead) { $null } elseif ($null -eq $service) { '' } else { [string]$service }
            Parent         = & $value 'DEVPKEY_Device_Parent'
            CompatibleIds  = [string[]]@(& $value 'DEVPKEY_Device_CompatibleIds')
            PortName       = if (& $parameter 'PortName') { [string](& $parameter 'PortName') } else { $null }
            InterfaceGuids = if ($guids) { [string[]]@($guids) } else { $null }
            ParametersRead = $parametersRead
            DriverInfPath  = & $value 'DEVPKEY_Device_DriverInfPath'
            DriverVersion  = & $value 'DEVPKEY_Device_DriverVersion'
            DriverProvider = & $value 'DEVPKEY_Device_DriverProvider'
        }
    }
}

function Resolve-ModemUsbDevice {
    <#
    .SYNOPSIS
        Groups the PnP devices of FM350 modems by modem, and tells the AT port and the network
        adapter apart, each with its driver state.
    .DESCRIPTION
        Takes device records as read from PnP, each with InstanceId, Present, ProblemCode,
        Service and Parent, plus, when read, CompatibleIds, PortName (the COM port of a function
        on MediaTek's driver), InterfaceGuids (its DeviceInterfaceGUIDs) and DriverInfPath,
        DriverVersion and DriverProvider; other properties are ignored. Only present USB
        functions of the FM350 compositions (USB\VID_0E8D&PID_7126 and 7127, interface MI_xx)
        count: devices left over from an earlier plug-in, the composite device itself and other
        MediaTek devices are skipped. A modem is the composite device its functions hang from.

        Returns one object per modem: InstanceId (of the composite device), ProductId, AtPort,
        Network and Functions (every function, by interface number). Each function has
        InstanceId, Interface, Role ('AtPort', 'Network' or 'Other'), Name (what it is: 'MdAt',
        'ApGnss'... - $null when the composition's names are not known), Vendor ($true for the
        serial functions of vendor class ff/00/00 and the AT port: those the app puts on WinUSB;
        never the network function), WinUsb ($true when its driver is Windows' WinUSB), Read ($false
        when its service or its registry parameters couldn't be read: what it is on is unknown), State,
        ProblemCode, Service, PortName, InterfaceGuids and Driver (InfPath, Version, Provider).
        State is 'Working' (no problem code, and a service or none read), 'NoDriver' (problem
        code 1 or 28, or no problem code and a service read as '': a driver just uninstalled) or
        'Problem' (any other problem code: disabled, failed to start...). AtPort or Network is
        $null when that function is not present; PortName, InterfaceGuids and Driver are $null
        when the record has none.
    .EXAMPLE
        Resolve-ModemUsbDevice -Device $records | Where-Object { -not $_.AtPort.WinUsb }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Device
    )

    $functions = foreach ($record in $Device) {
        if ($record.Present -and $record.InstanceId -match '^USB\\VID_0E8D&PID_(7126|7127)&MI_([0-9A-F]{2})\\') {
            $productId = $Matches[1]
            $interface = [Convert]::ToInt32($Matches[2], 16)
            $role = if ($interface -eq $script:AtPortInterfaces[$productId]) {
                'AtPort'
            }
            elseif ($interface -eq $script:NetworkInterface) {
                'Network'
            }
            else {
                'Other'
            }
            $property = { param($name) if ($record.PSObject.Properties[$name]) { $record.$name } }
            $problemCode = [int]$record.ProblemCode
            $service = & $property 'Service'
            $state = if ($problemCode -in $script:NoDriverProblemCodes) {
                'NoDriver'
            }
            elseif ($problemCode -ne 0) {
                'Problem'
            }
            elseif ($null -ne $service -and -not $service) {
                # Read, and none: a function whose driver was just uninstalled has no problem
                # code yet (AT-COMMANDS section 1.1).
                'NoDriver'
            }
            else {
                # A service, or one that couldn't be read: opening the port tells.
                'Working'
            }
            # Known enough to change its driver: a function without one by its problem code, or one whose
            # service and registry parameters were read. One that couldn't be read is left to the next
            # look - never taken for a function on another driver.
            $parametersRead = -not $record.PSObject.Properties['ParametersRead'] -or [bool]$record.ParametersRead
            $read = $problemCode -in $script:NoDriverProblemCodes -or ($null -ne $service -and $parametersRead)
            $compatible = @(& $property 'CompatibleIds')
            $vendor = $role -eq 'AtPort' -or ($role -ne 'Network' -and @($compatible | Where-Object { [string]::Equals([string]$_, $script:VendorFunctionId, 'OrdinalIgnoreCase') }).Count -gt 0)
            $guids = @(& $property 'InterfaceGuids' | Where-Object { $_ })
            $driver = { param($name) if ($record.PSObject.Properties[$name] -and $record.$name) { [string]$record.$name } }
            [pscustomobject]@{
                Parent         = [string]$record.Parent
                ProductId      = $productId
                InstanceId     = [string]$record.InstanceId
                Interface      = $interface
                Role           = $role
                Name           = $script:FunctionNames[$productId][$interface]
                Vendor         = $vendor
                WinUsb         = [string]::Equals([string]$service, 'WINUSB', 'OrdinalIgnoreCase')
                Read           = $read
                State          = $state
                ProblemCode    = $problemCode
                Service        = if ($service) { [string]$service } else { $null }
                PortName       = if (& $property 'PortName') { [string](& $property 'PortName') } else { $null }
                InterfaceGuids = if ($guids.Count -gt 0) { [string[]]$guids } else { $null }
                Driver         = if (& $driver 'DriverInfPath') {
                    [pscustomobject]@{ InfPath = & $driver 'DriverInfPath'; Version = & $driver 'DriverVersion'; Provider = & $driver 'DriverProvider' }
                }
                else {
                    $null
                }
            }
        }
    }

    foreach ($group in @(@($functions) | Group-Object -Property Parent)) {
        $members = @($group.Group | Sort-Object -Property Interface)
        [pscustomobject]@{
            InstanceId = $members[0].Parent
            ProductId  = $members[0].ProductId
            AtPort     = $members | Where-Object Role -EQ 'AtPort' | Select-Object -First 1 -ExcludeProperty Parent, ProductId
            Network    = $members | Where-Object Role -EQ 'Network' | Select-Object -First 1 -ExcludeProperty Parent, ProductId
            Functions  = @($members | Select-Object -ExcludeProperty Parent, ProductId)
        }
    }
}

function Test-UsbFunctionBound {
    # Whether a function is on WinUSB as the app needs it: working on WinUSB, and the AT port with
    # the app's interface class besides (Resolve-ModemPresence). An AT port that couldn't be read is
    # left to the opening of its interface, which tells, as a COM port's opening did.
    param([object] $Function, [string] $InterfaceGuid)

    if ($Function.Role -eq 'AtPort' -and $Function.PSObject.Properties['Read'] -and -not $Function.Read -and $Function.State -eq 'Working') {
        return $true
    }
    if (-not $Function.WinUsb -or $Function.State -ne 'Working') {
        return $false
    }
    if ($Function.Role -ne 'AtPort') {
        return $true
    }
    @($Function.InterfaceGuids | Where-Object { [string]::Equals(([string]$_).Trim(), $InterfaceGuid, 'OrdinalIgnoreCase') }).Count -gt 0
}

function Resolve-ModemPresence {
    <#
    .SYNOPSIS
        Tells whether there is a modem whose AT port can be opened on WinUSB, from
        Resolve-ModemUsbDevice's modems.
    .DESCRIPTION
        A pure decision, made again every time the worker looks for the modem: after a
        re-enumeration the modem can come back as a new device instance (AT-COMMANDS section 1),
        so nothing is remembered from an earlier look.

        Returns Device for the modem chosen:
        - 'Present': its AT port works on WinUSB with -InterfaceGuid, the app's interface class - or
          couldn't be read: opening its interface tells;
        - 'Unbound': its AT port is on another driver, on none, or on WinUSB without the app's
          interface class: the worker puts it on WinUSB (Resolve-ModemBinding);
        - 'Problem': its AT port is disabled by the user, or has a problem on WinUSB;
        - 'Absent': no modem with an AT port.
        With InstanceId (its composite USB device), AtInstanceId (its AT port), AdapterInstanceId
        (its network function), ProductId, Functions (every function of it, as
        Resolve-ModemUsbDevice gives them) - each $null without a modem - and Modems, how many
        there are. The modem chosen is the first by instance ID whose AT port works on WinUSB,
        else the first with an AT port: the same at every look. Driver: its AT port's (InfPath,
        Version, Provider), $null without one.
    .EXAMPLE
        Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device @(Get-ModemPnpRecord))
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Modem,

        [string] $InterfaceGuid = $script:AppInterfaceGuid
    )

    $atPorts = @($Modem | Where-Object { $_.AtPort } | Sort-Object -Property InstanceId)
    $usable = @($atPorts | Where-Object { Test-UsbFunctionBound -Function $_.AtPort -InterfaceGuid $InterfaceGuid })
    $chosen = if ($usable.Count -gt 0) { $usable[0] } elseif ($atPorts.Count -gt 0) { $atPorts[0] } else { $null }
    $device = if (-not $chosen) {
        'Absent'
    }
    elseif ($usable.Count -gt 0) {
        'Present'
    }
    elseif ($chosen.AtPort.State -eq 'Problem' -and ($chosen.AtPort.WinUsb -or $chosen.AtPort.ProblemCode -eq $script:DisabledProblemCode)) {
        'Problem'
    }
    else {
        'Unbound'
    }
    [pscustomobject]@{
        Device            = $device
        InstanceId        = if ($chosen) { $chosen.InstanceId } else { $null }
        AtInstanceId      = if ($chosen) { $chosen.AtPort.InstanceId } else { $null }
        AdapterInstanceId = if ($chosen -and $chosen.Network) { $chosen.Network.InstanceId } else { $null }
        Modems            = $Modem.Count
        ProductId         = if ($chosen -and $chosen.PSObject.Properties['ProductId']) { $chosen.ProductId } else { $null }
        Functions         = if ($chosen -and $chosen.PSObject.Properties['Functions']) { @($chosen.Functions) } else { $null }
        Driver            = if ($chosen -and $chosen.AtPort.PSObject.Properties['Driver']) { $chosen.AtPort.Driver } else { $null }
    }
}

function Resolve-ModemBinding {
    <#
    .SYNOPSIS
        Decides which of the modem's functions the app puts on WinUSB now.
    .DESCRIPTION
        A pure decision over the functions of the modem chosen (Resolve-ModemPresence's
        Functions; ARCHITECTURE -> USB functions). Its vendor functions - the AT port and every
        serial function of vendor class ff/00/00, GNSS, log, META, NPT, debug - go on WinUSB
        when they are on another driver or none, so that none stands as an unknown device; the
        AT port also when it is on WinUSB without -InterfaceGuid, the app's interface class.
        Never the network function, nor a function that is not a vendor one (ADB).

        Left as they are: a function that couldn't be read - what it is on is unknown, and it is
        looked at again next time -; one disabled by the user (problem code 22); one with a problem
        on WinUSB, which another installation wouldn't mend; and one whose installation failed
        already (-Failed, their instance IDs: tried once per instance - again at the app's next
        start, at a new instance, or when the user asks to check now; decided 2026-10-04).

        Returns Bind - the functions to put on WinUSB, the AT port first, each with InstanceId,
        Interface, Role, Name, PortName and InterfaceGuids (its COM port and its device interface
        classes, to be found free first) and Why
        ('NoDriver', 'OtherDriver' or 'NoInterface') - and Left: the others that aren't on WinUSB
        as the app needs, each with InstanceId, Interface, Role, Name and Why ('Unread', 'Disabled',
        'Problem', 'Failed').
    .EXAMPLE
        Resolve-ModemBinding -Function $presence.Functions -Failed @($worker.BindFailed)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Function,

        [string] $InterfaceGuid = $script:AppInterfaceGuid,

        [AllowEmptyCollection()]
        [string[]] $Failed = @()
    )

    $bind = [System.Collections.Generic.List[object]]::new()
    $left = [System.Collections.Generic.List[object]]::new()
    $ordered = @($Function | Where-Object { $_ } | Sort-Object -Property @{ Expression = { $_.Role -ne 'AtPort' } }, Interface)
    foreach ($item in $ordered) {
        if (-not $item.Vendor -or $item.Role -eq 'Network') {
            continue
        }
        $entry = [ordered]@{ InstanceId = $item.InstanceId; Interface = $item.Interface; Role = $item.Role; Name = $item.Name }
        if ($item.PSObject.Properties['Read'] -and -not $item.Read) {
            $entry['Why'] = 'Unread'
            $left.Add([pscustomobject]$entry)
            continue
        }
        if (Test-UsbFunctionBound -Function $item -InterfaceGuid $InterfaceGuid) {
            continue
        }
        $leftWhy = if ($item.State -eq 'Problem' -and $item.ProblemCode -eq $script:DisabledProblemCode) {
            'Disabled'
        }
        elseif ($item.State -eq 'Problem' -and $item.WinUsb) {
            'Problem'
        }
        elseif ($item.InstanceId -in $Failed) {
            'Failed'
        }
        if ($leftWhy) {
            $entry['Why'] = $leftWhy
            $left.Add([pscustomobject]$entry)
            continue
        }
        $entry['PortName'] = $item.PortName
        $entry['InterfaceGuids'] = $item.InterfaceGuids
        $entry['Why'] = if ($item.WinUsb) { 'NoInterface' } elseif ($item.State -eq 'NoDriver') { 'NoDriver' } else { 'OtherDriver' }
        $bind.Add([pscustomobject]$entry)
    }
    [pscustomobject]@{ Bind = [object[]]$bind.ToArray(); Left = [object[]]$left.ToArray() }
}

function Resolve-ModemRestore {
    <#
    .SYNOPSIS
        Decides which of the modems' functions go back to the driver Windows ranks best: the way back
        from WinUSB, when the app is uninstalled.
    .DESCRIPTION
        A pure decision over Resolve-ModemUsbDevice's modems - every FM350 present, not only the one
        the app uses: their vendor functions on WinUSB (ARCHITECTURE -> USB functions and WinUSB),
        each read whole. Never the network function, nor a function that is not a vendor one (ADB,
        which Windows puts on WinUSB itself), nor one that couldn't be read.

        Returns the functions, the AT ports first, each with InstanceId, Interface, Role, Name and
        InterfaceGuids (to look for a program holding it first).
    .EXAMPLE
        Resolve-ModemRestore -Modem @(Resolve-ModemUsbDevice -Device @(Get-ModemPnpRecord))
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Modem
    )

    $functions = foreach ($item in @($Modem | Where-Object { $_ } | ForEach-Object { $_.Functions })) {
        if (-not $item -or -not $item.Vendor -or $item.Role -eq 'Network' -or -not $item.WinUsb) {
            continue
        }
        if ($item.PSObject.Properties['Read'] -and -not $item.Read) {
            continue
        }
        $item
    }
    foreach ($item in @($functions | Sort-Object -Property @{ Expression = { $_.Role -ne 'AtPort' } }, InstanceId)) {
        [pscustomobject]@{ InstanceId = $item.InstanceId; Interface = $item.Interface; Role = $item.Role; Name = $item.Name; InterfaceGuids = $item.InterfaceGuids }
    }
}
function Restart-ModemUsbDevice {
    <#
    .SYNOPSIS
        Restarts the modem's USB device: Windows removes it and starts it again, every function
        with it.
    .DESCRIPTION
        The recovery step R6, for an AT port that stopped answering while the modem is still on
        USB. Runs pnputil /restart-device on the modem's composite device - found by PnP, never
        remembered: its instance ID changes with the USB port. Only an FM350 composite device is
        accepted. Needs administrator rights; the AT port must be closed first, or Windows may
        postpone the restart to the next reboot. pnputil is run from the system folder, never
        found through PATH: the app runs elevated (ARCHITECTURE -> Invariants).

        Returns Done ($true when pnputil reports success) and ExitCode (3010: the restart waits
        for a reboot; $null when pnputil didn't end within -TimeoutMs and was stopped).
    .EXAMPLE
        Restart-ModemUsbDevice -InstanceId (Resolve-ModemPresence -Modem $modems).InstanceId
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^USB\\VID_0E8D&PID_712[67]\\[^\\]+$')]
        [string] $InstanceId,

        [ValidateRange(1000, 120000)]
        [int] $TimeoutMs = 30000
    )

    if (-not $PSCmdlet.ShouldProcess("USB device $InstanceId", 'Restart')) {
        return
    }
    $exitCode = Invoke-Pnputil -Argument '/restart-device', $InstanceId -TimeoutMs $TimeoutMs
    [pscustomobject]@{ Done = $exitCode -eq 0; ExitCode = $exitCode }
}

function Invoke-Pnputil {
    # Runs pnputil with -Argument and returns its exit code; $null when it didn't end within
    # -TimeoutMs and was stopped. pnputil is run from the system folder, never found through PATH:
    # the app runs elevated (ARCHITECTURE -> Invariants). Its text is localized, so only the exit
    # code is read; the text is drained, so that it never fills the pipe. While it waits, -Beat
    # runs about once a second: the worker's heartbeat.
    param([string[]] $Argument, [int] $TimeoutMs, [scriptblock] $Beat)

    $start = [System.Diagnostics.ProcessStartInfo]::new((Join-Path -Path ([Environment]::SystemDirectory) -ChildPath 'pnputil.exe'))
    foreach ($item in $Argument) {
        $start.ArgumentList.Add($item)
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        [void]$process.StandardOutput.ReadToEndAsync()
        $deadline = [Environment]::TickCount64 + $TimeoutMs
        while (-not $process.WaitForExit([int][Math]::Max(0, [Math]::Min(1000, $deadline - [Environment]::TickCount64)))) {
            if ([Environment]::TickCount64 -ge $deadline) {
                $process.Kill()
                return $null
            }
            if ($Beat) {
                & $Beat
            }
        }
        $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

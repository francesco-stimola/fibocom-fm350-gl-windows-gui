# The modem's USB functions as Windows sees them: which one is the AT port, which one the network
# adapter, and whether each has its driver. Facts and sources: docs/AT-COMMANDS.md section 1;
# design: docs/ARCHITECTURE.md -> Drivers.

# The "MD AT" interface of each USB composition, by product ID.
$script:AtPortInterfaces = @{ '7126' = 4; '7127' = 6 }

# The RNDIS network function, in both compositions.
$script:NetworkInterface = 0

# Windows problem codes that mean "no driver": 1 not configured, 28 drivers not installed.
$script:NoDriverProblemCodes = @(1, 28)

function Get-ModemPnpRecord {
    <#
    .SYNOPSIS
        Reads the PnP records of the present MediaTek USB devices, as Resolve-ModemUsbDevice
        takes them.
    .DESCRIPTION
        The thin I/O around Resolve-ModemUsbDevice: Get-PnpDevice for the instance IDs under
        USB\VID_0E8D, then for each device one Get-PnpDeviceProperty call given the device object
        (about 50 ms; given its instance ID, about a second), and its COM port name from its
        registry parameters (Device Parameters\PortName, the same in every Windows language).
        One call per device: given several devices at once, Get-PnpDeviceProperty now and then
        labels one device's properties with another's instance ID. Reads only; needs no
        administrator rights and never opens a port.

        Returns one record per present device: InstanceId, Present, ProblemCode, Service ('' when
        the device has none; $null when it couldn't be read), Parent, PortName ($null when the
        device has none), and its driver: DriverInfPath (the name its package has in the driver
        store), DriverVersion, DriverProvider - $null without one.
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
    $keys = 'DEVPKEY_Device_ProblemCode', 'DEVPKEY_Device_Service', 'DEVPKEY_Device_Parent',
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
        $parameters = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)\Device Parameters" -ErrorAction SilentlyContinue
        $serviceRead = @($own | Where-Object KeyName -EQ 'DEVPKEY_Device_Service').Count -gt 0
        $service = & $value 'DEVPKEY_Device_Service'
        [pscustomobject]@{
            InstanceId     = [string]$device.InstanceId
            Present        = $true
            ProblemCode    = [int]((& $value 'DEVPKEY_Device_ProblemCode') -as [int])
            # '' when read and empty - no driver -, $null when it couldn't be read.
            Service        = if (-not $serviceRead) { $null } elseif ($null -eq $service) { '' } else { [string]$service }
            Parent         = & $value 'DEVPKEY_Device_Parent'
            PortName       = if ($parameters -and $parameters.PSObject.Properties['PortName']) { [string]$parameters.PortName } else { $null }
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
        Service and Parent, plus PortName (the COM port, from the device's registry parameters)
        for a serial port and DriverInfPath, DriverVersion and DriverProvider for a device with a
        driver; other properties are ignored. Only present USB functions of the FM350
        compositions (USB\VID_0E8D&PID_7126 and 7127, interface MI_xx) count: devices left over
        from an earlier plug-in, the composite device itself and other MediaTek devices are
        skipped. A modem is the composite device its functions hang from.

        Returns one object per modem: InstanceId (of the composite device), ProductId, AtPort,
        Network and Functions (every function, by interface number). Each function has
        InstanceId, Interface, Role ('AtPort', 'Network' or 'Other'), State, ProblemCode, Service,
        PortName and Driver (InfPath, Version, Provider). State is 'Working' (no problem code,
        and a service or none read), 'NoDriver' (problem code 1 or 28, or no problem code and a
        service read as '': a driver just uninstalled) or 'Problem' (any other problem code:
        disabled, failed to start...). AtPort or Network is $null when that function is not
        present; PortName and Driver are $null when the record has none.
    .EXAMPLE
        Resolve-ModemUsbDevice -Device $records | Where-Object { $_.AtPort.State -eq 'NoDriver' }
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
            $problemCode = [int]$record.ProblemCode
            $service = if ($record.PSObject.Properties['Service']) { $record.Service } else { $null }
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
            $driver = { param($name) if ($record.PSObject.Properties[$name] -and $record.$name) { [string]$record.$name } }
            [pscustomobject]@{
                Parent      = [string]$record.Parent
                ProductId   = $productId
                InstanceId  = [string]$record.InstanceId
                Interface   = $interface
                Role        = $role
                State       = $state
                ProblemCode = $problemCode
                Service     = if ($record.Service) { [string]$record.Service } else { $null }
                PortName    = if ($record.PSObject.Properties['PortName'] -and $record.PortName) { [string]$record.PortName } else { $null }
                Driver      = if (& $driver 'DriverInfPath') {
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

function Resolve-ModemPresence {
    <#
    .SYNOPSIS
        Tells whether there is a modem whose AT port can be opened, from Resolve-ModemUsbDevice's
        modems.
    .DESCRIPTION
        A pure decision, made again every time the worker looks for the modem: after a
        re-enumeration the modem can come back as a new device instance under other COM numbers
        (AT-COMMANDS section 1), so nothing is remembered from an earlier look.

        Returns Device - 'Present' (a modem whose AT port works and has a COM port), else
        'NoDriver' (an AT port without its driver), else 'Problem' (an AT port with another
        problem, or with no COM port), else 'Absent' - with InstanceId (its composite USB
        device), PortName and AdapterInstanceId (its network function, $null when absent) of the
        modem chosen, and Modems, how many there are.
        With several usable modems the first by instance ID is chosen, so the choice is the same
        at every look. ProductId and Driver (InfPath, Version, Provider: its AT port's driver, $null
        without one) are the chosen modem's, else those of the first modem with an AT port.
    .EXAMPLE
        Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device @(Get-ModemPnpRecord))
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Modem
    )

    $atPorts = @($Modem | Where-Object { $_.AtPort })
    $usable = @($atPorts | Where-Object { $_.AtPort.State -eq 'Working' -and $_.AtPort.PortName } | Sort-Object -Property InstanceId)
    $device = if ($usable.Count -gt 0) {
        'Present'
    }
    elseif (@($atPorts | Where-Object { $_.AtPort.State -eq 'NoDriver' }).Count -gt 0) {
        'NoDriver'
    }
    elseif ($atPorts.Count -gt 0) {
        'Problem'
    }
    else {
        'Absent'
    }
    $chosen = if ($usable.Count -gt 0) { $usable[0] } else { $null }
    $shown = if ($chosen) { $chosen } else { $atPorts | Sort-Object -Property InstanceId | Select-Object -First 1 }
    [pscustomobject]@{
        Device            = $device
        InstanceId        = if ($chosen) { $chosen.InstanceId } else { $null }
        PortName          = if ($chosen) { $chosen.AtPort.PortName } else { $null }
        AdapterInstanceId = if ($chosen -and $chosen.Network) { $chosen.Network.InstanceId } else { $null }
        Modems            = $Modem.Count
        ProductId         = if ($shown -and $shown.PSObject.Properties['ProductId']) { $shown.ProductId } else { $null }
        Driver            = if ($shown -and $shown.AtPort.PSObject.Properties['Driver']) { $shown.AtPort.Driver } else { $null }
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

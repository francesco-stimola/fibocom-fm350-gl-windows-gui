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

        Returns one record per present device: InstanceId, Present, ProblemCode, Service,
        Parent and PortName ($null when the device has none).
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
    $keys = 'DEVPKEY_Device_ProblemCode', 'DEVPKEY_Device_Service', 'DEVPKEY_Device_Parent'
    foreach ($device in $devices) {
        $own = @(Get-PnpDeviceProperty -InputObject $device -KeyName $keys -ErrorAction SilentlyContinue |
                Where-Object InstanceId -EQ $device.InstanceId)
        $value = {
            param($key)
            $property = $own | Where-Object KeyName -EQ $key | Select-Object -First 1
            if ($property) { $property.Data }
        }
        $parameters = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)\Device Parameters" -ErrorAction SilentlyContinue
        [pscustomobject]@{
            InstanceId  = [string]$device.InstanceId
            Present     = $true
            ProblemCode = [int]((& $value 'DEVPKEY_Device_ProblemCode') -as [int])
            Service     = & $value 'DEVPKEY_Device_Service'
            Parent      = & $value 'DEVPKEY_Device_Parent'
            PortName    = if ($parameters -and $parameters.PSObject.Properties['PortName']) { [string]$parameters.PortName } else { $null }
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
        for a serial port; other properties are ignored. Only present USB functions of the FM350
        compositions (USB\VID_0E8D&PID_7126 and 7127, interface MI_xx) count: devices left over
        from an earlier plug-in, the composite device itself and other MediaTek devices are
        skipped. A modem is the composite device its functions hang from.

        Returns one object per modem: InstanceId (of the composite device), ProductId, AtPort,
        Network and Functions (every function, by interface number). Each function has
        InstanceId, Interface, Role ('AtPort', 'Network' or 'Other'), State, ProblemCode, Service
        and PortName. State is 'Working', 'NoDriver' (problem code 1 or 28) or 'Problem' (any
        other problem code: disabled, failed to start...). AtPort or Network is $null when that
        function is not present; PortName is $null when the record has none.
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
            $state = if ($problemCode -eq 0) {
                'Working'
            }
            elseif ($problemCode -in $script:NoDriverProblemCodes) {
                'NoDriver'
            }
            else {
                'Problem'
            }
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
        at every look.
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
    [pscustomobject]@{
        Device            = $device
        InstanceId        = if ($chosen) { $chosen.InstanceId } else { $null }
        PortName          = if ($chosen) { $chosen.AtPort.PortName } else { $null }
        AdapterInstanceId = if ($chosen -and $chosen.Network) { $chosen.Network.InstanceId } else { $null }
        Modems            = $Modem.Count
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
    $start = [System.Diagnostics.ProcessStartInfo]::new((Join-Path -Path ([Environment]::SystemDirectory) -ChildPath 'pnputil.exe'))
    $start.ArgumentList.Add('/restart-device')
    $start.ArgumentList.Add($InstanceId)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    # Its text is localized: only the exit code is read. Drained, so that it never fills the pipe.
    $start.RedirectStandardOutput = $true
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        [void]$process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            $process.Kill()
            return [pscustomobject]@{ Done = $false; ExitCode = $null }
        }
        [pscustomobject]@{ Done = $process.ExitCode -eq 0; ExitCode = $process.ExitCode }
    }
    finally {
        $process.Dispose()
    }
}

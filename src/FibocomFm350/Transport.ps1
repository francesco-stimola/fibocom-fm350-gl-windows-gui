# The WinUSB transport: carries text between the AT channel and the modem's AT function, on
# Windows' own WinUSB driver, through its two bulk pipes. Facts and sources: docs/AT-COMMANDS.md
# sections 1.2 and 2.
#
# A transport is any object with this shape (the simulated modem has it too):
#   [string] PortName      a name for the log and the window - never a COM port's
#   [bool]   Lost          set once the port is gone: device unplugged, modem reset, driver
#                          restarted. A lost transport never touches the port again.
#   [void]   Write([string] $text)
#   [string] Read([int] $timeoutMs)   text received within the timeout, or ''
#   [void]   Close()       releases the port; safe to repeat, and after the port is lost
#
# [NoRunspaceAffinity()]: the app's worker runspace owns the port, so methods must run in whichever
# runspace calls them. For the same reason the class calls no module function.

[NoRunspaceAffinity()]
class WinUsbAtTransport {
    [string] $PortName = 'WinUSB'
    [bool] $Lost = $false
    # Why the port was declared lost, for the log.
    [string] $LostReason

    # The interface, opened through WinUSB (FibocomFm350.WinUsbInterface, or a stand-in in the
    # tests): Read, Write, SetTimeout, Dispose.
    hidden [object] $Usb
    hidden [byte] $InPipe
    hidden [byte] $OutPipe
    # One packet at a time: a full packet completes a read as a short one does, so a response
    # whose length is a multiple of the packet size never waits for a zero-length packet
    # (AT-COMMANDS section 1.2).
    hidden [byte[]] $ReadBuffer
    # The read timeout last set on the IN pipe, in ms.
    hidden [int] $ReadTimeout = -1

    WinUsbAtTransport([object] $usb, [byte] $inPipe, [byte] $outPipe, [int] $packetSize) {
        $this.Usb = $usb
        $this.InPipe = $inPipe
        $this.OutPipe = $outPipe
        $this.ReadBuffer = [byte[]]::new($packetSize)
    }

    [void] Write([string] $text) {
        if ($this.Lost -or -not $this.Usb) {
            return
        }
        $bytes = [System.Text.Encoding]::Latin1.GetBytes($text)
        $sent = 0
        while ($sent -lt $bytes.Length) {
            $transfer = $this.Usb.Write($this.OutPipe, $bytes, $sent, $bytes.Length - $sent)
            # ERROR_SEM_TIMEOUT (121): the transfer's time ran out. Any other error: the port is gone.
            if ($transfer.Error -eq 121) {
                # The port is there but the modem isn't draining it (hung): not a lost port. The
                # command then times out without an echo, which is how a hung modem shows up.
                Write-Debug 'Write to the AT port timed out.'
                return
            }
            if ($transfer.Error -ne 0) {
                $this.MarkLost('write', $transfer.Error)
                return
            }
            if ($transfer.Count -le 0) {
                return
            }
            $sent += $transfer.Count
        }
    }

    [string] Read([int] $timeoutMs) {
        if ($this.Lost -or -not $this.Usb) {
            return ''
        }
        $timeout = [Math]::Max(1, $timeoutMs)
        if ($timeout -ne $this.ReadTimeout) {
            $set = $this.Usb.SetTimeout($this.InPipe, [uint32]$timeout)
            if ($set -ne 0) {
                $this.MarkLost('read', $set)
                return ''
            }
            $this.ReadTimeout = $timeout
        }
        $transfer = $this.Usb.Read($this.InPipe, $this.ReadBuffer)
        # ERROR_SEM_TIMEOUT (121): nothing came within the timeout. Any other error: the port is gone.
        if ($transfer.Error -eq 121) {
            return ''
        }
        if ($transfer.Error -ne 0) {
            $this.MarkLost('read', $transfer.Error)
            return ''
        }
        return [System.Text.Encoding]::Latin1.GetString($this.ReadBuffer, 0, $transfer.Count)
    }

    [void] Close() {
        if ($this.Usb) {
            try {
                $this.Usb.Dispose()
            }
            catch {
                Write-Debug "Closing the AT port: $($_.Exception.Message)"
            }
            $this.Usb = $null
        }
    }

    hidden [void] MarkLost([string] $what, [int] $code) {
        $this.Lost = $true
        $this.LostReason = "${what}: $([System.ComponentModel.Win32Exception]::new($code).Message) ($code)"
    }
}

# How long a write may take before it counts as not drained, in ms: the modem hung, the port there.
$script:WinUsbWriteTimeoutMs = 2000

function Select-UsbBulkPipe {
    <#
    .SYNOPSIS
        Picks an interface's bulk IN and bulk OUT pipes.
    .DESCRIPTION
        A pure decision over the pipes WinUSB reports (Id - the endpoint address, bit 7 set for
        IN -, Type - 2 for bulk -, MaximumPacketSize): the modem's serial interfaces have one bulk
        IN and one bulk OUT endpoint and nothing else (AT-COMMANDS section 1.2). Returns In, Out
        and PacketSize (the IN pipe's maximum packet size); throws when there isn't exactly one of
        each.
    .EXAMPLE
        Select-UsbBulkPipe -Pipe $interface.Pipes
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Pipe
    )

    $bulk = @($Pipe | Where-Object { [int]$_.Type -eq 2 })
    $in = @($bulk | Where-Object { ([int]$_.Id -band 0x80) -ne 0 })
    $out = @($bulk | Where-Object { ([int]$_.Id -band 0x80) -eq 0 })
    if ($in.Count -ne 1 -or $out.Count -ne 1 -or [int]$in[0].MaximumPacketSize -le 0) {
        throw [System.InvalidOperationException]::new("The interface has $($in.Count) bulk IN and $($out.Count) bulk OUT pipes, not one of each.")
    }
    [pscustomobject]@{ In = [byte]$in[0].Id; Out = [byte]$out[0].Id; PacketSize = [int]$in[0].MaximumPacketSize }
}

function Open-WinUsbInterface {
    # The interface at a device interface path, opened through WinUSB; Windows' error as itself, a
    # Win32Exception, not wrapped in PowerShell's.
    param([string] $InterfacePath)

    try {
        [FibocomFm350.WinUsbInterface]::Open($InterfacePath)
    }
    catch [System.Management.Automation.MethodInvocationException] {
        throw $_.Exception.InnerException
    }
}

function Open-WinUsbAtTransport {
    <#
    .SYNOPSIS
        Opens the modem's AT function on WinUSB and returns a transport for New-AtChannel.
    .DESCRIPTION
        Opens the interface at -InterfacePath (Get-WinUsbInterfacePath), finds its bulk pair, and
        gives writes a timeout. No modem-control request is sent: the modem needs none
        (AT-COMMANDS section 1.2). The channel created on it owns it: Close-AtChannel releases it.
        Only one program can hold the interface; opening one that is held, or gone, fails with
        Windows' error (a Win32Exception).
    .EXAMPLE
        $channel = New-AtChannel -Transport (Open-WinUsbAtTransport -InterfacePath $path)
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string] $InterfacePath
    )

    $usb = Open-WinUsbInterface -InterfacePath $InterfacePath
    try {
        $pipes = Select-UsbBulkPipe -Pipe @($usb.Pipes)
        $set = $usb.SetTimeout($pipes.Out, [uint32]$script:WinUsbWriteTimeoutMs)
        if ($set -ne 0) {
            throw [System.ComponentModel.Win32Exception]::new([int]$set)
        }
        [WinUsbAtTransport]::new($usb, $pipes.In, $pipes.Out, $pipes.PacketSize)
    }
    catch {
        $usb.Dispose()
        throw
    }
}

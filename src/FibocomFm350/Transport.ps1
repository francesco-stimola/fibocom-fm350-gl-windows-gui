# The serial transport: carries text between the AT channel and the modem's COM port.
# Facts and sources: docs/AT-COMMANDS.md section 2.
#
# A transport is any object with this shape (the simulated modem has it too):
#   [string] PortName
#   [bool]   Lost          set once the port is gone: device unplugged, modem reset, driver
#                          restarted. A lost transport never touches the port again.
#   [void]   Write([string] $text)
#   [string] Read([int] $timeoutMs)   text received within the timeout, or ''
#   [void]   Close()       releases the port; safe to repeat, and after the port is lost
#
# [NoRunspaceAffinity()]: the app's worker runspace owns the port, so methods must run in whichever
# runspace calls them. For the same reason the class calls no module function.

[NoRunspaceAffinity()]
class SerialAtTransport {
    [string] $PortName
    [bool] $Lost = $false
    # Why the port was declared lost, for the log.
    [string] $LostReason

    hidden [System.IO.Ports.SerialPort] $Port
    hidden [byte[]] $ReadBuffer = [byte[]]::new(4096)

    SerialAtTransport([string] $portName) {
        $this.PortName = $portName
        # Baud rate and flow control don't apply to the USB virtual port (AT-COMMANDS section 2).
        # DTR and RTS are asserted, as a modem expects from a terminal that is ready.
        $serial = [System.IO.Ports.SerialPort]::new($portName, 115200)
        $serial.Encoding = [System.Text.Encoding]::Latin1
        $serial.Handshake = [System.IO.Ports.Handshake]::None
        $serial.DtrEnable = $true
        $serial.RtsEnable = $true
        $serial.WriteTimeout = 2000
        try {
            $serial.Open()
        }
        catch {
            $serial.Dispose()
            throw
        }
        $this.Port = $serial
    }

    [void] Write([string] $text) {
        if ($this.Lost -or -not $this.Port) {
            return
        }
        try {
            $this.Port.Write($text)
        }
        catch [System.TimeoutException] {
            # The port is there but the modem isn't draining it (hung): not a lost port. The
            # command then times out without an echo, which is how a hung modem shows up.
            Write-Debug "Write to $($this.PortName) timed out."
        }
        catch {
            $this.MarkLost("write: $($_.Exception.Message)")
        }
    }

    [string] Read([int] $timeoutMs) {
        if ($this.Lost -or -not $this.Port) {
            return ''
        }
        try {
            $this.Port.ReadTimeout = [Math]::Max(1, $timeoutMs)
            $count = $this.Port.Read($this.ReadBuffer, 0, $this.ReadBuffer.Length)
            return [System.Text.Encoding]::Latin1.GetString($this.ReadBuffer, 0, $count)
        }
        catch [System.TimeoutException] {
            return ''
        }
        catch {
            $this.MarkLost("read: $($_.Exception.Message)")
            return ''
        }
    }

    [void] Close() {
        if ($this.Port) {
            try {
                $this.Port.Dispose()
            }
            catch {
                Write-Debug "Closing $($this.PortName): $($_.Exception.Message)"
            }
            $this.Port = $null
        }
    }

    hidden [void] MarkLost([string] $reason) {
        $this.Lost = $true
        $this.LostReason = $reason
    }
}

function Open-SerialAtTransport {
    <#
    .SYNOPSIS
        Opens a modem's AT port and returns a transport for New-AtChannel.
    .DESCRIPTION
        Opens the COM port with the settings the FM350's USB AT port expects (AT-COMMANDS
        section 2). The channel created on it owns it: Close-AtChannel releases it.
        Only one process can hold a COM port; opening one that is held, or doesn't exist, fails.
    .EXAMPLE
        $channel = New-AtChannel -Transport (Open-SerialAtTransport -PortName COM5)
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^COM[1-9][0-9]{0,2}$')]
        [string] $PortName
    )

    [SerialAtTransport]::new($PortName)
}

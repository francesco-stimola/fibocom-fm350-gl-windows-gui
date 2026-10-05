# The WinUSB transport, with WinUSB stood in for at the interface the C# opens (Read, Write,
# SetTimeout, Dispose): packets, timeouts, the errors that mean the port is gone, writes in parts.
# Picking the bulk pipes, as a matrix. The real AT function is exercised only by the Hardware test,
# on purpose (docs/SETUP.md).

BeforeDiscovery {
    $script:hardware = $env:FM350_HARDWARE
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force

    # An interface opened through WinUSB, as the transport sees it: reads come from -Reads (text,
    # or an error code), writes are recorded or answered from -WriteResults; -Answer gives what
    # the modem sends back for a write.
    function Get-FakeUsb {
        param([object[]] $Reads = @(), [object[]] $WriteResults = @(), [int] $SetTimeoutError = 0, [scriptblock] $Answer)
        $fake = [pscustomobject]@{
            Reads           = [System.Collections.Generic.Queue[object]]::new()
            WriteResults    = [System.Collections.Generic.Queue[object]]::new()
            Written         = [System.Collections.Generic.List[string]]::new()
            Timeouts        = [System.Collections.Generic.List[object]]::new()
            ReadCalls       = 0
            Disposed        = 0
            SetTimeoutError = $SetTimeoutError
            Answer          = $Answer
            Pipes           = @(
                [pscustomobject]@{ Id = 0x87; Type = 2; MaximumPacketSize = 512 }
                [pscustomobject]@{ Id = 0x06; Type = 2; MaximumPacketSize = 512 }
            )
        }
        foreach ($read in $Reads) { $fake.Reads.Enqueue($read) }
        foreach ($result in $WriteResults) { $fake.WriteResults.Enqueue($result) }
        $fake | Add-Member -MemberType ScriptMethod -Name SetTimeout -Value {
            param($pipe, $milliseconds)
            $this.Timeouts.Add([pscustomobject]@{ Pipe = $pipe; Ms = $milliseconds })
            $this.SetTimeoutError
        }
        $fake | Add-Member -MemberType ScriptMethod -Name Read -Value {
            param($pipe, $buffer)
            if ($pipe -ne 0x87) { throw "read from pipe $pipe" }
            $this.ReadCalls++
            if ($this.Reads.Count -eq 0) {
                return [pscustomobject]@{ Error = 121; Count = 0 }
            }
            $next = $this.Reads.Dequeue()
            if ($next -is [int]) {
                return [pscustomobject]@{ Error = $next; Count = 0 }
            }
            $bytes = [System.Text.Encoding]::Latin1.GetBytes([string]$next)
            [Array]::Copy($bytes, $buffer, $bytes.Length)
            [pscustomobject]@{ Error = 0; Count = $bytes.Length }
        }
        $fake | Add-Member -MemberType ScriptMethod -Name Write -Value {
            param($pipe, $data, $offset, $length)
            if ($pipe -ne 0x06) { throw "write to pipe $pipe" }
            $result = if ($this.WriteResults.Count -gt 0) { $this.WriteResults.Dequeue() } else { [pscustomobject]@{ Error = 0; Count = $length } }
            if ($result.Count -gt 0) {
                $text = [System.Text.Encoding]::Latin1.GetString($data, $offset, $result.Count)
                $this.Written.Add($text)
                if ($this.Answer) {
                    foreach ($line in @(& $this.Answer $text)) { $this.Reads.Enqueue($line) }
                }
            }
            $result
        }
        $fake | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed++ }
        $fake
    }

    function Get-TestTransport {
        param([object] $Usb, [int] $PacketSize = 512)
        & (Get-Module FibocomFm350) { param($usb, $size) [WinUsbAtTransport]::new($usb, 0x87, 0x06, $size) } $Usb $PacketSize
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'The WinUSB transport' {
    It 'is named WinUSB, never by a COM port' {
        (Get-TestTransport -Usb (Get-FakeUsb)).PortName | Should -Be 'WinUSB'
    }

    It 'reads one packet at a time from the IN pipe, as Latin-1 text' {
        $usb = Get-FakeUsb -Reads @("AT`r", "`r`nOK`r`n", "caf$([char]0xE9)")
        $transport = Get-TestTransport -Usb $usb
        $transport.Read(1000) | Should -BeExactly "AT`r"
        $transport.Read(1000) | Should -BeExactly "`r`nOK`r`n"
        $transport.Read(1000) | Should -BeExactly "caf$([char]0xE9)"
        $transport.Lost | Should -BeFalse
    }

    It 'gives nothing when no packet comes within the timeout, the port still there' {
        $transport = Get-TestTransport -Usb (Get-FakeUsb -Reads @(121))
        $transport.Read(200) | Should -BeExactly ''
        $transport.Lost | Should -BeFalse
    }

    It 'sets the IN pipe''s timeout only when it changes, never under 1 ms' {
        $usb = Get-FakeUsb
        $transport = Get-TestTransport -Usb $usb
        [void]$transport.Read(1000)
        [void]$transport.Read(1000)
        [void]$transport.Read(250)
        [void]$transport.Read(0)
        $usb.Timeouts.Ms | Should -Be @(1000, 250, 1)
        $usb.Timeouts.Pipe | Should -Be @(0x87, 0x87, 0x87)
    }

    It 'loses the port on read error <Code>, and never touches it again' -ForEach @(
        @{ Code = 22 }
        @{ Code = 31 }
        @{ Code = 995 }
        @{ Code = 1167 }
        @{ Code = 6 }
    ) {
        $usb = Get-FakeUsb -Reads @($Code, 'late')
        $transport = Get-TestTransport -Usb $usb
        $transport.Read(1000) | Should -BeExactly ''
        $transport.Lost | Should -BeTrue
        $transport.LostReason | Should -Match "^read: .*\($Code\)$"
        $transport.Read(1000) | Should -BeExactly ''
        $transport.Write("AT`r")
        $usb.ReadCalls | Should -Be 1
        $usb.Written.Count | Should -Be 0
    }

    It 'loses the port when its timeout can''t be set' {
        $transport = Get-TestTransport -Usb (Get-FakeUsb -SetTimeoutError 22)
        $transport.Read(1000) | Should -BeExactly ''
        $transport.Lost | Should -BeTrue
    }

    It 'writes the text as Latin-1 to the OUT pipe' {
        $usb = Get-FakeUsb
        (Get-TestTransport -Usb $usb).Write("AT+CGMM?`r")
        $usb.Written | Should -Be @("AT+CGMM?`r")
    }

    It 'writes what is left when a transfer moves part of it' {
        $usb = Get-FakeUsb -WriteResults @([pscustomobject]@{ Error = 0; Count = 3 })
        (Get-TestTransport -Usb $usb).Write("AT+CSQ`r")
        $usb.Written -join '' | Should -BeExactly "AT+CSQ`r"
        $usb.Written.Count | Should -Be 2
    }

    It 'keeps the port when a write times out: the modem is not draining it' {
        $usb = Get-FakeUsb -WriteResults @([pscustomobject]@{ Error = 121; Count = 0 })
        $transport = Get-TestTransport -Usb $usb
        $transport.Write("AT`r")
        $transport.Lost | Should -BeFalse
    }

    It 'loses the port on a write error' {
        $transport = Get-TestTransport -Usb (Get-FakeUsb -WriteResults @([pscustomobject]@{ Error = 1167; Count = 0 }))
        $transport.Write("AT`r")
        $transport.Lost | Should -BeTrue
        $transport.LostReason | Should -Match '^write: .*\(1167\)$'
    }

    It 'stops writing when a transfer moves nothing without an error' {
        $usb = Get-FakeUsb -WriteResults @([pscustomobject]@{ Error = 0; Count = 0 })
        $transport = Get-TestTransport -Usb $usb
        $transport.Write("AT`r")
        $transport.Lost | Should -BeFalse
        $usb.Written.Count | Should -Be 0
    }

    It 'releases the interface once, however often it is closed' {
        $usb = Get-FakeUsb
        $transport = Get-TestTransport -Usb $usb
        $transport.Close()
        $transport.Close()
        $usb.Disposed | Should -Be 1
        $transport.Read(100) | Should -BeExactly ''
    }

    It 'closes a port that was lost' {
        $usb = Get-FakeUsb -Reads @(1167)
        $transport = Get-TestTransport -Usb $usb
        [void]$transport.Read(100)
        $transport.Close()
        $usb.Disposed | Should -Be 1
    }

    It 'carries the AT channel: a command, its echo and its answer' {
        $usb = Get-FakeUsb -Answer { param($text) if ($text -like 'AT*') { $text; "`r`nFM350-GL`r`n"; "`r`nOK`r`n" } }
        $channel = New-AtChannel -Transport (Get-TestTransport -Usb $usb)
        try {
            $answer = Invoke-AtCommand -Channel $channel -Command 'AT+CGMM' -TimeoutMs 3000
            $answer.Status | Should -Be 'OK'
            $answer.Lines | Should -Contain 'FM350-GL'
        }
        finally {
            Close-AtChannel -Channel $channel
        }
        $usb.Disposed | Should -Be 1
    }
}

Describe 'Select-UsbBulkPipe' {
    It '<Name>' -ForEach @(
        @{ Name = 'the AT interface: bulk IN 0x87 and OUT 0x06'; Pipes = @(@(0x87, 2, 512), @(0x06, 2, 512)); In = 0x87; Out = 0x06; Size = 512 }
        @{ Name = 'in the other order'; Pipes = @(@(0x06, 2, 512), @(0x87, 2, 512)); In = 0x87; Out = 0x06; Size = 512 }
        @{ Name = 'SuperSpeed packets'; Pipes = @(@(0x81, 2, 1024), @(0x01, 2, 1024)); In = 0x81; Out = 0x01; Size = 1024 }
        @{ Name = 'an interrupt pipe besides'; Pipes = @(@(0x82, 3, 64), @(0x81, 2, 512), @(0x01, 2, 512)); In = 0x81; Out = 0x01; Size = 512 }
    ) {
        $pipes = @(foreach ($pipe in $Pipes) { [pscustomobject]@{ Id = $pipe[0]; Type = $pipe[1]; MaximumPacketSize = $pipe[2] } })
        $chosen = Select-UsbBulkPipe -Pipe $pipes
        $chosen.In | Should -Be $In
        $chosen.Out | Should -Be $Out
        $chosen.PacketSize | Should -Be $Size
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'no pipe'; Pipes = @() }
        @{ Name = 'two bulk IN pipes'; Pipes = @(@(0x81, 2, 512), @(0x82, 2, 512), @(0x01, 2, 512)) }
        @{ Name = 'no bulk OUT pipe'; Pipes = @(@(0x81, 2, 512), @(0x01, 3, 64)) }
        @{ Name = 'an IN pipe without a packet size'; Pipes = @(@(0x81, 2, 0), @(0x01, 2, 512)) }
    ) {
        $pipes = @(foreach ($pipe in $Pipes) { [pscustomobject]@{ Id = $pipe[0]; Type = $pipe[1]; MaximumPacketSize = $pipe[2] } })
        { Select-UsbBulkPipe -Pipe $pipes -ErrorAction Stop } | Should -Throw -ExceptionType ([System.InvalidOperationException])
    }
}

Describe 'Open-WinUsbAtTransport' {
    It 'opens the interface, gives writes a timeout and reads one packet at a time' {
        $usb = Get-FakeUsb -Reads @('x' * 512)
        Mock -ModuleName FibocomFm350 Open-WinUsbInterface { $usb }
        $transport = Open-WinUsbAtTransport -InterfacePath '\\?\usb#test'
        $usb.Timeouts | Where-Object Pipe -EQ 0x06 | ForEach-Object Ms | Should -Be @(2000)
        $transport.Read(1000).Length | Should -Be 512
        Should -Invoke -ModuleName FibocomFm350 Open-WinUsbInterface -Times 1 -Exactly -ParameterFilter { $InterfacePath -eq '\\?\usb#test' }
    }

    It 'releases the interface when its pipes are not a bulk pair' {
        $usb = Get-FakeUsb
        $usb.Pipes = @([pscustomobject]@{ Id = 0x81; Type = 3; MaximumPacketSize = 64 })
        Mock -ModuleName FibocomFm350 Open-WinUsbInterface { $usb }
        { Open-WinUsbAtTransport -InterfacePath '\\?\usb#test' -ErrorAction Stop } | Should -Throw
        $usb.Disposed | Should -Be 1
    }

    It 'releases the interface when the write timeout can''t be set' {
        $usb = Get-FakeUsb -SetTimeoutError 31
        Mock -ModuleName FibocomFm350 Open-WinUsbInterface { $usb }
        { Open-WinUsbAtTransport -InterfacePath '\\?\usb#test' -ErrorAction Stop } | Should -Throw -ExceptionType ([System.ComponentModel.Win32Exception])
        $usb.Disposed | Should -Be 1
    }

    It 'says why it can''t open: another program holds the interface' {
        Mock -ModuleName FibocomFm350 Open-WinUsbInterface { throw [System.ComponentModel.Win32Exception]::new(5) }
        $failure = { Open-WinUsbAtTransport -InterfacePath '\\?\usb#test' -ErrorAction Stop } | Should -Throw -PassThru
        $failure.Exception.GetBaseException().NativeErrorCode | Should -Be 5
    }

    It 'fails on an interface that is not there' {
        { Open-WinUsbAtTransport -InterfacePath '\\?\usb#vid_0e8d&pid_7127&mi_06#none#{4fde9624-2286-4dc0-9d07-601a3922581a}' -ErrorAction Stop } |
            Should -Throw -ExceptionType ([System.ComponentModel.Win32Exception])
    }
}

# Needs an FM350 whose AT function the app put on WinUSB, and this app not running (it would hold
# the port).
Describe 'WinUSB transport on a real FM350' -Tag Hardware -Skip:(-not $script:hardware) {
    It 'opens the AT port found by PnP, initializes the channel and gets an answer' {
        $presence = Resolve-ModemPresence -Modem @(Resolve-ModemUsbDevice -Device @(Get-ModemPnpRecord))
        $presence.Device | Should -Be 'Present'
        $path = @(Get-WinUsbInterfacePath -InstanceId $presence.AtInstanceId)[0]
        $channel = New-AtChannel -Transport (Open-WinUsbAtTransport -InterfacePath $path)
        try {
            (Initialize-AtChannel -Channel $channel -TimeoutMs 3000).Status | Should -Be 'OK'
            (Invoke-AtCommand -Channel $channel -Command 'AT+CGMM?' -TimeoutMs 3000).Status | Should -Be 'OK'
        }
        finally {
            Close-AtChannel -Channel $channel
        }
    }
}

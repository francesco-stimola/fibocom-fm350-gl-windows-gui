# The AT channel over the simulated modem, including the fault scenarios of ROADMAP M1.
# Timings are real but short: delays of a few hundred milliseconds at most.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'AT channel' {
    BeforeEach {
        $script:modem = New-SimulatedModem -PortName 'COM5'
        $script:modem.SetAnswer('AT+CSQ', @('+CSQ: 20,99', 'OK'))
        $script:channel = New-AtChannel -Transport $script:modem
        $script:ready = Initialize-AtChannel -Channel $script:channel -TimeoutMs 5000
    }

    AfterEach {
        Close-AtChannel -Channel $script:channel
    }

    Context 'normal operation' {
        It 'initializes with echo on and numeric error codes' {
            $script:ready.Status | Should -Be 'OK'
            $script:ready.EchoSeen | Should -BeTrue
            $script:modem.Received | Should -Be @('ATE1', 'AT+CMEE=1')
        }

        It 'returns the answer lines without echo or final result' {
            $answer = Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 5000
            $answer.Status | Should -Be 'OK'
            $answer.Lines | Should -Be @('+CSQ: 20,99')
            $answer.EchoSeen | Should -BeTrue
            $answer.Discarded | Should -Be 0
        }

        It 'reports ERROR for a command the modem rejects' {
            (Invoke-AtCommand -Channel $script:channel -Command 'AT+NOPE' -TimeoutMs 5000).Status | Should -Be 'Error'
        }

        It 'reports a +CME ERROR with its number' {
            $script:modem.SetAnswer('AT+CPIN?', @('+CME ERROR: 10'))
            $answer = Invoke-AtCommand -Channel $script:channel -Command 'AT+CPIN?' -TimeoutMs 5000
            $answer.Status | Should -Be 'CmeError'
            $answer.ErrorCode | Should -Be 10
        }

        It 'queues a URC that follows the final result in the same read' {
            $script:modem.Script('AT+CSQ', @{ Lines = @('+CSQ: 20,99', 'OK', '+CEREG: 1') })
            (Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 5000).Status | Should -Be 'OK'
            Receive-AtUrc -Channel $script:channel | Should -Be @('+CEREG: 1')
        }
    }

    Context 'fault scenarios' {
        It 'times out when no final result code comes, and stays usable' {
            $script:modem.Script('AT+CSQ', @{ NoFinal = $true })
            $answer = Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 150
            $answer.Status | Should -Be 'Timeout'
            $answer.Lines | Should -Be @('+CSQ: 20,99')
            $answer.ElapsedMs | Should -BeGreaterOrEqual 150

            (Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 5000).Status | Should -Be 'OK'
        }

        It 'reassembles an answer split across reads' {
            # Output: "AT+CSQ`r" (0-6), "`r`n+CSQ: 20,99`r`n" (7-21), "`r`nOK`r`n" (22-27).
            # Cuts inside the echo, twice inside '+CSQ: 20,99', and between 'O' and 'K'.
            $script:modem.Script('AT+CSQ', @{ SplitAt = @(3, 12, 18, 25) })
            $answer = Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 5000
            $answer.Status | Should -Be 'OK'
            $answer.Lines | Should -Be @('+CSQ: 20,99')
        }

        It 'ignores garbled bytes before the answer' {
            $script:modem.Script('AT+CSQ', @{ Garbage = "$([char]0)$([char]0xFF)$([char]0xFE)$([char]0x13)" })
            $answer = Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 5000
            $answer.Status | Should -Be 'OK'
            $answer.Lines | Should -Be @('+CSQ: 20,99')
        }

        It 'takes a URC out of the middle of an answer' {
            $script:modem.Script('AT+CSQ', @{ UrcAfter = 1; Urc = '+CEREG: 5' })
            $answer = Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 5000
            $answer.Lines | Should -Be @('+CSQ: 20,99')
            Receive-AtUrc -Channel $script:channel | Should -Be @('+CEREG: 5')
        }

        It 'reports PortLost when the port vanishes mid-command, and never touches it again' {
            $script:modem.Script('AT+CSQ', @{ NoFinal = $true; Vanish = $true })
            (Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 5000).Status | Should -Be 'PortLost'
            $script:channel.State | Should -Be 'Lost'

            $written = $script:modem.Received.Count
            (Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 5000).Status | Should -Be 'PortLost'
            $script:modem.Received.Count | Should -Be $written
        }

        It 'works on a new channel when the device comes back under another COM number' {
            $script:modem.Vanish()
            (Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 5000).Status | Should -Be 'PortLost'
            Close-AtChannel -Channel $script:channel

            $script:modem.Reappear('COM9')
            $script:channel = New-AtChannel -Transport $script:modem
            (Initialize-AtChannel -Channel $script:channel -TimeoutMs 5000).Status | Should -Be 'OK'
            (Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 5000).Status | Should -Be 'OK'
            $script:channel.Transport.PortName | Should -Be 'COM9'
        }

        It 'reports SIM busy after a band change until the SIM is ready' {
            $script:modem.SetAnswer('AT+GTACT=2,3,3,0', @('OK'))
            $script:modem.SetAnswer('AT+CPIN?', @('+CPIN: READY', 'OK'))
            $script:modem.Script('AT+CPIN?', @{ Lines = @('+CME ERROR: 14'); Times = 2 })

            (Invoke-AtCommand -Channel $script:channel -Command 'AT+GTACT=2,3,3,0' -TimeoutMs 5000).Status | Should -Be 'OK'
            $statuses = 1..3 | ForEach-Object {
                $answer = Invoke-AtCommand -Channel $script:channel -Command 'AT+CPIN?' -TimeoutMs 5000
                '{0}:{1}' -f $answer.Status, $answer.ErrorCode
            }
            $statuses | Should -Be @('CmeError:14', 'CmeError:14', 'OK:')
        }

        It 'delivers registration lost and regained, in order, while idle' {
            $script:modem.EmitUnsolicited('+CEREG: 2', 0)
            $script:modem.EmitUnsolicited('+CEREG: 1', 50)
            $received = [System.Collections.Generic.List[string]]::new()
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            while ($received.Count -lt 2 -and $clock.ElapsedMilliseconds -lt 5000) {
                foreach ($urc in Receive-AtUrc -Channel $script:channel -TimeoutMs 200) {
                    $received.Add($urc)
                }
            }
            $received | Should -Be @('+CEREG: 2', '+CEREG: 1')
        }

        It 'waits for a slow AT+COPS=0 within its timeout' {
            $script:modem.SetAnswer('AT+COPS=0', @('OK'))
            $script:modem.Script('AT+COPS=0', @{ DelayMs = 300 })
            $answer = Invoke-AtCommand -Channel $script:channel -Command 'AT+COPS=0' -TimeoutMs 5000
            $answer.Status | Should -Be 'OK'
            $answer.ElapsedMs | Should -BeGreaterOrEqual 300
        }

        It 'does not mistake a late answer for the next command''s answer' {
            $script:modem.SetAnswer('AT+COPS=0', @('OK'))
            $script:modem.SetAnswer('AT+CPIN?', @('ERROR'))
            $script:modem.Script('AT+COPS=0', @{ DelayMs = 400 })
            (Invoke-AtCommand -Channel $script:channel -Command 'AT+COPS=0' -TimeoutMs 100).Status | Should -Be 'Timeout'

            # The late OK of AT+COPS=0 arrives before this command's echo and must be discarded.
            $answer = Invoke-AtCommand -Channel $script:channel -Command 'AT+CPIN?' -TimeoutMs 5000
            $answer.Status | Should -Be 'Error'
            $answer.Discarded | Should -Be 1
        }

        It 'initializes after a timeout even when the late answer is an error' {
            $script:modem.Script('AT+COPS=0', @{ Lines = @('+CME ERROR: 30'); DelayMs = 300 })
            (Invoke-AtCommand -Channel $script:channel -Command 'AT+COPS=0' -TimeoutMs 100).Status | Should -Be 'Timeout'

            # ATE1 can't be anchored and may take the late error as its own answer; AT+CMEE=1 decides.
            (Initialize-AtChannel -Channel $script:channel -TimeoutMs 5000).Status | Should -Be 'OK'
            $script:modem.Received[-1] | Should -Be 'AT+CMEE=1'
        }

        It 'keeps a late answer out of the unsolicited codes: <Command>' -ForEach @(
            @{ Command = 'AT+CSCON?'; Lines = @('+CSCON: 1,0', 'OK') }
            @{ Command = 'AT+CIMI'; Lines = @('001010000000001', 'OK') }
        ) {
            $script:modem.Script($Command, @{ Lines = $Lines; DelayMs = 300 })
            (Invoke-AtCommand -Channel $script:channel -Command $Command -TimeoutMs 100).Status | Should -Be 'Timeout'
            $script:modem.EmitUnsolicited('+CEREG: 1', 500)

            $received = [System.Collections.Generic.List[string]]::new()
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            while ($received -notcontains '+CEREG: 1' -and $clock.ElapsedMilliseconds -lt 5000) {
                foreach ($urc in Receive-AtUrc -Channel $script:channel -TimeoutMs 200) {
                    $received.Add($urc)
                }
            }
            $received | Should -Be @('+CEREG: 1')
        }

        It 'keeps a late answer out of the unsolicited codes when Initialize-AtChannel runs next' {
            $script:modem.Script('AT+CSCON?', @{ Lines = @('+CSCON: 1,0', 'OK'); DelayMs = 300 })
            (Invoke-AtCommand -Channel $script:channel -Command 'AT+CSCON?' -TimeoutMs 100).Status | Should -Be 'Timeout'
            (Initialize-AtChannel -Channel $script:channel -TimeoutMs 5000).Status | Should -Be 'OK'
            Receive-AtUrc -Channel $script:channel -TimeoutMs 300 | Should -BeNullOrEmpty
        }

        It 'keeps two late answers in a row out of the unsolicited codes' {
            $script:modem.Script('AT+CSCON?', @{ Lines = @('+CSCON: 1,0', 'OK'); DelayMs = 300 })
            $script:modem.SetAnswer('AT+CPIN?', @('+CPIN: READY', 'OK'))
            (Invoke-AtCommand -Channel $script:channel -Command 'AT+CSCON?' -TimeoutMs 100).Status | Should -Be 'Timeout'
            # The modem is still busy: this one's echo comes after the late answer, too late.
            $second = Invoke-AtCommand -Channel $script:channel -Command 'AT+CPIN?' -TimeoutMs 100
            $second.Status | Should -Be 'Timeout'
            $second.EchoSeen | Should -BeFalse
            $script:modem.EmitUnsolicited('+CEREG: 1', 700)

            $received = [System.Collections.Generic.List[string]]::new()
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            while ($received -notcontains '+CEREG: 1' -and $clock.ElapsedMilliseconds -lt 5000) {
                foreach ($urc in Receive-AtUrc -Channel $script:channel -TimeoutMs 200) {
                    $received.Add($urc)
                }
            }
            $received | Should -Be @('+CEREG: 1')
        }

        It 'passes on a real registration report that arrives while a late one is due' {
            $script:modem.Script('AT+CEREG?', @{ Lines = @('+CEREG: 2,1,"ABCD","0ABCDEF0",7', 'OK'); DelayMs = 400 })
            (Invoke-AtCommand -Channel $script:channel -Command 'AT+CEREG?' -TimeoutMs 100).Status | Should -Be 'Timeout'
            $script:modem.EmitUnsolicited('+CEREG: 0', 100)

            $received = [System.Collections.Generic.List[string]]::new()
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            while ($clock.ElapsedMilliseconds -lt 1000) {
                foreach ($urc in Receive-AtUrc -Channel $script:channel -TimeoutMs 200) {
                    $received.Add($urc)
                }
            }
            $received | Should -Contain '+CEREG: 0'
            # The late read answer may come through too; it still reads as what it is.
            $late = $received | Where-Object { $_ -ne '+CEREG: 0' } | ForEach-Object { ConvertFrom-AtRegistration -Line $_ }
            @($late | Where-Object { $_.Stat -ne 1 }) | Should -BeNullOrEmpty
        }

        It 'leaves a URC that arrives during a set command to Receive-AtUrc' {
            $script:modem.SetAnswer('AT+CEREG=2', @('OK'))
            $script:modem.Script('AT+CEREG=2', @{ UrcAfter = 0; Urc = '+CEREG: 1' })
            $answer = Invoke-AtCommand -Channel $script:channel -Command 'AT+CEREG=2' -TimeoutMs 5000
            $answer.Status | Should -Be 'OK'
            $answer.Lines | Should -BeNullOrEmpty
            Receive-AtUrc -Channel $script:channel | Should -Be @('+CEREG: 1')
        }

        It 'recovers when the modem''s echo was turned off' {
            (Invoke-AtCommand -Channel $script:channel -Command 'ATE0' -TimeoutMs 5000).Status | Should -Be 'OK'
            $lost = Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 150
            $lost.Status | Should -Be 'Timeout'
            $lost.EchoSeen | Should -BeFalse

            (Initialize-AtChannel -Channel $script:channel -TimeoutMs 5000).Status | Should -Be 'OK'
            (Invoke-AtCommand -Channel $script:channel -Command 'AT+CSQ' -TimeoutMs 5000).Lines | Should -Be @('+CSQ: 20,99')
        }
    }

    Context 'command text' {
        # A CR would make the modem run two commands; a character the port can't carry would
        # leave the echo unrecognizable, and a command that ran would be reported as a timeout.
        It 'refuses <Name> without writing anything' -ForEach @(
            @{ Name = 'an embedded CR'; Command = "AT`rAT+CFUN=0" }
            @{ Name = 'an embedded LF'; Command = "AT`nAT+CFUN=0" }
            @{ Name = 'a non-ASCII character'; Command = "AT+CGDCONT=1,`"IP`",`"apn$([char]0xE8)`"" }
        ) {
            $written = $script:modem.Received.Count
            { Invoke-AtCommand -Channel $script:channel -Command $Command -TimeoutMs 5000 -ErrorAction Stop } |
                Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
            $script:modem.Received.Count | Should -Be $written
        }
    }

    Context 'closing' {
        It 'releases the transport, is idempotent, and refuses further use' {
            Close-AtChannel -Channel $script:channel
            Close-AtChannel -Channel $script:channel
            $script:modem.Closed | Should -BeTrue
            { Invoke-AtCommand -Channel $script:channel -Command 'AT' -TimeoutMs 100 -ErrorAction Stop } |
                Should -Throw -ExceptionType ([System.InvalidOperationException])
            { Receive-AtUrc -Channel $script:channel -ErrorAction Stop } |
                Should -Throw -ExceptionType ([System.InvalidOperationException])
        }

        It 'closes a channel whose port is lost' {
            $script:modem.Vanish()
            [void](Invoke-AtCommand -Channel $script:channel -Command 'AT' -TimeoutMs 100)
            { Close-AtChannel -Channel $script:channel -ErrorAction Stop } | Should -Not -Throw
            $script:modem.Closed | Should -BeTrue
        }
    }
}

Describe 'New-AtChannel' {
    It 'refuses an object that is not a transport' {
        { New-AtChannel -Transport ([pscustomobject]@{ PortName = 'COM5' }) -ErrorAction Stop } |
            Should -Throw -ExceptionType ([System.ArgumentException])
    }
}

Describe 'Late command queue' {
    It 'remembers at most 10 timed-out commands, and the next echo clears them' {
        $modem = New-SimulatedModem
        $modem.Echo = $false
        $channel = New-AtChannel -Transport $modem
        try {
            # A modem that stops answering: no echo, no answer, every command times out.
            foreach ($i in 1..12) {
                $modem.Script("AT+X$i", @{ Lines = @() })
                [void](Invoke-AtCommand -Channel $channel -Command "AT+X$i" -TimeoutMs 1)
            }
            $channel.LateCommands.Count | Should -Be 10
            $channel.LateCommands[0] | Should -Be 'AT+X3'

            $modem.Echo = $true
            (Invoke-AtCommand -Channel $channel -Command 'AT' -TimeoutMs 5000).Status | Should -Be 'OK'
            $channel.LateCommands.Count | Should -Be 0
        }
        finally {
            Close-AtChannel -Channel $channel
        }
    }
}

Describe 'Unsolicited code queue' {
    It 'keeps the newest 1000 codes when nobody reads them' {
        InModuleScope FibocomFm350 {
            $channel = New-AtChannel -Transport (New-SimulatedModem)
            foreach ($i in 1..1005) {
                Add-AtQueuedUrc -Channel $channel -Line "+CEREG: $i"
            }
            $channel.Urcs.Count | Should -Be 1000
            $channel.Urcs.Peek() | Should -Be '+CEREG: 6'
        }
    }
}

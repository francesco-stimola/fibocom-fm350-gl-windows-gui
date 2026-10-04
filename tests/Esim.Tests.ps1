# eSIM: lpac's lines read, its APDU requests carried as AT+CCHO / AT+CGLA / AT+CCHC and answered
# (a matrix each), its command lines, its results read; the bridge run end to end against the
# simulated modem with a scripted lpac; and the real process plumbing with a stand-in for lpac.
# Facts: docs/AT-COMMANDS.md section 8.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    . "$PSScriptRoot/FixtureAnswer.ps1"

    $script:isdR = 'A0000005591010FFFFFFFF8900000100'
    $script:fakeLpac = Join-Path -Path $PSScriptRoot -ChildPath 'Lpac/FakeLpac.ps1'

    # An APDU request line as lpac writes it.
    function Get-RequestLine {
        param([string] $Function, [string] $Parameter)
        $param = if ($Parameter) { "`"$Parameter`"" } else { 'null' }
        "{`"type`":`"apdu`",`"payload`":{`"func`":`"$Function`",`"param`":$param}}"
    }

    # A bridge with these channel -> session pairs open.
    function Get-TestBridge {
        param([object[]] $Pair = @())
        [pscustomobject]@{ Channels = [object[]]@(foreach ($p in $Pair) { [pscustomobject]@{ Channel = $p[0]; Session = $p[1] } }) }
    }

    # A scripted lpac with Invoke-LpacOperation's shape: it writes -Request one at a time, each
    # once the previous one is answered, then -Result (unless -NoResult), and its output ends.
    # -Hang: its output never ends. Answers and whether it was stopped and disposed are recorded.
    function Get-ScriptedLpac {
        param([string[]] $Request = @(), [string] $Result = '{"type":"lpa","payload":{"code":0,"message":"success","data":null}}',
            [switch] $NoResult, [switch] $Hang, [string[]] $Before = @())
        $lpac = [pscustomobject]@{
            Ended    = $false
            Queue    = [System.Collections.Generic.Queue[string]]::new()
            Answers  = [System.Collections.Generic.List[string]]::new()
            Waiting  = $false
            Stopped  = $false
            Disposed = $false
            Hang     = [bool]$Hang
            Result   = if ($NoResult) { $null } else { $Result }
        }
        foreach ($line in $Before) { $lpac.Queue.Enqueue("free:$line") }
        foreach ($line in $Request) { $lpac.Queue.Enqueue($line) }
        $lpac | Add-Member -MemberType ScriptMethod -Name ReadLine -Value {
            param([int] $TimeoutMs)
            if ($this.Ended) { return $null }
            if (-not $this.Waiting -and $this.Queue.Count -gt 0) {
                $next = $this.Queue.Dequeue()
                if ($next.StartsWith('free:')) { return $next.Substring(5) }
                $this.Waiting = $true
                return $next
            }
            if (-not $this.Waiting -and $this.Queue.Count -eq 0) {
                if ($this.Hang) {
                    Start-Sleep -Milliseconds ([Math]::Min($TimeoutMs, 20))
                    return $null
                }
                if ($this.Result) {
                    $line = $this.Result
                    $this.Result = $null
                    return $line
                }
                $this.Ended = $true
                return $null
            }
            Start-Sleep -Milliseconds ([Math]::Min($TimeoutMs, 20))
            $null
        }
        $lpac | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
            param([string] $Text)
            $this.Answers.Add($Text)
            $this.Waiting = $false
        }
        $lpac | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Stopped = $true; $this.Ended = $true }
        $lpac | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true; $this.Ended = $true }
        $lpac | Add-Member -MemberType ScriptMethod -Name ExitCode -Value { 0 }
        $lpac
    }

    # The simulated modem answering the logical-channel commands of one run as the FM350 does
    # (AT-COMMANDS section 8): the session ID alone on its line, '+CGLA: <length>,"<hex>"'.
    function Get-ChannelModem {
        $modem = New-SimulatedModem
        $modem.SetAnswer("AT+CCHO=`"$script:isdR`"", @('1', 'OK'))
        $modem.SetAnswer('AT+CCHC=1', @('OK'))
        $channel = New-AtChannel -Transport $modem
        [void](Initialize-AtChannel -Channel $channel -TimeoutMs 2000)
        [pscustomobject]@{ Modem = $modem; Channel = $channel }
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Get-LpacPath' {
    It 'names lpac.exe in the lpac folder beside the modules' {
        $expected = Join-Path -Path (Resolve-Path "$PSScriptRoot/../src").Path -ChildPath 'lpac\lpac.exe'
        Get-LpacPath | Should -Be $expected
    }
}

Describe 'ConvertFrom-LpacLine' {
    It '<Name>' -ForEach @(
        @{ Name = 'connect, no parameter'; Line = '{"type":"apdu","payload":{"func":"connect","param":null}}'; Kind = 'Apdu'; Function = 'connect'; Parameter = $null }
        @{ Name = 'a channel opened on an AID'; Line = '{"type":"apdu","payload":{"func":"logic_channel_open","param":"a0000005591010ffffffff8900000100"}}'; Kind = 'Apdu'; Function = 'logic_channel_open'; Parameter = 'A0000005591010FFFFFFFF8900000100' }
        @{ Name = 'an APDU, padded with blanks'; Line = '  {"type":"apdu","payload":{"func":"transmit","param":"81E2910003BF2000"}}  '; Kind = 'Apdu'; Function = 'transmit'; Parameter = '81E2910003BF2000' }
        @{ Name = 'no param at all'; Line = '{"type":"apdu","payload":{"func":"disconnect"}}'; Kind = 'Apdu'; Function = 'disconnect'; Parameter = $null }
    ) {
        $read = ConvertFrom-LpacLine -Line $Line
        $read.Kind | Should -Be $Kind
        $read.Function | Should -Be $Function
        $read.Parameter | Should -Be $Parameter
    }

    It 'a result: its code, message and data' {
        $read = ConvertFrom-LpacLine -Line '{"type":"lpa","payload":{"code":0,"message":"success","data":[{"isdpAid":"A0000005591010FFFFFFFF8900001000"}]}}'
        $read.Kind | Should -Be 'Result'
        $read.Code | Should -Be 0
        $read.Message | Should -Be 'success'
        @($read.Data)[0].isdpAid | Should -Be 'A0000005591010FFFFFFFF8900001000'
    }

    It 'a failure: code -1, the step, and the reason' {
        $read = ConvertFrom-LpacLine -Line '{"type":"lpa","payload":{"code":-1,"message":"es10c_enable_profile","data":"profile not in disabled state"}}'
        $read.Kind | Should -Be 'Result'
        $read.Code | Should -Be -1
        $read.Message | Should -Be 'es10c_enable_profile'
        $read.Data | Should -Be 'profile not in disabled state'
    }

    It 'a version-like string stays a string' {
        (ConvertFrom-LpacLine -Line '{"type":"lpa","payload":{"code":0,"message":"success","data":{"svn":"2026-10-04"}}}').Data.svn | Should -BeOfType [string]
    }

    It 'progress: the step alone, never its data (it can name the ICCID)' {
        $read = ConvertFrom-LpacLine -Line '{"type":"progress","payload":{"code":0,"message":"es8p_meatadata_parse","data":{"iccid":"8900100000000000000"}}}'
        $read.Kind | Should -Be 'Progress'
        $read.Step | Should -Be 'es8p_meatadata_parse'
        $read.PSObject.Properties.Name | Should -Not -Contain 'Data'
    }

    It 'a request for the network' {
        $read = ConvertFrom-LpacLine -Line '{"type":"http","payload":{"url":"https://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication","tx":"7B7D","headers":[]}}'
        $read.Kind | Should -Be 'Http'
        $read.Url | Should -BeLike 'https://smdp.example.com/*'
    }

    It 'other: <Name>' -ForEach @(
        @{ Name = 'an empty line'; Line = '' }
        @{ Name = 'text'; Line = 'No APDU driver found' }
        @{ Name = 'broken JSON'; Line = '{"type":"apdu","payload":{' }
        @{ Name = 'a JSON list'; Line = '[1,2]' }
        @{ Name = 'a driver list'; Line = '{"type":"driver","payload":{"LPAC_APDU":["stdio"]}}' }
        @{ Name = 'no payload'; Line = '{"type":"apdu"}' }
        @{ Name = 'a payload that is no object'; Line = '{"type":"apdu","payload":"x"}' }
        @{ Name = 'a function that is no text'; Line = '{"type":"apdu","payload":{"func":1}}' }
        @{ Name = 'a code that is no number'; Line = '{"type":"lpa","payload":{"code":"0","message":"success"}}' }
        @{ Name = 'no type'; Line = '{"payload":{"func":"connect"}}' }
    ) {
        (ConvertFrom-LpacLine -Line $Line).Kind | Should -Be 'Other'
    }
}

Describe 'Resolve-LpacApduRequest' {
    It '<Name>' -ForEach @(
        @{ Name = 'connect is answered at once'; Function = 'connect'; Parameter = ''; Pairs = @(); Command = $null; ECode = 0 }
        @{ Name = 'disconnect is answered at once'; Function = 'disconnect'; Parameter = ''; Pairs = @(); Command = $null; ECode = 0 }
        @{ Name = 'a channel opened on the ISD-R'; Function = 'logic_channel_open'; Parameter = 'A0000005591010FFFFFFFF8900000100'; Pairs = @(); Command = 'AT+CCHO="A0000005591010FFFFFFFF8900000100"'; ECode = $null }
        @{ Name = 'a partial AID (5 bytes)'; Function = 'logic_channel_open'; Parameter = 'A000000087'; Pairs = @(); Command = 'AT+CCHO="A000000087"'; ECode = $null }
        @{ Name = 'an AID too short'; Function = 'logic_channel_open'; Parameter = 'A0000000'; Pairs = @(); Command = $null; ECode = -1 }
        @{ Name = 'an AID too long'; Function = 'logic_channel_open'; Parameter = 'A0000005591010FFFFFFFF890000010000'; Pairs = @(); Command = $null; ECode = -1 }
        @{ Name = 'an AID that is not hexadecimal'; Function = 'logic_channel_open'; Parameter = 'A0000005591010FFFFFFFF89000001ZZ'; Pairs = @(); Command = $null; ECode = -1 }
        @{ Name = 'an AID of half a byte'; Function = 'logic_channel_open'; Parameter = 'A0000005591'; Pairs = @(); Command = $null; ECode = -1 }
        @{ Name = 'no AID'; Function = 'logic_channel_open'; Parameter = ''; Pairs = @(); Command = $null; ECode = -1 }
        @{ Name = 'a channel the bridge opened is closed'; Function = 'logic_channel_close'; Parameter = '01'; Pairs = @(, @(1, 2)); Command = 'AT+CCHC=2'; ECode = $null }
        @{ Name = 'a channel the bridge never opened: nothing sent'; Function = 'logic_channel_close'; Parameter = '02'; Pairs = @(, @(1, 2)); Command = $null; ECode = 0 }
        @{ Name = 'a close of two bytes'; Function = 'logic_channel_close'; Parameter = '0001'; Pairs = @(, @(1, 2)); Command = $null; ECode = -1 }
        @{ Name = 'an APDU on the one channel open'; Function = 'transmit'; Parameter = '81E2910003BF2000'; Pairs = @(, @(1, 1)); Command = 'AT+CGLA=1,16,"81E2910003BF2000"'; ECode = $null }
        @{ Name = 'the class byte names another channel: the one open'; Function = 'transmit'; Parameter = '80E2910003BF2000'; Pairs = @(, @(1, 7)); Command = 'AT+CGLA=7,16,"80E2910003BF2000"'; ECode = $null }
        @{ Name = 'two open: the one the class byte names'; Function = 'transmit'; Parameter = '82E2910003BF2000'; Pairs = @(@(1, 5), @(2, 9)); Command = 'AT+CGLA=9,16,"82E2910003BF2000"'; ECode = $null }
        @{ Name = 'two open, none named'; Function = 'transmit'; Parameter = '83E2910003BF2000'; Pairs = @(@(1, 5), @(2, 9)); Command = $null; ECode = -1 }
        @{ Name = 'none open'; Function = 'transmit'; Parameter = '81E2910003BF2000'; Pairs = @(); Command = $null; ECode = -1 }
        @{ Name = 'a session with no channel is not lpac''s'; Function = 'transmit'; Parameter = '81E2910003BF2000'; Pairs = @(, @($null, 4)); Command = $null; ECode = -1 }
        @{ Name = 'an APDU of 3 bytes'; Function = 'transmit'; Parameter = '81E291'; Pairs = @(, @(1, 1)); Command = $null; ECode = -1 }
        @{ Name = 'an odd number of digits'; Function = 'transmit'; Parameter = '81E2910'; Pairs = @(, @(1, 1)); Command = $null; ECode = -1 }
        @{ Name = 'another function'; Function = 'reset'; Parameter = ''; Pairs = @(); Command = $null; ECode = -1 }
    ) {
        $request = [pscustomobject]@{ Kind = 'Apdu'; Function = $Function; Parameter = if ($Parameter) { $Parameter } else { $null } }
        $decision = Resolve-LpacApduRequest -Request $request -Bridge (Get-TestBridge -Pair $Pairs)
        $decision.Command | Should -Be $Command
        if ($null -eq $ECode) {
            $decision.Answer | Should -BeNullOrEmpty
        }
        else {
            $decision.Answer.ECode | Should -Be $ECode
            $decision.Answer.Data | Should -BeNullOrEmpty
        }
    }

    It 'carries a 261-byte APDU, and refuses 262' {
        $bridge = Get-TestBridge -Pair @(, @(1, 1))
        $apdu = '81E29100FF' + ('00' * 256)
        (Resolve-LpacApduRequest -Request ([pscustomobject]@{ Function = 'transmit'; Parameter = $apdu }) -Bridge $bridge).Command | Should -Be "AT+CGLA=1,522,`"$apdu`""
        (Resolve-LpacApduRequest -Request ([pscustomobject]@{ Function = 'transmit'; Parameter = $apdu + '00' }) -Bridge $bridge).Answer.ECode | Should -Be -1
    }
}

Describe 'Resolve-LpacApduAnswer' {
    It '<Name>' -ForEach @(
        @{ Name = 'a session opened: channel 1'; Function = 'logic_channel_open'; Parameter = 'A0000005591010FFFFFFFF8900000100'; Pairs = @(); Status = 'OK'; Lines = @('1'); ECode = 1; Data = $null; After = @(, @(1, 1)) }
        @{ Name = 'a session answered with a prefix'; Function = 'logic_channel_open'; Parameter = 'A0000005591010FFFFFFFF8900000100'; Pairs = @(); Status = 'OK'; Lines = @('+CCHO: 3'); ECode = 1; Data = $null; After = @(, @(1, 3)) }
        @{ Name = 'a second one: the next channel free'; Function = 'logic_channel_open'; Parameter = 'A000000087'; Pairs = @(, @(1, 1)); Status = 'OK'; Lines = @('2'); ECode = 2; Data = $null; After = @(@(1, 1), @(2, 2)) }
        @{ Name = 'a channel freed is given again'; Function = 'logic_channel_open'; Parameter = 'A000000087'; Pairs = @(, @(2, 4)); Status = 'OK'; Lines = @('5'); ECode = 1; Data = $null; After = @(@(2, 4), @(1, 5)) }
        @{ Name = 'refused'; Function = 'logic_channel_open'; Parameter = 'A000000087'; Pairs = @(); Status = 'CmeError'; Lines = @(); ECode = -1; Data = $null; After = @() }
        @{ Name = 'OK with no session ID'; Function = 'logic_channel_open'; Parameter = 'A000000087'; Pairs = @(); Status = 'OK'; Lines = @(); ECode = -1; Data = $null; After = @() }
        @{ Name = 'no answer'; Function = 'logic_channel_open'; Parameter = 'A000000087'; Pairs = @(); Status = 'Timeout'; Lines = @(); ECode = -1; Data = $null; After = @() }
        @{ Name = 'closed'; Function = 'logic_channel_close'; Parameter = '01'; Pairs = @(@(1, 1), @(2, 2)); Status = 'OK'; Lines = @(); ECode = 0; Data = $null; After = @(, @(2, 2)) }
        @{ Name = 'closed already by a SIM reset (an error)'; Function = 'logic_channel_close'; Parameter = '01'; Pairs = @(, @(1, 1)); Status = 'CmeError'; Lines = @(); ECode = 0; Data = $null; After = @() }
        @{ Name = 'a close unanswered stays, to be closed'; Function = 'logic_channel_close'; Parameter = '01'; Pairs = @(, @(1, 1)); Status = 'Timeout'; Lines = @(); ECode = 0; Data = $null; After = @(, @(1, 1)) }
        @{ Name = 'a response with its status word'; Function = 'transmit'; Parameter = '81E2910003BF2000'; Pairs = @(, @(1, 1)); Status = 'OK'; Lines = @('+CGLA: 12,"bf20039000"'); ECode = -1; Data = $null; After = @(, @(1, 1)) }
        @{ Name = 'a response read'; Function = 'transmit'; Parameter = '81E2910003BF2000'; Pairs = @(, @(1, 1)); Status = 'OK'; Lines = @('+CGLA: 10,"bf20019000"'); ECode = 0; Data = 'BF20019000'; After = @(, @(1, 1)) }
        @{ Name = 'a profile switch: 910B'; Function = 'transmit'; Parameter = '81E2910003BF3100'; Pairs = @(, @(1, 1)); Status = 'OK'; Lines = @('+CIREPI: 0', '+CGLA: 16,"BF3103800100910B"'); ECode = 0; Data = 'BF3103800100910B'; After = @(, @(1, 1)) }
        @{ Name = 'an error'; Function = 'transmit'; Parameter = '81E2910003BF2000'; Pairs = @(, @(1, 1)); Status = 'CmeError'; Lines = @(); ECode = -1; Data = $null; After = @(, @(1, 1)) }
        @{ Name = 'OK without a response'; Function = 'transmit'; Parameter = '81E2910003BF2000'; Pairs = @(, @(1, 1)); Status = 'OK'; Lines = @(); ECode = -1; Data = $null; After = @(, @(1, 1)) }
    ) {
        $bridge = Get-TestBridge -Pair $Pairs
        $before = $bridge | ConvertTo-Json -Depth 4
        $request = [pscustomobject]@{ Kind = 'Apdu'; Function = $Function; Parameter = $Parameter }
        $response = [pscustomobject]@{ Status = $Status; Lines = [string[]]$Lines; ErrorCode = $null }
        $next = Resolve-LpacApduAnswer -Request $request -Bridge $bridge -Response $response
        $next.Answer.ECode | Should -Be $ECode
        $next.Answer.Data | Should -Be $Data
        @($next.Bridge.Channels | ForEach-Object { "$($_.Channel):$($_.Session)" }) | Should -Be @($After | ForEach-Object { "$($_[0]):$($_[1])" })
        # The state given is left as it was.
        $bridge | ConvertTo-Json -Depth 4 | Should -Be $before
    }

    It 'a session with no channel number free stays, to be closed' {
        $bridge = Get-TestBridge -Pair @(1..15 | ForEach-Object { , @($_, $_) })
        $next = Resolve-LpacApduAnswer -Request ([pscustomobject]@{ Function = 'logic_channel_open'; Parameter = 'A000000087' }) -Bridge $bridge -Response ([pscustomobject]@{ Status = 'OK'; Lines = @('16') })
        $next.Answer.ECode | Should -Be -1
        $orphan = @($next.Bridge.Channels)[-1]
        $orphan.Channel | Should -BeNullOrEmpty
        $orphan.Session | Should -Be 16
    }
}

Describe 'ConvertTo-LpacAnswerLine' {
    It '<Name>' -ForEach @(
        @{ Name = 'an ecode alone'; ECode = 0; Data = $null; Line = '{"type":"apdu","payload":{"ecode":0}}' }
        @{ Name = 'a channel number'; ECode = 2; Data = $null; Line = '{"type":"apdu","payload":{"ecode":2}}' }
        @{ Name = 'a failure'; ECode = -1; Data = $null; Line = '{"type":"apdu","payload":{"ecode":-1}}' }
        @{ Name = 'a response'; ECode = 0; Data = 'BF20019000'; Line = '{"type":"apdu","payload":{"ecode":0,"data":"BF20019000"}}' }
    ) {
        ConvertTo-LpacAnswerLine -Answer ([pscustomobject]@{ ECode = $ECode; Data = $Data }) | Should -BeExactly $Line
    }
}

Describe 'Resolve-LpacHttpRequest' {
    It 'takes <Name>' -ForEach @(
        @{ Name = 'initiateAuthentication'; Url = 'https://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication'; Body = '7B7D'; HostName = 'smdp.example.com' }
        @{ Name = 'authenticateClient'; Url = 'https://smdp.example.com/gsma/rsp2/es9plus/authenticateClient'; Body = ''; HostName = 'smdp.example.com' }
        @{ Name = 'getBoundProfilePackage'; Url = 'https://smdp.example.com/gsma/rsp2/es9plus/getBoundProfilePackage'; Body = '00'; HostName = 'smdp.example.com' }
        @{ Name = 'cancelSession'; Url = 'https://smdp.example.com/gsma/rsp2/es9plus/cancelSession'; Body = '00'; HostName = 'smdp.example.com' }
        @{ Name = 'handleNotification'; Url = 'https://smdp.example.com/gsma/rsp2/es9plus/handleNotification'; Body = '00'; HostName = 'smdp.example.com' }
        @{ Name = 'a host in capitals, read in lower case'; Url = 'https://RSP.Example.ORG/gsma/rsp2/es9plus/initiateAuthentication'; Body = ''; HostName = 'rsp.example.org' }
    ) {
        $request = Resolve-LpacHttpRequest -Request ([pscustomobject]@{ Url = $Url; Body = $Body; Headers = [string[]]@('User-Agent: gsma-rsp-lpad', 'X-Admin-Protocol: gsma/rsp/v2.2.0', 'Content-Type: application/json') })
        $request.Problem | Should -BeNullOrEmpty
        $request.Host | Should -Be $HostName
        [Convert]::ToHexString($request.Body) | Should -Be $Body
        @($request.Headers.Keys) | Should -Be @('User-Agent', 'X-Admin-Protocol', 'Content-Type')
        $request.Headers['X-Admin-Protocol'] | Should -Be 'gsma/rsp/v2.2.0'
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'plain HTTP'; Url = 'http://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication'; Body = ''; Header = 'User-Agent: gsma-rsp-lpad'; Problem = 'Url' }
        @{ Name = 'a port'; Url = 'https://smdp.example.com:8443/gsma/rsp2/es9plus/initiateAuthentication'; Body = ''; Header = 'User-Agent: gsma-rsp-lpad'; Problem = 'Url' }
        @{ Name = 'an address for a host'; Url = 'https://192.0.2.10/gsma/rsp2/es9plus/initiateAuthentication'; Body = ''; Header = 'User-Agent: gsma-rsp-lpad'; Problem = 'Url' }
        @{ Name = 'a host without a domain'; Url = 'https://localhost/gsma/rsp2/es9plus/initiateAuthentication'; Body = ''; Header = 'User-Agent: gsma-rsp-lpad'; Problem = 'Url' }
        @{ Name = 'a user in the address'; Url = 'https://me@smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication'; Body = ''; Header = 'User-Agent: gsma-rsp-lpad'; Problem = 'Url' }
        @{ Name = 'another function'; Url = 'https://smdp.example.com/gsma/rsp2/es9plus/getProfile'; Body = ''; Header = 'User-Agent: gsma-rsp-lpad'; Problem = 'Url' }
        @{ Name = 'a query'; Url = 'https://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication?x=1'; Body = ''; Header = 'User-Agent: gsma-rsp-lpad'; Problem = 'Url' }
        @{ Name = 'a body that is not hexadecimal'; Url = 'https://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication'; Body = '7B7'; Header = 'User-Agent: gsma-rsp-lpad'; Problem = 'Body' }
        @{ Name = 'another header'; Url = 'https://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication'; Body = ''; Header = 'Authorization: x'; Problem = 'Header' }
        @{ Name = 'a header without a value'; Url = 'https://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication'; Body = ''; Header = 'User-Agent:'; Problem = 'Header' }
    ) {
        (Resolve-LpacHttpRequest -Request ([pscustomobject]@{ Url = $Url; Body = $Body; Headers = [string[]]@($Header) })).Problem | Should -Be $Problem
    }

    It 'reads lpac''s line whole' {
        $read = ConvertFrom-LpacLine -Line '{"type":"http","payload":{"url":"https://smdp.example.com/gsma/rsp2/es9plus/handleNotification","tx":"7b7d","headers":["Content-Type: application/json"]}}'
        $read.Body | Should -Be '7B7D'
        $read.Headers | Should -Be @('Content-Type: application/json')
        (Resolve-LpacHttpRequest -Request $read).Problem | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-LpacHttpAnswerLine' {
    It '<Name>' -ForEach @(
        @{ Name = 'an answer'; Status = 200; Body = @(0x7B, 0x7D); Line = '{"type":"http","payload":{"rcode":200,"rx":"7B7D"}}' }
        @{ Name = 'no content'; Status = 204; Body = @(); Line = '{"type":"http","payload":{"rcode":204,"rx":""}}' }
        @{ Name = 'no answer'; Status = 0; Body = $null; Line = '{"type":"http","payload":{"rcode":0,"rx":""}}' }
    ) {
        ConvertTo-LpacHttpAnswerLine -Status $Status -Body ([byte[]]@($Body)) | Should -BeExactly $Line
    }
}

Describe 'Get-EsimCiRoot' {
    It 'is the GSMA''s production root, the one our eUICC trusts (AT-COMMANDS section 8)' {
        $roots = Get-EsimCiRoot
        $roots.Count | Should -Be 1
        [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($roots[0].RawData)) | Should -Be '5E3E91FD454327C3AF5D32A7A73BBC59FE43AA7D85FD32D5DB44423F80A56BB3'
        $roots[0].Subject | Should -Be 'CN=GSM Association - RSP2 Root CI1, O=GSM Association'
        ($roots[0].Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension] }).SubjectKeyIdentifier | Should -Be '81370F5125D0B1D408D4C3B232E6D25E795BEBFB'
    }
}

Describe 'The SM-DP+ certificate check' {
    BeforeAll {
        # A CI of the test's own, a server certificate it issues, and another CI.
        function Get-TestCa {
            param([string] $Name)
            $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$Name", $key, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
            $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
            $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new('KeyCertSign, CrlSign', $true))
            $request.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddYears(5))
        }
        $script:ci = Get-TestCa -Name 'Test CI'
        $script:otherCi = Get-TestCa -Name 'Other CI'
        $key = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=smdp.example.com', $key, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $names = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $names.AddDnsName('smdp.example.com')
        $request.CertificateExtensions.Add($names.Build())
        $script:server = $request.Create($script:ci, [DateTimeOffset]::Now.AddHours(-1), [DateTimeOffset]::Now.AddYears(1), [byte[]]@(1, 2, 3, 4))
        $script:roots = { param($certificate) $c = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new(); [void]$c.Add($certificate); , $c }
    }

    It '<Name>' -ForEach @(
        @{ Name = 'a certificate Windows trusts is taken'; Root = 'other'; Errors = 'None'; Taken = $true }
        @{ Name = 'one that chains to the CI given is taken'; Root = 'ci'; Errors = 'RemoteCertificateChainErrors'; Taken = $true }
        @{ Name = 'one that chains to another CI is refused'; Root = 'other'; Errors = 'RemoteCertificateChainErrors'; Taken = $false }
        @{ Name = 'one for another host is refused, even from the CI'; Root = 'ci'; Errors = 'RemoteCertificateChainErrors, RemoteCertificateNameMismatch'; Taken = $false }
        @{ Name = 'none is refused'; Root = 'ci'; Errors = 'RemoteCertificateNotAvailable'; Taken = $false }
    ) {
        $root = if ($Root -eq 'ci') { $script:ci } else { $script:otherCi }
        $certificate = if ($Errors -eq 'RemoteCertificateNotAvailable') { $null } else { $script:server }
        [FibocomFm350.EsimHttp]::Validate((& $script:roots $root), $certificate, $null, [System.Net.Security.SslPolicyErrors]$Errors) | Should -Be $Taken
    }
}

Describe 'Invoke-EsimHttpRequest, on this computer only' {
    It 'says the network failed when nothing listens' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()
        $request = [pscustomobject]@{ Uri = [uri]"https://127.0.0.1:$port/gsma/rsp2/es9plus/initiateAuthentication"; Body = [byte[]]@(0x7B, 0x7D); Headers = [ordered]@{ 'Content-Type' = 'application/json' } }
        $reply = Invoke-EsimHttpRequest -Request $request -TimeoutMs 5000
        $reply.Status | Should -Be 0
        $reply.Failure | Should -Be 'Network'
    }

    It 'posts the body with lpac''s headers, and reads the answer' {
        # A server of one request, over plain HTTP: it answers with what it received.
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            $server = Start-ThreadJob -ScriptBlock {
                # $using: takes a variable alone, never a member of it.
                $listening = $using:listener
                $client = $listening.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 10000
                    $received = [System.Collections.Generic.List[byte]]::new()
                    $buffer = [byte[]]::new(4096)
                    do {
                        $count = $stream.Read($buffer, 0, $buffer.Length)
                        $received.AddRange([byte[]]$buffer[0..($count - 1)])
                        $text = [System.Text.Encoding]::ASCII.GetString($received.ToArray())
                        $end = $text.IndexOf("`r`n`r`n")
                        $length = if ($text -match '(?im)^Content-Length:\s*(\d+)') { [int]$Matches[1] } else { 0 }
                    } while ($count -gt 0 -and ($end -lt 0 -or $received.Count -lt $end + 4 + $length))
                    $echo = [System.Text.Encoding]::ASCII.GetBytes($text)
                    $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($echo.Length)`r`nConnection: close`r`n`r`n")
                    $stream.Write($head, 0, $head.Length)
                    $stream.Write($echo, 0, $echo.Length)
                }
                finally {
                    $client.Dispose()
                }
            }
            $request = [pscustomobject]@{
                Uri     = [uri]"http://127.0.0.1:$port/gsma/rsp2/es9plus/initiateAuthentication"
                Body    = [System.Text.Encoding]::ASCII.GetBytes('{"a":1}')
                Headers = [ordered]@{ 'User-Agent' = 'gsma-rsp-lpad'; 'X-Admin-Protocol' = 'gsma/rsp/v2.2.0'; 'Content-Type' = 'application/json' }
            }
            $reply = Invoke-EsimHttpRequest -Request $request -TimeoutMs 10000
            # Stopped first: a server still waiting for its client is let go, never waited on.
            $listener.Stop()
            [void](Wait-Job -Job $server -Timeout 15)
            Remove-Job -Job $server -Force
            $reply.Failure | Should -BeNullOrEmpty
            $reply.Status | Should -Be 200
            $echo = [System.Text.Encoding]::ASCII.GetString($reply.Body)
            $echo | Should -Match '^POST /gsma/rsp2/es9plus/initiateAuthentication HTTP/1\.1'
            $echo | Should -Match '(?m)^User-Agent: gsma-rsp-lpad\r$'
            $echo | Should -Match '(?m)^X-Admin-Protocol: gsma/rsp/v2\.2\.0\r$'
            $echo | Should -Match '(?m)^Content-Type: application/json\r$'
            $echo | Should -Not -Match '(?mi)^Cookie:'
            $echo | Should -Match '\{"a":1\}$'
        }
        finally {
            $listener.Stop()
        }
    }

    It 'gives up after its time, beating meanwhile, when the server never answers' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            $request = [pscustomobject]@{ Uri = [uri]"https://127.0.0.1:$port/gsma/rsp2/es9plus/initiateAuthentication"; Body = [byte[]]@(); Headers = [ordered]@{} }
            $beats = [System.Collections.Generic.List[int]]::new()
            $reply = Invoke-EsimHttpRequest -Request $request -TimeoutMs 2500 -Beat { $beats.Add(1) }
            $reply.Failure | Should -Be 'Timeout'
            $beats.Count | Should -BeGreaterThan 0
        }
        finally {
            $listener.Stop()
        }
    }

    It 'gives the request up at once when its beat throws: the run is stopping' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            $request = [pscustomobject]@{ Uri = [uri]"https://127.0.0.1:$port/gsma/rsp2/es9plus/initiateAuthentication"; Body = [byte[]]@(); Headers = [ordered]@{} }
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $reply = Invoke-EsimHttpRequest -Request $request -TimeoutMs 60000 -Beat { throw [System.OperationCanceledException]::new('stopping') }
            $clock.ElapsedMilliseconds | Should -BeLessThan 5000
            $reply.Status | Should -Be 0
            $reply.Failure | Should -Not -BeNullOrEmpty
        }
        finally {
            $listener.Stop()
        }
    }
}

Describe 'ConvertFrom-AtLogicalChannel' {
    It '<Name>' -ForEach @(
        @{ Name = 'the ID alone, as the FM350 answers'; Lines = @('1'); Session = 1 }
        @{ Name = 'with blanks'; Lines = @(' 2 '); Session = 2 }
        @{ Name = 'with a prefix'; Lines = @('+CCHO: 3'); Session = 3 }
        @{ Name = 'after a code of the modem''s'; Lines = @('+CIREPI: 0', '4'); Session = 4 }
        @{ Name = 'nothing'; Lines = @(); Session = $null }
        @{ Name = 'not a number'; Lines = @('A'); Session = $null }
    ) {
        ConvertFrom-AtLogicalChannel -Lines $Lines | Should -Be $Session
    }
}

Describe 'ConvertFrom-AtGenericAccess' {
    It '<Name>' -ForEach @(
        @{ Name = 'a response, quoted'; Lines = @('+CGLA: 4,"9000"'); Data = '9000' }
        @{ Name = 'lower case read as upper'; Lines = @('+CGLA: 10,"bf20019000"'); Data = 'BF20019000' }
        @{ Name = 'unquoted'; Lines = @('+CGLA: 4,9000'); Data = '9000' }
        @{ Name = 'among other lines'; Lines = @('+ESIMS: 0,1', '+CGLA: 8,"61109000"'); Data = '61109000' }
        @{ Name = 'a length that doesn''t match'; Lines = @('+CGLA: 6,"9000"'); Data = $null }
        @{ Name = 'one byte: no status word'; Lines = @('+CGLA: 2,"90"'); Data = $null }
        @{ Name = 'an odd number of digits'; Lines = @('+CGLA: 5,"90001"'); Data = $null }
        @{ Name = 'none'; Lines = @(); Data = $null }
    ) {
        ConvertFrom-AtGenericAccess -Lines $Lines | Should -Be $Data
    }
}

Describe 'ConvertFrom-EsimActivationCode' {
    It '<Name>' -ForEach @(
        @{ Name = 'a code'; Text = 'LPA:1$smdp.example.com$ABC-123'; Code = 'LPA:1$smdp.example.com$ABC-123'; Address = 'smdp.example.com'; Confirmation = $false; Problem = $null }
        @{ Name = 'without LPA:'; Text = '1$smdp.example.com$ABC-123'; Code = 'LPA:1$smdp.example.com$ABC-123'; Address = 'smdp.example.com'; Confirmation = $false; Problem = $null }
        @{ Name = 'lpa: in lower case, blanks around'; Text = '  lpa:1$smdp.example.com$ABC  '; Code = 'LPA:1$smdp.example.com$ABC'; Address = 'smdp.example.com'; Confirmation = $false; Problem = $null }
        @{ Name = 'no matching ID'; Text = 'LPA:1$smdp.example.com$'; Code = 'LPA:1$smdp.example.com$'; Address = 'smdp.example.com'; Confirmation = $false; Problem = $null }
        @{ Name = 'an OID'; Text = 'LPA:1$smdp.example.com$ABC$1.2.3'; Code = 'LPA:1$smdp.example.com$ABC$1.2.3'; Address = 'smdp.example.com'; Confirmation = $false; Problem = $null }
        @{ Name = 'a confirmation code required'; Text = 'LPA:1$smdp.example.com$ABC$$1'; Code = 'LPA:1$smdp.example.com$ABC$$1'; Address = 'smdp.example.com'; Confirmation = $true; Problem = $null }
        @{ Name = 'not required'; Text = 'LPA:1$smdp.example.com$ABC$$0'; Code = 'LPA:1$smdp.example.com$ABC$$0'; Address = 'smdp.example.com'; Confirmation = $false; Problem = $null }
        @{ Name = 'empty'; Text = ''; Code = $null; Address = $null; Confirmation = $false; Problem = 'Empty' }
        @{ Name = 'LPA: alone'; Text = 'LPA:'; Code = $null; Address = $null; Confirmation = $false; Problem = 'Empty' }
        @{ Name = 'another format'; Text = 'LPA:2$smdp.example.com$ABC'; Code = $null; Address = 'smdp.example.com'; Confirmation = $false; Problem = 'Format' }
        @{ Name = 'an address alone'; Text = 'LPA:1$smdp.example.com'; Code = $null; Address = 'smdp.example.com'; Confirmation = $false; Problem = 'Format' }
        @{ Name = 'not a code'; Text = 'hello'; Code = $null; Address = $null; Confirmation = $false; Problem = 'Format' }
        @{ Name = 'an address with a path'; Text = 'LPA:1$smdp.example.com/x$ABC'; Code = $null; Address = 'smdp.example.com/x'; Confirmation = $false; Problem = 'Address' }
        @{ Name = 'an address with a port'; Text = 'LPA:1$smdp.example.com:8443$ABC'; Code = $null; Address = 'smdp.example.com:8443'; Confirmation = $false; Problem = 'Address' }
        @{ Name = 'a host without a domain'; Text = 'LPA:1$localhost$ABC'; Code = $null; Address = 'localhost'; Confirmation = $false; Problem = 'Address' }
        @{ Name = 'an address for a host'; Text = 'LPA:1$192.0.2.10$ABC'; Code = $null; Address = '192.0.2.10'; Confirmation = $false; Problem = 'Address' }
        @{ Name = 'a matching ID with a blank'; Text = 'LPA:1$smdp.example.com$AB C'; Code = $null; Address = 'smdp.example.com'; Confirmation = $false; Problem = 'MatchingId' }
        @{ Name = 'a matching ID with a quote'; Text = 'LPA:1$smdp.example.com$AB"C'; Code = $null; Address = 'smdp.example.com'; Confirmation = $false; Problem = 'MatchingId' }
    ) {
        $read = ConvertFrom-EsimActivationCode -Text $Text
        $read.Code | Should -Be $Code
        $read.Address | Should -Be $Address
        $read.ConfirmationRequired | Should -Be $Confirmation
        $read.Problem | Should -Be $Problem
    }
}

Describe 'Get-LpacArgument' {
    It '<Operation>: <Expected>' -ForEach @(
        @{ Operation = 'ChipInfo'; ProfileId = ''; Nickname = ''; Code = ''; Confirmation = ''; Expected = 'chip|info' }
        @{ Operation = 'ProfileList'; ProfileId = ''; Nickname = ''; Code = ''; Confirmation = ''; Expected = 'profile|list' }
        @{ Operation = 'EnableProfile'; ProfileId = 'a0000005591010ffffffff8900001000'; Nickname = ''; Code = ''; Confirmation = ''; Expected = 'profile|enable|A0000005591010FFFFFFFF8900001000|1' }
        @{ Operation = 'DisableProfile'; ProfileId = 'A0000005591010FFFFFFFF8900001000'; Nickname = ''; Code = ''; Confirmation = ''; Expected = 'profile|disable|A0000005591010FFFFFFFF8900001000|1' }
        @{ Operation = 'DeleteProfile'; ProfileId = 'A0000005591010FFFFFFFF8900001000'; Nickname = ''; Code = ''; Confirmation = ''; Expected = 'profile|delete|A0000005591010FFFFFFFF8900001000' }
        @{ Operation = 'SetNickname'; ProfileId = '8900100000000000000'; Nickname = 'Lavoro è "mio" $x'; Code = ''; Confirmation = ''; Expected = 'profile|nickname|8900100000000000000|Lavoro è "mio" $x' }
        @{ Operation = 'SetNickname'; ProfileId = '89001000000000000000'; Nickname = ''; Code = ''; Confirmation = ''; Expected = 'profile|nickname|89001000000000000000' }
        @{ Operation = 'SetNickname'; ProfileId = '8900100000000000000'; Nickname = 'Travel 🇮🇹'; Code = ''; Confirmation = ''; Expected = 'profile|nickname|8900100000000000000|Travel 🇮🇹' }
        @{ Operation = 'SetNickname'; ProfileId = '8900100000000000000'; Nickname = "Family $([char]::ConvertFromUtf32(0x1F468))$([char]0x200D)$([char]::ConvertFromUtf32(0x1F467))"; Code = ''; Confirmation = ''; Expected = "profile|nickname|8900100000000000000|Family $([char]::ConvertFromUtf32(0x1F468))$([char]0x200D)$([char]::ConvertFromUtf32(0x1F467))" }
        @{ Operation = 'DownloadProfile'; ProfileId = ''; Nickname = ''; Code = '1$smdp.example.com$ABC-123'; Confirmation = ''; Expected = 'profile|download|-a|LPA:1$smdp.example.com$ABC-123' }
        @{ Operation = 'DownloadProfile'; ProfileId = ''; Nickname = ''; Code = 'LPA:1$smdp.example.com$ABC$$1'; Confirmation = '1234'; Expected = 'profile|download|-a|LPA:1$smdp.example.com$ABC$$1|-c|1234' }
        @{ Operation = 'ListNotifications'; ProfileId = ''; Nickname = ''; Code = ''; Confirmation = ''; Expected = 'notification|list' }
        @{ Operation = 'ProcessNotifications'; ProfileId = ''; Nickname = ''; Code = ''; Confirmation = ''; Expected = 'notification|process|-a|-r' }
    ) {
        $arguments = Get-LpacArgument -Operation $Operation -ProfileId $ProfileId -Nickname $Nickname -ActivationCode $Code -ConfirmationCode $Confirmation
        $arguments -join '|' | Should -BeExactly $Expected
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'an ICCID to enable (it takes the AID)'; Operation = 'EnableProfile'; ProfileId = '8900100000000000000'; Nickname = ''; Code = '' }
        @{ Name = 'no profile to delete'; Operation = 'DeleteProfile'; ProfileId = ''; Nickname = ''; Code = '' }
        @{ Name = 'an AID to nickname (it takes the ICCID)'; Operation = 'SetNickname'; ProfileId = 'A0000005591010FFFFFFFF8900001000'; Nickname = 'x'; Code = '' }
        @{ Name = 'a nickname of 65 bytes'; Operation = 'SetNickname'; ProfileId = '8900100000000000000'; Nickname = ('a' * 65); Code = '' }
        @{ Name = 'a nickname of 33 two-byte letters'; Operation = 'SetNickname'; ProfileId = '8900100000000000000'; Nickname = ('è' * 33); Code = '' }
        @{ Name = 'a nickname with a line end'; Operation = 'SetNickname'; ProfileId = '8900100000000000000'; Nickname = "a`nb"; Code = '' }
        @{ Name = 'a nickname with a tab'; Operation = 'SetNickname'; ProfileId = '8900100000000000000'; Nickname = "a`tb"; Code = '' }
        @{ Name = 'a code that is not one'; Operation = 'DownloadProfile'; ProfileId = ''; Nickname = ''; Code = 'hello' }
        @{ Name = 'no code'; Operation = 'DownloadProfile'; ProfileId = ''; Nickname = ''; Code = '' }
    ) {
        { Get-LpacArgument -Operation $Operation -ProfileId $ProfileId -Nickname $Nickname -ActivationCode $Code -ErrorAction Stop } | Should -Throw
    }

    It 'takes a nickname of 64 bytes' {
        (Get-LpacArgument -Operation SetNickname -ProfileId '8900100000000000000' -Nickname ('è' * 32))[3] | Should -Be ('è' * 32)
    }

    It 'has no operation for chip purge' {
        (Get-Command Get-LpacArgument).Parameters['Operation'].Attributes.ValidValues | Should -Not -Contain 'ChipPurge'
        (Get-Command Get-LpacArgument).Parameters['Operation'].Attributes.ValidValues -join ' ' | Should -Not -Match 'Purge'
    }
}

Describe 'ConvertFrom-LpacProfileList' {
    It 'reads each profile, the ICCID kept apart' {
        $data = ConvertFrom-Json -InputObject '[{"iccid":"8900100000000000000","isdpAid":"a0000005591010ffffffff8900002000","profileState":"disabled","profileNickname":null,"serviceProviderName":"Rohde & Schwarz","profileName":"R&S CMW500 3G_XOR","iconType":"none","icon":null,"profileClass":"test"},{"iccid":"89001000000000000000","isdpAid":"A0000005591010FFFFFFFF8900001000","profileState":"enabled","profileNickname":"Travel","serviceProviderName":"Provider","profileName":"Name","iconType":"png","icon":"iVBO","profileClass":"operational"}]'
        $profiles = @(ConvertFrom-LpacProfileList -Data $data)
        $profiles.Count | Should -Be 2
        $profiles[0].Aid | Should -Be 'A0000005591010FFFFFFFF8900002000'
        $profiles[0].Iccid | Should -Be '8900100000000000000'
        $profiles[0].State | Should -Be 'Disabled'
        $profiles[0].Nickname | Should -BeNullOrEmpty
        $profiles[0].Provider | Should -Be 'Rohde & Schwarz'
        $profiles[0].Class | Should -Be 'Test'
        $profiles[1].State | Should -Be 'Enabled'
        $profiles[1].Nickname | Should -Be 'Travel'
        $profiles[1].Class | Should -Be 'Operational'
    }

    It 'reads <Name>' -ForEach @(
        @{ Name = 'an unknown state and class as Unknown'; Json = '[{"isdpAid":"A0000005591010FFFFFFFF8900001000","profileState":"weird","profileClass":"other"}]'; Count = 1; State = 'Unknown'; Class = 'Unknown' }
        @{ Name = 'an entry without its AID: left out'; Json = '[{"iccid":"8900100000000000000","profileState":"enabled"}]'; Count = 0; State = $null; Class = $null }
        @{ Name = 'an empty list'; Json = '[]'; Count = 0; State = $null; Class = $null }
    ) {
        $profiles = @(ConvertFrom-LpacProfileList -Data (ConvertFrom-Json -InputObject $Json -NoEnumerate))
        $profiles.Count | Should -Be $Count
        if ($Count) {
            $profiles[0].State | Should -Be $State
            $profiles[0].Class | Should -Be $Class
        }
    }

    It 'reads no data as no profile' {
        @(ConvertFrom-LpacProfileList -Data $null).Count | Should -Be 0
    }
}

Describe 'ConvertFrom-LpacChipInfo' {
    It 'reads the eUICC''s facts' {
        $data = ConvertFrom-Json -InputObject '{"eidValue":"89001000000000000000000000000000","EuiccConfiguredAddresses":{"defaultDpAddress":null,"rootDsAddress":"lpa.ds.gsma.com"},"EUICCInfo2":{"profileVersion":"2.3.1","svn":"2.2.2","euiccFirmwareVer":"66.99.0","extCardResource":{"installedApplication":1,"freeNonVolatileMemory":391000,"freeVolatileMemory":5970},"euiccCiPKIdListForVerification":["81370f5125d0b1d408d4c3b232e6d25e795bebfb"]}}'
        $info = ConvertFrom-LpacChipInfo -Data $data
        $info.Eid | Should -Be '89001000000000000000000000000000'
        $info.DefaultAddress | Should -BeNullOrEmpty
        $info.Specification | Should -Be '2.2.2'
        $info.Firmware | Should -Be '66.99.0'
        $info.FreeMemory | Should -Be 391000
        $info.CiKeys | Should -Be @('81370F5125D0B1D408D4C3B232E6D25E795BEBFB')
    }

    It 'reads what is missing as unknown' {
        $info = ConvertFrom-LpacChipInfo -Data (ConvertFrom-Json -InputObject '{"eidValue":"89001000000000000000000000000000"}')
        $info.Specification | Should -BeNullOrEmpty
        $info.FreeMemory | Should -BeNullOrEmpty
        @($info.CiKeys).Count | Should -Be 0
    }
}

Describe 'ConvertFrom-LpacNotificationList' {
    It 'reads each notification without its ICCID' {
        $data = ConvertFrom-Json -InputObject '[{"seqNumber":178,"profileManagementOperation":"install","notificationAddress":"smdp.example.com","iccid":"8900100000000000000"},{"profileManagementOperation":"enable"}]'
        $notifications = @(ConvertFrom-LpacNotificationList -Data $data)
        $notifications.Count | Should -Be 1
        $notifications[0].Sequence | Should -Be 178
        $notifications[0].Operation | Should -Be 'install'
        $notifications[0].Address | Should -Be 'smdp.example.com'
        $notifications[0].PSObject.Properties.Name | Should -Not -Contain 'Iccid'
    }
}

Describe 'Invoke-LpacOperation' {
    BeforeEach {
        $script:device = Get-ChannelModem
    }

    AfterEach {
        Close-AtChannel -Channel $script:device.Channel
    }

    It 'carries one run: connect, a channel, two APDUs, its close, disconnect' {
        $script:device.Modem.SetAnswer('AT+CGLA=1,16,"81E2910003BF2000"', @('+CGLA: 10,"BF20019000"', 'OK'))
        $script:device.Modem.SetAnswer('AT+CGLA=1,10,"81C0000010"', @('+CGLA: 4,"9000"', 'OK'))
        $lpac = Get-ScriptedLpac -Request @(
            (Get-RequestLine -Function connect)
            (Get-RequestLine -Function logic_channel_open -Parameter $script:isdR)
            (Get-RequestLine -Function transmit -Parameter '81E2910003BF2000')
            (Get-RequestLine -Function transmit -Parameter '81C0000010')
            (Get-RequestLine -Function logic_channel_close -Parameter '01')
            (Get-RequestLine -Function disconnect)
        ) -Result '{"type":"lpa","payload":{"code":0,"message":"success","data":{"svn":"2.2.2"}}}'
        $run = Invoke-LpacOperation -Channel $script:device.Channel -Lpac $lpac -TimeoutMs 10000
        $run.Outcome | Should -Be 'Done'
        $run.Code | Should -Be 0
        $run.Data.svn | Should -Be '2.2.2'
        $run.Requests | Should -Be 6
        $lpac.Answers | Should -Be @(
            '{"type":"apdu","payload":{"ecode":0}}'
            '{"type":"apdu","payload":{"ecode":1}}'
            '{"type":"apdu","payload":{"ecode":0,"data":"BF20019000"}}'
            '{"type":"apdu","payload":{"ecode":0,"data":"9000"}}'
            '{"type":"apdu","payload":{"ecode":0}}'
            '{"type":"apdu","payload":{"ecode":0}}'
        )
        $lpac.Disposed | Should -BeTrue
        @($script:device.Modem.Received | Where-Object { $_ -like 'AT+CC*' -or $_ -like 'AT+CGLA*' }) | Should -Be @(
            "AT+CCHO=`"$script:isdR`"", 'AT+CGLA=1,16,"81E2910003BF2000"', 'AT+CGLA=1,10,"81C0000010"', 'AT+CCHC=1')
    }

    It 'notes the progress, and hands the failure''s reason on' {
        $lpac = Get-ScriptedLpac -Before @('{"type":"progress","payload":{"code":0,"message":"es10b_get_euicc_challenge_and_info","data":"smdp.example.com"}}') `
            -Result '{"type":"lpa","payload":{"code":-1,"message":"es9p_initiate_authentication","data":"Profile not available"}}'
        $run = Invoke-LpacOperation -Channel $script:device.Channel -Lpac $lpac -TimeoutMs 10000
        $run.Outcome | Should -Be 'Done'
        $run.Code | Should -Be -1
        $run.Message | Should -Be 'es9p_initiate_authentication'
        $run.Data | Should -Be 'Profile not available'
        $run.Steps | Should -Be @('es10b_get_euicc_challenge_and_info')
    }

    It 'closes a channel lpac left open' {
        $lpac = Get-ScriptedLpac -Request @(
            (Get-RequestLine -Function connect)
            (Get-RequestLine -Function logic_channel_open -Parameter $script:isdR)
        ) -NoResult
        $run = Invoke-LpacOperation -Channel $script:device.Channel -Lpac $lpac -TimeoutMs 10000
        $run.Outcome | Should -Be 'NoResult'
        $script:device.Modem.Received | Should -Contain 'AT+CCHC=1'
    }

    It 'gives up after its timeout, stops lpac and closes its channel' {
        $lpac = Get-ScriptedLpac -Request @(
            (Get-RequestLine -Function connect)
            (Get-RequestLine -Function logic_channel_open -Parameter $script:isdR)
        ) -Hang
        $beats = [System.Collections.Generic.List[int]]::new()
        $run = Invoke-LpacOperation -Channel $script:device.Channel -Lpac $lpac -TimeoutMs 400 -Beat { $beats.Add(1) }
        $run.Outcome | Should -Be 'Timeout'
        $lpac.Disposed | Should -BeTrue
        $beats.Count | Should -BeGreaterThan 2
        $script:device.Modem.Received | Should -Contain 'AT+CCHC=1'
    }

    It 'stops when the worker is ending: lpac stopped, its channel closed' {
        $lpac = Get-ScriptedLpac -Request @(
            (Get-RequestLine -Function connect)
            (Get-RequestLine -Function logic_channel_open -Parameter $script:isdR)
        ) -Hang
        $asked = [System.Collections.Generic.List[int]]::new()
        $run = Invoke-LpacOperation -Channel $script:device.Channel -Lpac $lpac -TimeoutMs 60000 -Stop { $asked.Add(1); $asked.Count -gt 3 }
        $run.Outcome | Should -Be 'Stopped'
        $run.ElapsedMs | Should -BeLessThan 5000
        $lpac.Disposed | Should -BeTrue
        $script:device.Modem.Received | Should -Contain 'AT+CCHC=1'
    }

    It 'gives up a request for the network under way when the worker is ending' {
        $script:stopping = $false
        # Waits as Invoke-EsimHttpRequest does, beating, and fails as it does when the beat throws.
        $http = {
            try {
                for ($i = 0; $i -lt 500; $i++) {
                    $script:stopping = $i -ge 3
                    & $args[2]
                    Start-Sleep -Milliseconds 10
                }
                [pscustomobject]@{ Status = 200; Body = $null; Failure = $null }
            }
            catch [System.OperationCanceledException] {
                [pscustomobject]@{ Status = 0; Body = $null; Failure = 'Network' }
            }
        }
        $lpac = Get-ScriptedLpac -Request @('{"type":"http","payload":{"url":"https://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication","tx":"","headers":[]}}') -Hang
        $run = Invoke-LpacOperation -Channel $script:device.Channel -Lpac $lpac -TimeoutMs 60000 -Http $http -Stop { $script:stopping }
        $run.Outcome | Should -Be 'Stopped'
        $run.ElapsedMs | Should -BeLessThan 5000
        $lpac.Answers | Should -Be @('{"type":"http","payload":{"rcode":0,"rx":""}}')
    }

    It 'stops on a lost port, with nothing more sent' {
        $script:device.Modem.Script('AT+CGLA=1,16,"81E2910003BF2000"', @{ Vanish = $true; Lines = @() })
        $lpac = Get-ScriptedLpac -Request @(
            (Get-RequestLine -Function connect)
            (Get-RequestLine -Function logic_channel_open -Parameter $script:isdR)
            (Get-RequestLine -Function transmit -Parameter '81E2910003BF2000')
            (Get-RequestLine -Function logic_channel_close -Parameter '01')
        )
        $run = Invoke-LpacOperation -Channel $script:device.Channel -Lpac $lpac -TimeoutMs 10000
        $run.Outcome | Should -Be 'PortLost'
        $lpac.Answers.Count | Should -Be 2
        $script:device.Modem.Received | Should -Not -Contain 'AT+CCHC=1'
    }

    It 'sends a request for the network, checked, and hands the answer back' {
        $script:sent = [System.Collections.Generic.List[object]]::new()
        $http = { $script:sent.Add($args[0]); [pscustomobject]@{ Status = 200; Body = [System.Text.Encoding]::ASCII.GetBytes('{}'); Failure = $null } }
        $lpac = Get-ScriptedLpac -Request @('{"type":"http","payload":{"url":"https://SMDP.example.com/gsma/rsp2/es9plus/initiateAuthentication","tx":"7b7d","headers":["User-Agent: gsma-rsp-lpad","X-Admin-Protocol: gsma/rsp/v2.2.0","Content-Type: application/json"]}}')
        $run = Invoke-LpacOperation -Channel $script:device.Channel -Lpac $lpac -TimeoutMs 10000 -Http $http
        $run.HttpRequests | Should -Be 1
        $run.HttpFailure | Should -BeNullOrEmpty
        $lpac.Answers | Should -Be @('{"type":"http","payload":{"rcode":200,"rx":"7B7D"}}')
        $script:sent[0].Uri.AbsoluteUri | Should -Be 'https://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication'
        [System.Text.Encoding]::ASCII.GetString($script:sent[0].Body) | Should -Be '{}'
        $script:sent[0].Headers['Content-Type'] | Should -Be 'application/json'
    }

    It 'never sends a request that fails the check: <Name>' -ForEach @(
        @{ Name = 'another address'; Line = '{"type":"http","payload":{"url":"https://smdp.example.com/elsewhere","tx":"","headers":[]}}'; Failure = 'Url' }
        @{ Name = 'plain HTTP'; Line = '{"type":"http","payload":{"url":"http://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication","tx":"","headers":[]}}'; Failure = 'Url' }
        @{ Name = 'another header'; Line = '{"type":"http","payload":{"url":"https://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication","tx":"","headers":["Cookie: a=b"]}}'; Failure = 'Header smdp.example.com' }
    ) {
        $script:sent = [System.Collections.Generic.List[object]]::new()
        $http = { $script:sent.Add($args[0]); [pscustomobject]@{ Status = 200; Body = $null; Failure = $null } }
        $lpac = Get-ScriptedLpac -Request @($Line)
        $run = Invoke-LpacOperation -Channel $script:device.Channel -Lpac $lpac -TimeoutMs 10000 -Http $http
        $script:sent.Count | Should -Be 0
        $run.HttpFailure | Should -Be $Failure
        $lpac.Answers | Should -Be @('{"type":"http","payload":{"rcode":0,"rx":""}}')
    }

    It 'says a request that failed on the way, with its host' {
        $http = { [pscustomobject]@{ Status = 0; Body = $null; Failure = 'Certificate' } }
        $lpac = Get-ScriptedLpac -Request @('{"type":"http","payload":{"url":"https://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication","tx":"","headers":[]}}')
        $run = Invoke-LpacOperation -Channel $script:device.Channel -Lpac $lpac -TimeoutMs 10000 -Http $http
        $run.HttpFailure | Should -Be 'Certificate smdp.example.com'
        $lpac.Answers | Should -Be @('{"type":"http","payload":{"rcode":0,"rx":""}}')
    }
}

Describe 'ConvertFrom-AtSimSlot and ConvertFrom-AtSimType, on the device' {
    It 'reads slot 1 in use, the eUICC''s' {
        $slot = ConvertFrom-AtSimSlot -Lines (Get-FixtureAnswer -Name 'gtdualsim.esim.txt' -Folder device)
        $slot.Slot | Should -Be 1
        $slot.Name | Should -Be 'SUB2'
        $slot.Service | Should -Be 'NO SERVICE'
        ConvertFrom-AtSimType -Lines (Get-FixtureAnswer -Name 'simtype.esim.txt' -Folder device) | Should -Be 'Esim'
    }

    It 'reads slot 0 in use, a physical SIM' {
        (ConvertFrom-AtSimSlot -Lines (Get-FixtureAnswer -Name 'gtdualsim.lte.txt' -Folder device)).Slot | Should -Be 0
        ConvertFrom-AtSimType -Lines (Get-FixtureAnswer -Name 'simtype.usim.txt' -Folder device) | Should -Be 'Usim'
    }

    It 'reads <Name>' -ForEach @(
        @{ Name = 'no blank before the colon'; Lines = @('+GTDUALSIM: 0, "SUB1", "LTE"'); Slot = 0 }
        @{ Name = 'the slot alone'; Lines = @('+GTDUALSIM: 1'); Slot = 1 }
        @{ Name = 'nothing'; Lines = @(); Slot = $null }
    ) {
        $read = ConvertFrom-AtSimSlot -Lines $Lines
        if ($null -eq $Slot) { $read | Should -BeNullOrEmpty } else { $read.Slot | Should -Be $Slot }
    }

    It 'reads no type from <Name>' -ForEach @(
        @{ Name = 'another value'; Lines = @('+SIMTYPE: 2') }
        @{ Name = 'no answer'; Lines = @() }
    ) {
        ConvertFrom-AtSimType -Lines $Lines | Should -BeNullOrEmpty
    }
}

Describe 'The simulated eUICC' {
    BeforeEach {
        $script:device = New-SimulatedDevice -Scenario Online
        $script:device.Modem.Euicc.ResetMs = 0
        $script:channel = New-AtChannel -Transport $script:device.Open()
        [void](Initialize-AtChannel -Channel $script:channel -TimeoutMs 2000)
        $script:ask = { param($command) Invoke-AtCommand -Channel $script:channel -Command $command -TimeoutMs 2000 }
        $script:run = { param($operation, $option = @{}) Invoke-LpacOperation -Channel $script:channel -Lpac $script:device.StartLpac((Get-LpacArgument -Operation $operation @option)) -TimeoutMs 10000 }
    }

    AfterEach {
        Close-AtChannel -Channel $script:channel
    }

    It 'is on slot 1, out of reach while slot 0 is in use' {
        (& $script:ask 'AT+GTDUALSIM?').Lines | Should -Be @('+GTDUALSIM : 0, "SUB1", "LTE"')
        (& $script:ask 'AT+SIMTYPE?').Lines | Should -Be @('+SIMTYPE: 0')
        (& $script:ask 'AT+EID?').Lines | Should -Be @('+EID:')
        (& $script:ask 'AT+CPIN?').Lines | Should -Be @('+CPIN: READY')
        (& $script:ask "AT+CCHO=`"$script:isdR`"").Status | Should -Be 'CmeError'
        (& $script:run ProfileList).Code | Should -Be -1
    }

    It 'answers on slot 1: no profile enabled, its EID, its channels' {
        (& $script:ask 'AT+GTDUALSIM=1').Status | Should -Be 'OK'
        (& $script:ask 'AT+GTDUALSIM?').Lines | Should -Be @('+GTDUALSIM : 1, "SUB2", "NO SERVICE"')
        (& $script:ask 'AT+SIMTYPE?').Lines | Should -Be @('+SIMTYPE: 1')
        (& $script:ask 'AT+EID?').Lines | Should -Be @('+EID: "89001000000000000000000000000000"')
        (& $script:ask 'AT+CPIN?').Lines | Should -Be @('+CPIN: EMPTY_EUICC')
        (& $script:ask "AT+CCHO=`"$script:isdR`"").Lines | Should -Be @('1')
        (& $script:ask 'AT+CGLA=1,4,"9000"').Lines | Should -Be @('+CGLA: 4,"9000"')
        (& $script:ask 'AT+CGLA=1,6,"9000"').Status | Should -Be 'CmeError'
        (& $script:ask 'AT+CCHC=1').Status | Should -Be 'OK'
        (& $script:ask 'AT+CCHC=1').Status | Should -Be 'CmeError'
    }

    It 'enables a profile through lpac: a reset closes the channel, the SIM busy a while, then ready' {
        [void](& $script:ask 'AT+GTDUALSIM=1')
        $script:device.Modem.Euicc.ResetMs = 60000
        $run = & $script:run EnableProfile @{ ProfileId = 'A0000005591010FFFFFFFF8900002000' }
        $run.Outcome | Should -Be 'Done'
        $run.Code | Should -Be 0
        $script:device.Modem.Euicc.Profiles[0].State | Should -Be 'Enabled'
        @($script:device.Modem.Received | Where-Object { $_ -like 'AT+CCHC=*' }) | Should -Be @('AT+CCHC=1')
        (& $script:ask 'AT+CPIN?').ErrorCode | Should -Be 14
        & (Get-Module FibocomFm350) { param($euicc) $euicc.ResetUntil = 0 } $script:device.Modem.Euicc
        (& $script:ask 'AT+CPIN?').Lines | Should -Be @('+CPIN: READY')
        (& $script:ask 'AT+CGACT?').Lines | Should -BeNullOrEmpty
    }

    It 'refuses what the eUICC refuses: <Name>' -ForEach @(
        @{ Name = 'enabling an enabled profile'; Operation = 'EnableProfile'; Option = @{ ProfileId = 'A0000005591010FFFFFFFF8900002000' }; First = $true; Step = 'es10c_enable_profile'; Reason = 'profile not in disabled state' }
        @{ Name = 'disabling a disabled one'; Operation = 'DisableProfile'; Option = @{ ProfileId = 'A0000005591010FFFFFFFF8900002000' }; First = $false; Step = 'es10c_disable_profile'; Reason = 'profile not in enabled state' }
        @{ Name = 'deleting an enabled one'; Operation = 'DeleteProfile'; Option = @{ ProfileId = 'A0000005591010FFFFFFFF8900002000' }; First = $true; Step = 'es10c_delete_profile'; Reason = 'profile not in disabled state' }
        @{ Name = 'an AID it doesn''t have'; Operation = 'EnableProfile'; Option = @{ ProfileId = 'A0000005591010FFFFFFFF8900009900' }; First = $false; Step = 'es10c_enable_profile'; Reason = 'iccid or aid not found' }
        @{ Name = 'a nickname for an ICCID it doesn''t have'; Operation = 'SetNickname'; Option = @{ ProfileId = '89001000000000000000'; Nickname = 'x' }; First = $false; Step = 'es10c_set_nickname'; Reason = 'iccid not found' }
        @{ Name = 'a code with a bad format'; Operation = 'DownloadProfile'; Option = @{ ActivationCode = 'LPA:1$smdp.example.com$ABC$$1' }; First = $false; Step = 'confirmation_code'; Reason = 'required' }
        @{ Name = 'a server that refuses'; Operation = 'DownloadProfile'; Option = @{ ActivationCode = 'LPA:1$smdp.example.com$FAIL-1' }; First = $false; Step = 'es9p_initiate_authentication'; Reason = 'Profile not available' }
    ) {
        [void](& $script:ask 'AT+GTDUALSIM=1')
        if ($First) {
            $script:device.Modem.Euicc.Profiles[0].State = 'Enabled'
        }
        $run = & $script:run $Operation $Option
        $run.Outcome | Should -Be 'Done'
        $run.Code | Should -Be -1
        $run.Message | Should -Be $Step
        $run.Data | Should -Be $Reason
        @($script:device.Modem.Received | Where-Object { $_ -like 'AT+CCHC=*' }).Count | Should -Be 1
    }

    It 'sets and clears a nickname, deletes, downloads, and sends the notifications' {
        [void](& $script:ask 'AT+GTDUALSIM=1')
        $euicc = $script:device.Modem.Euicc
        (& $script:run SetNickname @{ ProfileId = '8900100000000000001'; Nickname = 'Laboratorio è' }).Code | Should -Be 0
        $euicc.Profiles[0].Nickname | Should -Be 'Laboratorio è'
        (& $script:run SetNickname @{ ProfileId = '8900100000000000001' }).Code | Should -Be 0
        $euicc.Profiles[0].Nickname | Should -BeNullOrEmpty
        $download = & $script:run DownloadProfile @{ ActivationCode = 'LPA:1$smdp.example.com$ABC-1' }
        $download.Code | Should -Be 0
        $download.Steps | Should -Contain 'es10b_load_bound_profile_package'
        $euicc.Profiles.Count | Should -Be 2
        $added = $euicc.Profiles[1]
        (& $script:run DeleteProfile @{ ProfileId = $added.Aid }).Code | Should -Be 0
        $euicc.Profiles.Count | Should -Be 1
        @(ConvertFrom-LpacNotificationList -Data (& $script:run ListNotifications).Data | ForEach-Object Operation) | Should -Be @('install', 'delete')
        (& $script:run ProcessNotifications).Code | Should -Be 0
        $euicc.Notifications.Count | Should -Be 0
    }
}

Describe 'The worker and the eSIM' {
    BeforeAll {
        $script:folder = Join-Path $TestDrive 'worker'
        New-Item -ItemType Directory -Path $script:folder -Force | Out-Null

        function Get-EsimWorker {
            param([string] $Scenario, [hashtable] $Extra = @{})
            $script:device = New-SimulatedDevice -Scenario $Scenario
            $script:device.Modem.Euicc.ResetMs = 0
            $script:link = New-ModemWorkerLink
            $worker = New-ModemWorker -Link $script:link -Simulation $script:device -DataFolder $script:folder @Extra
            for ($i = 0; $i -lt 3; $i++) { Invoke-ModemWorkerCycle -Worker $worker }
            $worker
        }

        function Invoke-EsimCommand {
            param([hashtable] $Worker, [string] $Kind, [hashtable] $Parameter = @{})
            $id = Send-ModemCommand -Link $Worker.Link -Kind $Kind -Parameter $Parameter
            Invoke-ModemWorkerCycle -Worker $Worker
            $Worker.Link['Snapshot'].Results | Where-Object Id -EQ $id
        }

        function ConvertTo-TestSecret {
            param([string] $Text)
            $secret = [securestring]::new()
            foreach ($character in $Text.ToCharArray()) { $secret.AppendChar($character) }
            $secret
        }
    }

    AfterEach {
        if ($script:worker) { Close-ModemWorker -Worker $script:worker }
        Get-ChildItem -LiteralPath $script:folder | Remove-Item -Recurse -Force
    }

    It 'tells an eSIM with no profile enabled from the other SIM states: blocked, its profiles read' {
        $script:worker = Get-EsimWorker -Scenario EsimEmpty
        $snapshot = $script:link['Snapshot']
        $snapshot.State | Should -Be 'Identified'
        $snapshot.Reason | Should -Be 'NoProfile'
        $snapshot.Blocked | Should -BeTrue
        $snapshot.Sim.State | Should -Be 'NoProfile'
        $snapshot.Esim.Slot | Should -Be 1
        $snapshot.Esim.SimType | Should -Be 'Esim'
        $snapshot.Esim.Specification | Should -Be '2.2.2'
        @($snapshot.Esim.Profiles).Count | Should -Be 1
        $snapshot.Esim.Profiles[0].State | Should -Be 'Disabled'
        $snapshot.Esim.Profiles[0].Class | Should -Be 'Test'
        $snapshot.Esim.Notifications | Should -Be 0
    }

    It 'carries the EID in its snapshot, for the window to show (decided 2026-10-04), and no ICCID' {
        $script:worker = Get-EsimWorker -Scenario Esim
        $snapshot = $script:link['Snapshot']
        $snapshot.Esim.Eid | Should -Be $script:device.Modem.Euicc.Eid
        $text = ($snapshot | ConvertTo-Json -Depth 8).Replace($snapshot.Esim.Eid, '<eid>')
        foreach ($iccid in @($script:device.Modem.Euicc.Profiles | ForEach-Object Iccid)) {
            $text | Should -Not -Match $iccid
        }
        $snapshot.Esim.Profiles[0].PSObject.Properties.Name | Should -Not -Contain 'Iccid'
    }

    It 'takes a slot switch left unanswered for one that may have happened: a maintenance window, the slot read again' {
        $script:worker = Get-EsimWorker -Scenario Esim
        $script:link['Snapshot'].Recovery.History.MaintenanceUntil | Should -BeNullOrEmpty
        # The modem switches, and its OK is lost.
        $script:device.Modem.Script('AT+GTDUALSIM=0', @{ NoFinal = $true })
        $outcome = Invoke-EsimCommand -Worker $script:worker -Kind SelectSimSlot -Parameter @{ Slot = 0 }
        $outcome.Result | Should -Be 'Failed'
        $outcome.Detail | Should -Be 'AT+GTDUALSIM=0 Timeout'
        $script:link['Snapshot'].Recovery.History.MaintenanceUntil | Should -Not -BeNullOrEmpty
        $script:worker.PassForced = $true
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].Esim.Slot | Should -Be 0 -Because 'the slot is read again, not kept from before'
    }

    It 'opens a maintenance window for a profile switch whose run failed: the eUICC may have switched all the same' {
        $script:worker = Get-EsimWorker -Scenario EsimEmpty
        $script:link['Snapshot'].Recovery.History.MaintenanceUntil | Should -BeNullOrEmpty
        # Every run fails from here: the enable's as an APDU answered too late would fail it.
        Mock -ModuleName FibocomFm350 Invoke-WorkerLpac { [pscustomobject]@{ Outcome = 'Done'; Code = -1; Message = 'es10c_enable_profile'; Data = ''; HttpFailure = $null } }
        $outcome = Invoke-EsimCommand -Worker $script:worker -Kind EnableProfile -Parameter @{ Aid = 'A0000005591010FFFFFFFF8900002000' }
        $outcome.Result | Should -Be 'Failed'
        $script:link['Snapshot'].Recovery.History.MaintenanceUntil | Should -Not -BeNullOrEmpty
    }

    It 'reads the slot again at the next pass when the modem left the read unanswered' {
        $script:device = New-SimulatedDevice -Scenario Esim
        $script:device.Modem.Euicc.ResetMs = 0
        $script:device.Modem.Script('AT+GTDUALSIM?', @{ Lines = @('OK'); NoFinal = $true })
        $script:link = New-ModemWorkerLink
        $script:worker = New-ModemWorker -Link $script:link -Simulation $script:device -DataFolder $script:folder
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:worker.SimSlotRead | Should -BeFalse
        $script:link['Snapshot'].Esim.Slot | Should -BeNullOrEmpty
        $script:worker.PassForced = $true
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].Esim.Slot | Should -Be 1
    }

    It 'reads the slot again when the user asks to read the eSIM' {
        $script:worker = Get-EsimWorker -Scenario Esim
        # Switched by another program meanwhile.
        [void]$script:device.Modem.Euicc.Answer('AT+GTDUALSIM=0', $script:device.Modem)
        (Invoke-EsimCommand -Worker $script:worker -Kind ReadEsim).Result | Should -Be 'NotEuicc'
        $script:link['Snapshot'].Esim.Slot | Should -Be 0
    }

    It 'starts no lpac once the worker is ending' {
        $script:worker = Get-EsimWorker -Scenario Esim
        $before = $script:device.Modem.Received.Count
        $script:link['Stop'] = $true
        $outcome = Invoke-EsimCommand -Worker $script:worker -Kind ReadEsim
        $outcome.Result | Should -Be 'Failed'
        $outcome.Detail | Should -Match 'Stopped'
        @($script:device.Modem.Received | Select-Object -Skip $before | Where-Object { $_ -like 'AT+CCHO=*' }) | Should -BeNullOrEmpty
    }

    Context 'each SIM''s own APN settings' {
        BeforeAll {
            # Passes until the SIM in use is identified again, after a switch.
            function Invoke-EsimPass {
                for ($i = 0; $i -lt 3; $i++) {
                    $script:worker.PassForced = $true
                    Invoke-ModemWorkerCycle -Worker $script:worker
                }
                $script:link['Snapshot']
            }

            function Save-EsimApn {
                param([string] $Apn, [string] $Token)
                $settings = $script:link['Snapshot'].Settings | Select-Object -Property *
                $settings.Apn = $Apn
                Invoke-EsimCommand -Worker $script:worker -Kind SaveSettings -Parameter @{ Settings = $settings; SimToken = $Token }
            }

            $script:simsPath = Join-Path $script:folder 'sim-settings.json'
            $script:settingsPath = Join-Path $script:folder 'settings.json'
        }

        It 'gives the APN settings saved before to the first SIM identified; another SIM starts with the subscription''s APN' {
            Export-AppSetting -Settings @{ Apn = 'internet' } -Path $script:settingsPath
            $script:worker = Get-EsimWorker -Scenario Esim
            $script:link['Snapshot'].Settings.Apn | Should -Be 'internet'
            @((Import-SimSetting -Path $script:simsPath).Sims | ForEach-Object Apn) | Should -Be @('internet')
            (Import-AppSetting -Path $script:settingsPath).Settings.Apn | Should -Be '' -Because 'they are that SIM''s now'
            (Invoke-EsimCommand -Worker $script:worker -Kind SelectSimSlot -Parameter @{ Slot = 0 }).Result | Should -Be 'Done'
            $physical = Invoke-EsimPass
            $physical.Esim.SimType | Should -Be 'Usim'
            $physical.Settings.Apn | Should -Be ''
            @((Import-SimSetting -Path $script:simsPath).Sims).Count | Should -Be 1 -Because 'only the first SIM takes them'
        }

        It 'keeps each SIM''s APN apart, and shows the one of the SIM in use' {
            $script:worker = Get-EsimWorker -Scenario Esim
            $esim = $script:link['Snapshot'].SimToken
            $esim | Should -Not -BeNullOrEmpty
            (Save-EsimApn -Apn 'truphone.com' -Token $esim).Result | Should -Be 'Done'
            $script:link['Snapshot'].Settings.Apn | Should -Be 'truphone.com'
            (Invoke-EsimCommand -Worker $script:worker -Kind SelectSimSlot -Parameter @{ Slot = 0 }).Result | Should -Be 'Done'
            $physical = Invoke-EsimPass
            $physical.SimToken | Should -Not -BeNullOrEmpty
            $physical.SimToken | Should -Not -Be $esim
            $physical.Settings.Apn | Should -Be ''
            (Save-EsimApn -Apn 'internet' -Token $physical.SimToken).Result | Should -Be 'Done'
            (Invoke-EsimCommand -Worker $script:worker -Kind SelectSimSlot -Parameter @{ Slot = 1 }).Result | Should -Be 'Done'
            (Invoke-EsimPass).Settings.Apn | Should -Be 'truphone.com'
            $script:device.Modem.Received | Should -Contain 'AT+CGDCONT=1,"IPV4V6","truphone.com"'
            (Import-AppSetting -Path $script:settingsPath).Settings.Apn | Should -Be '' -Because 'no SIM''s APN is every SIM''s'
        }

        It 'saves no APN for a SIM that changed since the window showed it, nor with none ready' {
            $script:worker = Get-EsimWorker -Scenario Esim
            $old = $script:link['Snapshot'].SimToken
            (Invoke-EsimCommand -Worker $script:worker -Kind SelectSimSlot -Parameter @{ Slot = 0 }).Result | Should -Be 'Done'
            [void](Invoke-EsimPass)
            (Save-EsimApn -Apn 'truphone.com' -Token $old).Result | Should -Be 'SimChanged'
            $script:link['Snapshot'].Settings.Apn | Should -Be ''
            Close-ModemWorker -Worker $script:worker
            $script:worker = Get-EsimWorker -Scenario EsimEmpty
            $script:link['Snapshot'].SimToken | Should -BeNullOrEmpty
            (Save-EsimApn -Apn 'truphone.com' -Token $null).Result | Should -Be 'NoSim'
            (Invoke-EsimCommand -Worker $script:worker -Kind SaveSettings -Parameter @{ Settings = @{ InterfaceMetric = 30 } }).Result | Should -Be 'Done' -Because 'the other settings are every SIM''s'
        }

        It 'forgets a deleted profile''s APN settings' {
            $script:worker = Get-EsimWorker -Scenario Esim
            (Save-EsimApn -Apn 'truphone.com' -Token $script:link['Snapshot'].SimToken).Result | Should -Be 'Done'
            (Invoke-EsimCommand -Worker $script:worker -Kind DisableProfile -Parameter @{ Aid = 'A0000005591010FFFFFFFF8900001000' }).Result | Should -Be 'Done'
            (Invoke-EsimCommand -Worker $script:worker -Kind DeleteProfile -Parameter @{ Aid = 'A0000005591010FFFFFFFF8900001000' }).Result | Should -Be 'Done'
            @((Import-SimSetting -Path $script:simsPath).Sims).Count | Should -Be 0
        }
    }

    It 'publishes an eUICC with no profile as read, with none' {
        $script:worker = Get-EsimWorker -Scenario EsimEmpty
        (Invoke-EsimCommand -Worker $script:worker -Kind DeleteProfile -Parameter @{ Aid = 'A0000005591010FFFFFFFF8900002000' }).Result | Should -Be 'Done'
        Invoke-ModemWorkerCycle -Worker $script:worker
        $profiles = $script:link['Snapshot'].Esim.Profiles
        $null -eq $profiles | Should -BeFalse -Because 'an empty list is not a list never read'
        @($profiles).Count | Should -Be 0
    }

    It 'says whether ZXing.Net is there to read a QR code' {
        $script:worker = Get-EsimWorker -Scenario Esim
        $script:link['Snapshot'].Esim.QrAvailable | Should -Be (Test-Path -LiteralPath (Get-ZxingPath) -PathType Leaf)
    }

    It 'refuses to download from an image it can''t read a code from: <Name>' -ForEach @(
        @{ Name = 'no file'; Make = { Join-Path $TestDrive 'missing.png' }; Detail = 'NotImage' }
        @{ Name = 'not an image'; Make = { $path = Join-Path $TestDrive 'code.png'; Set-Content -LiteralPath $path -Value 'LPA:1$smdp.example.com$ABC'; $path }; Detail = 'NotImage' }
    ) {
        $script:worker = Get-EsimWorker -Scenario Esim
        $before = $script:device.Modem.Received.Count
        $outcome = Invoke-EsimCommand -Worker $script:worker -Kind DownloadProfile -Parameter @{ QrImage = (& $Make) }
        $outcome.Result | Should -Be 'NoQrCode'
        $outcome.Detail | Should -Be $Detail
        @($script:device.Modem.Received | Select-Object -Skip $before | Where-Object { $_ -like 'AT+CGLA=*' }) | Should -BeNullOrEmpty
    }

    It 'reads no eUICC while slot 0 is in use' {
        $script:worker = Get-EsimWorker -Scenario Online
        $snapshot = $script:link['Snapshot']
        $snapshot.Esim.Slot | Should -Be 0
        $snapshot.Esim.SimType | Should -Be 'Usim'
        $snapshot.Esim.Profiles | Should -BeNullOrEmpty
        $script:device.Modem.Received | Should -Not -Contain "AT+CCHO=`"$script:isdR`""
        (Invoke-EsimCommand -Worker $script:worker -Kind EnableProfile -Parameter @{ Aid = 'A0000005591010FFFFFFFF8900002000' }).Result | Should -Be 'NotEuicc'
    }

    It 'enables a profile in a maintenance window, then reads the eUICC again and sends its notification' {
        $script:worker = Get-EsimWorker -Scenario EsimEmpty
        $result = Invoke-EsimCommand -Worker $script:worker -Kind EnableProfile -Parameter @{ Aid = 'A0000005591010FFFFFFFF8900002000' }
        $result.Result | Should -Be 'Done'
        $snapshot = $script:link['Snapshot']
        $snapshot.Recovery.History.MaintenanceUntil | Should -Not -BeNullOrEmpty
        $snapshot.Esim.Profiles[0].State | Should -Be 'Enabled'
        $snapshot.Sim.State | Should -Be 'Ready'
        $script:device.Modem.Euicc.Notifications.Count | Should -Be 0
    }

    It 'switches to slot 0 and back, each in a maintenance window, reading what is there' {
        $script:worker = Get-EsimWorker -Scenario Esim
        (Invoke-EsimCommand -Worker $script:worker -Kind SelectSimSlot -Parameter @{ Slot = 1 }).Result | Should -Be 'Unchanged'
        (Invoke-EsimCommand -Worker $script:worker -Kind SelectSimSlot -Parameter @{ Slot = 0 }).Result | Should -Be 'Done'
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.Esim.Slot | Should -Be 0
        $snapshot.Esim.Profiles | Should -BeNullOrEmpty
        $snapshot.Recovery.History.MaintenanceUntil | Should -Not -BeNullOrEmpty
        (Invoke-EsimCommand -Worker $script:worker -Kind SelectSimSlot -Parameter @{ Slot = 1 }).Result | Should -Be 'Done'
        $script:worker.PassForced = $true
        Invoke-ModemWorkerCycle -Worker $script:worker
        $snapshot = $script:link['Snapshot']
        $snapshot.Esim.Slot | Should -Be 1
        @($snapshot.Esim.Profiles).Count | Should -Be 2
        @($script:device.Modem.Received | Where-Object { $_ -like 'AT+GTDUALSIM=*' }) | Should -Be @('AT+GTDUALSIM=0', 'AT+GTDUALSIM=1')
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a profile it doesn''t list'; Kind = 'EnableProfile'; Parameter = @{ Aid = 'A0000005591010FFFFFFFF8900009900' }; Result = 'UnknownProfile' }
        @{ Name = 'to enable the profile enabled'; Kind = 'EnableProfile'; Parameter = @{ Aid = 'A0000005591010FFFFFFFF8900001000' }; Result = 'Unchanged' }
        @{ Name = 'to disable a disabled profile'; Kind = 'DisableProfile'; Parameter = @{ Aid = 'A0000005591010FFFFFFFF8900002000' }; Result = 'Unchanged' }
        @{ Name = 'to delete the profile enabled'; Kind = 'DeleteProfile'; Parameter = @{ Aid = 'A0000005591010FFFFFFFF8900001000' }; Result = 'ProfileEnabled' }
        @{ Name = 'a slot that doesn''t exist'; Kind = 'SelectSimSlot'; Parameter = @{ Slot = 2 }; Result = 'Failed' }
    ) {
        $script:worker = Get-EsimWorker -Scenario Esim
        $before = $script:device.Modem.Received.Count
        (Invoke-EsimCommand -Worker $script:worker -Kind $Kind -Parameter $Parameter).Result | Should -Be $Result
        @($script:device.Modem.Received | Select-Object -Skip $before | Where-Object { $_ -like 'AT+CGLA=*' -or $_ -like 'AT+GTDUALSIM=*' }) | Should -BeNullOrEmpty
    }

    It 'changes nothing in observe-only mode, and still reads' {
        $script:worker = Get-EsimWorker -Scenario Esim -Extra @{ ObserveOnly = $true }
        @($script:link['Snapshot'].Esim.Profiles).Count | Should -Be 2
        foreach ($command in @(
                @{ Kind = 'SelectSimSlot'; Parameter = @{ Slot = 0 } }
                @{ Kind = 'DisableProfile'; Parameter = @{ Aid = 'A0000005591010FFFFFFFF8900001000' } }
                @{ Kind = 'DownloadProfile'; Parameter = @{ ActivationCode = (ConvertTo-TestSecret 'LPA:1$smdp.example.com$ABC') } }
            )) {
            (Invoke-EsimCommand -Worker $script:worker -Kind $command.Kind -Parameter $command.Parameter).Result | Should -Be 'Refused'
        }
        @($script:device.Modem.Received | Where-Object { $_ -like 'AT+GTDUALSIM=*' }) | Should -BeNullOrEmpty
    }

    It 'refuses a switch while a network mode is on trial' {
        $script:worker = Get-EsimWorker -Scenario Esim
        $script:worker.NetworkModeTrial = [pscustomobject]@{ Selection = $null }
        $command = { param($worker, $kind, $parameter) Invoke-WorkerEsimCommand -Worker $worker -Kind $kind -Parameter $parameter }
        (& (Get-Module FibocomFm350) $command $script:worker SelectSimSlot @{ Slot = 0 }).Result | Should -Be 'TrialOn'
        (& (Get-Module FibocomFm350) $command $script:worker DisableProfile @{ Aid = 'A0000005591010FFFFFFFF8900001000' }).Result | Should -Be 'TrialOn'
        $script:worker.NetworkModeTrial = $null
        @($script:device.Modem.Received | Where-Object { $_ -like 'AT+GTDUALSIM=*' -or $_ -like 'AT+CGLA=*BF32*' }) | Should -BeNullOrEmpty
    }

    It 'says lpac is missing' {
        $script:worker = Get-EsimWorker -Scenario Esim
        Mock -ModuleName FibocomFm350 Test-WorkerLpac { $false }
        (Invoke-EsimCommand -Worker $script:worker -Kind ReadEsim).Result | Should -Be 'NoLpac'
        $script:link['Snapshot'].Esim.LpacAvailable | Should -BeFalse
    }

    It 'downloads from an activation code, which no log line and no snapshot carries' {
        $script:worker = Get-EsimWorker -Scenario Esim
        $result = Invoke-EsimCommand -Worker $script:worker -Kind DownloadProfile -Parameter @{ ActivationCode = (ConvertTo-TestSecret 'LPA:1$smdp.example.com$SECRET-MATCH-1') }
        $result.Result | Should -Be 'Done'
        @($script:link['Snapshot'].Esim.Profiles).Count | Should -Be 3
        $script:device.Modem.Euicc.Notifications.Count | Should -Be 0
        $log = Get-ChildItem -Path (Join-Path $script:folder 'logs') -Filter '*.log' | Get-Content -Raw
        $log | Should -Not -Match 'SECRET-MATCH'
        $script:link['Snapshot'] | ConvertTo-Json -Depth 8 | Should -Not -Match 'SECRET-MATCH'
    }

    It 'checks the code first: <Name>' -ForEach @(
        @{ Name = 'not a code'; Code = 'hello'; Confirmation = ''; Result = 'BadCode'; Detail = 'Format' }
        @{ Name = 'a confirmation code asked and none given'; Code = 'LPA:1$smdp.example.com$ABC$$1'; Confirmation = ''; Result = 'ConfirmationNeeded'; Detail = $null }
        @{ Name = 'a server that refuses'; Code = 'LPA:1$smdp.example.com$FAIL-1'; Confirmation = ''; Result = 'Failed'; Detail = 'es9p_initiate_authentication: Profile not available' }
    ) {
        $script:worker = Get-EsimWorker -Scenario Esim
        $parameter = @{ ActivationCode = (ConvertTo-TestSecret $Code) }
        if ($Confirmation) { $parameter['ConfirmationCode'] = ConvertTo-TestSecret $Confirmation }
        $outcome = Invoke-EsimCommand -Worker $script:worker -Kind DownloadProfile -Parameter $parameter
        $outcome.Result | Should -Be $Result
        $outcome.Detail | Should -Be $Detail
        @($script:link['Snapshot'].Esim.Profiles).Count | Should -Be 2
    }

    It 'sets a nickname by the profile''s AID, its ICCID kept in the worker' {
        $script:worker = Get-EsimWorker -Scenario Esim
        (Invoke-EsimCommand -Worker $script:worker -Kind SetProfileNickname -Parameter @{ Aid = 'A0000005591010FFFFFFFF8900002000'; Nickname = 'Lab' }).Result | Should -Be 'Done'
        $script:link['Snapshot'].Esim.Profiles[0].Nickname | Should -Be 'Lab'
    }

    It 'waits for a SIM that is resetting before it reads the eUICC' {
        $script:worker = Get-EsimWorker -Scenario EsimEmpty
        $script:device.Modem.Euicc.ResetMs = 60000
        (Invoke-EsimCommand -Worker $script:worker -Kind EnableProfile -Parameter @{ Aid = 'A0000005591010FFFFFFFF8900002000' }).Result | Should -Be 'Done'
        $snapshot = $script:link['Snapshot']
        $snapshot.Sim.State | Should -Be 'Busy'
        $script:worker.EsimDue | Should -BeTrue
        $snapshot.Esim.Profiles[0].State | Should -Be 'Disabled'
    }
}

Describe 'Start-LpacProcess' {
    BeforeAll {
        $script:pwsh = [Environment]::ProcessPath
    }

    It 'refuses a missing lpac' {
        { Start-LpacProcess -Path (Join-Path $TestDrive 'lpac.exe') -Argument 'chip', 'info' -ErrorAction Stop } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
    }

    It 'passes each argument as one, its own settings alone, and one line each way' {
        $saved = @{ LPAC_CUSTOM_ISD_R_AID = $env:LPAC_CUSTOM_ISD_R_AID; LIBEUICC_DEBUG_APDU = $env:LIBEUICC_DEBUG_APDU; LPAC_APDU = $env:LPAC_APDU }
        $env:LPAC_CUSTOM_ISD_R_AID = 'A000000087'
        $env:LIBEUICC_DEBUG_APDU = '1'
        $env:LPAC_APDU = 'at'
        try {
            $lpac = Start-LpacProcess -Path $script:pwsh -Argument '-NoProfile', '-File', $script:fakeLpac, 'echo', 'Lavoro è "mio" $x', 'LPA:1$a.b$C'
        }
        finally {
            foreach ($name in $saved.Keys) {
                if ($null -eq $saved[$name]) { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue } else { Set-Item -Path "Env:$name" -Value $saved[$name] }
            }
        }
        $device = Get-ChannelModem
        try {
            $run = Invoke-LpacOperation -Channel $device.Channel -Lpac $lpac -TimeoutMs 30000
        }
        finally {
            Close-AtChannel -Channel $device.Channel
        }
        $run.Outcome | Should -Be 'Done'
        $run.Data.arguments | Should -Be @('echo', 'Lavoro è "mio" $x', 'LPA:1$a.b$C')
        $run.Data.answer | Should -BeExactly '{"type":"apdu","payload":{"ecode":0}}'
        $names = @($run.Data.environment.PSObject.Properties.Name)
        $names | Should -Be @('LPAC_APDU', 'LPAC_HTTP')
        $run.Data.environment.LPAC_APDU | Should -Be 'stdio'
        $run.Data.environment.LPAC_HTTP | Should -Be 'stdio'
    }

    It 'is stopped when it hangs' {
        $lpac = Start-LpacProcess -Path $script:pwsh -Argument '-NoProfile', '-File', $script:fakeLpac, 'hang'
        $device = Get-ChannelModem
        try {
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $run = Invoke-LpacOperation -Channel $device.Channel -Lpac $lpac -TimeoutMs 3000
            $clock.ElapsedMilliseconds | Should -BeLessThan 15000
        }
        finally {
            Close-AtChannel -Channel $device.Channel
        }
        $run.Outcome | Should -Be 'Timeout'
    }

    It 'ends with no result when lpac writes none' {
        $lpac = Start-LpacProcess -Path $script:pwsh -Argument '-NoProfile', '-File', $script:fakeLpac, 'exit', '3'
        $device = Get-ChannelModem
        try {
            $run = Invoke-LpacOperation -Channel $device.Channel -Lpac $lpac -TimeoutMs 30000
        }
        finally {
            Close-AtChannel -Channel $device.Channel
        }
        $run.Outcome | Should -Be 'NoResult'
    }
}

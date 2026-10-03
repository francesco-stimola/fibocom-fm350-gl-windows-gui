# The update notice: what GitHub's answer means (a matrix), the request - asking for nothing but
# the app's name, never waited on, sent here to the loopback address only -, the worker's one
# attempt per app start with the request mocked, and the tray menu's item.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    Import-Module "$PSScriptRoot/../src/App/FibocomFm350.App.psd1" -Force

    $script:page = 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/releases/tag/'

    function Get-ReleaseJson {
        param([string] $Tag, [bool] $Draft = $false, [bool] $Prerelease = $false, [string] $Url = "https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/releases/tag/$Tag")
        [pscustomobject]@{ tag_name = $Tag; html_url = $Url; draft = $Draft; prerelease = $Prerelease; name = $Tag } | ConvertTo-Json
    }

    # A request as Start-UpdateCheck returns it, its task already ended - or never. -Page: one
    # for the latest release's page, after the API's -Refusal.
    function Get-TestCheck {
        param([int] $Status = 200, [string] $Body = '', [hashtable] $Headers = @{}, [string] $Location,
            [string] $Fault, [switch] $Canceled, [switch] $Pending, [switch] $Page, [string] $Refusal)
        $source = [System.Threading.Tasks.TaskCompletionSource[System.Net.Http.HttpResponseMessage]]::new()
        if ($Fault) {
            $source.SetException([System.Net.Http.HttpRequestException]::new($Fault))
        }
        elseif ($Canceled) {
            $source.SetCanceled()
        }
        elseif (-not $Pending) {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$Status)
            $response.Content = [System.Net.Http.StringContent]::new($Body)
            foreach ($name in $Headers.Keys) {
                [void]$response.Headers.TryAddWithoutValidation($name, [string]$Headers[$name])
            }
            if ($Location) {
                $response.Headers.Location = [uri]::new($Location, [UriKind]::RelativeOrAbsolute)
            }
            $source.SetResult($response)
        }
        [pscustomobject]@{ Client = [System.Net.Http.HttpClient]::new(); Task = $source.Task; Page = [bool]$Page; Refusal = $Refusal }
    }
}

AfterAll {
    Remove-Module FibocomFm350.App, FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Resolve-UpdateNotice' {
    It '<Name>: <Result>' -ForEach @(
        @{ Name = 'a newer release'; Current = '1.0.0'; Status = 200; Tag = 'v1.1.0'; Result = 'Newer'; Version = '1.1.0' }
        @{ Name = 'a newer patch'; Current = '1.0.0'; Status = 200; Tag = 'v1.0.1'; Result = 'Newer'; Version = '1.0.1' }
        @{ Name = 'a newer major'; Current = '1.9.9'; Status = 200; Tag = 'v2.0.0'; Result = 'Newer'; Version = '2.0.0' }
        @{ Name = 'compared as numbers'; Current = '1.9.0'; Status = 200; Tag = 'v1.10.0'; Result = 'Newer'; Version = '1.10.0' }
        @{ Name = 'the running version'; Current = '1.1.0'; Status = 200; Tag = 'v1.1.0'; Result = 'Current'; Version = '1.1.0' }
        @{ Name = 'an older release'; Current = '1.2.0'; Status = 200; Tag = 'v1.1.0'; Result = 'Current'; Version = '1.1.0' }
        @{ Name = 'a running version with four parts'; Current = '1.1.0.0'; Status = 200; Tag = 'v1.1.0'; Result = 'Current'; Version = '1.1.0' }
        @{ Name = 'a draft'; Current = '1.0.0'; Status = 200; Tag = 'v1.1.0'; Draft = $true; Result = 'Current'; Version = '1.1.0' }
        @{ Name = 'a prerelease'; Current = '1.0.0'; Status = 200; Tag = 'v1.1.0'; Prerelease = $true; Result = 'Current'; Version = '1.1.0' }
        @{ Name = 'no release published'; Current = '1.0.0'; Status = 404; Tag = ''; Result = 'NoRelease'; Version = $null }
        @{ Name = 'a refusal'; Current = '1.0.0'; Status = 403; Tag = ''; Result = 'Refused'; Version = $null }
        @{ Name = 'too many requests'; Current = '1.0.0'; Status = 429; Tag = ''; Result = 'Refused'; Version = $null }
        @{ Name = 'a server error'; Current = '1.0.0'; Status = 500; Tag = ''; Result = 'Failed'; Version = $null }
        @{ Name = 'a tag that names no version'; Current = '1.0.0'; Status = 200; Tag = 'latest'; Result = 'Failed'; Version = $null }
        @{ Name = 'a prerelease tag'; Current = '1.0.0'; Status = 200; Tag = 'v1.1.0-rc1'; Result = 'Failed'; Version = $null }
    ) {
        $draft = if ($_.ContainsKey('Draft')) { $Draft } else { $false }
        $prerelease = if ($_.ContainsKey('Prerelease')) { $Prerelease } else { $false }
        $body = if ($Status -eq 200) { Get-ReleaseJson -Tag $Tag -Draft $draft -Prerelease $prerelease } else { '{"message":"Not Found"}' }
        $notice = Resolve-UpdateNotice -Current ([version]$Current) -StatusCode $Status -Body $body
        $notice.Result | Should -Be $Result
        $notice.Version | Should -Be $Version
        if ($Result -eq 'Newer') {
            $notice.Url | Should -Be "$script:page$Tag"
        }
        else {
            $notice.Url | Should -BeNullOrEmpty
        }
    }

    It 'links the release''s page built from its tag, never an address from the answer' {
        $body = Get-ReleaseJson -Tag 'v1.1.0' -Url 'https://evil.example/download.exe'
        (Resolve-UpdateNotice -Current ([version]'1.0.0') -StatusCode 200 -Body $body).Url | Should -Be "$($script:page)v1.1.0"
    }

    It 'says when a refusal is the rate limit used up: <Remaining>' -ForEach @(
        @{ Status = 403; Remaining = '0'; Detail = 'HTTP 403, rate limit used up' }
        @{ Status = 429; Remaining = '0'; Detail = 'HTTP 429, rate limit used up' }
        @{ Status = 403; Remaining = '12'; Detail = 'HTTP 403' }
        @{ Status = 403; Remaining = ''; Detail = 'HTTP 403' }
    ) {
        $notice = Resolve-UpdateNotice -Current ([version]'1.0.0') -StatusCode $Status -Body '{"message":"API rate limit exceeded"}' -RateLimitRemaining $Remaining
        $notice.Result | Should -Be 'Refused'
        $notice.Detail | Should -BeExactly $Detail
    }

    It 'fails on an answer that is not JSON, and on no answer' {
        $notice = Resolve-UpdateNotice -Current ([version]'1.0.0') -StatusCode 200 -Body '<html>'
        $notice.Result | Should -Be 'Failed'
        $notice.Detail | Should -Match 'not JSON'
        $notice = Resolve-UpdateNotice -Current ([version]'1.0.0') -Failure 'No answer in time.'
        $notice.Result | Should -Be 'Failed'
        $notice.Detail | Should -Be 'No answer in time.'
    }
}

Describe 'Resolve-UpdateRedirect' {
    BeforeAll {
        $script:list = 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/releases'
    }

    It '<Name>: <Result>' -ForEach @(
        @{ Name = 'a newer release'; Current = '1.0.0'; Status = 302; Location = 'PAGEv1.1.0'; Result = 'Newer'; Version = '1.1.0' }
        @{ Name = 'compared as numbers'; Current = '1.9.0'; Status = 302; Location = 'PAGEv1.10.0'; Result = 'Newer'; Version = '1.10.0' }
        @{ Name = 'a permanent redirect'; Current = '1.0.0'; Status = 301; Location = 'PAGEv1.1.0'; Result = 'Newer'; Version = '1.1.0' }
        @{ Name = 'a temporary redirect'; Current = '1.0.0'; Status = 307; Location = 'PAGEv1.1.0'; Result = 'Newer'; Version = '1.1.0' }
        @{ Name = 'the running version'; Current = '1.1.0'; Status = 302; Location = 'PAGEv1.1.0'; Result = 'Current'; Version = '1.1.0' }
        @{ Name = 'an older release'; Current = '1.2.0'; Status = 302; Location = 'PAGEv1.1.0'; Result = 'Current'; Version = '1.1.0' }
        @{ Name = 'no release published'; Current = '1.0.0'; Status = 302; Location = 'LIST'; Result = 'NoRelease'; Version = $null }
        @{ Name = 'no release published, with a slash'; Current = '1.0.0'; Status = 302; Location = 'LIST/'; Result = 'NoRelease'; Version = $null }
        @{ Name = 'a tag that names no version'; Current = '1.0.0'; Status = 302; Location = 'PAGElatest'; Result = 'Failed'; Version = $null }
        @{ Name = 'a prerelease tag'; Current = '1.0.0'; Status = 302; Location = 'PAGEv1.1.0-rc1'; Result = 'Failed'; Version = $null }
        @{ Name = 'a page below a release''s'; Current = '1.0.0'; Status = 302; Location = 'PAGEother/v1.1.0'; Result = 'Failed'; Version = $null }
        @{ Name = 'another site'; Current = '1.0.0'; Status = 302; Location = 'https://evil.example/francesco-stimola/fibocom-fm350-gl-windows-gui/releases/tag/v9.0.0'; Result = 'Failed'; Version = $null }
        @{ Name = 'another page'; Current = '1.0.0'; Status = 302; Location = 'https://github.com/login'; Result = 'Failed'; Version = $null }
        @{ Name = 'a redirect with nowhere to go'; Current = '1.0.0'; Status = 302; Location = ''; Result = 'Failed'; Version = $null }
        @{ Name = 'the page itself, not a redirect'; Current = '1.0.0'; Status = 200; Location = ''; Result = 'Failed'; Version = $null }
        @{ Name = 'a refusal, never asked about again'; Current = '1.0.0'; Status = 403; Location = ''; Result = 'Failed'; Version = $null }
        @{ Name = 'too many requests, never asked about again'; Current = '1.0.0'; Status = 429; Location = ''; Result = 'Failed'; Version = $null }
    ) {
        $to = $Location -replace '^PAGE', $script:page -replace '^LIST', $script:list
        $notice = Resolve-UpdateRedirect -Current ([version]$Current) -StatusCode $Status -Location $to -Refusal 'HTTP 403, rate limit used up'
        $notice.Result | Should -Be $Result
        $notice.Version | Should -Be $Version
        if ($Result -eq 'Newer') {
            $notice.Url | Should -Be "$script:page$($to.Substring($script:page.Length))"
        }
        else {
            $notice.Url | Should -BeNullOrEmpty
        }
        if ($Result -eq 'Failed') {
            $notice.Detail | Should -BeLike "HTTP 403, rate limit used up; the latest release's page: *"
        }
        else {
            $notice.Detail | Should -BeNullOrEmpty
        }
    }

    It 'links the release''s page built from its tag, whatever the redirect''s case' {
        $location = "$($script:page.ToUpperInvariant())v1.1.0"
        (Resolve-UpdateRedirect -Current ([version]'1.0.0') -StatusCode 302 -Location $location).Url | Should -BeExactly "$($script:page)v1.1.0"
    }

    It 'fails on no answer, after the refusal' {
        $notice = Resolve-UpdateRedirect -Current ([version]'1.0.0') -Refusal 'HTTP 403' -Failure 'No answer in time.'
        $notice.Result | Should -Be 'Failed'
        $notice.Detail | Should -BeExactly "HTTP 403; the latest release's page: No answer in time."
    }
}

Describe 'The request' {
    It 'is read once ended, and released' {
        $check = Get-TestCheck -Body (Get-ReleaseJson -Tag 'v2.0.0')
        $notice = Receive-UpdateCheck -Check $check -Current ([version]'1.0.0')
        $notice.Result | Should -Be 'Newer'
        $notice.Version | Should -Be '2.0.0'
        { $check.Client.CancelPendingRequests() } | Should -Throw -Because 'the client was released'
    }

    It 'gives nothing while under way' {
        $check = Get-TestCheck -Pending
        try {
            Receive-UpdateCheck -Check $check -Current ([version]'1.0.0') | Should -BeNullOrEmpty
        }
        finally {
            Stop-UpdateCheck -Check $check -Confirm:$false
        }
    }

    It 'fails on <Name>' -ForEach @(
        @{ Name = 'a refused connection'; Fault = 'No connection could be made'; Canceled = $false; Detail = 'No connection could be made' }
        @{ Name = 'a timeout'; Fault = ''; Canceled = $true; Detail = 'No answer in time.' }
    ) {
        $check = if ($Canceled) { Get-TestCheck -Canceled } else { Get-TestCheck -Fault $Fault }
        $notice = Receive-UpdateCheck -Check $check -Current ([version]'1.0.0')
        $notice.Result | Should -Be 'Failed'
        $notice.Detail | Should -Be $Detail
    }

    It 'names the app and nothing else, and never waits: sent here to the loopback address' {
        # Port 9 (discard) on the loopback: refused at once, nothing leaves the computer.
        $check = Start-UpdateCheck -Uri 'http://127.0.0.1:9/releases/latest' -TimeoutMs 5000 -Confirm:$false
        try {
            $headers = $check.Client.DefaultRequestHeaders
            $headers.UserAgent.ToString() | Should -BeExactly 'fibocom-fm350-gl-windows-gui'
            $headers.Accept.ToString() | Should -Be 'application/vnd.github+json'
            @($headers.GetValues('X-GitHub-Api-Version')) | Should -Be @('2022-11-28')
            $deadline = [Environment]::TickCount64 + 10000
            $notice = $null
            while (-not $notice -and [Environment]::TickCount64 -lt $deadline) {
                Start-Sleep -Milliseconds 50
                $notice = Receive-UpdateCheck -Check $check -Current ([version]'1.0.0')
            }
            $notice.Result | Should -Be 'Failed'
        }
        finally {
            Stop-UpdateCheck -Check $check -Confirm:$false
        }
    }

    It 'reads the rate limit from the API''s refusal' {
        $check = Get-TestCheck -Status 403 -Body '{"message":"API rate limit exceeded"}' -Headers @{ 'X-RateLimit-Remaining' = '0' }
        $notice = Receive-UpdateCheck -Check $check -Current ([version]'1.0.0')
        $notice.Result | Should -Be 'Refused'
        $notice.Detail | Should -BeExactly 'HTTP 403, rate limit used up'
    }

    It 'reads where the latest release''s page leads: <Name>' -ForEach @(
        @{ Name = 'an absolute address'; Location = 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/releases/tag/v2.0.0' }
        @{ Name = 'a relative one'; Location = '/francesco-stimola/fibocom-fm350-gl-windows-gui/releases/tag/v2.0.0' }
    ) {
        $check = Get-TestCheck -Page -Refusal 'HTTP 403' -Status 302 -Location $Location
        $notice = Receive-UpdateCheck -Check $check -Current ([version]'1.0.0')
        $notice.Result | Should -Be 'Newer'
        $notice.Url | Should -Be "$($script:page)v2.0.0"
        { $check.Client.CancelPendingRequests() } | Should -Throw -Because 'the client was released'
    }

    It 'fails on the page''s timeout, after the refusal' {
        $notice = Receive-UpdateCheck -Check (Get-TestCheck -Page -Refusal 'HTTP 429' -Canceled) -Current ([version]'1.0.0')
        $notice.Result | Should -Be 'Failed'
        $notice.Detail | Should -BeExactly "HTTP 429; the latest release's page: No answer in time."
    }

    It 'asks for the page with a HEAD that names the app and follows no redirect: sent here to the loopback address' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $check = $null
        try {
            $port = $listener.LocalEndpoint.Port
            $check = Start-UpdateCheck -Page -Refusal 'HTTP 403' -Uri "http://127.0.0.1:$port/releases/latest" -TimeoutMs 5000 -Confirm:$false
            $headers = $check.Client.DefaultRequestHeaders
            $headers.UserAgent.ToString() | Should -BeExactly 'fibocom-fm350-gl-windows-gui'
            $accepted = $listener.AcceptTcpClientAsync()
            $accepted.Wait(5000) | Should -BeTrue
            $client = $accepted.Result
            try {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 5000
                $request = [System.Text.StringBuilder]::new()
                $buffer = [byte[]]::new(4096)
                while (-not $request.ToString().Contains("`r`n`r`n")) {
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    [void]$request.Append([System.Text.Encoding]::ASCII.GetString($buffer, 0, $read))
                }
                # Followed, this would be refused at once: port 9 (discard) on the loopback.
                $answer = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 302 Found`r`nLocation: http://127.0.0.1:9/elsewhere`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                $stream.Write($answer, 0, $answer.Length)
                $stream.Flush()
            }
            finally {
                $client.Dispose()
            }
            $lines = $request.ToString() -split "`r`n"
            $lines[0] | Should -BeLike 'HEAD /releases/latest HTTP/*'
            $lines | Should -Contain 'User-Agent: fibocom-fm350-gl-windows-gui'
            @($lines | Where-Object { $_ -match '^(Accept|X-GitHub-Api-Version):' }) | Should -BeNullOrEmpty
            $deadline = [Environment]::TickCount64 + 10000
            $notice = $null
            while (-not $notice -and [Environment]::TickCount64 -lt $deadline) {
                Start-Sleep -Milliseconds 50
                $notice = Receive-UpdateCheck -Check $check -Current ([version]'1.0.0')
            }
            $notice.Result | Should -Be 'Failed'
            $notice.Detail | Should -BeExactly "HTTP 403; the latest release's page: it led to another page." -Because 'the redirect is read, not followed'
        }
        finally {
            if ($check) { Stop-UpdateCheck -Check $check -Confirm:$false }
            $listener.Stop()
        }
    }

    It 'sends nothing under -WhatIf' {
        Start-UpdateCheck -WhatIf | Should -BeNullOrEmpty
        Start-UpdateCheck -Page -WhatIf | Should -BeNullOrEmpty
    }

    It 'reads GitHub''s own addresses' {
        & (Get-Module FibocomFm350) { $script:ReleaseFeed } | Should -Be 'https://api.github.com/repos/francesco-stimola/fibocom-fm350-gl-windows-gui/releases/latest'
        & (Get-Module FibocomFm350) { $script:ReleaseLatestPage } | Should -Be 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/releases/latest'
    }
}

Describe 'The worker''s update check' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
        $script:now = 100000
        $script:answers = [System.Collections.Generic.Queue[object]]::new()
        Mock -ModuleName FibocomFm350 Start-UpdateCheck { [pscustomobject]@{ Client = $null; Task = $null } }
        Mock -ModuleName FibocomFm350 Receive-UpdateCheck { if ($script:answers.Count) { $script:answers.Dequeue() } }
        Mock -ModuleName FibocomFm350 Stop-UpdateCheck { }

        function Get-TestWorker {
            param([string] $Scenario = 'Online', [object] $Previous, [switch] $Off)
            $script:link = New-ModemWorkerLink
            $extra = @{ CheckForUpdates = -not $Off }
            if ($Previous) { $extra['Previous'] = $Previous }
            New-ModemWorker -Link $script:link -Simulation (New-SimulatedDevice -Scenario $Scenario) -DataFolder $script:folder -Clock { $script:now } @extra
        }
        function Invoke-TestCycle {
            param([hashtable] $Worker, [int] $Count = 1)
            for ($i = 0; $i -lt $Count; $i++) {
                Invoke-ModemWorkerCycle -Worker $Worker
                $script:now += [Math]::Max(1, $Worker.WaitMs)
            }
        }
        function Get-TestLog {
            Get-ChildItem -Path (Join-Path $script:folder 'logs') -Filter '*.log' | Get-Content
        }
    }

    It 'asks once the connection is online, then takes the answer, and never asks again' {
        $worker = Get-TestWorker
        try {
            Invoke-TestCycle -Worker $worker
            $script:link['Snapshot'].State | Should -Be 'Online'
            $script:link['Snapshot'].Update.Status | Should -Be 'Running'
            Should -Invoke -ModuleName FibocomFm350 Start-UpdateCheck -Times 1 -Exactly
            $worker.WaitMs | Should -BeLessOrEqual 1000 -Because 'the answer is looked for every second'

            $script:answers.Enqueue([pscustomobject]@{ Result = 'Newer'; Version = '1.1.0'; Url = "$($script:page)v1.1.0"; Detail = $null })
            Invoke-TestCycle -Worker $worker -Count 5
            $update = $script:link['Snapshot'].Update
            $update.Status | Should -Be 'Done'
            $update.Result | Should -Be 'Newer'
            $update.Version | Should -Be '1.1.0'
            $update.Url | Should -Be "$($script:page)v1.1.0"
            Should -Invoke -ModuleName FibocomFm350 Start-UpdateCheck -Times 1 -Exactly
            @(Get-TestLog | Where-Object { $_ -match 'Update check: version 1\.1\.0 is available' }).Count | Should -Be 1
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $script:link
        }
    }

    It 'asks the latest release''s page once when the API refuses: <Name>' -ForEach @(
        @{ Name = 'a newer release'; Answer = @{ Result = 'Newer'; Version = '1.1.0'; Url = 'https://github.com/x/releases/tag/v1.1.0'; Detail = $null }; Log = 'Update check: version 1\.1\.0 is available' }
        @{ Name = 'the page fails too'; Answer = @{ Result = 'Failed'; Version = $null; Url = $null; Detail = "HTTP 403, rate limit used up; the latest release's page: HTTP 500" }; Log = 'WARNING.*Update check: no answer \(HTTP 403, rate limit used up; the latest release''s page: HTTP 500\)' }
    ) {
        $worker = Get-TestWorker
        try {
            Invoke-TestCycle -Worker $worker
            $script:answers.Enqueue([pscustomobject]@{ Result = 'Refused'; Version = $null; Url = $null; Detail = 'HTTP 403, rate limit used up' })
            Invoke-TestCycle -Worker $worker
            $script:link['Snapshot'].Update.Status | Should -Be 'Running'
            Should -Invoke -ModuleName FibocomFm350 Start-UpdateCheck -Times 1 -Exactly -ParameterFilter { $Page -and $Refusal -eq 'HTTP 403, rate limit used up' }
            Should -Invoke -ModuleName FibocomFm350 Stop-UpdateCheck -Times 0 -Exactly -Because 'the refused request was released as it was read'
            $worker.WaitMs | Should -BeLessOrEqual 1000 -Because 'the page''s answer is looked for every second'

            $script:answers.Enqueue([pscustomobject]$Answer)
            Invoke-TestCycle -Worker $worker -Count 5
            $update = $script:link['Snapshot'].Update
            $update.Status | Should -Be 'Done'
            $update.Result | Should -Be $Answer.Result
            $update.Detail | Should -Be $Answer.Detail
            Should -Invoke -ModuleName FibocomFm350 Start-UpdateCheck -Times 2 -Exactly
            $written = Get-TestLog
            @($written | Where-Object { $_ -match "INFO.*Update check: the API refused \(HTTP 403, rate limit used up\); asking the latest release's page" }).Count | Should -Be 1
            @($written | Where-Object { $_ -match $Log }).Count | Should -Be 1
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $script:link
        }
    }

    It 'counts a page it can''t even ask for as the one attempt' {
        Mock -ModuleName FibocomFm350 Start-UpdateCheck { throw 'No network stack.' } -ParameterFilter { $Page }
        $worker = Get-TestWorker
        try {
            Invoke-TestCycle -Worker $worker
            $script:answers.Enqueue([pscustomobject]@{ Result = 'Refused'; Version = $null; Url = $null; Detail = 'HTTP 403' })
            Invoke-TestCycle -Worker $worker -Count 3
            $update = $script:link['Snapshot'].Update
            $update.Status | Should -Be 'Done'
            $update.Result | Should -Be 'Failed'
            # Only the page's request throws.
            $update.Detail | Should -Be 'No network stack.'
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $script:link
        }
    }

    It 'never asks before the connection is online' {
        $worker = Get-TestWorker -Scenario ApnNeeded
        try {
            Invoke-TestCycle -Worker $worker -Count 3
            $script:link['Snapshot'].Update.Status | Should -Be 'Pending'
            Should -Invoke -ModuleName FibocomFm350 Start-UpdateCheck -Times 0 -Exactly
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $script:link
        }
    }

    It 'never asks when <Name>' -ForEach @(
        @{ Name = 'the settings turn it off'; Setting = $false; Off = $false }
        @{ Name = 'the worker is not the real app''s (development mode)'; Setting = $true; Off = $true }
    ) {
        Export-AppSetting -Settings @{ CheckForUpdates = $Setting } -Path (Join-Path $script:folder 'settings.json') -Confirm:$false
        $worker = Get-TestWorker -Off:$Off
        try {
            Invoke-TestCycle -Worker $worker -Count 3
            $script:link['Snapshot'].State | Should -Be 'Online'
            Should -Invoke -ModuleName FibocomFm350 Start-UpdateCheck -Times 0 -Exactly
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $script:link
        }
    }

    It 'counts a request it can''t even send as the one attempt, and the cycle goes on' {
        Mock -ModuleName FibocomFm350 Start-UpdateCheck { throw 'No network stack.' }
        $worker = Get-TestWorker
        try {
            Invoke-TestCycle -Worker $worker -Count 3
            $update = $script:link['Snapshot'].Update
            $update.Status | Should -Be 'Done'
            $update.Result | Should -Be 'Failed'
            $update.Detail | Should -Be 'No network stack.'
            Should -Invoke -ModuleName FibocomFm350 Start-UpdateCheck -Times 1 -Exactly
            (Get-TestLog) -match 'WARNING.*Update check: no answer \(No network stack\.\)' | Should -Not -BeNullOrEmpty
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $script:link
        }
    }

    It 'carries the notice to a worker that replaces this one, and never asks again' {
        $first = Get-TestWorker
        try {
            Invoke-TestCycle -Worker $first
            $script:answers.Enqueue([pscustomobject]@{ Result = 'Current'; Version = '1.0.0'; Url = $null; Detail = $null })
            Invoke-TestCycle -Worker $first
        }
        finally {
            Close-ModemWorker -Worker $first
            Close-ModemWorkerLink -Link $script:link
        }
        $last = $script:link['Snapshot']
        $last.Update.Result | Should -Be 'Current'
        $second = Get-TestWorker -Previous $last
        try {
            Invoke-TestCycle -Worker $second -Count 3
            $script:link['Snapshot'].Update.Result | Should -Be 'Current'
            Should -Invoke -ModuleName FibocomFm350 Start-UpdateCheck -Times 1 -Exactly
        }
        finally {
            Close-ModemWorker -Worker $second
            Close-ModemWorkerLink -Link $script:link
        }
    }

    It 'never asks again after a worker that ended while asking' {
        $first = Get-TestWorker
        try {
            Invoke-TestCycle -Worker $first
            $script:link['Snapshot'].Update.Status | Should -Be 'Running'
        }
        finally {
            Close-ModemWorker -Worker $first
            Close-ModemWorkerLink -Link $script:link
        }
        Should -Invoke -ModuleName FibocomFm350 Stop-UpdateCheck -Times 1 -Exactly -Because 'the request under way is released with its worker'
        $second = Get-TestWorker -Previous $script:link['Snapshot']
        try {
            Invoke-TestCycle -Worker $second -Count 3
            $update = $script:link['Snapshot'].Update
            $update.Status | Should -Be 'Done'
            $update.Result | Should -Be 'Failed'
            Should -Invoke -ModuleName FibocomFm350 Start-UpdateCheck -Times 1 -Exactly
        }
        finally {
            Close-ModemWorker -Worker $second
            Close-ModemWorkerLink -Link $script:link
        }
    }

    It 'says which version runs' {
        $worker = Get-TestWorker
        try {
            Invoke-TestCycle -Worker $worker
            $script:link['Snapshot'].AppVersion | Should -Be (Get-Module FibocomFm350).Version.ToString()
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $script:link
        }
    }
}

Describe 'Get-TrayUpdateItem' {
    It '<Name>' -ForEach @(
        @{ Name = 'shows a newer release, with its page'; Update = @{ Status = 'Done'; Result = 'Newer'; Version = '1.1.0'; Url = 'https://github.com/x/releases/tag/v1.1.0' }; Check = $true; Visible = $true; Text = 'Version 1.1.0 is available...' }
        @{ Name = 'hides it once the settings turn the notice off'; Update = @{ Status = 'Done'; Result = 'Newer'; Version = '1.1.0'; Url = 'https://github.com/x/releases/tag/v1.1.0' }; Check = $false; Visible = $false; Text = $null }
        @{ Name = 'shows nothing for the running version'; Update = @{ Status = 'Done'; Result = 'Current'; Version = '1.0.0'; Url = $null }; Check = $true; Visible = $false; Text = $null }
        @{ Name = 'shows nothing while asking'; Update = @{ Status = 'Running'; Result = $null; Version = $null; Url = $null }; Check = $true; Visible = $false; Text = $null }
        @{ Name = 'shows nothing after a failure'; Update = @{ Status = 'Done'; Result = 'Failed'; Version = $null; Url = $null }; Check = $true; Visible = $false; Text = $null }
    ) {
        $snapshot = [pscustomobject]@{ Update = [pscustomobject]$Update; Settings = [pscustomobject]@{ CheckForUpdates = $Check } }
        $item = Get-TrayUpdateItem -Snapshot $snapshot
        $item.Visible | Should -Be $Visible
        $item.Text | Should -Be $Text
        if ($Visible) { $item.Url | Should -Be $Update.Url }
    }

    It 'shows nothing without a snapshot' {
        (Get-TrayUpdateItem -Snapshot $null).Visible | Should -BeFalse
    }

    It 'is at the top of the tray menu, and opens the release''s page' {
        $link = New-ModemWorkerLink
        $worker = New-ModemWorker -Link $link -Simulation (New-SimulatedDevice -Scenario Online) -DataFolder (Join-Path $TestDrive ([guid]::NewGuid()))
        try {
            Invoke-ModemWorkerCycle -Worker $worker
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $link
        }
        $snapshot = $link['Snapshot'] | Select-Object -Property *
        $snapshot.Update = [pscustomobject]@{ Status = 'Done'; Result = 'Newer'; Version = '1.1.0'; Url = 'https://github.com/x/releases/tag/v1.1.0' }
        $state = & (Get-Module FibocomFm350.App) {
            param($snapshot)
            $opened = [System.Collections.Generic.List[string]]::new()
            $script:MainWindow = @{ Open = { param($url) $opened.Add($url) }.GetNewClosure() }
            $script:App = @{ LastSnapshot = $snapshot; Worker = $null; ResumedAt = 0; Tray = New-AppTray }
            try {
                Update-AppTrayMenu
                $items = $script:App.Tray.ContextMenuStrip.Items
                $first = $items[0]
                $result = [pscustomobject]@{ Name = $first.Name; Text = $first.Text; Visible = $first.Available; Separator = $items['UpdateSeparator'].Available }
                $first.PerformClick()
                $result | Add-Member -NotePropertyName Opened -NotePropertyValue @($opened)
                $result
            }
            finally {
                $script:App.Tray.ContextMenuStrip.Dispose()
                $script:App.Tray.Dispose()
                $script:App = $null
                $script:MainWindow = $null
            }
        } $snapshot
        $state.Name | Should -Be 'Update'
        $state.Visible | Should -BeTrue
        $state.Separator | Should -BeTrue
        $state.Text | Should -Be 'Version 1.1.0 is available...'
        $state.Opened | Should -Be @('https://github.com/x/releases/tag/v1.1.0')
    }
}

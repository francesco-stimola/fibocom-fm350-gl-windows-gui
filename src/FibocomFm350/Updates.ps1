# The update notice: once per app start, when the connection first comes online, the worker reads
# the latest release from GitHub's public API - or, when the API refuses, from where the latest
# release's page leads - and says whether it is newer than the running app. It never downloads or
# installs anything. Design: docs/ARCHITECTURE.md -> Updates; facts: docs/AT-COMMANDS.md section 11.3.

$script:ReleaseFeed = 'https://api.github.com/repos/francesco-stimola/fibocom-fm350-gl-windows-gui/releases/latest'

# The page a newer release is shown on: built from its tag, never taken from the answer.
$script:ReleasePage = 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/releases/tag/'

# The latest release's page, asked when the API refuses: it leads to that release's page, or to
# the list of releases while there is none.
$script:ReleaseLatestPage = 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/releases/latest'
$script:ReleaseList = 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/releases'

# The request names the app and nothing else: no version, no Windows build, no language - what
# .NET's and PowerShell's own user agents would add. GitHub rejects a request without one.
$script:UpdateUserAgent = 'fibocom-fm350-gl-windows-gui'

# The API version the answer is read as (docs/AT-COMMANDS.md section 11.3).
$script:UpdateApiVersion = '2022-11-28'

# How long the one request may take, and how often the worker looks whether it is done.
$script:UpdateTimeoutMs = 10000
$script:UpdatePollMs = 1000

function Resolve-UpdateNotice {
    <#
    .SYNOPSIS
        Decides what GitHub's answer about the latest release means for the running app.
    .DESCRIPTION
        A pure decision from -Current (the running version), -StatusCode and -Body (the answer of
        the latest-release endpoint), or -Failure (why no answer came). Returns Result:
        - 'Newer': the latest release is newer; Version (major.minor.patch) and Url, the release's
          page, built from its tag - an address from the answer is never opened;
        - 'Current': it is not newer (the same, or older), or it is a draft or a prerelease,
          which that endpoint shouldn't return;
        - 'NoRelease': none published (404);
        - 'Refused': the API refused to answer (403 or 429) - its rate limit used up when
          -RateLimitRemaining (the X-RateLimit-Remaining header) is 0; Detail says so, and the
          latest release's page is asked instead (Resolve-UpdateRedirect);
        - 'Failed': no usable answer; Detail says why.
    .EXAMPLE
        Resolve-UpdateNotice -Current ([version]'1.0.0') -StatusCode 200 -Body $json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [version] $Current,

        [int] $StatusCode,

        [AllowEmptyString()]
        [string] $Body,

        [string] $RateLimitRemaining,

        [string] $Failure
    )

    if ($Failure) {
        return New-UpdateNotice -Result 'Failed' -Detail $Failure
    }
    if ($StatusCode -eq 404) {
        return New-UpdateNotice -Result 'NoRelease'
    }
    if ($StatusCode -in 403, 429) {
        return New-UpdateNotice -Result 'Refused' -Detail "HTTP $StatusCode$(if ($RateLimitRemaining -eq '0') { ', rate limit used up' })"
    }
    if ($StatusCode -ne 200) {
        return New-UpdateNotice -Result 'Failed' -Detail "HTTP $StatusCode"
    }
    try {
        $release = $Body | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return New-UpdateNotice -Result 'Failed' -Detail 'The answer is not JSON.'
    }
    $tag = if ($release -and $release.PSObject.Properties['tag_name']) { [string]$release.tag_name } else { '' }
    $flagged = { param($name) $release.PSObject.Properties[$name] -and $release.$name -eq $true }
    ConvertFrom-ReleaseTag -Current $Current -Tag $tag -Unlisted:((& $flagged 'draft') -or (& $flagged 'prerelease'))
}

function Resolve-UpdateRedirect {
    <#
    .SYNOPSIS
        Decides what the latest release's page, asked when the API refused, means for the running app.
    .DESCRIPTION
        A pure decision from -Current (the running version), -StatusCode and -Location (the answer
        to a request for the latest release's page, its redirect not followed), or -Failure (why no
        answer came). A redirect to a release's page names the latest release by its tag; one to
        the list of releases means none is published. Returns what Resolve-UpdateNotice returns -
        never 'Refused' -, and -Refusal (the API's refusal) at the head of a failure's Detail.
    .EXAMPLE
        Resolve-UpdateRedirect -Current ([version]'1.0.0') -StatusCode 302 -Location $location -Refusal 'HTTP 403'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [version] $Current,

        [int] $StatusCode,

        [string] $Location,

        [string] $Refusal,

        [string] $Failure
    )

    $before = if ($Refusal) { "$Refusal; the latest release's page: " } else { '' }
    $failed = { param($why) New-UpdateNotice -Result 'Failed' -Detail "$before$why" }
    if ($Failure) {
        return & $failed $Failure
    }
    if ($StatusCode -notin 301, 302, 303, 307, 308 -or -not $Location) {
        return & $failed "HTTP $StatusCode"
    }
    if ([string]::Equals($Location.TrimEnd('/'), $script:ReleaseList, [StringComparison]::OrdinalIgnoreCase)) {
        return New-UpdateNotice -Result 'NoRelease'
    }
    if (-not $Location.StartsWith($script:ReleasePage, [StringComparison]::OrdinalIgnoreCase)) {
        return & $failed 'it led to another page.'
    }
    $notice = ConvertFrom-ReleaseTag -Current $Current -Tag $Location.Substring($script:ReleasePage.Length)
    if ($notice.Result -eq 'Failed') {
        return & $failed $notice.Detail
    }
    $notice
}

function New-UpdateNotice {
    # One update notice, as Resolve-UpdateNotice and Resolve-UpdateRedirect return it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an object in memory; changes nothing.')]
    param([string] $Result, [string] $Version, [string] $Url, [string] $Detail)

    [pscustomobject]@{
        Result  = $Result
        Version = if ($Version) { $Version } else { $null }
        Url     = if ($Url) { $Url } else { $null }
        Detail  = if ($Detail) { $Detail } else { $null }
    }
}

function ConvertFrom-ReleaseTag {
    # The notice for the latest release's tag, v<major>.<minor>.<patch>: newer than -Current, or
    # not - never newer when -Unlisted (a draft or a prerelease). Its page is built from the tag.
    param([version] $Current, [AllowEmptyString()] [string] $Tag, [switch] $Unlisted)

    if ($Tag -notmatch '^v(\d+)\.(\d+)\.(\d+)$') {
        return New-UpdateNotice -Result 'Failed' -Detail "The latest release's tag is not v<major>.<minor>.<patch>: '$Tag'."
    }
    $latest = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    $running = [version]::new($Current.Major, $Current.Minor, [Math]::Max(0, $Current.Build))
    if ($Unlisted -or $latest -le $running) {
        return New-UpdateNotice -Result 'Current' -Version $latest.ToString()
    }
    New-UpdateNotice -Result 'Newer' -Version $latest.ToString() -Url "$script:ReleasePage$Tag"
}

function Start-UpdateCheck {
    <#
    .SYNOPSIS
        Sends the request for the latest release, and returns at once.
    .DESCRIPTION
        One GET to GitHub's public API, with the app's name as user agent and nothing that
        identifies the computer or its user; it gives up after the timeout. With -Page, once the
        API refused (-Refusal, its Detail): one HEAD for the latest release's page instead, the
        same user agent, its redirect read and never followed. Returns the request under way -
        Client, Task, Page, Refusal -, which Receive-UpdateCheck reads once done and
        Stop-UpdateCheck releases. The worker never waits on it.
    .EXAMPLE
        $check = Start-UpdateCheck
    .EXAMPLE
        $check = Start-UpdateCheck -Page -Refusal $notice.Detail
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string] $Uri,

        [int] $TimeoutMs = $script:UpdateTimeoutMs,

        [switch] $Page,

        [string] $Refusal
    )

    if (-not $Uri) {
        $Uri = if ($Page) { $script:ReleaseLatestPage } else { $script:ReleaseFeed }
    }
    if (-not $PSCmdlet.ShouldProcess($Uri, 'Read the latest release')) {
        return
    }
    $client = if ($Page) {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        # The client owns its handler: disposing it disposes both.
        [System.Net.Http.HttpClient]::new($handler)
    }
    else {
        [System.Net.Http.HttpClient]::new()
    }
    try {
        $client.Timeout = [timespan]::FromMilliseconds($TimeoutMs)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd($script:UpdateUserAgent)
        $task = if ($Page) {
            $client.SendAsync([System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $Uri))
        }
        else {
            $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
            $client.DefaultRequestHeaders.Add('X-GitHub-Api-Version', $script:UpdateApiVersion)
            $client.GetAsync($Uri)
        }
        [pscustomobject]@{ Client = $client; Task = $task; Page = [bool]$Page; Refusal = $Refusal }
    }
    catch {
        $client.Dispose()
        throw
    }
}

function Receive-UpdateCheck {
    <#
    .SYNOPSIS
        Reads the answer to Start-UpdateCheck's request once it has come, and releases it.
    .DESCRIPTION
        Returns nothing while the request is under way. Once it has ended - answered, failed or
        timed out -, returns the decision for -Current - Resolve-UpdateNotice's, or for the
        latest release's page Resolve-UpdateRedirect's - and releases the request.
    .EXAMPLE
        $notice = Receive-UpdateCheck -Check $check -Current $version
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Check,

        [Parameter(Mandatory)]
        [version] $Current
    )

    if (-not $Check.Task.IsCompleted) {
        return
    }
    $response = $null
    try {
        if ($Check.Task.IsFaulted -or $Check.Task.IsCanceled) {
            $why = if ($Check.Task.IsCanceled) { 'No answer in time.' } else { $Check.Task.Exception.GetBaseException().Message }
            if ($Check.Page) {
                return Resolve-UpdateRedirect -Current $Current -Refusal $Check.Refusal -Failure $why
            }
            return Resolve-UpdateNotice -Current $Current -Failure $why
        }
        $response = $Check.Task.Result
        if ($Check.Page) {
            $location = $response.Headers.Location
            if ($location -and -not $location.IsAbsoluteUri) {
                $location = [uri]::new([uri]$script:ReleaseLatestPage, $location)
            }
            return Resolve-UpdateRedirect -Current $Current -StatusCode ([int]$response.StatusCode) -Location $(if ($location) { $location.AbsoluteUri }) -Refusal $Check.Refusal
        }
        $remaining = $null
        $values = $null
        if ($response.Headers.TryGetValues('X-RateLimit-Remaining', [ref]$values)) {
            $remaining = @($values)[0]
        }
        # The answer is read whole before the task completes: this doesn't wait.
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        Resolve-UpdateNotice -Current $Current -StatusCode ([int]$response.StatusCode) -Body $body -RateLimitRemaining $remaining
    }
    finally {
        if ($response) {
            $response.Dispose()
        }
        Stop-UpdateCheck -Check $Check -Confirm:$false
    }
}

function Stop-UpdateCheck {
    <#
    .SYNOPSIS
        Releases a request of Start-UpdateCheck's, under way or ended.
    .EXAMPLE
        Stop-UpdateCheck -Check $check
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object] $Check
    )

    if ($Check.Client -and $PSCmdlet.ShouldProcess('the update check', 'Release')) {
        # Disposing the client cancels a request still under way.
        $Check.Client.Dispose()
    }
}

# The app's settings and secrets. Design: docs/ARCHITECTURE.md -> Settings and logs, Network
# configuration, SIM PIN.
#
# Settings live in a JSON file under %APPDATA%\fibocom-fm350-gl-windows-gui\. Secrets - an APN
# password, the SIM PIN - never go in it: each is kept in a file of its own in the same folder,
# encrypted with DPAPI for the current user (the elevated logon task runs as the same user).

$script:AppFolderName = 'fibocom-fm350-gl-windows-gui'

# Defaults, decided 2026-10-01 (DEVLOG): the subscription's own APN, dual stack; the operator's DNS;
# the modem as a backup connection (a metric far above what Windows gives wired and wireless
# adapters). The network mode: not managed - the modem keeps its own - until the user picks one
# (ROADMAP M5). Encrypted DNS: off, decided 2026-10-03 (DEVLOG); a DoH server named by its
# template looked up again every hour (decided 2026-10-03). The update notice: on (ROADMAP M7).
$script:DefaultSettings = [ordered]@{
    Apn               = ''
    PdpType           = 'IPV4V6'
    ApnAuthentication = 'None'
    ApnUser           = ''
    DnsServers        = [string[]]@()
    DnsOverHttps      = $false
    DohTemplate       = ''
    DohRefreshMinutes = 60
    InterfaceMetric   = 500
    NetworkMode       = ''
    LteBands          = [int[]]@()
    NrBands           = [int[]]@()
    CheckForUpdates   = $true
}

# A DoH template: an https address, without credentials, blanks or quotes (docs/AT-COMMANDS.md
# section 11.1).
$script:DohTemplateMaxLength = 2048

# How often, in minutes, the name of a DoH server named by its template is looked up again.
$script:DohRefreshRange = @(5, 1440)

# The band numbers a setting can name: those the AT+GTACT codec encodes (AT-COMMANDS section 5).
$script:SettingBandRanges = @{ LteBands = @(1, 99); NrBands = @(1, 512) }

# IPv6 alone is not offered: the adapter is configured from the context's IPv4 address
# (ARCHITECTURE -> Network configuration).
$script:PdpTypes = @('IP', 'IPV4V6')
$script:ApnAuthentications = @('None', 'PAP', 'CHAP')

function Get-AppDataPath {
    # The path of one of the app's files under %APPDATA% (settings and secrets) or %LOCALAPPDATA%
    # (logs, data).
    param([string] $Name, [switch] $Local)

    $root = if ($Local) { $env:LOCALAPPDATA } else { $env:APPDATA }
    Join-Path -Path $root -ChildPath $script:AppFolderName | Join-Path -ChildPath $Name
}

function Write-AppFile {
    # Writes a whole file at once: to a temporary file first, then moved over the old one, so a
    # crash halfway never leaves a truncated settings or secret file.
    param([string] $Path, [string] $Content)

    $folder = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $folder)) {
        [void](New-Item -ItemType Directory -Path $folder -Force)
    }
    $temporary = "$Path.tmp"
    try {
        [System.IO.File]::WriteAllText($temporary, $Content, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporary, $Path, $true)
    }
    catch {
        # Thrown on, whatever the caller's error preference: a file that wasn't written must
        # never pass for written. No temporary file is left behind.
        [System.IO.File]::Delete($temporary)
        throw
    }
}

function Test-AtStringValue {
    # Whether a value can travel as a quoted AT command argument: printable ASCII without a double
    # quote (the channel's rule for command text, AT-COMMANDS section 2).
    param([AllowEmptyString()] [string] $Value)

    $Value -cmatch '^[\x20\x21\x23-\x7E]*$'
}

function ConvertTo-AppSetting {
    <#
    .SYNOPSIS
        Validates settings and fills in the defaults.
    .DESCRIPTION
        Takes the settings as read from the file (an object or a hashtable; missing values take
        their defaults) and returns an object with Settings - every setting, valid -, Problems:
        one sentence per value that was invalid and replaced by its default, or unknown and
        ignored, in English, for the log - and the same as Issues: Setting, Rule and its Values,
        which the window says in its language. Nothing is thrown: a bad settings file never
        stops the app.

        Settings:
        - Apn: '' (the subscription's own) or an APN, printable ASCII without double quotes.
        - PdpType: 'IP' or 'IPV4V6'.
        - ApnAuthentication: 'None', 'PAP' or 'CHAP'; ApnUser goes with it. The password is a
          secret, kept apart (Save-ApnPassword).
        - DnsServers: IP addresses that replace the operator's DNS servers; empty keeps them.
        - DnsOverHttps: $true encrypts the queries to those servers (DNS over HTTPS); it needs
          them - the operator's speak no DoH -, or a DohTemplate whose host names the server:
          without either it is reported and kept, and no server is set until there are some.
          DohTemplate: '' (the template Windows knows for each server) or an https address that
          serves them all; a template naming an IP address serves only that server. Without
          DnsServers the template's host is the server: its address, or the addresses its name is
          looked up to, again every DohRefreshMinutes (5-1440).
        - InterfaceMetric: the modem adapter's interface metric, 1 to 9999. The default, 500,
          keeps the modem a backup connection; a low value makes it the preferred one.
        - NetworkMode: '' (the app leaves the modem's mode and bands as they are), 'Automatic'
          (4G + 5G), 'LteOnly' or 'NrOnly'. LteBands (1-99) and NrBands (1-512): the bands that
          mode may use, sorted, each once; empty for every band the modem supports.
        - CheckForUpdates: $true looks for a newer release once per start.
    .EXAMPLE
        (ConvertTo-AppSetting -InputObject @{ Apn = 'internet' }).Settings
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $InputObject
    )

    $values = @{}
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $values[[string]$key] = $InputObject[$key]
        }
    }
    elseif ($null -ne $InputObject) {
        foreach ($property in $InputObject.PSObject.Properties) {
            $values[$property.Name] = $property.Value
        }
    }

    $issues = [System.Collections.Generic.List[object]]::new()
    $settings = [ordered]@{}
    foreach ($name in $script:DefaultSettings.Keys) {
        $settings[$name] = $script:DefaultSettings[$name]
    }
    # A value replaced by its default, and the rule it broke (SettingRules), with its values.
    $reject = {
        param($name, $rule, $ruleValues)
        $issues.Add([pscustomobject]@{ Setting = $name; Rule = $rule; Values = [object[]]@($ruleValues) })
    }

    foreach ($name in @($values.Keys | Sort-Object)) {
        $value = $values[$name]
        $known = $script:DefaultSettings.Keys | Where-Object { $_ -eq $name } | Select-Object -First 1
        if (-not $known) {
            $issues.Add([pscustomobject]@{ Setting = $name; Rule = 'Unknown'; Values = [object[]]@() })
            continue
        }
        switch ($known) {
            'Apn' {
                if ($value -is [string] -and (Test-AtStringValue -Value $value) -and $value -eq $value.Trim()) {
                    $settings.Apn = $value
                }
                else {
                    & $reject $known 'Text'
                }
            }
            'PdpType' {
                if ($value -is [string] -and $value -in $script:PdpTypes) {
                    $settings.PdpType = $value.ToUpperInvariant()
                }
                else {
                    & $reject $known 'OneOf' ($script:PdpTypes -join ', ')
                }
            }
            'ApnAuthentication' {
                $match = if ($value -is [string]) { $script:ApnAuthentications | Where-Object { $_ -eq $value } }
                if ($match) {
                    $settings.ApnAuthentication = $match
                }
                else {
                    & $reject $known 'OneOf' ($script:ApnAuthentications -join ', ')
                }
            }
            'ApnUser' {
                if ($value -is [string] -and (Test-AtStringValue -Value $value)) {
                    $settings.ApnUser = $value
                }
                else {
                    & $reject $known 'TextQuotes'
                }
            }
            'DnsServers' {
                $servers = @($value | Where-Object { $null -ne $_ })
                $parsed = [System.Collections.Generic.List[string]]::new()
                foreach ($server in $servers) {
                    $address = $null
                    if ($server -is [string] -and [System.Net.IPAddress]::TryParse($server.Trim(), [ref]$address)) {
                        $parsed.Add($address.ToString())
                    }
                }
                if ($parsed.Count -eq $servers.Count) {
                    $settings.DnsServers = $parsed.ToArray()
                }
                else {
                    & $reject $known 'Addresses'
                }
            }
            'InterfaceMetric' {
                $number = 0
                if ($value -isnot [bool] -and [int]::TryParse([string]$value, [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$number) -and $number -ge 1 -and $number -le 9999) {
                    $settings.InterfaceMetric = $number
                }
                else {
                    & $reject $known 'Number' @(1, 9999)
                }
            }
            'NetworkMode' {
                $match = if ($value -is [string]) { @($script:NetworkModes.Keys) + '' | Where-Object { $_ -eq $value } | Select-Object -First 1 }
                if ($null -ne $match) {
                    $settings.NetworkMode = $match
                }
                else {
                    & $reject $known 'EmptyOrOneOf' ($script:NetworkModes.Keys -join ', ')
                }
            }
            { $_ -in 'DnsOverHttps', 'CheckForUpdates' } {
                if ($value -is [bool]) {
                    $settings[$known] = $value
                }
                else {
                    & $reject $known 'Bool'
                }
            }
            'DohRefreshMinutes' {
                $low, $high = $script:DohRefreshRange
                $number = 0
                if ($value -isnot [bool] -and [int]::TryParse([string]$value, [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$number) -and $number -ge $low -and $number -le $high) {
                    $settings.DohRefreshMinutes = $number
                }
                else {
                    & $reject $known 'Minutes' @($low, $high)
                }
            }
            'DohTemplate' {
                if ($value -is [string] -and (Test-DohTemplate -Template $value)) {
                    $settings.DohTemplate = $value
                }
                else {
                    & $reject $known 'Https'
                }
            }
            { $_ -in 'LteBands', 'NrBands' } {
                $low, $high = $script:SettingBandRanges[$known]
                $items = @($value | Where-Object { $null -ne $_ })
                $bands = [System.Collections.Generic.SortedSet[int]]::new()
                foreach ($item in $items) {
                    $number = 0
                    if ($item -isnot [bool] -and [int]::TryParse([string]$item, [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$number) -and $number -ge $low -and $number -le $high) {
                        [void]$bands.Add($number)
                    }
                }
                if ($bands.Count -eq $items.Count) {
                    $settings[$known] = [int[]]@($bands)
                }
                else {
                    & $reject $known 'Bands' @($low, $high)
                }
            }
        }
    }

    # Encrypted DNS is for the servers of the override, and a template naming an IP address
    # serves only that server.
    if ($settings.DnsOverHttps -and @($settings.DnsServers).Count -eq 0 -and -not $settings.DohTemplate) {
        $issues.Add([pscustomobject]@{ Setting = 'DnsOverHttps'; Rule = 'DohNeedsServers'; Values = [object[]]@() })
    }
    $templateHost = if ($settings.DohTemplate) { ([uri]$settings.DohTemplate).Host.Trim('[', ']') } else { $null }
    $address = $null
    if ($templateHost -and [System.Net.IPAddress]::TryParse($templateHost, [ref]$address) -and @($settings.DnsServers | Where-Object { $_ -ne $address.ToString() }).Count -gt 0) {
        $settings.DohTemplate = ''
        & $reject 'DohTemplate' 'TemplateAddress' $templateHost
    }

    [pscustomobject]@{
        Settings = [pscustomobject]$settings
        Problems = [string[]]@($issues | ForEach-Object { ConvertTo-SettingProblemText -Issue $_ })
        Issues   = [object[]]$issues.ToArray()
    }
}

# Each rule a setting can break, in English: the settings' problems as the log says them. The
# window says them in the app's language (its texts Setting.* and Rule.*).
$script:SettingRules = @{
    Text         = 'must be printable ASCII without double quotes or surrounding blanks'
    TextQuotes   = 'must be printable ASCII without double quotes'
    OneOf        = 'must be one of {0}'
    EmptyOrOneOf = 'must be empty or one of {0}'
    Addresses    = 'must be a list of IP addresses'
    Number       = 'must be a whole number from {0} to {1}'
    Minutes      = 'must be a whole number of minutes from {0} to {1}'
    Bool         = 'must be true or false'
    Https        = 'must be empty or an https address without blanks, quotes or credentials'
    Bands        = 'must be a list of distinct band numbers from {0} to {1}'
}

function ConvertTo-SettingProblemText {
    # One issue of ConvertTo-AppSetting's - Setting, Rule, Values - as an English sentence.
    param([object] $Issue)

    $values = [object[]]@($Issue.Values)
    switch ($Issue.Rule) {
        'Unknown' { return "Unknown setting '$($Issue.Setting)' is ignored." }
        'Unreadable' { return "The settings file can't be read ($($values[0])); the defaults are used." }
        'DohNeedsServers' { return 'DnsOverHttps needs DnsServers, or a DohTemplate that names the server: the operator''s servers speak no DoH, and no DNS server is set until there is one.' }
        'TemplateAddress' { return "DohTemplate names the address $($values[0]), so it can serve only that server; the default is used." }
    }
    $why = [string]::Format([cultureinfo]::InvariantCulture, $script:SettingRules[$Issue.Rule], $values)
    "$($Issue.Setting) $why; the default is used."
}

function Test-DohTemplate {
    # Whether a value can be a DoH template: empty, or an absolute https address with a host, no
    # credentials, no blanks or quotes.
    param([AllowEmptyString()] [string] $Template)

    if ($Template -eq '') {
        return $true
    }
    $uri = $null
    $Template.Length -le $script:DohTemplateMaxLength -and $Template -notmatch '[\s"]' -and
    [uri]::TryCreate($Template, [System.UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https' -and $uri.Host -and -not $uri.UserInfo
}

function Import-AppSetting {
    <#
    .SYNOPSIS
        Reads the settings file, validates it, and fills in the defaults.
    .DESCRIPTION
        Returns what ConvertTo-AppSetting returns: Settings, Problems and Issues. A missing file
        gives the defaults without a problem; an unreadable one gives the defaults and says so.
    .EXAMPLE
        $settings = (Import-AppSetting).Settings
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = (Get-AppDataPath -Name 'settings.json')
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ConvertTo-AppSetting -InputObject $null
    }
    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $result = ConvertTo-AppSetting -InputObject $null
        $result.Issues = [object[]]@([pscustomobject]@{ Setting = $null; Rule = 'Unreadable'; Values = [object[]]@($_.Exception.Message) })
        $result.Problems = [string[]]@($result.Issues | ForEach-Object { ConvertTo-SettingProblemText -Issue $_ })
        return $result
    }
    ConvertTo-AppSetting -InputObject $content
}

function Export-AppSetting {
    <#
    .SYNOPSIS
        Writes the settings file.
    .DESCRIPTION
        Validates the settings first and refuses to write any that is invalid or unknown, so the
        file always reads back as written. The file is replaced as a whole.
    .EXAMPLE
        Export-AppSetting -Settings ([pscustomobject]@{ Apn = 'internet' })
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object] $Settings,

        [string] $Path = (Get-AppDataPath -Name 'settings.json')
    )

    $checked = ConvertTo-AppSetting -InputObject $Settings
    if ($checked.Problems.Count -gt 0) {
        throw [System.ArgumentException]::new("Settings not saved: $($checked.Problems -join ' ')", 'Settings')
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Write settings')) {
        Write-AppFile -Path $Path -Content ($checked.Settings | ConvertTo-Json -Depth 3)
    }
}

function ConvertTo-ProtectedText {
    # A secret encrypted with DPAPI for the current user, as text. -Text protects a value that is
    # not typed by the user (a fingerprint).
    param([securestring] $Secret, [string] $Text)

    if ($PSBoundParameters.ContainsKey('Text')) {
        $Secret = [securestring]::new()
        foreach ($character in $Text.ToCharArray()) {
            $Secret.AppendChar($character)
        }
    }
    ConvertFrom-SecureString -SecureString $Secret
}

function ConvertFrom-ProtectedText {
    # The secret back from ConvertTo-ProtectedText; $null if it can't be decrypted (another user,
    # another machine, a damaged file).
    param([string] $Text)

    try {
        ConvertTo-SecureString -String $Text -ErrorAction Stop
    }
    catch {
        $null
    }
}

function Save-ApnPassword {
    <#
    .SYNOPSIS
        Stores the APN password, encrypted for the current user.
    .DESCRIPTION
        The password goes in a file of its own next to the settings, encrypted with DPAPI for the
        current user. It must be printable ASCII without double quotes: it travels as an AT
        command argument.
    .EXAMPLE
        Save-ApnPassword -Password (Read-Host -AsSecureString)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [securestring] $Password,

        [string] $Path = (Get-AppDataPath -Name 'apn-password.dat')
    )

    if (-not (Test-AtStringValue -Value ([System.Net.NetworkCredential]::new('', $Password).Password))) {
        throw [System.ArgumentException]::new('The APN password must be printable ASCII without double quotes.', 'Password')
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Store the APN password')) {
        Write-AppFile -Path $Path -Content (ConvertTo-ProtectedText -Secret $Password)
    }
}

function Get-ApnPassword {
    <#
    .SYNOPSIS
        Returns the stored APN password as a SecureString, or nothing.
    .DESCRIPTION
        Nothing when no password is stored, or when the file can't be decrypted by the current
        user.
    .EXAMPLE
        $password = Get-ApnPassword
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [string] $Path = (Get-AppDataPath -Name 'apn-password.dat')
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $text = [string](Get-Content -LiteralPath $Path -Raw)
        if ($text.Trim()) {
            ConvertFrom-ProtectedText -Text $text.Trim()
        }
    }
}

function Remove-ApnPassword {
    <#
    .SYNOPSIS
        Deletes the stored APN password.
    .EXAMPLE
        Remove-ApnPassword
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Path = (Get-AppDataPath -Name 'apn-password.dat')
    )

    if ((Test-Path -LiteralPath $Path) -and $PSCmdlet.ShouldProcess($Path, 'Delete the APN password')) {
        Remove-Item -LiteralPath $Path -Force
    }
}

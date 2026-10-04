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
# Data usage: the billing cycle starts on day 1, no quota (decided 2026-10-04).
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
    UsageCycleDay     = 1
    UsageQuotaGB      = 0
}

# The quota a setting can name, in gigabytes (10^9 bytes); 0 is none.
$script:UsageQuotaRange = @(0, 10000)

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

# The settings that belong to a SIM, kept for each SIM apart (decided 2026-10-04, DEVLOG): an
# operator gives them together. In sim-settings.json, each SIM told by a fingerprint of its ICCID,
# encrypted as the PIN file's is; its APN password in a file of its own, named by the entry's
# random Id.
$script:SimSettingNames = @('Apn', 'PdpType', 'ApnAuthentication', 'ApnUser')

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
        - UsageCycleDay: the day of the month the billing cycle starts on, 1 to 31; a month
          without it starts the cycle on its last day.
        - UsageQuotaGB: the data the cycle allows, in gigabytes (10^9 bytes), decimals allowed,
          up to 10000; 0 for no quota.
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
            'UsageCycleDay' {
                $number = 0
                if ($value -isnot [bool] -and [int]::TryParse([string]$value, [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$number) -and $number -ge 1 -and $number -le 31) {
                    $settings.UsageCycleDay = $number
                }
                else {
                    & $reject $known 'Number' @(1, 31)
                }
            }
            'UsageQuotaGB' {
                $low, $high = $script:UsageQuotaRange
                $number = 0.0
                $text = if ($value -is [double] -or $value -is [decimal] -or $value -is [single]) { $value.ToString([cultureinfo]::InvariantCulture) } else { [string]$value }
                if ($value -isnot [bool] -and [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$number) -and $number -ge $low -and $number -le $high) {
                    $settings.UsageQuotaGB = $number
                }
                else {
                    & $reject $known 'Gigabytes' @($low, $high)
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
    Gigabytes    = 'must be a number of gigabytes from {0} to {1}, 0 for none'
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

function Get-SimSettingFingerprint {
    # What tells a SIM among the settings kept for each SIM: Get-SimFingerprint's, of its ICCID
    # without the filler F - the modem's +ICCID carries it on a 19-digit ICCID, lpac's list of
    # profiles doesn't.
    param([string] $Iccid)

    Get-SimFingerprint -Iccid $Iccid.Trim().TrimEnd('F', 'f')
}

function Get-SimSettingValue {
    # The APN settings among settings - an object or a dictionary -, as a hashtable of those
    # given.
    param([object] $Settings)

    $values = @{}
    foreach ($name in $script:SimSettingNames) {
        $value = if ($Settings -is [System.Collections.IDictionary]) { $Settings[$name] } elseif ($null -ne $Settings -and $Settings.PSObject.Properties[$name]) { $Settings.$name } else { $null }
        if ($null -ne $value) {
            $values[$name] = $value
        }
    }
    $values
}

function Get-SimApnSecretPath {
    <#
    .SYNOPSIS
        Where a SIM's APN password is kept.
    .DESCRIPTION
        A file of its own beside -ApnSecretPath, named by the SIM's entry's Id - which tells
        nothing of the SIM. Without an Id, -ApnSecretPath itself: the password saved before the
        settings were kept for each SIM.
    .EXAMPLE
        Get-SimApnSecretPath -ApnSecretPath (Get-AppDataPath -Name 'apn-password.dat') -Id $entry.Id
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ApnSecretPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Id
    )

    if (-not $Id) {
        return $ApnSecretPath
    }
    Join-Path -Path (Split-Path -Parent $ApnSecretPath) -ChildPath "apn-password-$Id.dat"
}

function Import-SimSetting {
    <#
    .SYNOPSIS
        Reads the settings kept for each SIM.
    .DESCRIPTION
        Returns Exists - whether the file is there: once it is, the settings file's APN settings
        belong to no SIM (Resolve-SimSetting) - and Sims, an entry per SIM: Fingerprint
        (Get-SimFingerprint's, decrypted - never in a snapshot or the log), Id (32 hexadecimal
        digits, which name its APN password's file), Apn, PdpType, ApnAuthentication and ApnUser.
        An entry that can't be decrypted or whose values are not valid is left out; a file that
        can't be read holds no SIM.
    .EXAMPLE
        $sims = Import-SimSetting
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = (Get-AppDataPath -Name 'sim-settings.json')
    )

    $sims = [System.Collections.Generic.List[object]]::new()
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $content = $null
    if ($exists) {
        try {
            $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $content = $null
        }
    }
    $entries = if ($content -and $content.PSObject.Properties['Sims']) { @($content.Sims) } else { @() }
    foreach ($entry in $entries) {
        if (-not $entry -or -not $entry.PSObject.Properties['Sim'] -or -not $entry.PSObject.Properties['Id'] -or [string]$entry.Id -cnotmatch '^[0-9a-f]{32}$') {
            continue
        }
        $sim = ConvertFrom-ProtectedText -Text ([string]$entry.Sim)
        $checked = ConvertTo-AppSetting -InputObject (Get-SimSettingValue -Settings $entry)
        if (-not $sim -or $checked.Issues.Count -gt 0) {
            continue
        }
        $item = [ordered]@{ Fingerprint = [System.Net.NetworkCredential]::new('', $sim).Password; Id = [string]$entry.Id }
        foreach ($name in $script:SimSettingNames) {
            $item[$name] = $checked.Settings.$name
        }
        $sims.Add([pscustomobject]$item)
    }
    [pscustomobject]@{ Exists = $exists; Sims = [object[]]$sims.ToArray() }
}

function Export-SimSetting {
    # Writes the settings kept for each SIM - Import-SimSetting's Sims -, each fingerprint
    # encrypted again. The file is replaced as a whole.
    param([object[]] $Sims, [string] $Path)

    $entries = foreach ($sim in @($Sims | Where-Object { $_ })) {
        $item = [ordered]@{ Sim = ConvertTo-ProtectedText -Text $sim.Fingerprint; Id = $sim.Id }
        foreach ($name in $script:SimSettingNames) {
            $item[$name] = $sim.$name
        }
        [pscustomobject]$item
    }
    Write-AppFile -Path $Path -Content ([pscustomobject]@{ Sims = [object[]]@($entries) } | ConvertTo-Json -Depth 4)
}

function Save-SimSetting {
    <#
    .SYNOPSIS
        Keeps the APN settings of one SIM.
    .DESCRIPTION
        Sets the SIM's entry among the settings kept for each SIM: Apn, PdpType,
        ApnAuthentication and ApnUser, taken from -Setting and validated - one that is not valid
        is refused, and nothing is written. An entry new for this SIM gets a new random Id.
        Returns the entry, as Import-SimSetting gives it. The SIM is told by its fingerprint
        (Get-SimFingerprint). The file is replaced as a whole.
    .EXAMPLE
        Save-SimSetting -Fingerprint (Get-SimFingerprint -Iccid $iccid) -Setting @{ Apn = 'internet' }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9A-F]{64}$')]
        [string] $Fingerprint,

        [Parameter(Mandatory)]
        [object] $Setting,

        [string] $Path = (Get-AppDataPath -Name 'sim-settings.json')
    )

    $checked = ConvertTo-AppSetting -InputObject (Get-SimSettingValue -Settings $Setting)
    if ($checked.Problems.Count -gt 0) {
        throw [System.ArgumentException]::new("SIM settings not saved: $($checked.Problems -join ' ')", 'Setting')
    }
    $sims = [System.Collections.Generic.List[object]]::new()
    foreach ($sim in (Import-SimSetting -Path $Path).Sims) {
        $sims.Add($sim)
    }
    $old = @($sims | Where-Object Fingerprint -EQ $Fingerprint) | Select-Object -First 1
    $entry = [ordered]@{
        Fingerprint = $Fingerprint.ToUpperInvariant()
        Id          = if ($old) { $old.Id } else { [System.Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant() }
    }
    foreach ($name in $script:SimSettingNames) {
        $entry[$name] = $checked.Settings.$name
    }
    $entry = [pscustomobject]$entry
    if ($old) {
        $sims[$sims.IndexOf($old)] = $entry
    }
    else {
        $sims.Add($entry)
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Keep the settings of a SIM')) {
        Export-SimSetting -Sims $sims.ToArray() -Path $Path
    }
    $entry
}

function Remove-SimSetting {
    <#
    .SYNOPSIS
        Forgets the settings kept for one SIM, and its APN password.
    .DESCRIPTION
        For an eSIM profile deleted: nothing of it is kept. -ApnSecretPath is the APN password's
        path that Get-SimApnSecretPath starts from. Does nothing for a SIM without settings of
        its own.
    .EXAMPLE
        Remove-SimSetting -Fingerprint (Get-SimFingerprint -Iccid $profile.Iccid)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9A-F]{64}$')]
        [string] $Fingerprint,

        [string] $Path = (Get-AppDataPath -Name 'sim-settings.json'),

        [string] $ApnSecretPath = (Get-AppDataPath -Name 'apn-password.dat')
    )

    $sims = (Import-SimSetting -Path $Path).Sims
    $gone = @($sims | Where-Object Fingerprint -EQ $Fingerprint)
    if ($gone.Count -eq 0 -or -not $PSCmdlet.ShouldProcess($Path, 'Forget the settings of a SIM')) {
        return
    }
    Export-SimSetting -Sims @($sims | Where-Object Fingerprint -NE $Fingerprint) -Path $Path
    foreach ($entry in $gone) {
        Remove-ApnPassword -Path (Get-SimApnSecretPath -ApnSecretPath $ApnSecretPath -Id $entry.Id) -Confirm:$false
    }
}

function Move-ApnSettingToSim {
    <#
    .SYNOPSIS
        Gives the APN settings saved before they were kept for each SIM to the SIM in use.
    .DESCRIPTION
        The first SIM identified takes the settings file's Apn, PdpType, ApnAuthentication and
        ApnUser, and the APN password (decided 2026-10-04): its entry is written, with the
        password file copied as it is to the entry's own first; then the old one is deleted and
        the settings file's APN settings go back to their defaults. Once the file of the settings
        kept for each SIM is there, the settings file's are no SIM's: a step that fails after it
        leaves nothing a SIM would take, and the move does nothing again - it returns the SIM's
        entry, if it has one. A settings file that can't be read is never taken for one without
        APN settings: the move throws, to be tried again. Returns the entry (Save-SimSetting's).
    .EXAMPLE
        Move-ApnSettingToSim -Fingerprint (Get-SimFingerprint -Iccid $iccid)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9A-F]{64}$')]
        [string] $Fingerprint,

        [string] $SettingsPath = (Get-AppDataPath -Name 'settings.json'),

        [string] $Path = (Get-AppDataPath -Name 'sim-settings.json'),

        [string] $ApnSecretPath = (Get-AppDataPath -Name 'apn-password.dat')
    )

    $kept = Import-SimSetting -Path $Path
    if ($kept.Exists) {
        return @($kept.Sims | Where-Object Fingerprint -EQ $Fingerprint) | Select-Object -First 1
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Give the APN settings to the SIM in use')) {
        return
    }
    $read = Import-AppSetting -Path $SettingsPath
    if (@($read.Issues | Where-Object Rule -EQ 'Unreadable').Count -gt 0) {
        throw [System.IO.IOException]::new("The settings file can't be read: the APN settings are given to no SIM yet.")
    }
    $settings = $read.Settings
    $id = [System.Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    $copy = Get-SimApnSecretPath -ApnSecretPath $ApnSecretPath -Id $id
    # Copied as it is: one that can't be decrypted stays so - never an empty password.
    if (Test-Path -LiteralPath $ApnSecretPath -PathType Leaf) {
        [System.IO.File]::Copy($ApnSecretPath, $copy, $true)
    }
    try {
        $entry = [pscustomobject]@{ Fingerprint = $Fingerprint.ToUpperInvariant(); Id = $id }
        foreach ($name in $script:SimSettingNames) {
            $entry | Add-Member -NotePropertyName $name -NotePropertyValue $settings.$name
        }
        $sims = @((Import-SimSetting -Path $Path).Sims | Where-Object { $_.Fingerprint -ne $entry.Fingerprint }) + $entry
        Export-SimSetting -Sims $sims -Path $Path
    }
    catch {
        Remove-ApnPassword -Path $copy -Confirm:$false
        throw
    }
    Remove-ApnPassword -Path $ApnSecretPath -Confirm:$false
    $values = [ordered]@{}
    foreach ($property in $settings.PSObject.Properties) {
        $values[$property.Name] = $property.Value
    }
    $moved = @($script:SimSettingNames | Where-Object { $values[$_] -cne $script:DefaultSettings[$_] }).Count -gt 0
    foreach ($name in $script:SimSettingNames) {
        $values[$name] = $script:DefaultSettings[$name]
    }
    # Written only when it held some: the settings file is not created for nothing.
    if ($moved) {
        Export-AppSetting -Settings $values -Path $SettingsPath -Confirm:$false
    }
    $entry
}

function Resolve-SimSetting {
    <#
    .SYNOPSIS
        The settings a SIM connects with: the app's, with that SIM's own APN settings.
    .DESCRIPTION
        A pure function. -SimSettings is Import-SimSetting's; -Fingerprint the SIM's
        (Get-SimFingerprint), $null when none is identified. Returns Settings (-Settings with
        Apn, PdpType, ApnAuthentication and ApnUser replaced), Id (the SIM's entry's, which names
        its APN password's file - Get-SimApnSecretPath -; $null without one) and Source:
        - 'Sim': the SIM's own.
        - 'Legacy': no SIM has settings of its own yet: the settings file's, as saved before they
          were kept for each SIM - the first SIM identified takes them (Move-ApnSettingToSim).
        - 'New': a SIM without settings of its own: the defaults - the subscription's own APN -
          until the user gives some (decided 2026-10-04).
        - 'Unknown': no SIM identified: the settings file's, which nothing connects with.
    .EXAMPLE
        (Resolve-SimSetting -Settings $settings -SimSettings (Import-SimSetting) -Fingerprint $fingerprint).Settings
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Settings,

        [AllowNull()]
        [object] $SimSettings,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Fingerprint
    )

    $own = if ($Fingerprint -and $SimSettings) { @($SimSettings.Sims | Where-Object { $_ -and $_.Fingerprint -eq $Fingerprint }) | Select-Object -First 1 } else { $null }
    $source = if (-not $Fingerprint) { 'Unknown' } elseif ($own) { 'Sim' } elseif (-not $SimSettings -or -not $SimSettings.Exists) { 'Legacy' } else { 'New' }
    $values = [ordered]@{}
    if ($Settings -is [System.Collections.IDictionary]) {
        foreach ($key in $Settings.Keys) {
            $values[[string]$key] = $Settings[$key]
        }
    }
    else {
        foreach ($property in $Settings.PSObject.Properties) {
            $values[$property.Name] = $property.Value
        }
    }
    if ($source -in 'Sim', 'New') {
        foreach ($name in $script:SimSettingNames) {
            $values[$name] = if ($own) { $own.$name } else { $script:DefaultSettings[$name] }
        }
    }
    [pscustomobject]@{
        Settings = [pscustomobject]$values
        Id       = if ($own) { $own.Id } else { $null }
        Source   = $source
    }
}

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
# (ROADMAP M5).
$script:DefaultSettings = [ordered]@{
    Apn               = ''
    PdpType           = 'IPV4V6'
    ApnAuthentication = 'None'
    ApnUser           = ''
    DnsServers        = [string[]]@()
    InterfaceMetric   = 500
    NetworkMode       = ''
    LteBands          = [int[]]@()
    NrBands           = [int[]]@()
}

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
        their defaults) and returns an object with Settings - every setting, valid - and
        Problems: one sentence per value that was invalid and replaced by its default, or unknown
        and ignored. Nothing is thrown: a bad settings file never stops the app.

        Settings:
        - Apn: '' (the subscription's own) or an APN, printable ASCII without double quotes.
        - PdpType: 'IP' or 'IPV4V6'.
        - ApnAuthentication: 'None', 'PAP' or 'CHAP'; ApnUser goes with it. The password is a
          secret, kept apart (Save-ApnPassword).
        - DnsServers: IP addresses that replace the operator's DNS servers; empty keeps them.
        - InterfaceMetric: the modem adapter's interface metric, 1 to 9999. The default, 500,
          keeps the modem a backup connection; a low value makes it the preferred one.
        - NetworkMode: '' (the app leaves the modem's mode and bands as they are), 'Automatic'
          (4G + 5G), 'LteOnly' or 'NrOnly'. LteBands (1-99) and NrBands (1-512): the bands that
          mode may use, sorted, each once; empty for every band the modem supports.
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

    $problems = [System.Collections.Generic.List[string]]::new()
    $settings = [ordered]@{}
    foreach ($name in $script:DefaultSettings.Keys) {
        $settings[$name] = $script:DefaultSettings[$name]
    }
    $reject = {
        param($name, $why)
        $problems.Add("$name $why; the default is used.")
    }

    foreach ($name in @($values.Keys | Sort-Object)) {
        $value = $values[$name]
        $known = $script:DefaultSettings.Keys | Where-Object { $_ -eq $name } | Select-Object -First 1
        if (-not $known) {
            $problems.Add("Unknown setting '$name' is ignored.")
            continue
        }
        switch ($known) {
            'Apn' {
                if ($value -is [string] -and (Test-AtStringValue -Value $value) -and $value -eq $value.Trim()) {
                    $settings.Apn = $value
                }
                else {
                    & $reject $known 'must be printable ASCII without double quotes or surrounding blanks'
                }
            }
            'PdpType' {
                if ($value -is [string] -and $value -in $script:PdpTypes) {
                    $settings.PdpType = $value.ToUpperInvariant()
                }
                else {
                    & $reject $known "must be one of $($script:PdpTypes -join ', ')"
                }
            }
            'ApnAuthentication' {
                $match = if ($value -is [string]) { $script:ApnAuthentications | Where-Object { $_ -eq $value } }
                if ($match) {
                    $settings.ApnAuthentication = $match
                }
                else {
                    & $reject $known "must be one of $($script:ApnAuthentications -join ', ')"
                }
            }
            'ApnUser' {
                if ($value -is [string] -and (Test-AtStringValue -Value $value)) {
                    $settings.ApnUser = $value
                }
                else {
                    & $reject $known 'must be printable ASCII without double quotes'
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
                    & $reject $known 'must be a list of IP addresses'
                }
            }
            'InterfaceMetric' {
                $number = 0
                if ($value -isnot [bool] -and [int]::TryParse([string]$value, [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$number) -and $number -ge 1 -and $number -le 9999) {
                    $settings.InterfaceMetric = $number
                }
                else {
                    & $reject $known 'must be a whole number from 1 to 9999'
                }
            }
            'NetworkMode' {
                $match = if ($value -is [string]) { @($script:NetworkModes.Keys) + '' | Where-Object { $_ -eq $value } | Select-Object -First 1 }
                if ($null -ne $match) {
                    $settings.NetworkMode = $match
                }
                else {
                    & $reject $known "must be empty or one of $($script:NetworkModes.Keys -join ', ')"
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
                    & $reject $known "must be a list of distinct band numbers from $low to $high"
                }
            }
        }
    }

    [pscustomobject]@{
        Settings = [pscustomobject]$settings
        Problems = [string[]]$problems
    }
}

function Import-AppSetting {
    <#
    .SYNOPSIS
        Reads the settings file, validates it, and fills in the defaults.
    .DESCRIPTION
        Returns what ConvertTo-AppSetting returns: Settings and Problems. A missing file gives the
        defaults without a problem; an unreadable one gives the defaults and says so.
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
        $result.Problems = [string[]]@("The settings file can't be read ($($_.Exception.Message)); the defaults are used.")
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

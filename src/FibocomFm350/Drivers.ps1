# The modem's AT-port driver, "bring your own driver": the packages the app knows, reading and
# checking a package the user hands over, installing and removing it with pnputil. The app never
# downloads or bundles a driver, and never runs a program from a package. Facts and sources:
# docs/AT-COMMANDS.md section 1.1; design: docs/ARCHITECTURE.md -> Drivers.

# The packages the app knows: the SHA-256 of their files, and where a copy is published.
$script:KnownDrivers = @((Import-PowerShellDataFile -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'Data/Drivers.psd1')).Packages)

# The signer of a WHQL release signature, as our package's catalog names it, and the enhanced key
# usage of WHQL cryptography (an attestation signature has another).
$script:WhqlSigner = @{ CN = 'Microsoft Windows Hardware Compatibility Publisher'; O = 'Microsoft Corporation' }
$script:WhqlKeyUsage = '1.3.6.1.4.1.311.10.3.5'

# WinVerifyTrust's answer for a file whose hash the catalog doesn't hold (TRUST_E_NOSIGNATURE).
$script:NotInCatalog = 0x800B0100

# A package the app copies: a driver package is a few MB, so a bigger one is refused.
$script:DriverPackageLimits = @{ Files = 1000; Bytes = 64MB }

# A folder only SYSTEM and administrators can open, with what is created in it: no inherited
# permission, so a user's program can't change a package between its check and its install.
$script:DriverStagingSddl = 'D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'

# How long pnputil may take to add or remove a package before it is stopped.
$script:PnputilTimeoutMs = 300000

function Get-KnownDriverPackage {
    <#
    .SYNOPSIS
        The driver packages the app knows (Data/Drivers.psd1).
    .DESCRIPTION
        Each with Name, Version, Files (SHA-256 by path relative to the INF's folder) and Copy:
        where a copy is published - Publisher, Page (pinned to a commit), File and its Sha256.
    .EXAMPLE
        (Get-KnownDriverPackage)[0].Copy.Page
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    foreach ($package in $script:KnownDrivers) {
        $package
    }
}

function ConvertFrom-InfQuote {
    # An INF value without its outermost double quotes, a doubled quote inside read as one.
    param([string] $Value)

    if ($Value.Length -ge 2 -and $Value.StartsWith('"') -and $Value.EndsWith('"')) {
        return $Value.Substring(1, $Value.Length - 2).Replace('""', '"')
    }
    $Value
}

function Split-InfField {
    # The comma-separated fields of an INF value, commas inside quotes kept, each one trimmed.
    param([string] $Value)

    $fields = [System.Collections.Generic.List[string]]::new()
    $field = [System.Text.StringBuilder]::new()
    $quoted = $false
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq ',' -and -not $quoted) {
            $fields.Add($field.ToString().Trim())
            [void]$field.Clear()
            continue
        }
        if ($char -eq '"') {
            $quoted = -not $quoted
        }
        [void]$field.Append($char)
    }
    $fields.Add($field.ToString().Trim())
    $fields.ToArray()
}

function ConvertFrom-DriverInf {
    <#
    .SYNOPSIS
        Reads what the app needs from an INF file's text: its class, provider and version, the
        catalog it names, and the hardware IDs it lists for x64 Windows.
    .DESCRIPTION
        A pure function, written from the INF syntax rules (AT-COMMANDS section 1.1): a ';'
        outside quotes and %strkey% tokens starts a comment, a '\' at the end of a line continues
        it, sections of the same name merge, names and keys are case-insensitive, %strkey% tokens
        come from the [Strings] section.

        The catalog is the one [Version] names for -Architecture: CatalogFile.NT<architecture>,
        else CatalogFile.NT, else CatalogFile; $null when there is none, or when it is no plain
        file name - Windows looks for it beside the INF. The hardware IDs are those of the
        models sections [Manufacturer] decorates for -Architecture (NT<architecture>...; an
        undecorated one is for x86 only): every ID of every line, the hardware ID and the
        compatible ones, as written. PackageFiles are the package's files, for any architecture,
        by path relative to the INF's folder ('/' between folders): every catalog [Version]
        names, every file of the [SourceDisksFiles] sections under the path [SourceDisksNames]
        gives its disk - the section of the same architecture first -, and the disks' tag and
        cabinet files.

        Returns Class, Provider, Version, Date, CatalogFile, HardwareIds and PackageFiles.
    .EXAMPLE
        ConvertFrom-DriverInf -Text (Get-Content -LiteralPath $inf)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text,

        [ValidateSet('x86', 'amd64', 'arm64')]
        [string] $Architecture = 'amd64'
    )

    # Logical lines: comments dropped, continued lines joined.
    $lines = [System.Collections.Generic.List[string]]::new()
    $pending = ''
    foreach ($raw in @($Text) + @('')) {
        $line = $pending + [regex]::Match([string]$raw, '^(?:"[^"]*"|%[^%\s]*%|[^;"])*').Value.TrimEnd()
        $pending = ''
        if ($line.EndsWith('\')) {
            $pending = $line.Substring(0, $line.Length - 1)
            continue
        }
        if ($line.Trim()) {
            $lines.Add($line.Trim())
        }
    }

    # The sections, by lower-case name; their entries as Key (lower case, $null for a line
    # without '='), Name (the key as written) and Value.
    $sections = @{}
    $current = $null
    foreach ($line in $lines) {
        if ($line -match '^\[([^\]]+)\]$') {
            $current = $Matches[1].Trim().ToLowerInvariant()
            if (-not $sections.ContainsKey($current)) {
                $sections[$current] = [System.Collections.Generic.List[object]]::new()
            }
            continue
        }
        if ($null -eq $current) {
            continue
        }
        $at = $line.IndexOf('=')
        $sections[$current].Add($(if ($at -gt 0) {
                    $name = $line.Substring(0, $at).Trim()
                    [pscustomobject]@{ Key = $name.ToLowerInvariant(); Name = $name; Value = $line.Substring($at + 1).Trim() }
                }
                else {
                    [pscustomobject]@{ Key = $null; Name = $null; Value = $line }
                }))
    }
    $entries = { param($name) if ($sections.ContainsKey($name)) { $sections[$name] } }

    $strings = @{}
    foreach ($entry in & $entries 'strings') {
        if ($entry.Key) {
            $strings[$entry.Key] = ConvertFrom-InfQuote -Value $entry.Value
        }
    }
    # A value with its %strkey% tokens replaced ('%%' is a percent sign), then unquoted.
    $expand = {
        param($value)
        $replaced = [regex]::Replace($value, '%([^%]*)%', {
                param($match)
                $key = $match.Groups[1].Value.ToLowerInvariant()
                if (-not $key) { '%' } elseif ($strings.ContainsKey($key)) { $strings[$key] } else { $match.Value }
            })
        ConvertFrom-InfQuote -Value $replaced
    }

    $version = @{}
    foreach ($entry in & $entries 'version') {
        if ($entry.Key) {
            $version[$entry.Key] = $entry.Value
        }
    }
    $catalog = $null
    foreach ($key in "catalogfile.nt$Architecture", 'catalogfile.nt', 'catalogfile') {
        if ($version.ContainsKey($key)) {
            $catalog = & $expand $version[$key]
            break
        }
    }
    if ($catalog -and ($catalog -match '[\\/:]' -or $catalog -match '^\.+$')) {
        $catalog = $null
    }
    $driverVer = @(if ($version.ContainsKey('driverver')) { Split-InfField -Value $version['driverver'] })

    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in & $entries 'manufacturer') {
        $fields = @(Split-InfField -Value $entry.Value)
        $models = ConvertFrom-InfQuote -Value $fields[0]
        $decorations = @($fields | Select-Object -Skip 1 | Where-Object { $_ })
        $names = if ($decorations.Count -eq 0) {
            if ($Architecture -eq 'x86') { $models }
        }
        else {
            foreach ($decoration in $decorations) {
                if ($decoration -match '^NT([a-z0-9]*)(\.|$)' -and $Matches[1] -eq $Architecture) {
                    "$models.$decoration"
                }
            }
        }
        foreach ($name in @($names)) {
            foreach ($line in & $entries $name.ToLowerInvariant()) {
                if (-not $line.Key) {
                    continue
                }
                foreach ($id in @(Split-InfField -Value $line.Value | Select-Object -Skip 1)) {
                    $id = ConvertFrom-InfQuote -Value $id
                    if ($id -and -not ($ids -contains $id)) {
                        $ids.Add($id)
                    }
                }
            }
        }
    }

    # The package's files, each once: a path's parts joined with '/', '.' and empty parts left out.
    $files = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([string[]] $part)
        $path = @($part | ForEach-Object { $_ -split '[\\/]' } | Where-Object { $_ -and $_ -ne '.' }) -join '/'
        if ($path -and -not ($files -contains $path)) {
            $files.Add($path)
        }
    }
    foreach ($key in @($version.Keys | Where-Object { $_ -like 'catalogfile*' } | Sort-Object)) {
        $name = & $expand $version[$key]
        if ($name -and $name -notmatch '[\\/:]' -and $name -notmatch '^\.+$') {
            & $add $name
        }
    }
    # The disks, by architecture ('' undecorated) and disk ID: their path, tag and cabinet files.
    $disks = @{}
    foreach ($section in @($sections.Keys | Where-Object { $_ -match '^sourcedisksnames(\.|$)' })) {
        $suffix = $section.Substring('sourcedisksnames'.Length).TrimStart('.')
        $disks[$suffix] = @{}
        foreach ($entry in & $entries $section) {
            if ($entry.Key) {
                $fields = @(Split-InfField -Value $entry.Value | ForEach-Object { ConvertFrom-InfQuote -Value $_ })
                $field = { param($index) if ($fields.Count -gt $index) { $fields[$index] } else { '' } }
                $disks[$suffix][$entry.Key] = @{ Path = & $field 3; Tags = @((& $field 1), (& $field 5) | Where-Object { $_ }) }
            }
        }
    }
    foreach ($disk in @($disks.Values | ForEach-Object { $_.Values })) {
        foreach ($tag in $disk.Tags) {
            & $add $disk.Path, $tag
            & $add $tag
        }
    }
    foreach ($section in @($sections.Keys | Where-Object { $_ -match '^sourcedisksfiles(\.|$)' } | Sort-Object)) {
        $suffix = $section.Substring('sourcedisksfiles'.Length).TrimStart('.')
        foreach ($entry in & $entries $section) {
            if (-not $entry.Key) {
                continue
            }
            $fields = @(Split-InfField -Value $entry.Value | ForEach-Object { ConvertFrom-InfQuote -Value $_ })
            $disk = $null
            foreach ($candidate in @($suffix, '') | Select-Object -Unique) {
                if (-not $disk -and $disks.ContainsKey($candidate) -and $disks[$candidate].ContainsKey($fields[0])) {
                    $disk = $disks[$candidate][$fields[0]]
                }
            }
            & $add $(if ($disk) { $disk.Path } else { '' }), $(if ($fields.Count -gt 1) { $fields[1] } else { '' }), $entry.Name
        }
    }

    [pscustomobject]@{
        Class        = if ($version.ContainsKey('class')) { & $expand $version['class'] } else { $null }
        Provider     = if ($version.ContainsKey('provider')) { & $expand $version['provider'] } else { $null }
        Version      = if ($driverVer.Count -gt 1 -and $driverVer[1]) { $driverVer[1] } else { $null }
        Date         = if ($driverVer.Count -gt 0 -and $driverVer[0]) { $driverVer[0] } else { $null }
        CatalogFile  = $catalog
        HardwareIds  = [string[]]$ids.ToArray()
        PackageFiles = [string[]]$files.ToArray()
    }
}

function Resolve-DriverPackage {
    <#
    .SYNOPSIS
        Decides whether a driver package the user handed over may be installed for the modem's AT
        port, and whether it is a version the app knows.
    .DESCRIPTION
        A pure decision (ARCHITECTURE -> Drivers) over Get-DriverPackageFact's facts, one per INF
        in the package: Path (of the INF, in the package), Inf (ConvertFrom-DriverInf's), Catalog
        ($true: the catalog the INF names is beside it), Signer (Subject and KeyUsages of the
        catalog's signer certificate; $null when none can be read), CatalogCheck (WinVerifyTrust's
        answer for the INF against that catalog: 0 when the catalog's signature is trusted and it
        holds the INF's hash) and Files (SHA-256 by path relative to the INF's folder, '/'
        between folders).

        Only an INF that lists the modem's AT port counts: -ProductId's (7126 or 7127), or
        either's when no modem is attached. It may be installed when its catalog is in the
        package, signed by Microsoft for WHQL, and vouches for the INF - the file the app reads;
        Windows checks every other file against the catalog when pnputil adds the package. When
        its files have every SHA-256 of one of -Known's packages, it is a verified version.

        Returns Verdict - 'Verified', 'Signed' (it may be installed, but is no version the app
        knows) or 'Refused' -, Problems (why it is refused: 'NoInf', 'NotForModem', 'NoCatalog',
        'NotWhql', 'NotInCatalog', 'NotTrusted'), Path (the INF chosen), Provider, Version
        (the INF's) and Known (the known package's Name and Version).
    .EXAMPLE
        Resolve-DriverPackage -Inf @(Get-DriverPackageFact -Folder $folder) -Known (Get-KnownDriverPackage) -ProductId 7127
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Inf,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Known,

        [AllowEmptyString()]
        [ValidateSet('', '7126', '7127')]
        [string] $ProductId
    )

    $products = if ($ProductId) { @($ProductId) } else { @($script:AtPortInterfaces.Keys | Sort-Object) }
    # The AT port's hardware ID, with or without the revision.
    $patterns = foreach ($product in $products) {
        '^USB\\VID_0E8D&PID_{0}(&REV_[0-9A-F]{{4}})?&MI_{1:X2}$' -f $product, $script:AtPortInterfaces[$product]
    }
    $outcome = {
        param($verdict, $problems, $fact, $match)
        [pscustomobject]@{
            Verdict  = $verdict
            Problems = [string[]]@($problems)
            Path     = if ($fact) { $fact.Path } else { $null }
            Provider = if ($fact) { $fact.Inf.Provider } else { $null }
            Version  = if ($fact) { $fact.Inf.Version } else { $null }
            Known    = if ($match) { [pscustomobject]@{ Name = $match.Name; Version = $match.Version } } else { $null }
        }
    }

    if ($Inf.Count -eq 0) {
        return & $outcome 'Refused' 'NoInf' $null $null
    }
    $candidates = @($Inf | Where-Object {
            $ids = @($_.Inf.HardwareIds)
            @($patterns | Where-Object { $pattern = $_; @($ids | Where-Object { $_ -match $pattern }).Count -gt 0 }).Count -gt 0
        })
    if ($candidates.Count -eq 0) {
        return & $outcome 'Refused' 'NotForModem' $null $null
    }

    $judged = foreach ($fact in $candidates) {
        $problems = [System.Collections.Generic.List[string]]::new()
        if (-not $fact.Inf.CatalogFile -or -not $fact.Catalog) {
            $problems.Add('NoCatalog')
        }
        else {
            $signer = $fact.Signer
            $whql = $signer -and $signer.Subject -match "(^|,\s*)CN=$([regex]::Escape($script:WhqlSigner.CN))(\s*,|$)" -and
            $signer.Subject -match "(^|,\s*)O=$([regex]::Escape($script:WhqlSigner.O))(\s*,|$)" -and $script:WhqlKeyUsage -in @($signer.KeyUsages)
            if (-not $whql) {
                $problems.Add('NotWhql')
            }
            if ($fact.CatalogCheck -eq $script:NotInCatalog) {
                $problems.Add('NotInCatalog')
            }
            elseif ($fact.CatalogCheck -ne 0) {
                $problems.Add('NotTrusted')
            }
        }
        $match = if ($problems.Count -eq 0) {
            @($Known | Where-Object {
                    $files = $_.Files
                    @($files.Keys | Where-Object { $fact.Files[$_] -ne $files[$_] }).Count -eq 0
                }) | Select-Object -First 1
        }
        [pscustomobject]@{ Fact = $fact; Problems = $problems; Match = $match }
    }
    $best = @($judged | Where-Object { $_.Problems.Count -eq 0 } | Sort-Object -Property { -not $_.Match } -Stable) | Select-Object -First 1
    if ($best) {
        return & $outcome $(if ($best.Match) { 'Verified' } else { 'Signed' }) @() $best.Fact $best.Match
    }
    $first = @($judged)[0]
    & $outcome 'Refused' $first.Problems $first.Fact $null
}

function New-DriverStagingFolder {
    <#
    .SYNOPSIS
        Creates an empty folder for a driver package: the app copies the package there, checks it
        there, and pnputil installs it from there.
    .DESCRIPTION
        -AdminOnly, the app's own use: a folder only SYSTEM and administrators can open, nothing
        inherited, under -Root - Windows' own temporary folder, where users can't list or delete
        what others create. What is checked is then what pnputil installs: no program running as
        the user can change the package in between, and the elevated app installs nothing from
        a folder the user can write (ARCHITECTURE -> Invariants, 10). Without it - development
        mode and tests - a plain folder. Its name is new every time.

        Returns the folder's path.
    .EXAMPLE
        New-DriverStagingFolder -Root (Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp') -AdminOnly
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [switch] $AdminOnly
    )

    $path = Join-Path -Path $Root -ChildPath "fm350-driver-$([guid]::NewGuid().ToString('N'))"
    if (-not $PSCmdlet.ShouldProcess($path, 'Create a folder for a driver package')) {
        return
    }
    if ($AdminOnly) {
        $security = [System.Security.AccessControl.DirectorySecurity]::new()
        $security.SetSecurityDescriptorSddlForm($script:DriverStagingSddl)
        [System.IO.FileSystemAclExtensions]::Create([System.IO.DirectoryInfo]::new($path), $security)
    }
    else {
        [void](New-Item -ItemType Directory -Path $path -Force)
    }
    $path
}

function Remove-DriverStagingLeftover {
    <#
    .SYNOPSIS
        Deletes the copies of driver packages that an app ended mid-install left in -Root.
    .DESCRIPTION
        Run as the app starts: one instance runs at a time, so any copy found then is a leftover.
        Only folders named as New-DriverStagingFolder names them, not links, and owned by one of
        -Owner - administrators and SYSTEM by default, as the app makes them - are deleted: a
        folder of that name a user's program made is left alone. Returns how many were deleted.
    .EXAMPLE
        Remove-DriverStagingLeftover -Root (Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp')
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [string[]] $Owner = @('S-1-5-32-544', 'S-1-5-18')
    )

    $deleted = 0
    foreach ($folder in @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'fm350-driver-*' -ErrorAction SilentlyContinue)) {
        if ($folder.Name -notmatch '^fm350-driver-[0-9a-f]{32}$' -or ($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            continue
        }
        $sid = try {
            [System.IO.FileSystemAclExtensions]::GetAccessControl($folder, [System.Security.AccessControl.AccessControlSections]::Owner).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            $null
        }
        if ($sid -in $Owner -and $PSCmdlet.ShouldProcess($folder.FullName, 'Delete a leftover copy of a driver package')) {
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $folder.FullName)) {
                $deleted++
            }
        }
    }
    $deleted
}

function Copy-DriverPackage {
    <#
    .SYNOPSIS
        Copies the driver package the user chose - a zip, an INF, or a folder - into an empty
        folder (New-DriverStagingFolder).
    .DESCRIPTION
        Reads the package and runs nothing from it. A zip's files are extracted, none outside the
        folder. For an INF, only the package's files are copied: the INF and the files it names
        (ConvertFrom-DriverInf's PackageFiles) that are in its folder or below - not the rest of a
        folder it may share with other files, such as Downloads. A folder's files are copied with
        their subfolders, links left out. A package of more than 1000 files or 64 MB is refused -
        a driver package is a few MB -, as soon as a folder is found to hold more. -Beat runs at
        every file: the worker's heartbeat.

        Returns the number of files copied.
    .EXAMPLE
        Copy-DriverPackage -Path "$HOME\Downloads\driver.zip" -Destination $folder
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Destination,

        [scriptblock] $Beat
    )

    if (-not $PSCmdlet.ShouldProcess($Path, "Copy the driver package to $Destination")) {
        return
    }
    $limits = $script:DriverPackageLimits
    $tooBig = { param($files, $bytes) $files -gt $limits.Files -or $bytes -gt $limits.Bytes }
    $refusal = "The package holds more than $($limits.Files) files or $($limits.Bytes / 1MB) MB: a driver package is a few MB."
    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'

    $extension = [System.IO.Path]::GetExtension($Path)
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and $extension -eq '.zip') {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $entries = @($zip.Entries | Where-Object { $_.Name })
            if (& $tooBig $entries.Count ($entries | Measure-Object -Property Length -Sum).Sum) {
                throw [System.IO.InvalidDataException]::new($refusal)
            }
            foreach ($entry in $entries) {
                if ($Beat) { & $Beat }
                $target = [System.IO.Path]::GetFullPath((Join-Path -Path $root -ChildPath $entry.FullName))
                if (-not $target.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw [System.IO.InvalidDataException]::new("The zip holds a file that would land outside its folder: $($entry.FullName)")
                }
                [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            }
            return $entries.Count
        }
        finally {
            $zip.Dispose()
        }
    }

    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $bytes = [long]0
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ($extension -ne '.inf') {
            throw [System.IO.InvalidDataException]::new('A driver package is a zip, or the INF file in its folder.')
        }
        $source = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path)).TrimEnd('\') + '\'
        $inf = ConvertFrom-DriverInf -Text @(Get-Content -LiteralPath $Path)
        foreach ($name in @([System.IO.Path]::GetFileName($Path)) + @($inf.PackageFiles)) {
            $full = [System.IO.Path]::GetFullPath((Join-Path -Path $source -ChildPath $name))
            if ($full.StartsWith($source, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full -PathType Leaf)) {
                $file = Get-Item -LiteralPath $full
                $files.Add($file)
                $bytes += $file.Length
            }
        }
    }
    else {
        $source = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
        # Read lazily, and given up at the first file too many: the folder may be a big one.
        Get-ChildItem -LiteralPath $source -Recurse -File -ErrorAction Stop | ForEach-Object {
            if ($Beat) { & $Beat }
            if (-not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                $files.Add($_)
                $bytes += $_.Length
                if (& $tooBig $files.Count $bytes) {
                    throw [System.IO.InvalidDataException]::new($refusal)
                }
            }
        }
    }
    if (& $tooBig $files.Count $bytes) {
        throw [System.IO.InvalidDataException]::new($refusal)
    }
    foreach ($file in $files) {
        if ($Beat) { & $Beat }
        $target = Join-Path -Path $root -ChildPath $file.FullName.Substring($source.Length)
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
    $files.Count
}

function Test-DriverCatalogMember {
    # WinVerifyTrust's answer for a file against one catalog: 0 when the catalog's signature is
    # trusted and it holds the file's hash; TRUST_E_NOSIGNATURE when it doesn't hold it; another
    # code when the catalog can't be read or its signature doesn't verify. Only the catalog given
    # counts - the machine's own catalogs would vouch for any copy of a package already installed
    # (AT-COMMANDS section 1.1). The file's hash is computed with SHA-256, then SHA-1 for a
    # catalog that holds only those; nothing is fetched from the network.
    param([string] $Catalog, [string] $Path)

    if (-not ('FibocomFm350.DriverCatalog' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace FibocomFm350
{
    public static class DriverCatalog
    {
        [DllImport("wintrust.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CryptCATAdminAcquireContext2(out IntPtr catAdmin, IntPtr subsystem, string hashAlgorithm, IntPtr strongHashPolicy, uint flags);

        [DllImport("wintrust.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CryptCATAdminReleaseContext(IntPtr catAdmin, uint flags);

        [DllImport("wintrust.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CryptCATAdminCalcHashFromFileHandle2(IntPtr catAdmin, SafeFileHandle file, ref uint hashSize, byte[] hash, uint flags);

        [DllImport("wintrust.dll", CharSet = CharSet.Unicode)]
        private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CatalogInfo
        {
            public uint cbStruct;
            public uint dwCatalogVersion;
            public string pcwszCatalogFilePath;
            public string pcwszMemberTag;
            public string pcwszMemberFilePath;
            public IntPtr hMemberFile;
            public IntPtr pbCalculatedFileHash;
            public uint cbCalculatedFileHash;
            public IntPtr pcCatalogContext;
            public IntPtr hCatAdmin;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TrustData
        {
            public uint cbStruct;
            public IntPtr pPolicyCallbackData;
            public IntPtr pSIPClientData;
            public uint dwUIChoice;
            public uint fdwRevocationChecks;
            public uint dwUnionChoice;
            public IntPtr pCatalog;
            public uint dwStateAction;
            public IntPtr hWVTStateData;
            public IntPtr pwszURLReference;
            public uint dwProvFlags;
            public uint dwUIContext;
            public IntPtr pSignatureSettings;
        }

        private const uint UiNone = 2;
        private const uint RevokeNone = 0;
        private const uint ChoiceCatalog = 2;
        private const uint StateVerify = 1;
        private const uint StateClose = 2;
        private const uint CacheOnlyUrlRetrieval = 0x1000;
        private const int NoSignature = unchecked((int)0x800B0100);

        // WINTRUST_ACTION_GENERIC_VERIFY_V2
        private static Guid genericVerify = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

        public static int Check(string catalogPath, string filePath)
        {
            int result = Check(catalogPath, filePath, "SHA256");
            return result == NoSignature ? Check(catalogPath, filePath, "SHA1") : result;
        }

        private static int Check(string catalogPath, string filePath, string hashAlgorithm)
        {
            IntPtr admin;
            if (!CryptCATAdminAcquireContext2(out admin, IntPtr.Zero, hashAlgorithm, IntPtr.Zero, 0))
            {
                return Marshal.GetHRForLastWin32Error();
            }
            try
            {
                byte[] hash;
                using (FileStream stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    uint size = 0;
                    CryptCATAdminCalcHashFromFileHandle2(admin, stream.SafeFileHandle, ref size, null, 0);
                    hash = new byte[size];
                    if (size == 0 || !CryptCATAdminCalcHashFromFileHandle2(admin, stream.SafeFileHandle, ref size, hash, 0))
                    {
                        return Marshal.GetHRForLastWin32Error();
                    }
                }
                IntPtr hashBuffer = Marshal.AllocHGlobal(hash.Length);
                IntPtr info = IntPtr.Zero;
                try
                {
                    Marshal.Copy(hash, 0, hashBuffer, hash.Length);
                    CatalogInfo catalog = new CatalogInfo();
                    catalog.cbStruct = (uint)Marshal.SizeOf(typeof(CatalogInfo));
                    catalog.pcwszCatalogFilePath = catalogPath;
                    catalog.pcwszMemberTag = BitConverter.ToString(hash).Replace("-", "");
                    catalog.pcwszMemberFilePath = filePath;
                    catalog.pbCalculatedFileHash = hashBuffer;
                    catalog.cbCalculatedFileHash = (uint)hash.Length;
                    catalog.hCatAdmin = admin;
                    info = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(CatalogInfo)));
                    Marshal.StructureToPtr(catalog, info, false);
                    TrustData data = new TrustData();
                    data.cbStruct = (uint)Marshal.SizeOf(typeof(TrustData));
                    data.dwUIChoice = UiNone;
                    data.fdwRevocationChecks = RevokeNone;
                    data.dwUnionChoice = ChoiceCatalog;
                    data.pCatalog = info;
                    data.dwStateAction = StateVerify;
                    data.dwProvFlags = CacheOnlyUrlRetrieval;
                    int result = WinVerifyTrust(IntPtr.Zero, ref genericVerify, ref data);
                    data.dwStateAction = StateClose;
                    WinVerifyTrust(IntPtr.Zero, ref genericVerify, ref data);
                    return result;
                }
                finally
                {
                    if (info != IntPtr.Zero)
                    {
                        Marshal.DestroyStructure(info, typeof(CatalogInfo));
                        Marshal.FreeHGlobal(info);
                    }
                    Marshal.FreeHGlobal(hashBuffer);
                }
            }
            finally
            {
                CryptCATAdminReleaseContext(admin, 0);
            }
        }
    }
}
'@
    }
    [FibocomFm350.DriverCatalog]::Check($Catalog, $Path)
}

function Get-DriverPackageFact {
    <#
    .SYNOPSIS
        Reads what Resolve-DriverPackage decides on, in a package Copy-DriverPackage copied.
    .DESCRIPTION
        For every INF in -Folder and below: Path (relative to -Folder, '/' between folders), Inf
        (ConvertFrom-DriverInf's), Catalog (the catalog it names is beside it), Signer (Subject
        and KeyUsages of the catalog's signer certificate, read with SignedCms: the signature
        itself is checked by WinVerifyTrust, next), CatalogCheck (WinVerifyTrust's answer for the
        INF against that catalog, and that catalog only; $null without one) and Files (the
        SHA-256 of every file in the INF's folder and below, by relative path - each file hashed
        once, whatever the number of INFs). Reads only; nothing is fetched from the network.
        -Beat runs at every file and every INF: the worker's heartbeat.
    .EXAMPLE
        Get-DriverPackageFact -Folder $folder
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Folder,

        [scriptblock] $Beat
    )

    $root = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\') + '\'
    $relative = { param($path, $base) $path.Substring($base.Length).Replace('\', '/') }
    $all = @{}
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -File)) {
        if ($Beat) { & $Beat }
        $all[(& $relative $item.FullName $root)] = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.inf' | Sort-Object -Property FullName)) {
        if ($Beat) { & $Beat }
        $inf = ConvertFrom-DriverInf -Text @(Get-Content -LiteralPath $file.FullName)
        $base = $file.DirectoryName.TrimEnd('\') + '\'
        $catalog = if ($inf.CatalogFile) { Join-Path -Path $base -ChildPath $inf.CatalogFile } else { $null }
        $present = [bool]($catalog -and (Test-Path -LiteralPath $catalog -PathType Leaf))
        $signer = $null
        $check = $null
        if ($present) {
            try {
                $cms = [System.Security.Cryptography.Pkcs.SignedCms]::new()
                $cms.Decode([System.IO.File]::ReadAllBytes($catalog))
                $certificate = @($cms.SignerInfos)[0].Certificate
                if ($certificate) {
                    $usages = @($certificate.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
                            ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object Value)
                    $signer = [pscustomobject]@{ Subject = $certificate.Subject; KeyUsages = [string[]]$usages }
                }
            }
            catch {
                Write-Verbose "The catalog $($inf.CatalogFile) can't be read as a signed message: $($_.Exception.Message)"
            }
            $check = Test-DriverCatalogMember -Catalog $catalog -Path $file.FullName
        }
        $prefix = & $relative $base $root
        $hashes = @{}
        foreach ($key in $all.Keys) {
            if ($key.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $hashes[$key.Substring($prefix.Length)] = $all[$key]
            }
        }
        [pscustomobject]@{
            Path         = & $relative $file.FullName $root
            Inf          = $inf
            Catalog      = $present
            Signer       = $signer
            CatalogCheck = $check
            Files        = $hashes
        }
    }
}

function Resolve-PnputilResult {
    # What pnputil's exit code says (AT-COMMANDS section 1.1): 'Done'; 'RestartNeeded' (3010);
    # for -Add, 'NoDevice' (259: added to the driver store, but no device took it - none
    # attached, or one with a driver Windows ranks higher); 'TimedOut' ($null: stopped);
    # else 'Failed'.
    param([Nullable[int]] $ExitCode, [switch] $Add)

    if ($null -eq $ExitCode) { 'TimedOut' }
    elseif ($ExitCode -eq 0) { 'Done' }
    elseif ($ExitCode -eq 3010) { 'RestartNeeded' }
    elseif ($Add -and $ExitCode -eq 259) { 'NoDevice' }
    else { 'Failed' }
}

function Install-ModemDriver {
    <#
    .SYNOPSIS
        Adds a driver package to Windows' driver store and installs it on the devices it fits:
        pnputil /add-driver <inf> /install.
    .DESCRIPTION
        For a package Resolve-DriverPackage allows, in the folder New-DriverStagingFolder made:
        Windows checks it against its catalog again as it adds it. Needs administrator rights.
        pnputil is run from the system folder, and only its exit code is read; -Beat runs about
        once a second while it works (the worker's heartbeat), and it is stopped after
        -TimeoutMs.

        Returns Result - 'Done', 'RestartNeeded', 'NoDevice' (in the driver store, but no device
        took it: no modem attached, or a driver Windows ranks higher), 'Failed' or 'TimedOut' -
        and ExitCode.
    .EXAMPLE
        Install-ModemDriver -InfPath (Join-Path $folder 'usb2ser_tm.inf')
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('\.inf$')]
        [string] $InfPath,

        [ValidateRange(1000, 3600000)]
        [int] $TimeoutMs = $script:PnputilTimeoutMs,

        [scriptblock] $Beat
    )

    if (-not $PSCmdlet.ShouldProcess($InfPath, 'Add the driver package and install it')) {
        return
    }
    $exitCode = Invoke-Pnputil -Argument '/add-driver', $InfPath, '/install' -TimeoutMs $TimeoutMs -Beat $Beat
    [pscustomobject]@{ Result = Resolve-PnputilResult -ExitCode $exitCode -Add; ExitCode = $exitCode }
}

function Uninstall-ModemDriver {
    <#
    .SYNOPSIS
        Removes a driver package from the devices that use it and from the driver store:
        pnputil /delete-driver <oem#.inf> /uninstall.
    .DESCRIPTION
        -PublishedName is the name the package has in the driver store, as the AT port reports
        it (DriverInfPath): only an oem<n>.inf - never one of Windows' own drivers. The AT port
        must be closed first. Needs administrator rights; pnputil as for Install-ModemDriver.

        Returns Result - 'Done', 'RestartNeeded', 'Failed' or 'TimedOut' - and ExitCode.
    .EXAMPLE
        Uninstall-ModemDriver -PublishedName 'oem24.inf'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^oem\d+\.inf$')]
        [string] $PublishedName,

        [ValidateRange(1000, 3600000)]
        [int] $TimeoutMs = $script:PnputilTimeoutMs,

        [scriptblock] $Beat
    )

    if (-not $PSCmdlet.ShouldProcess($PublishedName, 'Uninstall the driver package and delete it')) {
        return
    }
    $exitCode = Invoke-Pnputil -Argument '/delete-driver', $PublishedName, '/uninstall' -TimeoutMs $TimeoutMs -Beat $Beat
    [pscustomobject]@{ Result = Resolve-PnputilResult -ExitCode $exitCode; ExitCode = $exitCode }
}

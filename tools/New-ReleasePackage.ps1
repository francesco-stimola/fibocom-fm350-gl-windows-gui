#Requires -Version 7.6
<#
.SYNOPSIS
    Builds the release zip and its notes: what the release workflow publishes.
.DESCRIPTION
    Checks that the three modules (core, tray app, installer) carry one version, and with -Tag
    that the tag names it (v<version>); takes that version's section of CHANGELOG.md as the
    release notes - without -Tag, the Unreleased section when the version has none yet -; and
    builds fibocom-fm350-gl-windows-gui-<version>.zip: the contents of src/ (the app, its
    installer, install.cmd and uninstall.cmd at the top), with LICENSE, README.md and
    CHANGELOG.md. No folder at the top of the zip: Explorer's "Extract All" puts it in a folder
    named after the zip.

    lpac goes in the zip's 'lpac' folder (ARCHITECTURE -> eSIM): the files the pin lists (-LpacPin,
    tools/Lpac.psd1) from its pinned Windows build - lpac.exe, its README and licenses -, and
    SOURCE.txt, which says where its source is. Its source archive is written
    beside the zip, for the release to carry. Each of the two files is taken from -LpacCache, or
    downloaded there from the pinned address, and used only once its SHA-256 matches the pin; a
    file that doesn't match is deleted and nothing is built. A 'lpac' folder in src/ is never
    packaged: the binaries come from the pinned release alone.

    Writes the zip, release-notes.md and lpac's source archive into -OutputFolder, and returns
    Version, Zip, Notes, Files (the number of files in the zip) and LpacSource. Fails on any check
    that doesn't hold. CI runs it on every push, without -Tag: the package is proven before a tag
    is ever pushed.
.EXAMPLE
    ./tools/New-ReleasePackage.ps1 -Tag v1.0.0 -OutputFolder dist
#>
[CmdletBinding()]
param(
    [string] $Tag,

    [string] $OutputFolder = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'dist'),

    [string] $Root = (Split-Path -Parent $PSScriptRoot),

    [string] $LpacPin = (Join-Path -Path $PSScriptRoot -ChildPath 'Lpac.psd1'),

    # Where lpac's two files are looked for, and downloaded to when missing.
    [string] $LpacCache = (Join-Path -Path $OutputFolder -ChildPath 'lpac-download')
)

$script:ReleaseManifests = @('src/FibocomFm350/FibocomFm350.psd1', 'src/App/FibocomFm350.App.psd1', 'src/Installer/FibocomFm350.Installer.psd1')
$script:ReleaseTopFiles = @('LICENSE', 'README.md', 'CHANGELOG.md')
$script:LpacFolder = 'lpac'

function Resolve-ReleaseVersion {
    # The version to release: the one every module carries, and the tag's when there is one
    # (v<major>.<minor>.<patch>). A pure decision; throws when they disagree.
    param([string[]] $ModuleVersion, [string] $Tag)

    $versions = @($ModuleVersion | Sort-Object -Unique)
    if ($versions.Count -ne 1) {
        throw "The modules carry different versions: $($ModuleVersion -join ', ')."
    }
    $version = $versions[0]
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        throw "The modules' version is not major.minor.patch: $version."
    }
    if ($Tag) {
        if ($Tag -notmatch '^v(\d+\.\d+\.\d+)$') {
            throw "The tag is not v<major>.<minor>.<patch>: $Tag."
        }
        if ($Matches[1] -ne $version) {
            throw "The tag $Tag doesn't match the modules' version $version."
        }
    }
    $version
}

function Get-ChangelogSection {
    # The text of one section of a Keep a Changelog file - '## [<Name>]', with or without a date
    # after it - up to the next section or the link definitions at the end; $null when there is
    # no such section or nothing in it. A pure function.
    param([string] $Text, [string] $Name)

    $lines = $Text -split '\r?\n'
    $heading = '^##\s+\[' + [regex]::Escape($Name) + '\](\s|$)'
    $start = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $heading) {
            $start = $i + 1
            break
        }
    }
    if ($null -eq $start) {
        return $null
    }
    $body = [System.Collections.Generic.List[string]]::new()
    for ($i = $start; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^##\s' -or $lines[$i] -match '^\[[^\]]+\]:\s*\S') {
            break
        }
        $body.Add($lines[$i])
    }
    $section = ($body -join "`n").Trim()
    if ($section) { $section } else { $null }
}

function Get-ReleaseFile {
    # The files of the zip from the repository: Path on disk and Entry, its name in the zip, with
    # forward slashes. A 'lpac' folder in src/ is left out: lpac comes from its pinned release.
    param([string] $Root)

    $source = Join-Path -Path $Root -ChildPath 'src'
    foreach ($file in @(Get-ChildItem -LiteralPath $source -Recurse -File | Sort-Object FullName)) {
        $entry = [System.IO.Path]::GetRelativePath($source, $file.FullName).Replace('\', '/')
        if ($entry -notlike "$script:LpacFolder/*") {
            [pscustomobject]@{ Path = $file.FullName; Entry = $entry }
        }
    }
    foreach ($name in $script:ReleaseTopFiles) {
        [pscustomobject]@{ Path = (Join-Path -Path $Root -ChildPath $name); Entry = $name }
    }
}

function Test-LpacPin {
    # Whether a pin of lpac's release is complete: a version, the build's files to package -
    # lpac.exe among them, plain names -, and for its build and its source a file name, an https
    # address and a SHA-256. Throws on what is missing. A pure check.
    param([hashtable] $Pin)

    if ([string]$Pin['Version'] -notmatch '^\d+\.\d+\.\d+$') {
        throw "lpac's pin has no version."
    }
    $files = @($Pin['Files'])
    if ('lpac.exe' -notin $files -or @($files | Where-Object { [string]$_ -notmatch '^[A-Za-z0-9._-]+$' -or $_ -match '^\.\.?$' }).Count -gt 0) {
        throw "lpac's pin has no list of the build's files to package, lpac.exe among them, plain names."
    }
    foreach ($part in 'Build', 'Source') {
        $entry = $Pin[$part]
        if ($entry -isnot [hashtable] -or [string]$entry['Name'] -notmatch '^[A-Za-z0-9._-]+$' -or [string]$entry['Url'] -notmatch '^https://' -or
            [string]$entry['Sha256'] -notmatch '^[0-9a-fA-F]{64}$') {
            throw "lpac's pin has no complete $part (a file name, an https address, a SHA-256)."
        }
    }
    $true
}

function Get-LpacFile {
    # One of lpac's pinned files: from -Cache, downloaded there when missing, used only once its
    # SHA-256 matches the pin's. A file that doesn't match is deleted. Returns its path.
    param([hashtable] $Entry, [string] $Cache)

    if (-not (Test-Path -LiteralPath $Cache)) {
        [void](New-Item -ItemType Directory -Path $Cache)
    }
    $path = Join-Path -Path $Cache -ChildPath $Entry.Name
    if (-not (Test-Path -LiteralPath $path)) {
        Invoke-WebRequest -Uri $Entry.Url -OutFile $path -UseBasicParsing
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($hash -ne $Entry.Sha256.ToUpperInvariant()) {
        Remove-Item -LiteralPath $path -Force
        throw "$($Entry.Name): its SHA-256 is $hash, not the pinned $($Entry.Sha256.ToUpperInvariant()). Deleted; nothing is built."
    }
    $path
}

function Get-LpacSourceNote {
    # SOURCE.txt, beside lpac in the zip: what lpac is, its license, and where its source is. A
    # pure function.
    param([hashtable] $Pin)

    @(
        "lpac $($Pin.Version), by ESTKME TECHNOLOGY LIMITED: $($Pin.Page)"
        ''
        'This app runs lpac to manage the profiles of an eSIM. lpac is free software: its program is'
        'under the GNU Affero General Public License v3.0 only (LICENSE-lpac), its eUICC library under'
        'the GNU Lesser General Public License v2.1 (LICENSE-libeuicc); the other LICENSE files are'
        'those of the libraries built into it.'
        ''
        "Its corresponding source is attached to this app's GitHub Release, beside this zip, as"
        "$($Pin.Source.Name) (SHA-256 $($Pin.Source.Sha256.ToLowerInvariant()))."
    ) -join "`r`n"
}

# Dot-sourced (the tests): the functions alone.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

$ErrorActionPreference = 'Stop'
$versions = foreach ($manifest in $script:ReleaseManifests) {
    [string](Import-PowerShellDataFile -LiteralPath (Join-Path -Path $Root -ChildPath $manifest)).ModuleVersion
}
$version = Resolve-ReleaseVersion -ModuleVersion $versions -Tag $Tag

$changelog = Get-Content -LiteralPath (Join-Path -Path $Root -ChildPath 'CHANGELOG.md') -Raw
$notes = Get-ChangelogSection -Text $changelog -Name $version
if (-not $notes -and -not $Tag) {
    $notes = Get-ChangelogSection -Text $changelog -Name 'Unreleased'
}
if (-not $notes) {
    throw "CHANGELOG.md has no section for $version$(if (-not $Tag) { ' and no Unreleased one' }), or it is empty."
}

$pin = Import-PowerShellDataFile -LiteralPath $LpacPin
[void](Test-LpacPin -Pin $pin)
$lpacBuild = Get-LpacFile -Entry $pin.Build -Cache $LpacCache
$lpacSource = Get-LpacFile -Entry $pin.Source -Cache $LpacCache

if (-not (Test-Path -LiteralPath $OutputFolder)) {
    [void](New-Item -ItemType Directory -Path $OutputFolder)
}
$zipPath = Join-Path -Path $OutputFolder -ChildPath "fibocom-fm350-gl-windows-gui-$version.zip"
$notesPath = Join-Path -Path $OutputFolder -ChildPath 'release-notes.md'
$sourcePath = Join-Path -Path $OutputFolder -ChildPath $pin.Source.Name
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
$files = @(Get-ReleaseFile -Root $Root)
$count = $files.Count
$built = $false
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.Path, $file.Entry, [System.IO.Compression.CompressionLevel]::Optimal)
    }
    # The files of lpac's build the pin lists, as published, in the 'lpac' folder.
    $build = [System.IO.Compression.ZipFile]::OpenRead($lpacBuild)
    try {
        foreach ($name in @($pin.Files)) {
            $entry = @($build.Entries | Where-Object FullName -CEQ $name) | Select-Object -First 1
            if (-not $entry) {
                throw "$($pin.Build.Name) has no $name at its top."
            }
            $target = $zip.CreateEntry("$script:LpacFolder/$($entry.Name)", [System.IO.Compression.CompressionLevel]::Optimal)
            $in = $entry.Open()
            $out = $target.Open()
            try {
                $in.CopyTo($out)
            }
            finally {
                $out.Dispose()
                $in.Dispose()
            }
            $count++
        }
    }
    finally {
        $build.Dispose()
    }
    $note = $zip.CreateEntry("$script:LpacFolder/SOURCE.txt", [System.IO.Compression.CompressionLevel]::Optimal)
    $writer = [System.IO.StreamWriter]::new($note.Open(), [System.Text.UTF8Encoding]::new($false))
    try {
        $writer.Write((Get-LpacSourceNote -Pin $pin))
    }
    finally {
        $writer.Dispose()
    }
    $count++
    $built = $true
}
finally {
    $zip.Dispose()
    # A zip left half built is no package.
    if (-not $built) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
}
Copy-Item -LiteralPath $lpacSource -Destination $sourcePath -Force
Set-Content -LiteralPath $notesPath -Value $notes -Encoding utf8NoBOM

[pscustomobject]@{
    Version    = $version
    Zip        = $zipPath
    Notes      = $notesPath
    Files      = $count
    LpacSource = $sourcePath
}

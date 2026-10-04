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

    Two tools go in the zip beside the app (ARCHITECTURE -> eSIM), each from its pin:
    - lpac, in the 'lpac' folder: the files -LpacPin (tools/Lpac.psd1) lists from its pinned
      Windows build - lpac.exe, its README and licenses -, and SOURCE.txt, which says where its
      source is. Its source archive is written beside the zip, for the release to carry.
    - ZXing.Net, in the 'zxing' folder: the files -ZxingPin (tools/ZXing.psd1) lists from its
      pinned package, its license, and README.txt, which says what it is.
    Each pinned file is taken from -Cache, or downloaded there from its pinned address, and used
    only once its SHA-256 matches the pin; a file that doesn't match is deleted and nothing is
    built. A 'lpac' or 'zxing' folder in src/ is never packaged: the binaries come from the pins
    alone.

    Writes the zip, release-notes.md and lpac's source archive into -OutputFolder, and returns
    Version, Zip, Notes, Files (the number of files in the zip), LpacSource and Cache. Fails on
    any check that doesn't hold. CI runs it on every push, without -Tag, before the tests: the
    package is proven before a tag is ever pushed, and the tests run the programs its zip bundles
    (tests/Bundled.Tests.ps1).
.EXAMPLE
    ./tools/New-ReleasePackage.ps1 -Tag v1.0.0 -OutputFolder dist
#>
[CmdletBinding()]
param(
    [string] $Tag,

    [string] $OutputFolder = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'dist'),

    [string] $Root = (Split-Path -Parent $PSScriptRoot),

    [string] $LpacPin = (Join-Path -Path $PSScriptRoot -ChildPath 'Lpac.psd1'),

    [string] $ZxingPin = (Join-Path -Path $PSScriptRoot -ChildPath 'ZXing.psd1'),

    # Where the pinned files are looked for, and downloaded to when missing.
    [string] $Cache = (Join-Path -Path $OutputFolder -ChildPath 'download')
)

$script:ReleaseManifests = @('src/FibocomFm350/FibocomFm350.psd1', 'src/App/FibocomFm350.App.psd1', 'src/Installer/FibocomFm350.Installer.psd1')
$script:ReleaseTopFiles = @('LICENSE', 'README.md', 'CHANGELOG.md')
$script:BundledFolders = @('lpac', 'zxing')

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
    # forward slashes. A 'lpac' or 'zxing' folder in src/ is left out: those come from their pins.
    param([string] $Root)

    $source = Join-Path -Path $Root -ChildPath 'src'
    foreach ($file in @(Get-ChildItem -LiteralPath $source -Recurse -File | Sort-Object FullName)) {
        $entry = [System.IO.Path]::GetRelativePath($source, $file.FullName).Replace('\', '/')
        if ($entry.Split('/')[0] -notin $script:BundledFolders) {
            [pscustomobject]@{ Path = $file.FullName; Entry = $entry }
        }
    }
    foreach ($name in $script:ReleaseTopFiles) {
        [pscustomobject]@{ Path = (Join-Path -Path $Root -ChildPath $name); Entry = $name }
    }
}

function Test-PinnedFile {
    # Whether a pin names one file whole: a plain file name, an https address and a SHA-256.
    param([object] $Entry)

    $Entry -is [hashtable] -and [string]$Entry['Name'] -match '^[A-Za-z0-9._-]+$' -and [string]$Entry['Url'] -match '^https://' -and
    [string]$Entry['Sha256'] -match '^[0-9a-fA-F]{64}$'
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
        if (-not (Test-PinnedFile -Entry $Pin[$part])) {
            throw "lpac's pin has no complete $part (a file name, an https address, a SHA-256)."
        }
    }
    $true
}

function Test-ZxingPin {
    # Whether a pin of ZXing.Net is complete: a version, its package and its license each with a
    # file name, an https address and a SHA-256, and the package's files to take - zxing.dll among
    # their names in the zip, plain names. Throws on what is missing. A pure check.
    param([hashtable] $Pin)

    if ([string]$Pin['Version'] -notmatch '^\d+\.\d+\.\d+$') {
        throw "ZXing.Net's pin has no version."
    }
    foreach ($part in 'Package', 'License') {
        if (-not (Test-PinnedFile -Entry $Pin[$part])) {
            throw "ZXing.Net's pin has no complete $part (a file name, an https address, a SHA-256)."
        }
    }
    $files = $Pin['Files']
    if ($files -isnot [hashtable] -or 'zxing.dll' -notin @($files.Values) -or
        @($files.Values | Where-Object { [string]$_ -notmatch '^[A-Za-z0-9._-]+$' -or $_ -match '^\.\.?$' }).Count -gt 0) {
        throw "ZXing.Net's pin has no files to take from its package, zxing.dll among them, plain names."
    }
    $true
}

function Get-PinnedFile {
    # One pinned file: from -Cache, downloaded there when missing, used only once its SHA-256
    # matches the pin's. A file that doesn't match is deleted. Returns its path.
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

function Get-ZxingNote {
    # README.txt, beside ZXing.Net in the zip: what it is, where it comes from, its license. A
    # pure function.
    param([hashtable] $Pin)

    @(
        "ZXing.Net $($Pin.Version), by Michael Jahn: $($Pin.Page)"
        ''
        'This app uses ZXing.Net to read an eSIM activation code from the image of its QR code.'
        'ZXing.Net is under the Apache License 2.0 (COPYING). Its source:'
        'https://github.com/micjahn/ZXing.Net'
    ) -join "`r`n"
}

function Copy-ZipEntry {
    # Copies one file of an archive into the zip under -Entry; throws when the archive has none
    # named -Name.
    param([System.IO.Compression.ZipArchive] $From, [string] $Name, [string] $What, [System.IO.Compression.ZipArchive] $To, [string] $Entry)

    $source = @($From.Entries | Where-Object FullName -CEQ $Name) | Select-Object -First 1
    if (-not $source) {
        throw "$What has no $Name."
    }
    $target = $To.CreateEntry($Entry, [System.IO.Compression.CompressionLevel]::Optimal)
    $in = $source.Open()
    $out = $target.Open()
    try {
        $in.CopyTo($out)
    }
    finally {
        $out.Dispose()
        $in.Dispose()
    }
}

function Add-ZipText {
    # A text file of the package's own in the zip, UTF-8 without a byte order mark.
    param([System.IO.Compression.ZipArchive] $To, [string] $Entry, [string] $Text)

    $writer = [System.IO.StreamWriter]::new($To.CreateEntry($Entry, [System.IO.Compression.CompressionLevel]::Optimal).Open(), [System.Text.UTF8Encoding]::new($false))
    try {
        $writer.Write($Text)
    }
    finally {
        $writer.Dispose()
    }
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

$lpac = Import-PowerShellDataFile -LiteralPath $LpacPin
[void](Test-LpacPin -Pin $lpac)
$zxing = Import-PowerShellDataFile -LiteralPath $ZxingPin
[void](Test-ZxingPin -Pin $zxing)
$lpacBuild = Get-PinnedFile -Entry $lpac.Build -Cache $Cache
$lpacSource = Get-PinnedFile -Entry $lpac.Source -Cache $Cache
$zxingPackage = Get-PinnedFile -Entry $zxing.Package -Cache $Cache
$zxingLicense = Get-PinnedFile -Entry $zxing.License -Cache $Cache

if (-not (Test-Path -LiteralPath $OutputFolder)) {
    [void](New-Item -ItemType Directory -Path $OutputFolder)
}
$zipPath = Join-Path -Path $OutputFolder -ChildPath "fibocom-fm350-gl-windows-gui-$version.zip"
$notesPath = Join-Path -Path $OutputFolder -ChildPath 'release-notes.md'
$sourcePath = Join-Path -Path $OutputFolder -ChildPath $lpac.Source.Name
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
    # lpac: the files of its build the pin lists, as published, and where its source is.
    $build = [System.IO.Compression.ZipFile]::OpenRead($lpacBuild)
    try {
        foreach ($name in @($lpac.Files)) {
            Copy-ZipEntry -From $build -Name $name -What $lpac.Build.Name -To $zip -Entry "lpac/$name"
            $count++
        }
    }
    finally {
        $build.Dispose()
    }
    Add-ZipText -To $zip -Entry 'lpac/SOURCE.txt' -Text (Get-LpacSourceNote -Pin $lpac)
    $count++
    # ZXing.Net: the files of its package the pin lists, its license, what it is.
    $package = [System.IO.Compression.ZipFile]::OpenRead($zxingPackage)
    try {
        foreach ($name in @($zxing.Files.Keys | Sort-Object)) {
            Copy-ZipEntry -From $package -Name $name -What $zxing.Package.Name -To $zip -Entry "zxing/$($zxing.Files[$name])"
            $count++
        }
    }
    finally {
        $package.Dispose()
    }
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $zxingLicense, "zxing/$($zxing.License.Name)", [System.IO.Compression.CompressionLevel]::Optimal)
    Add-ZipText -To $zip -Entry 'zxing/README.txt' -Text (Get-ZxingNote -Pin $zxing)
    $count += 2
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
    Cache      = $Cache
}

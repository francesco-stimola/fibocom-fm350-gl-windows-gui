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

    Writes the zip and release-notes.md into -OutputFolder, and returns Version, Zip, Notes and
    Files (the number of files in the zip). Fails on any check that doesn't hold. CI runs it on
    every push, without -Tag: the package is proven before a tag is ever pushed.
.EXAMPLE
    ./tools/New-ReleasePackage.ps1 -Tag v1.0.0 -OutputFolder dist
#>
[CmdletBinding()]
param(
    [string] $Tag,

    [string] $OutputFolder = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'dist'),

    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

$script:ReleaseManifests = @('src/FibocomFm350/FibocomFm350.psd1', 'src/App/FibocomFm350.App.psd1', 'src/Installer/FibocomFm350.Installer.psd1')
$script:ReleaseTopFiles = @('LICENSE', 'README.md', 'CHANGELOG.md')

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
    # The files of the zip: Path on disk and Entry, its name in the zip, with forward slashes.
    param([string] $Root)

    $source = Join-Path -Path $Root -ChildPath 'src'
    foreach ($file in @(Get-ChildItem -LiteralPath $source -Recurse -File | Sort-Object FullName)) {
        [pscustomobject]@{ Path = $file.FullName; Entry = [System.IO.Path]::GetRelativePath($source, $file.FullName).Replace('\', '/') }
    }
    foreach ($name in $script:ReleaseTopFiles) {
        [pscustomobject]@{ Path = (Join-Path -Path $Root -ChildPath $name); Entry = $name }
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

if (-not (Test-Path -LiteralPath $OutputFolder)) {
    [void](New-Item -ItemType Directory -Path $OutputFolder)
}
$zipPath = Join-Path -Path $OutputFolder -ChildPath "fibocom-fm350-gl-windows-gui-$version.zip"
$notesPath = Join-Path -Path $OutputFolder -ChildPath 'release-notes.md'
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
$files = @(Get-ReleaseFile -Root $Root)
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.Path, $file.Entry, [System.IO.Compression.CompressionLevel]::Optimal)
    }
}
finally {
    $zip.Dispose()
}
Set-Content -LiteralPath $notesPath -Value $notes -Encoding utf8NoBOM

[pscustomobject]@{
    Version = $version
    Zip     = $zipPath
    Notes   = $notesPath
    Files   = $files.Count
}

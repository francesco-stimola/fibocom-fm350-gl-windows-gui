# The release package (tools/New-ReleasePackage.ps1): the version a tag may release, the
# CHANGELOG section that becomes the notes, and the zip itself - built into TestDrive from this
# repository, extracted, and found to be a package the installer takes.

BeforeAll {
    $script:root = (Resolve-Path "$PSScriptRoot/..").Path
    $script:builder = Join-Path $script:root 'tools/New-ReleasePackage.ps1'
    . $script:builder

    $script:changelog = @'
# Changelog

Intro.

## [Unreleased]

### Added
- Something new.

## [1.1.0] - 2026-11-02

### Fixed
- A fix.

## [1.0.0-beta] - 2026-10-20

- A beta.

## [1.0.0] - 2026-10-04

### Added
- The first release.
  - With a nested line.

[Unreleased]: https://example.invalid/compare/v1.1.0...HEAD
[1.1.0]: https://example.invalid/releases/tag/v1.1.0
'@
}

Describe 'Resolve-ReleaseVersion' {
    It '<Name>' -ForEach @(
        @{ Name = 'one version, no tag'; Versions = @('1.0.0', '1.0.0', '1.0.0'); Tag = ''; Version = '1.0.0' }
        @{ Name = 'the tag that names it'; Versions = @('1.2.3', '1.2.3', '1.2.3'); Tag = 'v1.2.3'; Version = '1.2.3' }
    ) {
        Resolve-ReleaseVersion -ModuleVersion $Versions -Tag $Tag | Should -Be $Version
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a tag for another version'; Versions = @('1.0.0', '1.0.0', '1.0.0'); Tag = 'v1.0.1'; Message = '*doesn''t match*' }
        @{ Name = 'a tag without the v'; Versions = @('1.0.0', '1.0.0', '1.0.0'); Tag = '1.0.0'; Message = '*not v<major>*' }
        @{ Name = 'a prerelease tag'; Versions = @('1.0.0', '1.0.0', '1.0.0'); Tag = 'v1.0.0-rc1'; Message = '*not v<major>*' }
        @{ Name = 'modules that disagree'; Versions = @('1.0.0', '0.1.0', '1.0.0'); Tag = ''; Message = '*different versions*' }
        @{ Name = 'a version with four parts'; Versions = @('1.0.0.1', '1.0.0.1', '1.0.0.1'); Tag = ''; Message = '*major.minor.patch*' }
    ) {
        { Resolve-ReleaseVersion -ModuleVersion $Versions -Tag $Tag } | Should -Throw $Message
    }

    It 'finds one version in the three modules of this repository' {
        $versions = foreach ($manifest in 'src/FibocomFm350/FibocomFm350.psd1', 'src/App/FibocomFm350.App.psd1', 'src/Installer/FibocomFm350.Installer.psd1') {
            [string](Import-PowerShellDataFile -LiteralPath (Join-Path $script:root $manifest)).ModuleVersion
        }
        { Resolve-ReleaseVersion -ModuleVersion $versions } | Should -Not -Throw
    }
}

Describe 'Get-ChangelogSection' {
    It 'takes <Name>' -ForEach @(
        @{ Name = 'the Unreleased section'; Section = 'Unreleased'; Text = "### Added`n- Something new." }
        @{ Name = 'a dated version, up to the next one'; Section = '1.1.0'; Text = "### Fixed`n- A fix." }
        @{ Name = 'the last section, without the links after it'; Section = '1.0.0'; Text = "### Added`n- The first release.`n  - With a nested line." }
        @{ Name = 'a version that only begins like another'; Section = '1.0.0-beta'; Text = '- A beta.' }
    ) {
        Get-ChangelogSection -Text $script:changelog -Name $Section | Should -BeExactly $Text
    }

    It 'gives nothing for <Name>' -ForEach @(
        @{ Name = 'a version it doesn''t have'; Text = "## [1.0.0]`n- x"; Section = '2.0.0' }
        @{ Name = 'an empty section'; Text = "## [Unreleased]`n`n## [1.0.0]`n- x"; Section = 'Unreleased' }
        @{ Name = 'a heading in a sentence'; Text = "Not a heading ## [1.0.0]`n- x"; Section = '1.0.0' }
    ) {
        Get-ChangelogSection -Text $Text -Name $Section | Should -BeNullOrEmpty
    }

    It 'reads CRLF as LF' {
        Get-ChangelogSection -Text "## [1.0.0]`r`n- one`r`n- two`r`n" -Name '1.0.0' | Should -BeExactly "- one`n- two"
    }
}

Describe 'New-ReleasePackage.ps1' {
    It 'builds the zip from this repository: the package at its top, nothing else' {
        $out = Join-Path $TestDrive 'dist'
        $result = & $script:builder -OutputFolder $out
        $result.Zip | Should -Exist
        $result.Notes | Should -Exist
        Split-Path -Leaf $result.Zip | Should -Be "fibocom-fm350-gl-windows-gui-$($result.Version).zip"

        $zip = [System.IO.Compression.ZipFile]::OpenRead($result.Zip)
        try {
            $entries = @($zip.Entries | ForEach-Object FullName)
        }
        finally {
            $zip.Dispose()
        }
        $entries.Count | Should -Be $result.Files
        foreach ($expected in 'install.cmd', 'uninstall.cmd', 'Start-Fm350.ps1', 'App/Start-Fm350App.ps1', 'FibocomFm350/FibocomFm350.psd1', 'FibocomFm350/Data/Drivers.psd1', 'Installer/Invoke-Fm350Setup.ps1', 'LICENSE', 'README.md', 'CHANGELOG.md') {
            $entries | Should -Contain $expected
        }
        $entries -match '\\' | Should -BeNullOrEmpty -Because 'zip entries use forward slashes'
        $entries -match '^(tests|docs|tools|captures|\.github)/' | Should -BeNullOrEmpty

        $extracted = Join-Path $TestDrive 'extracted'
        Expand-Archive -LiteralPath $result.Zip -DestinationPath $extracted
        Import-Module "$PSScriptRoot/../src/Installer/FibocomFm350.Installer.psd1" -Force
        try {
            Test-AppPackage -Path $extracted | Should -BeTrue
        }
        finally {
            Remove-Module FibocomFm350.Installer -ErrorAction SilentlyContinue
        }
        (Get-Content -LiteralPath $result.Notes -Raw).Trim() | Should -Not -BeNullOrEmpty
    }

    It 'refuses a tag that doesn''t name the version, and builds nothing' {
        $out = Join-Path $TestDrive 'refused'
        { & $script:builder -Tag 'v0.0.1' -OutputFolder $out } | Should -Throw '*doesn''t match*'
        Test-Path $out | Should -BeFalse
    }
}

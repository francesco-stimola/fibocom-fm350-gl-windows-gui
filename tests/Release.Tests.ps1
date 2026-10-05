# The release package (tools/New-ReleasePackage.ps1): the version a tag may release, the
# CHANGELOG section that becomes the notes, lpac's and ZXing.Net's pins, and the zip itself -
# built into TestDrive from this repository with stand-ins for both (no download), extracted, and
# found to be a package the installer takes.

BeforeAll {
    $script:root = (Resolve-Path "$PSScriptRoot/..").Path
    $script:builder = Join-Path $script:root 'tools/New-ReleasePackage.ps1'
    . $script:builder

    # A stand-in for lpac's release: a build zip - lpac.exe, its license, and a libcurl.dll the pin
    # doesn't list - and a source archive in -Cache, and a pin that names them with their SHA-256
    # (or -Wrong ones), addresses never fetched, and the files to package (one -Missing).
    function Get-TestLpac {
        param([string] $Folder, [switch] $Wrong, [switch] $Missing)
        $cache = Join-Path $Folder 'cache'
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $staging = Join-Path $Folder 'build'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $staging 'lpac.exe') -Value 'not a program'
        Set-Content -LiteralPath (Join-Path $staging 'LICENSE-lpac') -Value 'AGPL-3.0'
        Set-Content -LiteralPath (Join-Path $staging 'libcurl.dll') -Value 'not a library'
        $files = if ($Missing) { "'lpac.exe', 'LICENSE-lpac', 'LICENSE-cjson'" } else { "'lpac.exe', 'LICENSE-lpac'" }
        $build = Join-Path $cache 'lpac-test.zip'
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $build -Force
        $source = Join-Path $cache 'lpac-9.9.9-source.tar.gz'
        Set-Content -LiteralPath $source -Value 'source'
        $buildHash = (Get-FileHash -LiteralPath $build -Algorithm SHA256).Hash
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        if ($Wrong) {
            $buildHash = '0' * 64
            $sourceHash = '0' * 64
        }
        $pin = Join-Path $Folder 'Lpac.psd1'
        Set-Content -LiteralPath $pin -Value @(
            "@{ Version = '9.9.9'; Page = 'https://example.invalid/lpac'; Files = @($files)"
            "    Build = @{ Name = 'lpac-test.zip'; Url = 'https://example.invalid/build.zip'; Sha256 = '$buildHash' }"
            "    Source = @{ Name = 'lpac-9.9.9-source.tar.gz'; Url = 'https://example.invalid/source.tar.gz'; Sha256 = '$sourceHash' } }"
        )
        # ZXing.Net's stand-in in the same cache: a package with the library and another one, its
        # license, and a pin that takes the library.
        $nuget = Join-Path $Folder 'nuget'
        New-Item -ItemType Directory -Path (Join-Path $nuget 'lib/net9.0') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $nuget 'lib/net8.0') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $nuget 'lib/net9.0/zxing.dll') -Value 'not a library'
        Set-Content -LiteralPath (Join-Path $nuget 'lib/net8.0/zxing.dll') -Value 'not this one'
        $package = Join-Path $cache 'zxing.test.nupkg'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($nuget, $package)
        $license = Join-Path $cache 'COPYING'
        Set-Content -LiteralPath $license -Value 'Apache License 2.0'
        $zxingPin = Join-Path $Folder 'ZXing.psd1'
        Set-Content -LiteralPath $zxingPin -Value @(
            "@{ Version = '9.9.9'; Page = 'https://example.invalid/zxing'; Files = @{ 'lib/net9.0/zxing.dll' = 'zxing.dll' }"
            "    Package = @{ Name = 'zxing.test.nupkg'; Url = 'https://example.invalid/zxing.nupkg'; Sha256 = '$((Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash)' }"
            "    License = @{ Name = 'COPYING'; Url = 'https://example.invalid/COPYING'; Sha256 = '$((Get-FileHash -LiteralPath $license -Algorithm SHA256).Hash)' } }"
        )
        [pscustomobject]@{ Pin = $pin; ZxingPin = $zxingPin; Cache = $cache; Build = $build; Source = $source }
    }

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
    It 'builds the zip from this repository: the package at its top, lpac in its folder, nothing else' {
        $out = Join-Path $TestDrive 'dist'
        $lpac = Get-TestLpac -Folder (Join-Path $TestDrive 'lpac')
        $result = & $script:builder -OutputFolder $out -LpacPin $lpac.Pin -ZxingPin $lpac.ZxingPin -Cache $lpac.Cache
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
        foreach ($expected in 'install.cmd', 'uninstall.cmd', 'Start-Fm350.ps1', 'App/Start-Fm350App.ps1', 'FibocomFm350/FibocomFm350.psd1', 'FibocomFm350/Data/Simulation.psd1', 'Installer/Invoke-Fm350Setup.ps1', 'LICENSE', 'README.md', 'CHANGELOG.md') {
            $entries | Should -Contain $expected
        }
        $entries -match '\\' | Should -BeNullOrEmpty -Because 'zip entries use forward slashes'
        $entries -match '^(tests|docs|tools|captures|\.github)/' | Should -BeNullOrEmpty
        @($entries -like 'lpac/*') | Should -Be @('lpac/lpac.exe', 'lpac/LICENSE-lpac', 'lpac/SOURCE.txt')
        @($entries -like 'zxing/*') | Should -Be @('zxing/zxing.dll', 'zxing/COPYING', 'zxing/README.txt')
        $result.LpacSource | Should -Exist
        Split-Path -Leaf $result.LpacSource | Should -Be 'lpac-9.9.9-source.tar.gz'

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
        $lpac = Get-TestLpac -Folder (Join-Path $TestDrive 'lpac-refused')
        { & $script:builder -Tag 'v0.0.1' -OutputFolder $out -LpacPin $lpac.Pin -ZxingPin $lpac.ZxingPin -Cache $lpac.Cache } | Should -Throw '*doesn''t match*'
        Test-Path $out | Should -BeFalse
    }

    It 'refuses lpac''s files when a SHA-256 doesn''t match: deleted, nothing built' {
        $out = Join-Path $TestDrive 'wrong'
        $lpac = Get-TestLpac -Folder (Join-Path $TestDrive 'lpac-wrong') -Wrong
        { & $script:builder -OutputFolder $out -LpacPin $lpac.Pin -ZxingPin $lpac.ZxingPin -Cache $lpac.Cache } | Should -Throw '*SHA-256*'
        $lpac.Build | Should -Not -Exist
        Test-Path $out | Should -BeFalse
    }

    It 'refuses a build without a file the pin lists, and leaves no zip' {
        $out = Join-Path $TestDrive 'nested'
        $lpac = Get-TestLpac -Folder (Join-Path $TestDrive 'lpac-missing') -Missing
        { & $script:builder -OutputFolder $out -LpacPin $lpac.Pin -ZxingPin $lpac.ZxingPin -Cache $lpac.Cache } | Should -Throw '*has no LICENSE-cjson*'
        @(Get-ChildItem -LiteralPath $out -Filter '*.zip') | Should -BeNullOrEmpty
    }

    It 'never packages a lpac or zxing folder put in src' {
        $fake = Join-Path $TestDrive 'fake-root'
        foreach ($file in 'src/App/a.ps1', 'src/lpac/lpac.exe', 'src/lpacx/b.txt', 'src/zxing/zxing.dll', 'LICENSE', 'README.md', 'CHANGELOG.md') {
            New-Item -ItemType File -Path (Join-Path $fake $file) -Force | Out-Null
        }
        @(Get-ReleaseFile -Root $fake | ForEach-Object Entry) | Should -Be @('App/a.ps1', 'lpacx/b.txt', 'LICENSE', 'README.md', 'CHANGELOG.md')
    }
}

Describe 'lpac''s pin' {
    It 'pins this repository''s lpac: its official release, a version, two SHA-256' {
        $pin = Import-PowerShellDataFile -LiteralPath (Join-Path $script:root 'tools/Lpac.psd1')
        Test-LpacPin -Pin $pin | Should -BeTrue
        $pin.Build.Url | Should -BeLike "https://github.com/estkme-group/lpac/releases/download/v$($pin.Version)/*"
        $pin.Source.Url | Should -Be "https://github.com/estkme-group/lpac/archive/refs/tags/v$($pin.Version).tar.gz"
        $pin.Page | Should -Be "https://github.com/estkme-group/lpac/releases/tag/v$($pin.Version)"
        # The app makes the HTTPS requests itself (decided 2026-10-04): no libcurl in the zip.
        $pin.Files | Should -Not -Contain 'libcurl.dll'
        $pin.Files | Should -Contain 'LICENSE-lpac'
        $pin.Files | Should -Contain 'LICENSE-libeuicc'
    }

    It 'refuses a pin without <Name>' -ForEach @(
        @{ Name = 'a version'; Pin = @{ Files = @('lpac.exe'); Version = ''; Build = @{ Name = 'a.zip'; Url = 'https://x/a'; Sha256 = ('a' * 64) }; Source = @{ Name = 'b.tar.gz'; Url = 'https://x/b'; Sha256 = ('b' * 64) } } }
        @{ Name = 'a SHA-256'; Pin = @{ Files = @('lpac.exe'); Version = '1.0.0'; Build = @{ Name = 'a.zip'; Url = 'https://x/a'; Sha256 = 'abc' }; Source = @{ Name = 'b.tar.gz'; Url = 'https://x/b'; Sha256 = ('b' * 64) } } }
        @{ Name = 'an https address'; Pin = @{ Files = @('lpac.exe'); Version = '1.0.0'; Build = @{ Name = 'a.zip'; Url = 'http://x/a'; Sha256 = ('a' * 64) }; Source = @{ Name = 'b.tar.gz'; Url = 'https://x/b'; Sha256 = ('b' * 64) } } }
        @{ Name = 'its source'; Pin = @{ Files = @('lpac.exe'); Version = '1.0.0'; Build = @{ Name = 'a.zip'; Url = 'https://x/a'; Sha256 = ('a' * 64) } } }
        @{ Name = 'a plain file name'; Pin = @{ Files = @('lpac.exe'); Version = '1.0.0'; Build = @{ Name = '../a.zip'; Url = 'https://x/a'; Sha256 = ('a' * 64) }; Source = @{ Name = 'b.tar.gz'; Url = 'https://x/b'; Sha256 = ('b' * 64) } } }
        @{ Name = 'lpac.exe among its files'; Pin = @{ Files = @('README.md'); Version = '1.0.0'; Build = @{ Name = 'a.zip'; Url = 'https://x/a'; Sha256 = ('a' * 64) }; Source = @{ Name = 'b.tar.gz'; Url = 'https://x/b'; Sha256 = ('b' * 64) } } }
        @{ Name = 'files with plain names'; Pin = @{ Files = @('lpac.exe', '../x.dll'); Version = '1.0.0'; Build = @{ Name = 'a.zip'; Url = 'https://x/a'; Sha256 = ('a' * 64) }; Source = @{ Name = 'b.tar.gz'; Url = 'https://x/b'; Sha256 = ('b' * 64) } } }
    ) {
        { Test-LpacPin -Pin $Pin } | Should -Throw "*lpac's pin*"
    }

    It 'pins this repository''s ZXing.Net: its nuget.org package, the .NET 9 library, its license at its tag' {
        $pin = Import-PowerShellDataFile -LiteralPath (Join-Path $script:root 'tools/ZXing.psd1')
        Test-ZxingPin -Pin $pin | Should -BeTrue
        $pin.Package.Url | Should -Be "https://api.nuget.org/v3-flatcontainer/zxing.net/$($pin.Version)/zxing.net.$($pin.Version).nupkg"
        $pin.License.Url | Should -Be "https://raw.githubusercontent.com/micjahn/ZXing.Net/v$($pin.Version).0/COPYING"
        @($pin.Files.Keys) | Should -Be @('lib/net9.0/zxing.dll')
    }

    It 'refuses a ZXing.Net pin without <Name>' -ForEach @(
        @{ Name = 'a version'; Pin = @{ Version = ''; Files = @{ 'lib/net9.0/zxing.dll' = 'zxing.dll' }; Package = @{ Name = 'a.nupkg'; Url = 'https://x/a'; Sha256 = ('a' * 64) }; License = @{ Name = 'COPYING'; Url = 'https://x/c'; Sha256 = ('c' * 64) } } }
        @{ Name = 'its license'; Pin = @{ Version = '1.0.0'; Files = @{ 'lib/net9.0/zxing.dll' = 'zxing.dll' }; Package = @{ Name = 'a.nupkg'; Url = 'https://x/a'; Sha256 = ('a' * 64) } } }
        @{ Name = 'zxing.dll among its files'; Pin = @{ Version = '1.0.0'; Files = @{ 'lib/net9.0/other.dll' = 'other.dll' }; Package = @{ Name = 'a.nupkg'; Url = 'https://x/a'; Sha256 = ('a' * 64) }; License = @{ Name = 'COPYING'; Url = 'https://x/c'; Sha256 = ('c' * 64) } } }
        @{ Name = 'plain names in the zip'; Pin = @{ Version = '1.0.0'; Files = @{ 'lib/net9.0/zxing.dll' = '../zxing.dll' }; Package = @{ Name = 'a.nupkg'; Url = 'https://x/a'; Sha256 = ('a' * 64) }; License = @{ Name = 'COPYING'; Url = 'https://x/c'; Sha256 = ('c' * 64) } } }
        @{ Name = 'an https address'; Pin = @{ Version = '1.0.0'; Files = @{ 'lib/net9.0/zxing.dll' = 'zxing.dll' }; Package = @{ Name = 'a.nupkg'; Url = 'http://x/a'; Sha256 = ('a' * 64) }; License = @{ Name = 'COPYING'; Url = 'https://x/c'; Sha256 = ('c' * 64) } } }
    ) {
        { Test-ZxingPin -Pin $Pin } | Should -Throw "*ZXing.Net's pin*"
    }

    It 'says what ZXing.Net is, and its license' {
        $note = Get-ZxingNote -Pin @{ Version = '0.16.11'; Page = 'https://example.invalid/p' }
        $note | Should -Match 'ZXing\.Net 0\.16\.11'
        $note | Should -Match 'Apache License 2\.0 \(COPYING\)'
    }

    It 'says where lpac''s source is, beside it' {
        $note = Get-LpacSourceNote -Pin @{ Version = '2.3.0'; Page = 'https://example.invalid/p'; Source = @{ Name = 'lpac-2.3.0-source.tar.gz'; Sha256 = ('A' * 64) } }
        $note | Should -Match 'lpac 2\.3\.0'
        $note | Should -Match 'Affero'
        $note | Should -Match 'lpac-2\.3\.0-source\.tar\.gz'
        $note | Should -Match ('a' * 64)
    }
}

# The AT port's driver, "bring your own driver": the INF read as Windows reads it, the verdict on a
# package (a matrix of made-up facts), the known-fingerprints manifest, copying a package without
# running anything from it, the folder only administrators can open, the facts read from a package,
# and pnputil - mocked: these tests change nothing on the system. On a machine where the modem's
# driver is installed, the facts of its driver-store copy (Hardware, read-only).

BeforeDiscovery {
    $script:driverStore = @(Get-ChildItem -Path "$env:SystemRoot\System32\DriverStore\FileRepository" -Directory -Filter 'usb2ser_tm.inf_*' -ErrorAction SilentlyContinue)
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force

    # An INF written for these tests in the layout Windows documents (AT-COMMANDS section 1.1):
    # the FM350's IDs, everything else invented.
    $script:inf = @(
        '; A serial driver for tests.'
        '[Version]'
        'Signature = "$Windows NT$"'
        'Class=Ports'
        'ClassGUID={4D36E978-E325-11CE-BFC1-08002BE10318}'
        'Provider=%Maker% ; the maker'
        'CatalogFile=serial.cat'
        'DriverVer = 01/02/2024,1.2.3.4'
        ''
        '[Manufacturer]'
        '%Maker%=Models,NTx86,NTamd64'
        ''
        '[Models.NTx86]'
        '%AtPort% = Install, USB\VID_0E8D&PID_7127&MI_06'
        ''
        '[Models.NTamd64]'
        '%AtPort% = Install, USB\VID_0E8D&PID_7127&MI_06'
        '%AtPort% = Install, USB\VID_0E8D&PID_7126&MI_04'
        '%Other%  = Install, USB\VID_0E8D&PID_2000'
        ''
        '[Install.NTamd64]'
        'CopyFiles=Files'
        ''
        '[Strings]'
        'Maker = "Example Maker"'
        'AtPort = "Modem AT port; serial"'
        'Other = "Download mode"'
    )

    # The facts Get-DriverPackageFact gives for one INF: by default those of the known package,
    # signed for WHQL and vouched for by its catalog.
    $script:known = @(Get-KnownDriverPackage)
    $script:whql = [pscustomobject]@{
        Subject   = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        KeyUsages = [string[]]@('1.3.6.1.4.1.311.10.3.39', '1.3.6.1.4.1.311.10.3.5', '1.3.6.1.5.5.7.3.3')
    }
    function Get-PackageFact {
        param(
            [string] $Path = 'driver/usb2ser_tm.inf',
            [string[]] $HardwareIds = @('USB\VID_0E8D&PID_7127&MI_06', 'USB\VID_0E8D&PID_7126&MI_04'),
            [string] $CatalogFile = 'usb2ser_tm.cat',
            [bool] $Catalog = $true,
            [object] $Signer = $script:whql,
            [object] $CatalogCheck = 0,
            [hashtable] $Change = @{}
        )
        $files = @{}
        foreach ($key in $script:known[0].Files.Keys) {
            $files[$key] = $script:known[0].Files[$key]
        }
        foreach ($key in $Change.Keys) {
            if ($null -eq $Change[$key]) { $files.Remove($key) } else { $files[$key] = $Change[$key] }
        }
        [pscustomobject]@{
            Path         = $Path
            Inf          = [pscustomobject]@{ Class = 'Ports'; Provider = 'MediaTek'; Version = '3.22.43.1'; Date = '10/18/2022'; CatalogFile = $CatalogFile; HardwareIds = $HardwareIds }
            Catalog      = $Catalog
            Signer       = $Signer
            CatalogCheck = $CatalogCheck
            Files        = $files
        }
    }

    # A zip made in the test drive: entry name -> content.
    function Write-TestZip {
        param([string] $Path, [hashtable] $Entry)
        $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $Entry.Keys) {
                $writer = [System.IO.StreamWriter]::new($zip.CreateEntry($name).Open())
                try { $writer.Write($Entry[$name]) } finally { $writer.Dispose() }
            }
        }
        finally {
            $zip.Dispose()
        }
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-DriverInf' {
    It 'reads the class, the provider from [Strings], the version, its date and the catalog' {
        $read = ConvertFrom-DriverInf -Text $script:inf
        $read.Class | Should -Be 'Ports'
        $read.Provider | Should -Be 'Example Maker'
        $read.Version | Should -Be '1.2.3.4'
        $read.Date | Should -Be '01/02/2024'
        $read.CatalogFile | Should -Be 'serial.cat'
    }

    It 'lists the IDs of the models section decorated for x64' {
        (ConvertFrom-DriverInf -Text $script:inf).HardwareIds | Should -Be @('USB\VID_0E8D&PID_7127&MI_06', 'USB\VID_0E8D&PID_7126&MI_04', 'USB\VID_0E8D&PID_2000')
    }

    It 'lists those of the x86 section for x86' {
        (ConvertFrom-DriverInf -Text $script:inf -Architecture x86).HardwareIds | Should -Be @('USB\VID_0E8D&PID_7127&MI_06')
    }

    It 'reads an undecorated models section for x86 only' {
        $text = @('[Manufacturer]', '%M%=Models', '[Models]', 'Port = Install, USB\VID_0E8D&PID_7127&MI_06', '[Strings]', 'M = "Maker"')
        (ConvertFrom-DriverInf -Text $text).HardwareIds | Should -BeNullOrEmpty
        (ConvertFrom-DriverInf -Text $text -Architecture x86).HardwareIds | Should -Be @('USB\VID_0E8D&PID_7127&MI_06')
    }

    It 'takes a decoration with an OS version, and leaves out another architecture''s' {
        $text = @(
            '[Manufacturer]', 'Maker=Models,NTamd64.10.0...16299,NTarm64'
            '[Models.NTamd64.10.0...16299]', 'Port = Install, USB\VID_0E8D&PID_7127&MI_06'
            '[Models.NTarm64]', 'Port = Install, USB\VID_0E8D&PID_7126&MI_04'
        )
        (ConvertFrom-DriverInf -Text $text).HardwareIds | Should -Be @('USB\VID_0E8D&PID_7127&MI_06')
        (ConvertFrom-DriverInf -Text $text -Architecture arm64).HardwareIds | Should -Be @('USB\VID_0E8D&PID_7126&MI_04')
    }

    It 'keeps compatible IDs, unquoted, and each ID once' {
        $text = @(
            '[Manufacturer]', 'Maker=Models,NTamd64', '[Models.NTamd64]'
            'Port = Install, "USB\VID_0E8D&PID_7127&MI_06", USB\Class_FF'
            'Again = Install, usb\vid_0e8d&pid_7127&mi_06'
        )
        (ConvertFrom-DriverInf -Text $text).HardwareIds | Should -Be @('USB\VID_0E8D&PID_7127&MI_06', 'USB\Class_FF')
    }

    It 'takes the catalog for its architecture first: <Expected>' -ForEach @(
        @{ Lines = @('CatalogFile=a.cat', 'CatalogFile.NTamd64=b.cat', 'CatalogFile.NTx86=c.cat'); Expected = 'b.cat' }
        @{ Lines = @('CatalogFile=a.cat', 'CatalogFile.NT=n.cat'); Expected = 'n.cat' }
        @{ Lines = @('CatalogFile=a.cat', 'CatalogFile.NTx86=c.cat'); Expected = 'a.cat' }
        @{ Lines = @('catalogfile.ntamd64 = "quoted.cat"'); Expected = 'quoted.cat' }
    ) {
        (ConvertFrom-DriverInf -Text (@('[Version]') + $Lines)).CatalogFile | Should -Be $Expected
    }

    It 'names no catalog for <Value>' -ForEach @(
        @{ Value = $null }
        @{ Value = '..\other.cat' }
        @{ Value = 'C:\Windows\other.cat' }
        @{ Value = 'sub/other.cat' }
        @{ Value = '..' }
    ) {
        $lines = @('[Version]', 'Class=Ports')
        if ($Value) { $lines += "CatalogFile=$Value" }
        (ConvertFrom-DriverInf -Text $lines).CatalogFile | Should -BeNullOrEmpty
    }

    It 'drops comments outside quotes and keeps a ";" inside them' {
        $text = @('[Version]', 'Provider = %Maker% ; ignored', '[Strings]', 'Maker = "A;B" ; ignored too', '; [Strings]', '; Maker = "C"')
        (ConvertFrom-DriverInf -Text $text).Provider | Should -Be 'A;B'
    }

    It 'joins lines continued with a backslash' {
        $text = @('[Manufacturer]', 'Maker=Models,\', '  NTamd64', '[Models.NTamd64]', 'Port = Install, \', 'USB\VID_0E8D&PID_7127&MI_06')
        (ConvertFrom-DriverInf -Text $text).HardwareIds | Should -Be @('USB\VID_0E8D&PID_7127&MI_06')
    }

    It 'reads names and keys in any case, and merges sections of the same name' {
        $text = @(
            '[VERSION]', 'CATALOGFILE=upper.cat'
            '[manufacturer]', 'Maker=Models,ntamd64'
            '[MODELS.NTAMD64]', 'Port = Install, USB\VID_0E8D&PID_7127&MI_06'
            '[Strings]', 'X = "y"'
            '[models.ntamd64]', 'Port = Install, USB\VID_0E8D&PID_7126&MI_04'
        )
        $read = ConvertFrom-DriverInf -Text $text
        $read.CatalogFile | Should -Be 'upper.cat'
        $read.HardwareIds | Should -Be @('USB\VID_0E8D&PID_7127&MI_06', 'USB\VID_0E8D&PID_7126&MI_04')
    }

    It 'reads "%%" as a percent sign, a doubled quote as one, and leaves an unknown token as written' {
        $text = @('[Version]', 'Provider = "100%% ""Maker"""', 'Class = %Unknown%')
        $read = ConvertFrom-DriverInf -Text $text
        $read.Provider | Should -Be '100% "Maker"'
        $read.Class | Should -Be '%Unknown%'
    }

    It 'names the package''s files: its catalogs, and what it copies for every architecture' {
        $text = @(
            '[Version]', 'CatalogFile=serial.cat', 'CatalogFile.NTamd64=serial64.cat'
            '[SourceDisksNames]', '1 = %Disk%'
            '[SourceDisksFiles.amd64]', 'serial.sys = 1,.\x64'
            '[SourceDisksFiles.x86]', 'serial.sys = 1,.\x86'
            '[Strings]', 'Disk = "Disk"'
        )
        (ConvertFrom-DriverInf -Text $text).PackageFiles | Should -Be @('serial.cat', 'serial64.cat', 'x64/serial.sys', 'x86/serial.sys')
    }

    It 'puts a file under its disk''s path, the disk of its own architecture first, with the disk''s tag files' {
        $text = @(
            '[SourceDisksNames]', '1 = "Generic",,,\generic'
            '[SourceDisksNames.amd64]', '1 = "Only x64",disk.tag,,\x64only'
            '[SourceDisksFiles.amd64]', 'B.SYS = 1,sub'
            '[SourceDisksFiles]', 'c.dll = 1'
        )
        @((ConvertFrom-DriverInf -Text $text).PackageFiles | Sort-Object) | Should -Be @('disk.tag', 'generic/c.dll', 'x64only/disk.tag', 'x64only/sub/B.SYS') -Because 'a tag file lies in its disk''s path or in the root'
    }

    It 'names only the catalogs of an INF without files to copy, and nothing that is no plain name' {
        (ConvertFrom-DriverInf -Text $script:inf).PackageFiles | Should -Be @('serial.cat')
        (ConvertFrom-DriverInf -Text @('[Version]', 'CatalogFile=..\other.cat')).PackageFiles | Should -BeNullOrEmpty
    }

    It 'reads nothing from an INF without the sections it needs' {
        $read = ConvertFrom-DriverInf -Text @()
        $read.Class | Should -BeNullOrEmpty
        $read.Version | Should -BeNullOrEmpty
        $read.CatalogFile | Should -BeNullOrEmpty
        @($read.HardwareIds).Count | Should -Be 0
    }
}

Describe 'Resolve-DriverPackage' {
    It 'verifies the known package, signed for WHQL and vouched for by its catalog' {
        $verdict = Resolve-DriverPackage -Inf @(Get-PackageFact) -Known $script:known -ProductId 7127
        $verdict.Verdict | Should -Be 'Verified'
        $verdict.Problems | Should -BeNullOrEmpty
        $verdict.Path | Should -Be 'driver/usb2ser_tm.inf'
        $verdict.Known.Name | Should -Be 'MediaTek usb2ser_tm'
        $verdict.Known.Version | Should -Be '3.22.43.1'
        $verdict.Provider | Should -Be 'MediaTek'
        $verdict.Version | Should -Be '3.22.43.1'
    }

    It 'allows, as a version it doesn''t know, a signed package whose files differ: <Name>' -ForEach @(
        @{ Name = 'another catalog'; Change = @{ 'usb2ser_tm.cat' = 'ab' * 32 } }
        @{ Name = 'another driver'; Change = @{ 'x64/usb2ser_tm.sys' = 'cd' * 32 } }
        @{ Name = 'no x86 driver'; Change = @{ 'x86/usb2ser_tm.sys' = $null } }
    ) {
        $verdict = Resolve-DriverPackage -Inf @(Get-PackageFact -Change $Change) -Known $script:known -ProductId 7127
        $verdict.Verdict | Should -Be 'Signed'
        $verdict.Known | Should -BeNullOrEmpty
        $verdict.Version | Should -Be '3.22.43.1'
    }

    It 'takes the AT port''s hardware ID <Id> for composition <ProductId>' -ForEach @(
        @{ Id = 'USB\VID_0E8D&PID_7127&MI_06'; ProductId = '7127' }
        @{ Id = 'USB\VID_0E8D&PID_7127&REV_0001&MI_06'; ProductId = '7127' }
        @{ Id = 'usb\vid_0e8d&pid_7127&mi_06'; ProductId = '7127' }
        @{ Id = 'USB\VID_0E8D&PID_7126&MI_04'; ProductId = '7126' }
        @{ Id = 'USB\VID_0E8D&PID_7126&MI_04'; ProductId = '' }
        @{ Id = 'USB\VID_0E8D&PID_7127&MI_06'; ProductId = '' }
    ) {
        (Resolve-DriverPackage -Inf @(Get-PackageFact -HardwareIds $Id) -Known $script:known -ProductId $ProductId).Verdict | Should -Be 'Verified'
    }

    It 'refuses a package meant for another port: <Id> for composition <ProductId>' -ForEach @(
        @{ Id = 'USB\VID_0E8D&PID_2000'; ProductId = '7127' }
        @{ Id = 'USB\VID_0E8D&PID_7127&MI_04'; ProductId = '7127' }
        @{ Id = 'USB\VID_0E8D&PID_7126&MI_04'; ProductId = '7127' }
        @{ Id = 'USB\VID_0E8D&PID_7127&MI_06'; ProductId = '7126' }
        @{ Id = 'USB\VID_0E8D&PID_7127&MI_06&X'; ProductId = '' }
        @{ Id = 'USB\VID_1234&PID_7127&MI_06'; ProductId = '' }
    ) {
        $verdict = Resolve-DriverPackage -Inf @(Get-PackageFact -HardwareIds $Id) -Known $script:known -ProductId $ProductId
        $verdict.Verdict | Should -Be 'Refused'
        $verdict.Problems | Should -Be @('NotForModem')
        $verdict.Path | Should -BeNullOrEmpty
    }

    It 'refuses a package with no INF' {
        $verdict = Resolve-DriverPackage -Inf @() -Known $script:known -ProductId 7127
        $verdict.Verdict | Should -Be 'Refused'
        $verdict.Problems | Should -Be @('NoInf')
    }

    It 'refuses <Name>: <Problems>' -ForEach @(
        @{ Name = 'an INF that names no catalog'; Fact = @{ CatalogFile = '' }; Problems = @('NoCatalog') }
        @{ Name = 'a catalog missing from the package'; Fact = @{ Catalog = $false; CatalogCheck = $null; Signer = $null }; Problems = @('NoCatalog') }
        @{ Name = 'a catalog without a signer'; Fact = @{ Signer = $null; CatalogCheck = 0x80092003 }; Problems = @('NotWhql', 'NotTrusted') }
        @{ Name = 'another publisher''s signature'; Fact = @{ Signer = [pscustomobject]@{ Subject = 'CN=Example Software GmbH, O=Example Software GmbH, C=DE'; KeyUsages = [string[]]@('1.3.6.1.5.5.7.3.3') } }; Problems = @('NotWhql') }
        @{ Name = 'an attestation signature'; Fact = @{ Signer = [pscustomobject]@{ Subject = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation'; KeyUsages = [string[]]@('1.3.6.1.4.1.311.10.3.5.1', '1.3.6.1.5.5.7.3.3') } }; Problems = @('NotWhql') }
        @{ Name = 'the WHQL usage under another organization'; Fact = @{ Signer = [pscustomobject]@{ Subject = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Example Corporation'; KeyUsages = [string[]]@('1.3.6.1.4.1.311.10.3.5') } }; Problems = @('NotWhql') }
        @{ Name = 'a look-alike name'; Fact = @{ Signer = [pscustomobject]@{ Subject = 'CN=Microsoft Windows Hardware Compatibility Publisher Ltd, O=Microsoft Corporation'; KeyUsages = [string[]]@('1.3.6.1.4.1.311.10.3.5') } }; Problems = @('NotWhql') }
        @{ Name = 'an INF its catalog doesn''t vouch for'; Fact = @{ CatalogCheck = 0x800B0100 }; Problems = @('NotInCatalog') }
        @{ Name = 'a signature that doesn''t verify'; Fact = @{ CatalogCheck = 0x800B0109 }; Problems = @('NotTrusted') }
        @{ Name = 'a catalog not checked'; Fact = @{ CatalogCheck = $null }; Problems = @('NotTrusted') }
        @{ Name = 'a changed INF under another signature'; Fact = @{ CatalogCheck = 0x800B0100; Signer = [pscustomobject]@{ Subject = 'CN=Example'; KeyUsages = [string[]]@() } }; Problems = @('NotWhql', 'NotInCatalog') }
    ) {
        $verdict = Resolve-DriverPackage -Inf @(Get-PackageFact @Fact) -Known $script:known -ProductId 7127
        $verdict.Verdict | Should -Be 'Refused'
        $verdict.Problems | Should -Be $Problems
        $verdict.Known | Should -BeNullOrEmpty
        $verdict.Path | Should -Be 'driver/usb2ser_tm.inf'
    }

    It 'chooses, among several INFs, the one for the modem that may be installed, a known version first' {
        $other = Get-PackageFact -Path 'other/other.inf' -HardwareIds 'USB\VID_0E8D&PID_2000'
        $changed = Get-PackageFact -Path 'a/changed.inf' -CatalogCheck 0x800B0100
        $unknown = Get-PackageFact -Path 'b/unknown.inf' -Change @{ 'usb2ser_tm.cat' = 'ab' * 32 }
        $verified = Get-PackageFact -Path 'c/usb2ser_tm.inf'
        (Resolve-DriverPackage -Inf @($other, $changed, $unknown, $verified) -Known $script:known -ProductId 7127).Path | Should -Be 'c/usb2ser_tm.inf'
        $verdict = Resolve-DriverPackage -Inf @($other, $changed, $unknown) -Known $script:known -ProductId 7127
        $verdict.Verdict | Should -Be 'Signed'
        $verdict.Path | Should -Be 'b/unknown.inf'
    }

    It 'gives the problems of the first INF for the modem when none may be installed' {
        $verdict = Resolve-DriverPackage -Inf @((Get-PackageFact -Path 'a.inf' -CatalogCheck 0x800B0100), (Get-PackageFact -Path 'b.inf' -Signer $null)) -Known $script:known -ProductId 7127
        $verdict.Path | Should -Be 'a.inf'
        $verdict.Problems | Should -Be @('NotInCatalog')
    }

    It 'knows no version without known packages' {
        (Resolve-DriverPackage -Inf @(Get-PackageFact) -Known @() -ProductId 7127).Verdict | Should -Be 'Signed'
    }
}

Describe 'Get-KnownDriverPackage' {
    It 'lists packages by the SHA-256 of their catalog, INF and drivers, and where a copy is published, pinned to a commit' {
        $script:known.Count | Should -BeGreaterThan 0
        foreach ($package in $script:known) {
            $package.Name | Should -Not -BeNullOrEmpty
            $package.Version | Should -Match '^\d+(\.\d+){1,3}$'
            @($package.Files.Keys | Where-Object { $_ -like '*.cat' }).Count | Should -Be 1
            @($package.Files.Keys | Where-Object { $_ -like '*.inf' }).Count | Should -Be 1
            @($package.Files.Keys | Where-Object { $_ -like '*.sys' }).Count | Should -BeGreaterThan 0
            foreach ($key in $package.Files.Keys) {
                $key | Should -Not -Match '\\'
                $package.Files[$key] | Should -MatchExactly '^[0-9a-f]{64}$'
            }
            $package.Copy.Publisher | Should -Not -BeNullOrEmpty
            $package.Copy.Page | Should -Match '^https://github\.com/[^/]+/[^/]+/blob/[0-9a-f]{40}/'
            $package.Copy.Page | Should -BeLike "*/$($package.Copy.File)"
            $package.Copy.Sha256 | Should -MatchExactly '^[0-9a-f]{64}$'
        }
    }
}

Describe 'Copy-DriverPackage' {
    BeforeEach {
        $script:source = Join-Path $TestDrive ([guid]::NewGuid())
        $script:target = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:source, $script:target | Out-Null
    }

    It 'extracts a zip with its folders' {
        $zip = Join-Path $script:source 'driver.zip'
        Write-TestZip -Path $zip -Entry @{ 'setup.exe' = 'MZ'; 'driver/serial.inf' = 'inf'; 'driver/x64/serial.sys' = 'sys' }
        Copy-DriverPackage -Path $zip -Destination $script:target | Should -Be 3
        Get-Content -LiteralPath (Join-Path $script:target 'driver/x64/serial.sys') | Should -Be 'sys'
        Test-Path -LiteralPath (Join-Path $script:target 'setup.exe') | Should -BeTrue
    }

    It 'copies a folder with its subfolders, and the folder of an INF chosen in it' {
        New-Item -ItemType Directory -Path (Join-Path $script:source 'x64') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:source 'serial.inf') -Value 'inf'
        Set-Content -LiteralPath (Join-Path $script:source 'x64/serial.sys') -Value 'sys'
        Copy-DriverPackage -Path $script:source -Destination $script:target | Should -Be 2
        Get-Content -LiteralPath (Join-Path $script:target 'x64/serial.sys') | Should -Be 'sys'
        $again = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $again | Out-Null
        Copy-DriverPackage -Path (Join-Path $script:source 'serial.inf') -Destination $again | Should -Be 1 -Because 'an INF that names no other file goes alone'
    }

    It 'copies, for an INF chosen in a folder shared with other files, the package''s files alone' {
        $inf = @(
            '[Version]', 'CatalogFile=serial.cat'
            '[SourceDisksNames]', '1 = "Disk"'
            '[SourceDisksFiles.amd64]', 'serial.sys = 1,.\x64', 'missing.sys = 1', 'outside.sys = 1,..'
            '[SourceDisksFiles.x86]', 'serial.sys = 1,.\x86'
        )
        New-Item -ItemType Directory -Path (Join-Path $script:source 'x64'), (Join-Path $script:source 'x86'), (Join-Path $script:source 'Photos') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:source 'serial.inf') -Value $inf
        foreach ($name in 'serial.cat', 'x64/serial.sys', 'x86/serial.sys', 'readme.txt', 'other.zip', 'Photos/holiday.jpg') {
            Set-Content -LiteralPath (Join-Path $script:source $name) -Value $name
        }
        Set-Content -LiteralPath (Join-Path $TestDrive 'outside.sys') -Value 'outside'
        Copy-DriverPackage -Path (Join-Path $script:source 'serial.inf') -Destination $script:target | Should -Be 4
        @(Get-ChildItem -LiteralPath $script:target -Recurse -File | ForEach-Object { $_.FullName.Substring($script:target.Length + 1).Replace('\', '/') } | Sort-Object) |
            Should -Be @('serial.cat', 'serial.inf', 'x64/serial.sys', 'x86/serial.sys')
    }

    It 'beats at every file it copies' {
        $zip = Join-Path $script:source 'driver.zip'
        Write-TestZip -Path $zip -Entry @{ 'a.inf' = 'a'; 'b.cat' = 'b' }
        $script:beats = 0
        Copy-DriverPackage -Path $zip -Destination $script:target -Beat { $script:beats++ } | Out-Null
        $script:beats | Should -Be 2
    }

    It 'refuses a zip with a file that would land outside its folder' {
        $zip = Join-Path $script:source 'evil.zip'
        Write-TestZip -Path $zip -Entry @{ '../escaped.txt' = 'x' }
        { Copy-DriverPackage -Path $zip -Destination $script:target -ErrorAction Stop } | Should -Throw '*outside its folder*'
        Test-Path -LiteralPath (Join-Path $TestDrive 'escaped.txt') | Should -BeFalse
    }

    It 'refuses a file that is neither a zip nor an INF' {
        $exe = Join-Path $script:source 'setup.exe'
        Set-Content -LiteralPath $exe -Value 'MZ'
        { Copy-DriverPackage -Path $exe -Destination $script:target -ErrorAction Stop } | Should -Throw '*a zip, or the INF*'
        @(Get-ChildItem -LiteralPath $script:target).Count | Should -Be 0
    }

    It 'refuses a package bigger than a driver package can be' {
        $zip = Join-Path $script:source 'big.zip'
        Write-TestZip -Path $zip -Entry @{ 'a.txt' = 'a'; 'b.txt' = 'b'; 'c.txt' = 'c' }
        Set-Content -LiteralPath (Join-Path $script:source 'big.bin') -Value ('x' * 200)
        InModuleScope FibocomFm350 { $script:DriverPackageLimits = @{ Files = 2; Bytes = 100 } }
        try {
            { Copy-DriverPackage -Path $zip -Destination $script:target -ErrorAction Stop } | Should -Throw '*more than 2 files*'
            { Copy-DriverPackage -Path $script:source -Destination $script:target -ErrorAction Stop } | Should -Throw '*more than 2 files*'
        }
        finally {
            InModuleScope FibocomFm350 { $script:DriverPackageLimits = @{ Files = 1000; Bytes = 64MB } }
        }
        @(Get-ChildItem -LiteralPath $script:target).Count | Should -Be 0
    }

    It 'gives a big folder up at its first file too many, without reading the rest' {
        foreach ($index in 1..6) {
            Set-Content -LiteralPath (Join-Path $script:source "file$index.txt") -Value 'x'
        }
        $script:beats = 0
        InModuleScope FibocomFm350 { $script:DriverPackageLimits = @{ Files = 2; Bytes = 64MB } }
        try {
            { Copy-DriverPackage -Path $script:source -Destination $script:target -Beat { $script:beats++ } -ErrorAction Stop } | Should -Throw '*more than 2 files*'
        }
        finally {
            InModuleScope FibocomFm350 { $script:DriverPackageLimits = @{ Files = 1000; Bytes = 64MB } }
        }
        $script:beats | Should -Be 3
    }

    It 'copies nothing with -WhatIf' {
        Set-Content -LiteralPath (Join-Path $script:source 'serial.inf') -Value 'inf'
        Copy-DriverPackage -Path $script:source -Destination $script:target -WhatIf | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:target).Count | Should -Be 0
    }
}

Describe 'New-DriverStagingFolder' {
    It 'creates a new empty folder under the root every time' {
        $first = New-DriverStagingFolder -Root (Join-Path $TestDrive 'staging')
        $second = New-DriverStagingFolder -Root (Join-Path $TestDrive 'staging')
        $first | Should -Not -Be $second
        Split-Path -Path $first -Parent | Should -Be (Join-Path $TestDrive 'staging')
        @(Get-ChildItem -LiteralPath $first).Count | Should -Be 0
    }

    It 'opens the folder to SYSTEM and administrators only, nothing inherited, with -AdminOnly' {
        $folder = New-DriverStagingFolder -Root $TestDrive -AdminOnly
        try {
            $acl = Get-Acl -LiteralPath $folder
            $acl.AreAccessRulesProtected | Should -BeTrue
            $rules = @($acl.Access | ForEach-Object { "$($_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value) $($_.AccessControlType) $($_.FileSystemRights)" } | Sort-Object)
            $rules | Should -Be @('S-1-5-18 Allow FullControl', 'S-1-5-32-544 Allow FullControl')
        }
        finally {
            # Its owner may open it again, to delete it: only its access list is written.
            $info = [System.IO.DirectoryInfo]::new($folder)
            $acl = [System.IO.FileSystemAclExtensions]::GetAccessControl($info, [System.Security.AccessControl.AccessControlSections]::Access)
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
            [System.IO.FileSystemAclExtensions]::SetAccessControl($info, $acl)
            Remove-Item -LiteralPath $folder -Recurse -Force
        }
    }

    It 'creates nothing with -WhatIf' {
        New-DriverStagingFolder -Root (Join-Path $TestDrive 'whatif') -WhatIf | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $TestDrive 'whatif') | Should -BeFalse
    }
}

Describe 'Remove-DriverStagingLeftover' {
    It 'deletes the copies its owners left, and nothing else' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $left = New-DriverStagingFolder -Root $root
        Set-Content -LiteralPath (Join-Path $left 'usb2ser_tm.inf') -Value 'inf'
        $other = New-Item -ItemType Directory -Path (Join-Path $root 'fm350-driver-mine') | ForEach-Object FullName
        $kept = New-Item -ItemType Directory -Path (Join-Path $root 'photos') | ForEach-Object FullName
        $owner = (Get-Acl -LiteralPath $left).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        Remove-DriverStagingLeftover -Root $root -Owner 'S-1-5-18' -Confirm:$false | Should -Be 0 -Because 'another owner''s folder is left alone'
        Test-Path -LiteralPath $left | Should -BeTrue
        Remove-DriverStagingLeftover -Root $root -Owner $owner -Confirm:$false | Should -Be 1
        Test-Path -LiteralPath $left | Should -BeFalse
        Test-Path -LiteralPath $other | Should -BeTrue -Because 'the name is not one the app gives'
        Test-Path -LiteralPath $kept | Should -BeTrue
    }

    It 'finds nothing in a folder it can''t read' {
        Remove-DriverStagingLeftover -Root (Join-Path $TestDrive 'nowhere') -Confirm:$false | Should -Be 0
    }
}

Describe 'Get-DriverPackageFact' {
    BeforeEach {
        $script:package = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:package 'driver/x64') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:package 'driver/serial.inf') -Value $script:inf
        Set-Content -LiteralPath (Join-Path $script:package 'driver/serial.cat') -Value 'not a signed message'
        Set-Content -LiteralPath (Join-Path $script:package 'driver/x64/serial.sys') -Value 'driver'
        Set-Content -LiteralPath (Join-Path $script:package 'readme.txt') -Value 'read me'
    }

    It 'reads the INF, the catalog beside it, the INF checked against it, and the files'' SHA-256' {
        $facts = @(Get-DriverPackageFact -Folder $script:package)
        $facts.Count | Should -Be 1
        $fact = $facts[0]
        $fact.Path | Should -Be 'driver/serial.inf'
        $fact.Inf.CatalogFile | Should -Be 'serial.cat'
        $fact.Inf.HardwareIds | Should -Contain 'USB\VID_0E8D&PID_7127&MI_06'
        $fact.Catalog | Should -BeTrue
        $fact.Signer | Should -BeNullOrEmpty
        $fact.CatalogCheck | Should -Not -Be 0
        @($fact.Files.Keys | Sort-Object) | Should -Be @('serial.cat', 'serial.inf', 'x64/serial.sys')
        $fact.Files['x64/serial.sys'] | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:package 'driver/x64/serial.sys') -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    It 'checks nothing against a catalog that is not there' {
        Remove-Item -LiteralPath (Join-Path $script:package 'driver/serial.cat')
        $fact = Get-DriverPackageFact -Folder $script:package
        $fact.Catalog | Should -BeFalse
        $fact.CatalogCheck | Should -BeNullOrEmpty
        $fact.Signer | Should -BeNullOrEmpty
    }

    It 'reads every INF, a UTF-16 one too' {
        New-Item -ItemType Directory -Path (Join-Path $script:package 'other') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:package 'other/other.inf') -Value @('[Version]', 'CatalogFile=other.cat') -Encoding Unicode
        $facts = @(Get-DriverPackageFact -Folder $script:package)
        $facts.Path | Should -Be @('driver/serial.inf', 'other/other.inf')
        $facts[1].Inf.CatalogFile | Should -Be 'other.cat'
    }

    It 'hashes each file once, however many INFs share it, and beats meanwhile' {
        New-Item -ItemType Directory -Path (Join-Path $script:package 'driver/more') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:package 'driver/more/more.inf') -Value '[Version]'
        Mock -ModuleName FibocomFm350 Get-FileHash { [pscustomobject]@{ Hash = 'AB' } }
        $script:beats = 0
        $facts = @(Get-DriverPackageFact -Folder $script:package -Beat { $script:beats++ })
        $facts.Count | Should -Be 2
        $facts.Path | Should -Be @('driver/more/more.inf', 'driver/serial.inf')
        @($facts[0].Files.Keys) | Should -Be @('more.inf')
        @($facts[1].Files.Keys | Sort-Object) | Should -Be @('more/more.inf', 'serial.cat', 'serial.inf', 'x64/serial.sys')
        Should -Invoke -ModuleName FibocomFm350 Get-FileHash -Times 5 -Exactly
        $script:beats | Should -Be 7 -Because 'one beat per file, and one per INF'
    }

    It 'finds nothing in a package without an INF' {
        Remove-Item -LiteralPath (Join-Path $script:package 'driver/serial.inf')
        Get-DriverPackageFact -Folder $script:package | Should -BeNullOrEmpty
    }
}

Describe 'Install-ModemDriver and Uninstall-ModemDriver' {
    BeforeEach {
        $script:exitCode = 0
        Mock -ModuleName FibocomFm350 Invoke-Pnputil { $script:exitCode }
    }

    It 'adds the package and installs it: pnputil /add-driver, the INF, /install, the heartbeat passed on' {
        $result = Install-ModemDriver -InfPath 'C:\Windows\Temp\fm350-driver-1\usb2ser_tm.inf' -Beat { } -Confirm:$false
        $result.Result | Should -Be 'Done'
        $result.ExitCode | Should -Be 0
        Should -Invoke -ModuleName FibocomFm350 Invoke-Pnputil -Times 1 -Exactly -ParameterFilter {
            ($Argument -join ' ') -eq '/add-driver C:\Windows\Temp\fm350-driver-1\usb2ser_tm.inf /install' -and $Beat -and $TimeoutMs -eq 300000
        }
    }

    It 'reads pnputil''s exit code <ExitCode> as <Add> when adding, <Delete> when deleting' -ForEach @(
        @{ ExitCode = 0; Add = 'Done'; Delete = 'Done' }
        @{ ExitCode = 3010; Add = 'RestartNeeded'; Delete = 'RestartNeeded' }
        @{ ExitCode = 259; Add = 'NoDevice'; Delete = 'Failed' }
        @{ ExitCode = 5; Add = 'Failed'; Delete = 'Failed' }
        @{ ExitCode = $null; Add = 'TimedOut'; Delete = 'TimedOut' }
    ) {
        $script:exitCode = $ExitCode
        (Install-ModemDriver -InfPath 'C:\x\a.inf' -Confirm:$false).Result | Should -Be $Add
        (Uninstall-ModemDriver -PublishedName 'oem24.inf' -Confirm:$false).Result | Should -Be $Delete
    }

    It 'uninstalls the package from its devices, then deletes it: pnputil /delete-driver oem#.inf /uninstall' {
        Uninstall-ModemDriver -PublishedName 'oem24.inf' -Confirm:$false | Out-Null
        Should -Invoke -ModuleName FibocomFm350 Invoke-Pnputil -Times 1 -Exactly -ParameterFilter { ($Argument -join ' ') -eq '/delete-driver oem24.inf /uninstall' }
    }

    It 'never deletes another package than an oem-numbered INF: <_>' -ForEach @('usb.inf', 'oem.inf', 'C:\Windows\INF\oem24.inf', 'oem24.inf /force', 'oem24.pnf') {
        { Uninstall-ModemDriver -PublishedName $_ -Confirm:$false -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName FibocomFm350 Invoke-Pnputil -Times 0 -Exactly
    }

    It 'installs nothing but an INF' {
        { Install-ModemDriver -InfPath 'C:\x\setup.exe' -Confirm:$false -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName FibocomFm350 Invoke-Pnputil -Times 0 -Exactly
    }

    It 'runs nothing with -WhatIf' {
        Install-ModemDriver -InfPath 'C:\x\a.inf' -WhatIf | Should -BeNullOrEmpty
        Uninstall-ModemDriver -PublishedName 'oem24.inf' -WhatIf | Should -BeNullOrEmpty
        Should -Invoke -ModuleName FibocomFm350 Invoke-Pnputil -Times 0 -Exactly
    }

    It 'restarts the USB device through the same pnputil: /restart-device' {
        $script:exitCode = 0
        (Restart-ModemUsbDevice -InstanceId 'USB\VID_0E8D&PID_7127\7&00000000&0&1' -Confirm:$false).Done | Should -BeTrue
        Should -Invoke -ModuleName FibocomFm350 Invoke-Pnputil -Times 1 -Exactly -ParameterFilter { ($Argument -join ' ') -eq '/restart-device USB\VID_0E8D&PID_7127\7&00000000&0&1' -and $TimeoutMs -eq 30000 }
        $script:exitCode = $null
        $restart = Restart-ModemUsbDevice -InstanceId 'USB\VID_0E8D&PID_7127\7&00000000&0&1' -Confirm:$false
        $restart.Done | Should -BeFalse
        $restart.ExitCode | Should -BeNullOrEmpty
    }
}

# Reads the driver store only: nothing is installed, nothing opened but files.
Describe 'The driver-store copy of the modem''s driver' -Tag Hardware -Skip:($script:driverStore.Count -eq 0) {
    BeforeAll {
        $script:copy = @(Get-ChildItem -Path "$env:SystemRoot\System32\DriverStore\FileRepository" -Directory -Filter 'usb2ser_tm.inf_*')[0].FullName
    }

    It 'is signed for WHQL, its catalog vouches for its INF, and it is meant for the modem''s AT port' {
        $facts = @(Get-DriverPackageFact -Folder $script:copy)
        $facts.Count | Should -Be 1
        $facts[0].Signer.Subject | Should -BeLike 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation*'
        $facts[0].CatalogCheck | Should -Be 0
        $verdict = Resolve-DriverPackage -Inf $facts -Known @(Get-KnownDriverPackage) -ProductId 7127
        $verdict.Verdict | Should -BeIn @('Verified', 'Signed')
        $verdict.Version | Should -Be '3.22.43.1'
        $facts[0].Files['usb2ser_tm.inf'] | Should -Be @(Get-KnownDriverPackage)[0].Files['usb2ser_tm.inf']
    }
}

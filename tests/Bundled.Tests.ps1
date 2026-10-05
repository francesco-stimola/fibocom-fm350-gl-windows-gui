# The programs the release zip bundles - lpac and ZXing.Net -, taken out of a zip this commit built
# (tools/New-ReleasePackage.ps1) and run here: lpac through the bridge against the simulated eUICC,
# ZXing.Net reading QR codes. They prove at every push what the zip will carry, not a stand-in.
# CI builds the zip before the tests and names it in FM350_PACKAGE; without it, these are skipped
# (docs/SETUP.md).

BeforeDiscovery {
    $script:bundled = [bool]($env:FM350_PACKAGE -and (Test-Path -LiteralPath $env:FM350_PACKAGE -PathType Leaf))
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force

    # The files of one of the zip's folders, out into -Destination; returns that folder.
    function Expand-BundledFolder {
        param([string] $Folder, [string] $Destination)
        $target = Join-Path $Destination $Folder
        [void](New-Item -ItemType Directory -Path $target -Force)
        $zip = [System.IO.Compression.ZipFile]::OpenRead($env:FM350_PACKAGE)
        try {
            foreach ($entry in @($zip.Entries | Where-Object { $_.FullName -match "^$Folder/[^/]+$" })) {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $target $entry.Name), $true)
            }
        }
        finally {
            $zip.Dispose()
        }
        $target
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'lpac, as the release zip bundles it' -Skip:(-not $script:bundled) {
    BeforeAll {
        # The build of the Windows the tests run on, as the app picks it.
        $architecture = Split-Path -Leaf (Split-Path -Parent (Get-LpacPath))
        $script:lpac = Join-Path (Expand-BundledFolder -Folder "lpac/$architecture" -Destination $TestDrive) 'lpac.exe'
        $script:testAid = 'A0000005591010FFFFFFFF8900002000'

        # The libraries a PE image imports by name, from its import directory (PE/COFF: data
        # directory 1; one 20-byte descriptor per library, its name's RVA 12 bytes in).
        function Get-PeImport {
            param([byte[]] $Image)
            $pe = [BitConverter]::ToInt32($Image, 0x3C)
            $sections = [BitConverter]::ToUInt16($Image, $pe + 6)
            $optional = $pe + 24
            $table = $optional + [BitConverter]::ToUInt16($Image, $pe + 20)
            $directories = if ([BitConverter]::ToUInt16($Image, $optional) -eq 0x20B) { $optional + 112 } else { $optional + 96 }
            $offset = {
                param([uint32] $Rva)
                for ($i = 0; $i -lt $sections; $i++) {
                    $section = $table + 40 * $i
                    $start = [BitConverter]::ToUInt32($Image, $section + 12)
                    $size = [Math]::Max([BitConverter]::ToUInt32($Image, $section + 8), [BitConverter]::ToUInt32($Image, $section + 16))
                    if ($Rva -ge $start -and $Rva -lt $start + $size) {
                        return [int]($Rva - $start + [BitConverter]::ToUInt32($Image, $section + 20))
                    }
                }
                throw "RVA $Rva is in no section"
            }
            $descriptor = & $offset ([BitConverter]::ToUInt32($Image, $directories + 8))
            while (($name = [BitConverter]::ToUInt32($Image, $descriptor + 12)) -ne 0) {
                $start = & $offset $name
                [System.Text.Encoding]::ASCII.GetString($Image, $start, [Array]::IndexOf($Image, [byte]0, $start) - $start)
                $descriptor += 20
            }
        }

        # Runs the bundled lpac for one operation on the simulated eUICC; nothing may reach the
        # network.
        function Invoke-BundledLpac {
            param([string] $Operation, [hashtable] $Option = @{})
            $http = { throw "lpac asked for the network: $($args[0].Url)" }
            Invoke-LpacOperation -Channel $script:channel -Lpac (Start-LpacProcess -Path $script:lpac -Argument (Get-LpacArgument -Operation $Operation @Option)) -TimeoutMs 60000 -Http $http
        }
    }

    It 'carries a native build for x64 and one for Arm64, importing nothing but Windows'' own libraries' -ForEach @(
        @{ Architecture = 'x64'; Machine = 0x8664 }
        @{ Architecture = 'arm64'; Machine = 0xAA64 }
    ) {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($env:FM350_PACKAGE)
        try {
            $stream = $zip.GetEntry("lpac/$Architecture/lpac.exe").Open()
            $bytes = [System.IO.MemoryStream]::new()
            $stream.CopyTo($bytes)
            $stream.Dispose()
            $image = $bytes.ToArray()
        }
        finally {
            $zip.Dispose()
        }
        # The PE header's machine: where the header is, at 0x3C; the machine 4 bytes in.
        [BitConverter]::ToUInt16($image, [BitConverter]::ToInt32($image, 0x3C) + 4) | Should -Be $Machine
        # Not libcurl.dll, which the zip leaves out: the Arm64 build can't be run here to prove it.
        $imports = @(Get-PeImport -Image $image)
        $imports | Should -Not -BeNullOrEmpty
        $imports | Should -Not -Contain 'libcurl.dll'
        foreach ($library in $imports) {
            Join-Path ([Environment]::SystemDirectory) $library | Should -Exist -Because "$library is part of Windows"
        }
    }

    BeforeEach {
        $script:device = New-SimulatedDevice -Scenario EsimEmpty
        $script:device.Modem.Euicc.ResetMs = 0
        $script:channel = New-AtChannel -Transport $script:device.Open()
        [void](Initialize-AtChannel -Channel $script:channel -TimeoutMs 2000)
    }

    AfterEach {
        Close-AtChannel -Channel $script:channel
    }

    It 'enables a profile, the SIM reset after it' {
        $run = Invoke-BundledLpac -Operation EnableProfile -Option @{ ProfileId = $script:testAid }
        $run.Outcome | Should -Be 'Done'
        $run.Code | Should -Be 0
        $script:device.Modem.Euicc.Profiles[0].State | Should -Be 'Enabled'
        @($script:device.Modem.Received | Where-Object { $_ -like 'AT+CGLA=*BF31*' }).Count | Should -Be 1
    }

    It 'disables it again' {
        $script:device.Modem.Euicc.Profiles[0].State = 'Enabled'
        $run = Invoke-BundledLpac -Operation DisableProfile -Option @{ ProfileId = $script:testAid }
        $run.Outcome | Should -Be 'Done'
        $run.Code | Should -Be 0
        $script:device.Modem.Euicc.Profiles[0].State | Should -Be 'Disabled'
    }

    It 'says what the eUICC refused' {
        $run = Invoke-BundledLpac -Operation DisableProfile -Option @{ ProfileId = $script:testAid }
        $run.Outcome | Should -Be 'Done'
        $run.Code | Should -Not -Be 0
        $script:device.Modem.Euicc.Profiles[0].State | Should -Be 'Disabled'
    }

    It 'sets a nickname of letters beyond ASCII, and clears it' {
        $iccid = $script:device.Modem.Euicc.Profiles[0].Iccid
        (Invoke-BundledLpac -Operation SetNickname -Option @{ ProfileId = $iccid; Nickname = 'Prova è' }).Code | Should -Be 0
        $script:device.Modem.Euicc.Profiles[0].Nickname | Should -BeExactly 'Prova è'
        (Invoke-BundledLpac -Operation SetNickname -Option @{ ProfileId = $iccid; Nickname = '' }).Code | Should -Be 0
        $script:device.Modem.Euicc.Profiles[0].Nickname | Should -BeNullOrEmpty
    }

    It 'deletes a profile' {
        $run = Invoke-BundledLpac -Operation DeleteProfile -Option @{ ProfileId = $script:testAid }
        $run.Outcome | Should -Be 'Done'
        $run.Code | Should -Be 0
        $script:device.Modem.Euicc.Profiles.Count | Should -Be 0
    }

    It 'leaves no logical channel open' {
        [void](Invoke-BundledLpac -Operation EnableProfile -Option @{ ProfileId = $script:testAid })
        $opened = @($script:device.Modem.Received | Where-Object { $_ -like 'AT+CCHO=*' }).Count
        $opened | Should -BeGreaterThan 0
        # The eUICC's reset closed the channel its switch was carried on: nothing to close after it.
        $script:device.Modem.Euicc.Sessions.Count | Should -Be 0
    }
}

Describe 'ZXing.Net, as the release zip bundles it' -Skip:(-not $script:bundled) {
    BeforeAll {
        # A library loaded stays loaded, its file held, until the process ends: it goes in a folder
        # of its own outside TestDrive, named by its hash, the same one at every run.
        $folder = Expand-BundledFolder -Folder 'zxing' -Destination $TestDrive
        $hash = (Get-FileHash -LiteralPath (Join-Path $folder 'zxing.dll') -Algorithm SHA256).Hash.Substring(0, 16)
        $kept = Join-Path ([System.IO.Path]::GetTempPath()) "fibocom-fm350-tests\zxing-$hash"
        $script:library = Join-Path $kept 'zxing.dll'
        if (-not (Test-Path -LiteralPath $script:library)) {
            [void](New-Item -ItemType Directory -Path $kept -Force)
            Copy-Item -LiteralPath (Join-Path $folder 'zxing.dll') -Destination $script:library
        }
        Add-Type -LiteralPath $script:library
        Add-Type -AssemblyName System.Drawing

        # An image -Width x -Height, white, with the QR code of -Text drawn -Module pixels a module
        # at -Left, -Top; saved as -Format.
        function Get-QrImage {
            param([string] $Text, [int] $Width = 600, [int] $Height = 600, [int] $Module = 6, [int] $Left = 40, [int] $Top = 40,
                [string] $Format = 'Png', [string] $Name = 'qr.png')
            $bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.Clear([System.Drawing.Color]::White)
                    if ($Text) {
                        $matrix = [ZXing.QrCode.QRCodeWriter]::new().encode($Text, [ZXing.BarcodeFormat]::QR_CODE, 0, 0)
                        for ($y = 0; $y -lt $matrix.Height; $y++) {
                            for ($x = 0; $x -lt $matrix.Width; $x++) {
                                if ($matrix[$x, $y]) {
                                    $graphics.FillRectangle([System.Drawing.Brushes]::Black, $Left + $x * $Module, $Top + $y * $Module, $Module, $Module)
                                }
                            }
                        }
                    }
                }
                finally {
                    $graphics.Dispose()
                }
                $path = Join-Path $TestDrive $Name
                $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::$Format)
                $path
            }
            finally {
                $bitmap.Dispose()
            }
        }
    }

    It 'reads the code of <Name>' -ForEach @(
        @{ Name = 'a PNG'; Image = @{ Format = 'Png'; Name = 'code.png' } }
        @{ Name = 'a JPEG'; Image = @{ Format = 'Jpeg'; Name = 'code.jpg' } }
        @{ Name = 'a large photo, read scaled down'; Image = @{ Width = 4000; Height = 3000; Module = 12; Left = 1500; Top = 900; Format = 'Jpeg'; Name = 'photo.jpg' } }
        @{ Name = 'a small code in a corner'; Image = @{ Width = 1200; Height = 900; Module = 4; Left = 20; Top = 700; Format = 'Png'; Name = 'corner.png' } }
    ) {
        $text = 'LPA:1$smdp.example.com$TEST-0000-0000'
        $read = Read-QrCode -Path (Get-QrImage -Text $text @Image) -LibraryPath $script:library
        $read.Problem | Should -BeNullOrEmpty
        $read.Text | Should -BeExactly $text
    }

    It 'finds no code in an image without one' {
        $read = Read-QrCode -Path (Get-QrImage -Text '' -Name 'blank.png') -LibraryPath $script:library
        $read.Problem | Should -Be 'NoCode'
        $read.Text | Should -BeNullOrEmpty
    }

    It 'lets the worker download from the image of a code, which no log line and no snapshot carries' {
        $folder = Join-Path $TestDrive 'worker'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $device = New-SimulatedDevice -Scenario Esim
        $device.Modem.Euicc.ResetMs = 0
        $link = New-ModemWorkerLink
        $worker = New-ModemWorker -Link $link -Simulation $device -DataFolder $folder
        try {
            for ($i = 0; $i -lt 3; $i++) { Invoke-ModemWorkerCycle -Worker $worker }
            $image = Get-QrImage -Text 'LPA:1$smdp.example.com$SECRET-MATCH-2' -Name 'download.png'
            $id = Send-ModemCommand -Link $link -Kind DownloadProfile -Parameter @{ QrImage = $image }
            Invoke-ModemWorkerCycle -Worker $worker
            ($link['Snapshot'].Results | Where-Object Id -EQ $id).Result | Should -Be 'Done'
            @($link['Snapshot'].Esim.Profiles).Count | Should -Be 3
            $link['Snapshot'] | ConvertTo-Json -Depth 8 | Should -Not -Match 'SECRET-MATCH'
        }
        finally {
            Close-ModemWorker -Worker $worker
        }
        Get-ChildItem -Path (Join-Path $folder 'logs') -Filter '*.log' | Get-Content -Raw | Should -Not -Match 'SECRET-MATCH'
    }
}

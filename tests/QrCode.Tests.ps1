# A QR code read from an image: where ZXing.Net is, the size an image is read at, and what is
# refused before the library is needed. Reading a real code needs the library the release zip
# bundles: tests/Bundled.Tests.ps1.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    Add-Type -AssemblyName System.Drawing

    # A white PNG of this size.
    function Get-TestImage {
        param([string] $Name, [int] $Width = 300, [int] $Height = 200)
        $path = Join-Path $TestDrive $Name
        $bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try { $graphics.Clear([System.Drawing.Color]::White) } finally { $graphics.Dispose() }
            $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $bitmap.Dispose()
        }
        $path
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Get-ZxingPath' {
    It 'names zxing.dll in the zxing folder beside the modules' {
        $expected = Join-Path -Path (Resolve-Path "$PSScriptRoot/../src").Path -ChildPath 'zxing\zxing.dll'
        Get-ZxingPath | Should -Be $expected
    }
}

Describe 'Get-QrImageSize' {
    It '<Width> x <Height> is read at <ReadWidth> x <ReadHeight>' -ForEach @(
        @{ Width = 300; Height = 200; ReadWidth = 300; ReadHeight = 200 }
        @{ Width = 2000; Height = 2000; ReadWidth = 2000; ReadHeight = 2000 }
        @{ Width = 4000; Height = 3000; ReadWidth = 2000; ReadHeight = 1500 }
        @{ Width = 3000; Height = 4000; ReadWidth = 1500; ReadHeight = 2000 }
        @{ Width = 8000; Height = 6000; ReadWidth = 2000; ReadHeight = 1500 }
        @{ Width = 10000; Height = 1; ReadWidth = 2000; ReadHeight = 1 }
    ) {
        $size = InModuleScope FibocomFm350 -Parameters @{ W = $Width; H = $Height } { param($W, $H) Get-QrImageSize -Width $W -Height $H }
        $size.Width | Should -Be $ReadWidth
        $size.Height | Should -Be $ReadHeight
    }
}

Describe 'Read-QrCode, before the library' {
    It 'refuses <Name> as not an image' -ForEach @(
        @{ Name = 'a file that isn''t there'; Make = { Join-Path $TestDrive 'missing.png' } }
        @{ Name = 'a folder'; Make = { (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'folder.png') -Force).FullName } }
        @{ Name = 'a text file'; Make = { $path = Join-Path $TestDrive 'text.png'; Set-Content -LiteralPath $path -Value 'LPA:1$smdp.example.com$ABC'; $path } }
        @{ Name = 'an empty file'; Make = { $path = Join-Path $TestDrive 'empty.png'; [System.IO.File]::WriteAllBytes($path, [byte[]]@()); $path } }
    ) {
        $read = Read-QrCode -Path (& $Make) -LibraryPath (Join-Path $TestDrive 'no-zxing.dll')
        $read.Problem | Should -Be 'NotImage'
        $read.Text | Should -BeNullOrEmpty
    }

    It 'refuses a file larger than its limit, unread' {
        $path = Get-TestImage -Name 'large.png'
        InModuleScope FibocomFm350 { $script:QrMaxFileBytes = 100 }
        try {
            (Read-QrCode -Path $path -LibraryPath (Join-Path $TestDrive 'no-zxing.dll')).Problem | Should -Be 'TooLarge'
        }
        finally {
            InModuleScope FibocomFm350 { $script:QrMaxFileBytes = 20MB }
        }
    }

    It 'refuses an image of more pixels than its limit' {
        $path = Get-TestImage -Name 'pixels.png' -Width 300 -Height 200
        InModuleScope FibocomFm350 { $script:QrMaxPixels = 59999 }
        try {
            (Read-QrCode -Path $path -LibraryPath (Join-Path $TestDrive 'no-zxing.dll')).Problem | Should -Be 'TooLarge'
        }
        finally {
            InModuleScope FibocomFm350 { $script:QrMaxPixels = 50000000 }
        }
    }

    It 'says <Name>' -ForEach @(
        @{ Name = 'the library is missing'; Library = $null }
        @{ Name = 'the library is not one'; Library = 'not a library' }
    ) {
        $library = Join-Path $TestDrive "zxing-$([guid]::NewGuid().ToString('N')).dll"
        if ($Library) {
            Set-Content -LiteralPath $library -Value $Library
        }
        $image = Get-TestImage -Name 'white.png'
        # In a process of its own: a library once loaded stays loaded, and the bundled tests load it.
        $module = (Resolve-Path "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1").Path
        $read = Start-Job -ScriptBlock {
            Import-Module $using:module
            Read-QrCode -Path $using:image -LibraryPath $using:library | ConvertTo-Json -Compress
        } | Receive-Job -Wait -AutoRemoveJob | ConvertFrom-Json
        $read.Problem | Should -Be 'NoLibrary'
        $read.Text | Should -BeNullOrEmpty
    }

    It 'leaves the image it read free to delete' {
        $path = Get-TestImage -Name 'free.png'
        [void](Read-QrCode -Path $path -LibraryPath (Join-Path $TestDrive 'no-zxing.dll'))
        Remove-Item -LiteralPath $path -ErrorAction Stop
        $path | Should -Not -Exist
    }
}

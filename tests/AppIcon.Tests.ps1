# The app's own icon: the logo's glyph drawn where logo.html puts it - the arrow open where its head
# is, the bars rising, the last one lighter -, an icon file Windows reads with every size, and the
# window that shows it.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/App/FibocomFm350.App.psd1" -Force
    $script:app = Get-Module FibocomFm350.App

    # The color of the pixel at the point (X, Y) of logo.html's 176-unit square, drawn at 256.
    function Get-LogoPixel {
        param([double] $X, [double] $Y)
        $bitmap = & $script:app { New-AppIconBitmap -Size 256 }
        try {
            $bitmap.GetPixel([int]($X * 256 / 176), [int]($Y * 256 / 176))
        }
        finally {
            $bitmap.Dispose()
        }
    }
}

AfterAll {
    Remove-Module FibocomFm350.App, FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'The logo''s glyph' {
    It 'draws <Name>' -ForEach @(
        @{ Name = 'the first bar in the accent'; X = 58; Y = 116; Color = '#0C8F80' }
        @{ Name = 'the third bar in the accent'; X = 102; Y = 100; Color = '#0C8F80' }
        @{ Name = 'the last bar lighter'; X = 124; Y = 93; Color = '#33C2AD' }
        @{ Name = 'the arrow at six o''clock'; X = 88; Y = 150; Color = '#33C2AD' }
        @{ Name = 'the arrow at nine o''clock'; X = 26; Y = 88; Color = '#33C2AD' }
        @{ Name = 'the arrow''s head'; X = 133; Y = 34; Color = '#33C2AD' }
        @{ Name = 'nothing above the first bar'; X = 58; Y = 96; Color = $null }
        @{ Name = 'nothing in the arrow''s opening'; X = 145; Y = 64; Color = $null }
        @{ Name = 'nothing in a corner'; X = 4; Y = 4; Color = $null }
    ) {
        $pixel = Get-LogoPixel -X $X -Y $Y
        if ($Color) {
            $pixel.A | Should -Be 255
            ('#{0:X2}{1:X2}{2:X2}' -f $pixel.R, $pixel.G, $pixel.B) | Should -Be $Color
        }
        else {
            $pixel.A | Should -Be 0 -Because 'the background is transparent'
        }
    }
}

Describe 'Export-AppIcon' {
    It 'writes an icon file Windows reads, one PNG image per size' {
        $path = Join-Path $TestDrive 'app.ico'
        Export-AppIcon -Path $path -Confirm:$false
        $bytes = [System.IO.File]::ReadAllBytes($path)
        [System.BitConverter]::ToUInt16($bytes, 0) | Should -Be 0
        [System.BitConverter]::ToUInt16($bytes, 2) | Should -Be 1
        $count = [System.BitConverter]::ToUInt16($bytes, 4)
        $sizes = for ($i = 0; $i -lt $count; $i++) {
            $entry = 6 + 16 * $i
            $side = $bytes[$entry]
            $length = [System.BitConverter]::ToUInt32($bytes, $entry + 8)
            $offset = [System.BitConverter]::ToUInt32($bytes, $entry + 12)
            [System.BitConverter]::ToString($bytes, $offset, 4) | Should -Be '89-50-4E-47' -Because 'each image is a PNG'
            ($offset + $length) | Should -BeLessOrEqual $bytes.Length
            if ($side -eq 0) { 256 } else { [int]$side }
        }
        $sizes | Should -Be @(16, 20, 24, 32, 40, 48, 64, 256)
        $icon = [System.Drawing.Icon]::new($path, 32, 32)
        try {
            $icon.Width | Should -Be 32
        }
        finally {
            $icon.Dispose()
        }
    }

    It 'writes nothing under -WhatIf' {
        $path = Join-Path $TestDrive 'whatif.ico'
        Export-AppIcon -Path $path -WhatIf
        Test-Path $path | Should -BeFalse
    }
}

Describe 'The window''s icon' {
    It 'holds every size, for WPF to pick the title bar''s and the taskbar''s' {
        $image = & $script:app { New-AppIconImage }
        $image.Decoder.Frames.Count | Should -Be 8
        @($image.Decoder.Frames | ForEach-Object PixelWidth) | Should -Be @(16, 20, 24, 32, 40, 48, 64, 256)
    }
}

Describe 'The taskbar identity' {
    It 'gives a window the app''s AppUserModelID, and takes it off again' {
        $window = [System.Windows.Window]::new()
        try {
            $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).EnsureHandle()
            & $script:app { param($w) Set-AppWindowIdentity -Window $w -Id 'FibocomFm350Gl.WindowsGui.Test' } $window
            [FibocomFm350.AppIdentity]::GetWindowId($handle) | Should -Be 'FibocomFm350Gl.WindowsGui.Test'
            & $script:app { param($w) Set-AppWindowIdentity -Window $w -Remove } $window
            [FibocomFm350.AppIdentity]::GetWindowId($handle) | Should -BeNullOrEmpty
        }
        finally {
            $window.Close()
        }
    }

    It 'gives the shortcut the same, and keeps what it runs' {
        $path = Join-Path $TestDrive 'app.lnk'
        $target = Join-Path ([Environment]::GetFolderPath('System')) 'schtasks.exe'
        $shell = New-Object -ComObject 'WScript.Shell'
        try {
            $link = $shell.CreateShortcut($path)
            $link.TargetPath = $target
            $link.Save()
            Set-AppShortcutIdentity -Path $path -WhatIf
            [FibocomFm350.AppIdentity]::GetShortcutId($path) | Should -BeNullOrEmpty -Because '-WhatIf changes nothing'
            Set-AppShortcutIdentity -Path $path -Confirm:$false
            [FibocomFm350.AppIdentity]::GetShortcutId($path) | Should -Be 'FibocomFm350Gl.WindowsGui'
            $shell.CreateShortcut($path).TargetPath | Should -Be $target
        }
        finally {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
}

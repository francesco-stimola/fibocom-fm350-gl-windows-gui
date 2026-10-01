# The tray icon: drawn at every size, redrawn only when what it shows changes, and every handle
# destroyed - hundreds of redraws leave the process's GDI and USER object counts where they were
# (ARCHITECTURE -> Invariants, 5).

BeforeAll {
    Import-Module "$PSScriptRoot/../src/App/FibocomFm350.App.psd1" -Force

    function Get-TestIcon {
        param([string] $Tone = 'Online', $Bars = 3, $Label = '5G')
        [pscustomobject]@{ Tone = $Tone; Bars = $Bars; Label = $Label }
    }

    # The pixels of an icon handle, as text: two icons look the same when this is equal.
    function Get-IconPixel {
        param([System.IntPtr] $Handle)
        $bitmap = [System.Drawing.Icon]::FromHandle($Handle).ToBitmap()
        try {
            $stream = [System.IO.MemoryStream]::new()
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            [Convert]::ToBase64String($stream.ToArray())
        }
        finally {
            $bitmap.Dispose()
        }
    }
}

AfterAll {
    Remove-Module FibocomFm350.App, FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'New-TrayIconHandle' {
    It 'draws at <_> pixels' -ForEach @(16, 20, 24, 32, 48) {
        $handle = New-TrayIconHandle -Icon (Get-TestIcon) -Size $_
        try {
            $handle | Should -Not -Be ([System.IntPtr]::Zero)
            [System.Drawing.Icon]::FromHandle($handle).Width | Should -Be $_
        }
        finally {
            Remove-TrayIconHandle -Handle $handle
        }
    }

    It 'draws the technology label only where it is legible' {
        $handles = @(
            New-TrayIconHandle -Icon (Get-TestIcon -Label '5G') -Size 16
            New-TrayIconHandle -Icon (Get-TestIcon -Label $null) -Size 16
            New-TrayIconHandle -Icon (Get-TestIcon -Label '5G') -Size 32
            New-TrayIconHandle -Icon (Get-TestIcon -Label $null) -Size 32
        )
        try {
            Get-IconPixel $handles[0] | Should -Be (Get-IconPixel $handles[1]) -Because 'at 16 pixels the label would be a smudge'
            Get-IconPixel $handles[2] | Should -Not -Be (Get-IconPixel $handles[3])
        }
        finally {
            $handles | ForEach-Object { Remove-TrayIconHandle -Handle $_ }
        }
    }

    It 'shows the bars and the tone' {
        $handles = @(
            New-TrayIconHandle -Icon (Get-TestIcon -Bars 1) -Size 16
            New-TrayIconHandle -Icon (Get-TestIcon -Bars 4) -Size 16
            New-TrayIconHandle -Icon (Get-TestIcon -Tone Attention -Bars 4) -Size 16
            New-TrayIconHandle -Icon (Get-TestIcon -Bars $null) -Size 16
            New-TrayIconHandle -Icon (Get-TestIcon -Bars 0) -Size 16
        )
        try {
            Get-IconPixel $handles[0] | Should -Not -Be (Get-IconPixel $handles[1])
            Get-IconPixel $handles[1] | Should -Not -Be (Get-IconPixel $handles[2])
            Get-IconPixel $handles[3] | Should -Be (Get-IconPixel $handles[4]) -Because 'nothing measured draws every bar empty'
        }
        finally {
            $handles | ForEach-Object { Remove-TrayIconHandle -Handle $_ }
        }
    }
}

Describe 'Set-TrayIcon' {
    BeforeEach {
        $script:notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
        $script:state = @{}
    }

    AfterEach {
        if ($script:state['Handle']) {
            Remove-TrayIconHandle -Handle $script:state['Handle']
        }
        $script:notifyIcon.Dispose()
    }

    It 'redraws only when the tone, the bars or the label change' {
        Set-TrayIcon -NotifyIcon $script:notifyIcon -Icon (Get-TestIcon) -State $script:state | Should -BeTrue
        $first = $script:state['Handle']
        Set-TrayIcon -NotifyIcon $script:notifyIcon -Icon (Get-TestIcon) -State $script:state | Should -BeFalse
        $script:state['Handle'] | Should -Be $first
        Set-TrayIcon -NotifyIcon $script:notifyIcon -Icon (Get-TestIcon -Bars 4) -State $script:state | Should -BeTrue
        Set-TrayIcon -NotifyIcon $script:notifyIcon -Icon (Get-TestIcon -Bars 4 -Label '4G') -State $script:state | Should -BeTrue
        Set-TrayIcon -NotifyIcon $script:notifyIcon -Icon (Get-TestIcon -Tone Working -Bars 4 -Label '4G') -State $script:state | Should -BeTrue
    }

    It 'destroys the previous handle once the new icon is set' {
        [void](Set-TrayIcon -NotifyIcon $script:notifyIcon -Icon (Get-TestIcon -Bars 1) -State $script:state)
        $previous = $script:state['Handle']
        [void](Set-TrayIcon -NotifyIcon $script:notifyIcon -Icon (Get-TestIcon -Bars 2) -State $script:state)
        $script:notifyIcon.Icon.Handle | Should -Be $script:state['Handle']
        [FibocomFm350.NativeMethods]::DestroyIcon($previous) | Should -BeFalse -Because 'it was destroyed already'
    }

    It 'leaks no GDI or USER object over hundreds of redraws' {
        $models = foreach ($i in 0..299) {
            Get-TestIcon -Tone @('Online', 'Working', 'Attention')[$i % 3] -Bars ($i % 5) -Label @('5G', '4G', $null)[$i % 3]
        }
        # A first round settles what drawing allocates once (fonts, the icon's own window).
        foreach ($model in $models[0..29]) {
            [void](Set-TrayIcon -NotifyIcon $script:notifyIcon -Icon $model -State $script:state -Size 32)
        }
        $before = Get-GuiResourceCount
        foreach ($model in $models) {
            [void](Set-TrayIcon -NotifyIcon $script:notifyIcon -Icon $model -State $script:state -Size 32)
        }
        $after = Get-GuiResourceCount
        ($after.Gdi - $before.Gdi) | Should -BeLessOrEqual 2
        ($after.User - $before.User) | Should -BeLessOrEqual 2
    }

    It 'changes nothing under -WhatIf' {
        Set-TrayIcon -NotifyIcon $script:notifyIcon -Icon (Get-TestIcon) -State $script:state -WhatIf | Should -BeFalse
        $script:state['Handle'] | Should -BeNullOrEmpty
    }
}

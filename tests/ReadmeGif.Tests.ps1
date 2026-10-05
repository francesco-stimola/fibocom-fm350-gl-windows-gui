# The README's GIF (tools/New-ReadmeGif.ps1): made from the main window in development mode, a frame
# a tab; and the one committed still has a frame for each tab of the window, so that a tab added or
# taken away shows here first.

BeforeAll {
    # A GIF read block by block (GIF89a): whether it loops, and each frame's delay in hundredths of
    # a second (null without a graphic control extension).
    function Read-Gif {
        param([byte[]] $Gif)
        $frames = [System.Collections.Generic.List[object]]::new()
        $loops = $false
        $delay = $null
        $packed = $Gif[10]
        $at = 13 + $(if ($packed -band 0x80) { 3 * [Math]::Pow(2, ($packed -band 7) + 1) } else { 0 })
        $skip = {
            param([int] $From)
            while ($Gif[$From] -ne 0) {
                $From += $Gif[$From] + 1
            }
            $From + 1
        }
        while ($at -lt $Gif.Length -and $Gif[$at] -ne 0x3B) {
            if ($Gif[$at] -eq 0x21) {
                if ($Gif[$at + 1] -eq 0xF9) {
                    $delay = $Gif[$at + 4] + 256 * $Gif[$at + 5]
                }
                elseif ($Gif[$at + 1] -eq 0xFF -and [System.Text.Encoding]::ASCII.GetString($Gif, $at + 3, 11) -eq 'NETSCAPE2.0') {
                    $loops = $true
                }
                $at = & $skip ($at + 2)
                continue
            }
            if ($Gif[$at] -ne 0x2C) {
                throw "Unexpected block at $at"
            }
            $frames.Add([pscustomobject]@{ Delay = $delay })
            $delay = $null
            $flags = $Gif[$at + 9]
            $at += 10 + $(if ($flags -band 0x80) { 3 * [Math]::Pow(2, ($flags -band 7) + 1) } else { 0 })
            $at = & $skip ($at + 1)
        }
        [pscustomobject]@{
            Signature = [System.Text.Encoding]::ASCII.GetString($Gif, 0, 6)
            Width     = $Gif[6] + 256 * $Gif[7]
            Loops     = $loops
            Frames    = $frames.ToArray()
        }
    }

    $xaml = [xml](Get-Content -LiteralPath "$PSScriptRoot/../src/App/MainWindow.xaml" -Raw)
    $script:tabs = @($xaml.SelectNodes('//*[local-name()="TabItem"]')).Count
}

Describe 'The README''s GIF' {
    It 'is made from the main window: a frame a tab, two seconds each, looping, under 500 KB' {
        $path = Join-Path $TestDrive 'window.gif'
        # A process of its own: the script sets the app's language, which the other tests leave alone.
        & (Get-Process -Id $PID).Path -NoProfile -File "$PSScriptRoot/../tools/New-ReadmeGif.ps1" -OutputPath $path | Out-Null
        $LASTEXITCODE | Should -Be 0
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $gif = Read-Gif -Gif $bytes
        $gif.Signature | Should -Be 'GIF89a'
        $gif.Loops | Should -BeTrue
        $gif.Frames.Count | Should -Be $script:tabs
        $gif.Frames.Delay | Should -Be (@(200) * $script:tabs)
        $gif.Width | Should -BeGreaterThan 600
        $bytes.Length | Should -BeLessThan 500KB
    }

    It 'is committed with a frame for each tab of the window' {
        $gif = Read-Gif -Gif ([System.IO.File]::ReadAllBytes("$PSScriptRoot/../assets/window.gif"))
        $gif.Frames.Count | Should -Be $script:tabs -Because 'the window''s tabs changed: make the GIF again (docs/SETUP.md -> Releasing)'
    }
}

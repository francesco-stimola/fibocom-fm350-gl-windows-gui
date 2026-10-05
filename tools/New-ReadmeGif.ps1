#Requires -Version 7.6
<#
.SYNOPSIS
    Makes the README's animated GIF of the main window, tab by tab.
.DESCRIPTION
    The app's own window (New-MainWindow), shown off screen, given the view of the simulated modem
    in the Online scenario after a few worker cycles - made-up data only -, in English. What would
    change from one run to the next without the window changing is fixed: the footer's time, and
    no app version (decided 2026-10-05), no development-mode note, no "not elevated" note, the AT
    port named as on a real modem. Each tab
    is rendered as it is (RenderTargetBitmap), reduced to its own 256-colour palette, and the frames
    written as a GIF that loops, -FrameMs each (GifBitmapEncoder, then the loop and the delays
    written into the file: the encoder writes neither).

    Run it after a change to the window, and before a release (docs/SETUP.md -> Releasing); commit
    the GIF it writes. Windows only; WPF needs a single-threaded apartment, which pwsh gives.

    Returns Path, Frames and Bytes.
.EXAMPLE
    pwsh -NoProfile -File tools/New-ReadmeGif.ps1
#>
[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'assets/window.gif'),

    [ValidateRange(500, 10000)]
    [int] $FrameMs = 2000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'WPF needs a single-threaded apartment: run this with pwsh -STA.'
}
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path -Path $root -ChildPath 'src/FibocomFm350/FibocomFm350.psd1') -Force
Import-Module (Join-Path -Path $root -ChildPath 'src/App/FibocomFm350.App.psd1') -Force

function Get-ReadmeView {
    # The window's view of the simulated modem, online, with what varies between runs fixed.
    $data = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "fm350-readme-gif-$PID"
    $link = New-ModemWorkerLink
    $worker = New-ModemWorker -Link $link -Simulation (New-SimulatedDevice -Scenario Online) -DataFolder $data
    try {
        for ($cycle = 0; $cycle -lt 3; $cycle++) {
            Invoke-ModemWorkerCycle -Worker $worker
        }
        $snapshot = $link['Snapshot']
        $snapshot.Time = [DateTimeOffset]::new(2026, 1, 1, 12, 0, 0, [TimeSpan]::Zero)
        $snapshot.Simulated = $false
        $snapshot.Elevated = $true
        # The AT port as on a real modem, not the simulated one's name.
        $snapshot.PortName = 'WinUSB'
        if ($snapshot.PSObject.Properties['AppVersion']) {
            $snapshot.AppVersion = $null
        }
        ConvertTo-WindowView -Snapshot $snapshot
    }
    finally {
        Close-ModemWorker -Worker $worker
        Close-ModemWorkerLink -Link $link
        Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Wait-WindowIdle {
    # Lets WPF lay out and draw what is pending.
    param([System.Windows.Window] $Window)
    $Window.UpdateLayout()
    [void]$Window.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
}

function Get-WindowFrame {
    # The window's content as it is drawn, reduced to its own 256-colour palette.
    param([System.Windows.Window] $Window)
    $content = $Window.Content
    # Drawn where it lies in the window: its margin around it, as on screen.
    $margin = $content.Margin
    $width = [int][Math]::Ceiling($content.ActualWidth + $margin.Left + $margin.Right)
    $height = [int][Math]::Ceiling($content.ActualHeight + $margin.Top + $margin.Bottom)
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    # A white page under the content, as the window's own background is.
    $visual = [System.Windows.Media.DrawingVisual]::new()
    $context = $visual.RenderOpen()
    $context.DrawRectangle([System.Windows.Media.Brushes]::White, $null, [System.Windows.Rect]::new(0, 0, $width, $height))
    $context.Close()
    $bitmap.Render($visual)
    $bitmap.Render($content)
    $palette = [System.Windows.Media.Imaging.BitmapPalette]::new($bitmap, 256)
    $indexed = [System.Windows.Media.Imaging.FormatConvertedBitmap]::new($bitmap, [System.Windows.Media.PixelFormats]::Indexed8, $palette, 0)
    [System.Windows.Media.Imaging.BitmapFrame]::Create($indexed)
}

function ConvertTo-LoopingGif {
    <#
    The GIF the encoder wrote, looping for ever, each frame shown -DelayMs: a NETSCAPE2.0 block
    after the global colour table, and a graphic control extension before each image - its delay
    set when the encoder wrote one, written when it didn't. Blocks as GIF89a lays them out: an
    extension is 0x21, a label and sub-blocks; an image is 0x2C, a 9-byte descriptor, a local
    colour table if flagged, the LZW code size and sub-blocks; 0x3B ends the file.
    #>
    param([byte[]] $Gif, [int] $DelayMs)

    $hundredths = [int][Math]::Round($DelayMs / 10)
    $out = [System.Collections.Generic.List[byte]]::new()
    $out.AddRange([byte[]][System.Text.Encoding]::ASCII.GetBytes('GIF89a'))
    $position = 6
    $packed = $Gif[$position + 4]
    $tableEnd = $position + 7 + $(if ($packed -band 0x80) { 3 * [Math]::Pow(2, ($packed -band 7) + 1) } else { 0 })
    $out.AddRange([byte[]]$Gif[$position..($tableEnd - 1)])
    $position = $tableEnd
    $out.AddRange([byte[]](0x21, 0xFF, 0x0B))
    $out.AddRange([byte[]][System.Text.Encoding]::ASCII.GetBytes('NETSCAPE2.0'))
    $out.AddRange([byte[]](0x03, 0x01, 0x00, 0x00, 0x00))
    $control = $false
    $skipSubBlocks = {
        param([int] $At)
        while ($Gif[$At] -ne 0) {
            $At += $Gif[$At] + 1
        }
        $At + 1
    }
    while ($position -lt $Gif.Length) {
        $kind = $Gif[$position]
        if ($kind -eq 0x3B) {
            $out.Add(0x3B)
            break
        }
        if ($kind -eq 0x21) {
            $label = $Gif[$position + 1]
            $end = & $skipSubBlocks ($position + 2)
            $block = [byte[]]$Gif[$position..($end - 1)]
            if ($label -eq 0xF9) {
                $block[4] = [byte]($hundredths -band 0xFF)
                $block[5] = [byte]($hundredths -shr 8)
                $control = $true
            }
            elseif ($label -eq 0xFF -and [System.Text.Encoding]::ASCII.GetString($Gif, $position + 3, 8) -eq 'NETSCAPE') {
                # The encoder's own loop block, if any: ours is written above.
                $position = $end
                continue
            }
            $out.AddRange($block)
            $position = $end
            continue
        }
        if ($kind -eq 0x2C) {
            if (-not $control) {
                $out.AddRange([byte[]](0x21, 0xF9, 0x04, 0x00, ($hundredths -band 0xFF), ($hundredths -shr 8), 0x00, 0x00))
            }
            $control = $false
            $flags = $Gif[$position + 9]
            $dataAt = $position + 10 + $(if ($flags -band 0x80) { 3 * [Math]::Pow(2, ($flags -band 7) + 1) } else { 0 })
            $end = & $skipSubBlocks ($dataAt + 1)
            $out.AddRange([byte[]]$Gif[$position..($end - 1)])
            $position = $end
            continue
        }
        throw "Unexpected GIF block 0x$($kind.ToString('X2', [cultureinfo]::InvariantCulture)) at $position."
    }
    $out.ToArray()
}

[void](Set-AppLanguage -Culture 'en-US')
$view = Get-ReadmeView
$app = New-MainWindow -Send { 'readme' } -Ask { $false } -Open { }
$window = $app.Window
try {
    $window.WindowStartupLocation = 'Manual'
    $window.Left = -20000
    $window.Top = -20000
    $window.ShowActivated = $false
    $window.ShowInTaskbar = $false
    $window.Show()
    Update-MainWindow -View $view
    Wait-WindowIdle -Window $window
    $encoder = [System.Windows.Media.Imaging.GifBitmapEncoder]::new()
    $tabs = $window.FindName('Tabs')
    foreach ($tab in @($tabs.Items)) {
        $tabs.SelectedItem = $tab
        Wait-WindowIdle -Window $window
        $encoder.Frames.Add((Get-WindowFrame -Window $window))
    }
    $stream = [System.IO.MemoryStream]::new()
    try {
        $encoder.Save($stream)
        $gif = ConvertTo-LoopingGif -Gif $stream.ToArray() -DelayMs $FrameMs
    }
    finally {
        $stream.Dispose()
    }
}
finally {
    $app.Exiting = $true
    $window.Close()
}
$folder = Split-Path -Parent $OutputPath
if ($folder -and -not (Test-Path -LiteralPath $folder)) {
    [void](New-Item -ItemType Directory -Path $folder)
}
[System.IO.File]::WriteAllBytes($OutputPath, $gif)
[pscustomobject]@{ Path = $OutputPath; Frames = $encoder.Frames.Count; Bytes = $gif.Length }

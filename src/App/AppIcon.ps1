# The app's own icon - the window's, the taskbar's and the Start-menu shortcut's: the glyph of the
# project's logo (assets/logo.html, its ?icon variant), a circular arrow around four signal bars,
# drawn from the logo's own geometry at every size. The tray keeps its icon of the signal
# (TrayIcon.ps1).

# The logo's colors (its light theme): the bars, and the arrow with the last bar.
$script:LogoAccent = '#0C8F80'
$script:LogoAccentLight = '#33C2AD'

# The images an icon file holds: the sizes Windows asks a window, the taskbar and a shortcut for,
# at the common display scales.
$script:AppIconSizes = @(16, 20, 24, 32, 40, 48, 64, 256)

function New-AppIconBitmap {
    # Draws the logo's glyph at -Size pixels on a transparent background: logo.html's 176-unit
    # square, scaled to the size. The caller disposes the bitmap.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory bitmap; changes no system state.')]
    param([int] $Size)

    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = $null
    $pen = $null
    $brushes = @()
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.ScaleTransform([float]($Size / 176), [float]($Size / 176))
        $light = [System.Drawing.ColorTranslator]::FromHtml($script:LogoAccentLight)
        $pen = [System.Drawing.Pen]::new($light, [float]12)
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        # The arrow: radius 62 around the center, clockwise from three o'clock to half past one,
        # and its head.
        $graphics.DrawArc($pen, [float]26, [float]26, [float]124, [float]124, [float]0, [float]315)
        $graphics.DrawLines($pen, [System.Drawing.PointF[]]@(
                [System.Drawing.PointF]::new(134, 22), [System.Drawing.PointF]::new(133, 46), [System.Drawing.PointF]::new(109, 45)))
        # Four bars rising from the same line, rounded; the last one lighter, a step short of full.
        $brushes = @([System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($script:LogoAccent)), [System.Drawing.SolidBrush]::new($light))
        $bars = @(@(50, 24), @(72, 38), @(94, 54), @(116, 70))
        for ($i = 0; $i -lt $bars.Count; $i++) {
            $x, $height = $bars[$i]
            $top = 128 - $height
            $shape = [System.Drawing.Drawing2D.GraphicsPath]::new()
            try {
                $shape.AddArc([float]$x, [float]$top, [float]10, [float]10, [float]180, [float]90)
                $shape.AddArc([float]($x + 6), [float]$top, [float]10, [float]10, [float]270, [float]90)
                $shape.AddArc([float]($x + 6), [float](128 - 10), [float]10, [float]10, [float]0, [float]90)
                $shape.AddArc([float]$x, [float](128 - 10), [float]10, [float]10, [float]90, [float]90)
                $shape.CloseFigure()
                $graphics.FillPath($brushes[[int]($i -eq $bars.Count - 1)], $shape)
            }
            finally {
                $shape.Dispose()
            }
        }
        $bitmap
    }
    catch {
        $bitmap.Dispose()
        throw
    }
    finally {
        foreach ($drawing in @($brushes) + $pen + $graphics) {
            if ($drawing) {
                $drawing.Dispose()
            }
        }
    }
}

function Get-AppIconData {
    <#
    .SYNOPSIS
        The app's icon, as the bytes of an .ico file.
    .DESCRIPTION
        One image per size in AppIconSizes, each stored as a PNG, which icon files may hold since
        Windows Vista: an ICONDIR, one ICONDIRENTRY per image (a side of 256 written 0), then the
        images.
    .EXAMPLE
        $bytes = Get-AppIconData
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param()

    $images = foreach ($size in $script:AppIconSizes) {
        $bitmap = New-AppIconBitmap -Size $size
        $stream = [System.IO.MemoryStream]::new()
        try {
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            [pscustomobject]@{ Size = $size; Data = $stream.ToArray() }
        }
        finally {
            $stream.Dispose()
            $bitmap.Dispose()
        }
    }
    $file = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($file)
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]@($images).Count)
        $offset = 6 + 16 * @($images).Count
        foreach ($image in $images) {
            $side = if ($image.Size -ge 256) { [byte]0 } else { [byte]$image.Size }
            $writer.Write($side)
            $writer.Write($side)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$image.Data.Length)
            $writer.Write([uint32]$offset)
            $offset += $image.Data.Length
        }
        foreach ($image in $images) {
            $writer.Write($image.Data)
        }
        $writer.Flush()
        # One array, not its bytes one by one.
        Write-Output -NoEnumerate -InputObject $file.ToArray()
    }
    finally {
        $writer.Dispose()
        $file.Dispose()
    }
}

function Export-AppIcon {
    <#
    .SYNOPSIS
        Writes the app's icon as an .ico file.
    .DESCRIPTION
        For the Start-menu shortcut: Get-AppIconData's bytes.
    .EXAMPLE
        Export-AppIcon -Path (Join-Path -Path $installFolder -ChildPath 'App\fibocom-fm350-gl-windows-gui.ico')
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ($PSCmdlet.ShouldProcess($Path, 'Write the app''s icon')) {
        [System.IO.File]::WriteAllBytes($Path, (Get-AppIconData))
    }
}

function New-AppIconImage {
    # The app's icon for a WPF window: an image whose decoder holds every size, among which WPF
    # picks the title bar's and the taskbar's.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory image; changes no system state.')]
    param()

    $stream = [System.IO.MemoryStream]::new([byte[]](Get-AppIconData))
    try {
        [System.Windows.Media.Imaging.BitmapFrame]::Create($stream, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    }
    finally {
        $stream.Dispose()
    }
}

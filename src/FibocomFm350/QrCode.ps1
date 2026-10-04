# A QR code read from an image: an eSIM's activation code, as the provider sends it (decided
# 2026-10-04). ZXing.Net (Apache-2.0) does the reading; the release zip carries it in its 'zxing'
# folder (tools/ZXing.psd1). Facts and sources: docs/AT-COMMANDS.md section 8.

# Where ZXing.Net's library is, below the app's folder: the one place that names it.
$script:ZxingRelativePath = 'zxing\zxing.dll'

# The image a user picks is read whole: a photo of a QR code is a few megabytes. A file larger than
# this, or an image of more pixels, is refused unread.
$script:QrMaxFileBytes = 20MB
$script:QrMaxPixels = 50000000

# The image is read at this size at most, its longer side: a QR code that fills a fraction of a
# phone's photo still has several pixels per module, and the reading stays short.
$script:QrMaxSide = 2000

function Get-ZxingPath {
    <#
    .SYNOPSIS
        Returns where ZXing.Net's library is: in the 'zxing' folder beside the app's modules.
    .DESCRIPTION
        The one place that names it. The installer copies the folder with the rest of the app,
        under Program Files, where only administrators can write (invariant 10); no setting names
        it. Returns the path whether the file is there or not.
    .EXAMPLE
        Test-Path -LiteralPath (Get-ZxingPath)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath $script:ZxingRelativePath
}

function Get-QrImageSize {
    # The size an image is read at: as it is, or scaled down to $script:QrMaxSide on its longer
    # side. Returns Width and Height.
    param([int] $Width, [int] $Height)

    $scale = [Math]::Min(1.0, $script:QrMaxSide / [Math]::Max($Width, $Height))
    [pscustomobject]@{
        Width  = [Math]::Max(1, [int][Math]::Round($Width * $scale))
        Height = [Math]::Max(1, [int][Math]::Round($Height * $scale))
    }
}

function Read-QrCode {
    <#
    .SYNOPSIS
        Reads the QR code in an image file.
    .DESCRIPTION
        The image - PNG, JPEG, BMP, GIF or TIFF - is drawn at most $script:QrMaxSide pixels on its
        longer side, and ZXing.Net looks for a QR code in it, trying hard. Returns Text and
        Problem: 'NotImage' (missing, unreadable, not an image), 'TooLarge', 'NoLibrary' (ZXing.Net
        is missing or can't be loaded) or 'NoCode' (no QR code found). The text is returned as
        it is: the caller checks it.
    .EXAMPLE
        Read-QrCode -Path "$env:USERPROFILE\Pictures\esim.png"
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $LibraryPath = (Get-ZxingPath)
    )

    $outcome = { param($text, $problem) [pscustomobject]@{ Text = $text; Problem = $problem } }
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
    if (-not $file -or $file -isnot [System.IO.FileInfo]) {
        return & $outcome $null 'NotImage'
    }
    if ($file.Length -gt $script:QrMaxFileBytes) {
        return & $outcome $null 'TooLarge'
    }
    Add-Type -AssemblyName System.Drawing
    $bytes = $null
    $image = $null
    $stream = $null
    try {
        $stream = [System.IO.MemoryStream]::new([System.IO.File]::ReadAllBytes($file.FullName))
        # Its header only: the pixels are decoded when it is drawn.
        $image = [System.Drawing.Image]::FromStream($stream, $false, $false)
        if ([long]$image.Width * $image.Height -gt $script:QrMaxPixels) {
            return & $outcome $null 'TooLarge'
        }
        $size = Get-QrImageSize -Width $image.Width -Height $image.Height
        $bitmap = [System.Drawing.Bitmap]::new($size.Width, $size.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                # A transparent background read as white, as a viewer shows it.
                $graphics.Clear([System.Drawing.Color]::White)
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.DrawImage($image, 0, 0, $size.Width, $size.Height)
            }
            finally {
                $graphics.Dispose()
            }
            $data = $bitmap.LockBits([System.Drawing.Rectangle]::new(0, 0, $size.Width, $size.Height), [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $bitmap.PixelFormat)
            try {
                $bytes = [byte[]]::new($data.Stride * $data.Height)
                [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
            }
            finally {
                $bitmap.UnlockBits($data)
            }
        }
        finally {
            $bitmap.Dispose()
        }
    }
    catch {
        return & $outcome $null 'NotImage'
    }
    finally {
        if ($image) { $image.Dispose() }
        if ($stream) { $stream.Dispose() }
    }

    if (-not ('ZXing.BarcodeReaderGeneric' -as [type])) {
        if (-not (Test-Path -LiteralPath $LibraryPath -PathType Leaf)) {
            return & $outcome $null 'NoLibrary'
        }
        try {
            Add-Type -LiteralPath $LibraryPath
        }
        catch {
            return & $outcome $null 'NoLibrary'
        }
    }
    $source = [ZXing.RGBLuminanceSource]::new($bytes, $size.Width, $size.Height, [ZXing.RGBLuminanceSource+BitmapFormat]::BGRA32)
    $reader = [ZXing.BarcodeReaderGeneric]::new()
    $reader.Options.PossibleFormats = [System.Collections.Generic.List[ZXing.BarcodeFormat]]::new([ZXing.BarcodeFormat[]]@([ZXing.BarcodeFormat]::QR_CODE))
    $reader.Options.TryHarder = $true
    $found = $reader.Decode($source)
    if (-not $found -or -not $found.Text) {
        return & $outcome $null 'NoCode'
    }
    & $outcome $found.Text $null
}

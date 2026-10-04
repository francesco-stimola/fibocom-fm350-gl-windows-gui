# The tray icon: drawn at runtime at the size Windows asks for, redrawn only when what it shows
# changes, and every icon handle destroyed once the next one is set. Design: docs/ARCHITECTURE.md
# -> Tray icon; invariant 5.

# Win32 calls System.Drawing doesn't make: DestroyIcon for the handles Bitmap.GetHicon creates
# (Icon.FromHandle never owns them), GetGuiResources to count GDI and USER objects.
if (-not ('FibocomFm350.NativeMethods' -as [type])) {
    Add-Type -Namespace FibocomFm350 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool DestroyIcon(IntPtr hIcon);

[DllImport("user32.dll")]
public static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);
'@
}

# A tray notification with an icon of the app's own (Shell_NotifyIcon, NOTIFYICONDATAW): NIF_INFO
# with NIIF_USER and NIIF_LARGE_ICON, the icon in hBalloonIcon, sent with NIM_MODIFY to the
# notification area icon a WinForms NotifyIcon added (AT-COMMANDS section 11.2).
if (-not ('FibocomFm350.TrayNotice' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace FibocomFm350 {
    public static class TrayNotice {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct NotifyIconData {
            public int cbSize;
            public IntPtr hWnd;
            public int uID;
            public int uFlags;
            public int uCallbackMessage;
            public IntPtr hIcon;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
            public int dwState;
            public int dwStateMask;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
            public int uTimeoutOrVersion;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
            public int dwInfoFlags;
            public Guid guidItem;
            public IntPtr hBalloonIcon;
        }

        private const int NimModify = 0x1;
        private const int NifInfo = 0x10;
        private const int NiifUser = 0x4;
        private const int NiifLargeIcon = 0x20;

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool Shell_NotifyIconW(int message, ref NotifyIconData data);

        // Shows the notification on the icon (window, id) with the given icon; false when
        // Windows refuses it.
        public static bool Show(IntPtr window, int id, string title, string text, IntPtr icon) {
            NotifyIconData data = new NotifyIconData();
            data.cbSize = Marshal.SizeOf(typeof(NotifyIconData));
            data.hWnd = window;
            data.uID = id;
            data.uFlags = NifInfo;
            data.szTip = string.Empty;
            data.szInfo = text;
            data.szInfoTitle = title;
            data.dwInfoFlags = NiifUser | NiifLargeIcon;
            data.hBalloonIcon = icon;
            return Shell_NotifyIconW(NimModify, ref data);
        }
    }
}
'@
}

# The color of each tone (Resolve-TrayIcon): green online, amber on its way, red when the user must
# act, grey without a modem or a worker.
$script:ToneColors = @{
    Online     = '#2E9E44'
    Working    = '#D89B00'
    Recovering = '#D89B00'
    Attention  = '#D13438'
    Offline    = '#8A8A8A'
    Stopped    = '#8A8A8A'
}

# The smallest icon on which the technology label is legible, in pixels.
$script:TrayLabelMinSize = 24

function Get-GuiResourceCount {
    <#
    .SYNOPSIS
        Counts this process's GDI and USER objects - what a leaking icon handle would make grow.
    .EXAMPLE
        (Get-GuiResourceCount).Gdi
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    try {
        [pscustomobject]@{
            Gdi  = [FibocomFm350.NativeMethods]::GetGuiResources($process.Handle, 0)
            User = [FibocomFm350.NativeMethods]::GetGuiResources($process.Handle, 1)
        }
    }
    finally {
        $process.Dispose()
    }
}

function New-TrayIconBitmap {
    # Draws the icon of -Icon (Resolve-TrayIcon's) at -Size pixels: four signal bars, the filled
    # ones in the tone's color, the others faint; the technology label in the top-left corner when
    # it is legible. The caller disposes the bitmap.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory bitmap; changes no system state.')]
    param([object] $Icon, [int] $Size)

    $color = [System.Drawing.ColorTranslator]::FromHtml($script:ToneColors[$Icon.Tone])
    $faint = [System.Drawing.Color]::FromArgb(80, 128, 128, 128)
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = $null
    $filled = $null
    $empty = $null
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $filled = [System.Drawing.SolidBrush]::new($color)
        $empty = [System.Drawing.SolidBrush]::new($faint)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
        # Four bars across the icon, rising left to right, with a pixel between them.
        $bars = if ($null -ne $Icon.Bars) { [int]$Icon.Bars } else { 0 }
        $width = [Math]::Max(2, [Math]::Floor(($Size - 3) / 4))
        for ($i = 0; $i -lt 4; $i++) {
            $height = [Math]::Max(2, [Math]::Round($Size * ($i + 1) / 4))
            $brush = if ($i -lt $bars) { $filled } else { $empty }
            $graphics.FillRectangle($brush, [int]($i * ($width + 1)), [int]($Size - $height), [int]$width, [int]$height)
        }
        if ($Icon.Label -and $Size -ge $script:TrayLabelMinSize) {
            $font = [System.Drawing.Font]::new('Segoe UI', [float]($Size * 0.36), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            try {
                $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
                $graphics.DrawString($Icon.Label, $font, $filled, [float]0, [float]0)
            }
            finally {
                $font.Dispose()
            }
        }
        $bitmap
    }
    catch {
        $bitmap.Dispose()
        throw
    }
    finally {
        foreach ($drawing in $empty, $filled, $graphics) {
            if ($drawing) {
                $drawing.Dispose()
            }
        }
    }
}

function New-TrayIconHandle {
    <#
    .SYNOPSIS
        Draws the tray icon and returns its Win32 icon handle; the caller destroys it.
    .DESCRIPTION
        Four signal bars, the filled ones in the tone's color, the others faint; the technology
        label ('5G', '4G') in the top-left corner when the icon is at least 24 pixels wide. -Icon
        is Resolve-TrayIcon's. The bitmap and the graphics are released here; the handle is the
        caller's, to free with Remove-TrayIconHandle.
    .EXAMPLE
        $handle = New-TrayIconHandle -Icon (Resolve-TrayIcon -Snapshot $snapshot) -Size 16
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory icon; changes no system state.')]
    [CmdletBinding()]
    [OutputType([System.IntPtr])]
    param(
        [Parameter(Mandatory)]
        [object] $Icon,

        [ValidateRange(16, 256)]
        [int] $Size = 16
    )

    $bitmap = New-TrayIconBitmap -Icon $Icon -Size $Size
    try {
        $bitmap.GetHicon()
    }
    finally {
        $bitmap.Dispose()
    }
}

function Remove-TrayIconHandle {
    <#
    .SYNOPSIS
        Destroys an icon handle made by New-TrayIconHandle.
    .EXAMPLE
        Remove-TrayIconHandle -Handle $handle
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [System.IntPtr] $Handle
    )

    if ($Handle -ne [System.IntPtr]::Zero -and $PSCmdlet.ShouldProcess("icon handle $Handle", 'Destroy')) {
        [void][FibocomFm350.NativeMethods]::DestroyIcon($Handle)
    }
}

function Get-TrayNoticeTarget {
    # The window and the id Windows knows a WinForms NotifyIcon's icon by - private to the
    # NotifyIcon, read by reflection -, or $null for anything else, or a NotifyIcon of a .NET that
    # keeps them otherwise.
    param([object] $NotifyIcon)

    if ($NotifyIcon -isnot [System.Windows.Forms.NotifyIcon]) {
        return $null
    }
    $flags = [System.Reflection.BindingFlags]'NonPublic, Instance'
    $windowField = [System.Windows.Forms.NotifyIcon].GetField('_window', $flags)
    $idField = [System.Windows.Forms.NotifyIcon].GetField('_id', $flags)
    if (-not $windowField -or -not $idField) {
        return $null
    }
    $window = $windowField.GetValue($NotifyIcon)
    if (-not $window -or -not $window.PSObject.Properties['Handle'] -or $window.Handle -eq [System.IntPtr]::Zero) {
        return $null
    }
    [pscustomobject]@{ Window = $window.Handle; Id = [int]$idField.GetValue($NotifyIcon) }
}

function Show-TrayNotice {
    <#
    .SYNOPSIS
        Shows a tray notification with the app's own icon in it.
    .DESCRIPTION
        Windows heads a tray notification with the program that sends it: with PowerShell from
        its MSIX package, PowerShell, whatever AppUserModelID the process or a shortcut carries
        (AT-COMMANDS section 11.2). The app's icon goes in the notification itself (-Icon, large),
        through the window and id of -NotifyIcon's own tray icon. Where those can't be reached,
        or Windows refuses, the standard notification with -Fallback's icon is shown instead.
        Returns 'Own' or 'Standard'.
    .EXAMPLE
        Show-TrayNotice -NotifyIcon $tray -Title 'New message' -Text 'From Info' -Icon $noticeIcon
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $NotifyIcon,

        [Parameter(Mandatory)]
        [string] $Title,

        [Parameter(Mandatory)]
        [string] $Text,

        [System.Drawing.Icon] $Icon,

        [System.Windows.Forms.ToolTipIcon] $Fallback = 'Info'
    )

    if (-not $PSCmdlet.ShouldProcess('the tray', 'Show a notification')) {
        return
    }
    $target = Get-TrayNoticeTarget -NotifyIcon $NotifyIcon
    if ($target -and $Icon -and [FibocomFm350.TrayNotice]::Show($target.Window, $target.Id, $Title, $Text, $Icon.Handle)) {
        return 'Own'
    }
    $NotifyIcon.ShowBalloonTip(10000, $Title, $Text, $Fallback)
    'Standard'
}

function Set-TrayIcon {
    <#
    .SYNOPSIS
        Shows a new icon in the tray, then destroys the previous one's handle.
    .DESCRIPTION
        -State remembers what is shown between calls: Model (the last Resolve-TrayIcon result
        drawn) and Handle. The icon is drawn only when the model changed - tone, bars or label -
        and the old handle is destroyed only once the new icon is set: a GDI handle leaking at
        every refresh would end the process after days. Returns $true when it redrew.
    .EXAMPLE
        Set-TrayIcon -NotifyIcon $notifyIcon -Icon $model -State $trayState
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object] $NotifyIcon,

        [Parameter(Mandatory)]
        [object] $Icon,

        [Parameter(Mandatory)]
        [hashtable] $State,

        [int] $Size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    )

    $shown = $State['Model']
    if ($shown -and $shown.Tone -eq $Icon.Tone -and $shown.Bars -eq $Icon.Bars -and $shown.Label -eq $Icon.Label) {
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess('the tray icon', 'Redraw')) {
        return $false
    }
    $handle = New-TrayIconHandle -Icon $Icon -Size $Size
    try {
        $NotifyIcon.Icon = [System.Drawing.Icon]::FromHandle($handle)
    }
    catch {
        Remove-TrayIconHandle -Handle $handle -Confirm:$false
        throw
    }
    if ($State['Handle']) {
        Remove-TrayIconHandle -Handle $State['Handle'] -Confirm:$false
    }
    $State['Handle'] = $handle
    $State['Model'] = $Icon
    $true
}

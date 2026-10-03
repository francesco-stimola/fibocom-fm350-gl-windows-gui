Set-StrictMode -Version Latest

# The tray app: UI thread, supervisor and worker runspace (docs/ARCHITECTURE.md -> Process model).
# WPF for the window, WinForms for the tray icon, System.Drawing to draw it: all ship with
# PowerShell 7 on Windows.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# The module path as the app's start script set it - this PowerShell's folder and Windows' own -,
# kept as it is: opening a runspace puts the user's module folder back in it, process-wide
# (docs/AT-COMMANDS.md section 11.2), and Start-WorkerRunspace takes it out again.
$script:ModulePath = $env:PSModulePath

# The core module: the worker, the snapshots, the simulated modem. Every worker runspace imports it
# again from the same folder (Supervisor.ps1).
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../FibocomFm350/FibocomFm350.psd1')

# One file per concern. The manifest's FunctionsToExport is the single list of public functions.
. (Join-Path $PSScriptRoot 'Texts.ps1')
. (Join-Path $PSScriptRoot 'View.ps1')
. (Join-Path $PSScriptRoot 'TrayIcon.ps1')
. (Join-Path $PSScriptRoot 'AppIcon.ps1')
. (Join-Path $PSScriptRoot 'AppIdentity.ps1')
. (Join-Path $PSScriptRoot 'MainWindow.ps1')
. (Join-Path $PSScriptRoot 'Supervisor.ps1')
. (Join-Path $PSScriptRoot 'App.ps1')

@{
    RootModule           = 'FibocomFm350.App.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'e6cd3125-87a3-43f0-8d01-56d3474bf688'
    Author               = 'Francesco Stimola'
    Copyright            = '(c) 2026 Francesco Stimola. Licensed under AGPL-3.0-or-later.'
    Description          = 'The tray app of fibocom-fm350-gl-windows-gui: tray icon, main window, supervisor of the worker that keeps the Fibocom FM350-GL online.'
    PowerShellVersion    = '7.6'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Complete-WorkerRunspace'
        'ConvertTo-TrayText'
        'ConvertTo-WindowView'
        'Enter-AppInstance'
        'Exit-AppInstance'
        'Export-AppIcon'
        'Get-AppText'
        'Get-DriverView'
        'Get-GuiResourceCount'
        'Get-NetworkModeView'
        'Get-TrayModeMenu'
        'Get-TrayUpdateItem'
        'New-MainWindow'
        'New-TrayIconHandle'
        'Receive-WorkerMessage'
        'Remove-TrayIconHandle'
        'Resolve-AppLanguage'
        'Resolve-SupervisorAction'
        'Resolve-TrayIcon'
        'Set-AppLanguage'
        'Set-AppShortcutIdentity'
        'Set-TrayIcon'
        'Show-MainWindow'
        'Start-Fm350App'
        'Start-WorkerRunspace'
        'Stop-WorkerRunspace'
        'Update-MainWindow'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('Fibocom', 'FM350', '5G', 'LTE', 'Modem', 'Windows')
            LicenseUri = 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui/blob/main/LICENSE'
            ProjectUri = 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui'
        }
    }
}

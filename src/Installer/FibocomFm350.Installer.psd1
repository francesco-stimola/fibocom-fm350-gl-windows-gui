@{
    RootModule           = 'FibocomFm350.Installer.psm1'
    ModuleVersion        = '2.0.0'
    GUID                 = '7f0a3c52-5d1e-4b8a-9c36-2e4f8b1d6a90'
    Author               = 'Francesco Stimola'
    Copyright            = '(c) 2026 Francesco Stimola. Licensed under AGPL-3.0-or-later.'
    Description          = 'The installer of fibocom-fm350-gl-windows-gui: copies the app under Program Files, registers the tasks that start it elevated and its Start-menu shortcut, and removes them.'
    PowerShellVersion    = '7.6'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'ConvertTo-CommandLine'
        'Copy-AppPackage'
        'Exit-AppInstallLock'
        'Get-AppInstallLayout'
        'Get-PathAccess'
        'Get-SetupText'
        'Install-Fm350App'
        'New-AppShortcut'
        'New-AppTaskDefinition'
        'Register-AppTask'
        'Register-AppUninstallEntry'
        'Resolve-SetupLanguage'
        'Set-SetupLanguage'
        'Stop-AppInstance'
        'Test-AdminOnlyAccess'
        'Test-AppFolderAccess'
        'Test-AppPackage'
        'Uninstall-Fm350App'
        'Unregister-AppTask'
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

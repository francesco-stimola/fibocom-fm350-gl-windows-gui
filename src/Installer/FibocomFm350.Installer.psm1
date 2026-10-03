Set-StrictMode -Version Latest

# The installer (docs/ARCHITECTURE.md -> Installing and updating). It runs elevated from the
# package's folder - extracted from the release zip, or the installed copy - started by
# Start-Fm350.ps1 through Invoke-Fm350Setup.ps1. The manifest's FunctionsToExport is the single list
# of public functions.
. (Join-Path $PSScriptRoot 'Texts.ps1')
. (Join-Path $PSScriptRoot 'Installer.ps1')

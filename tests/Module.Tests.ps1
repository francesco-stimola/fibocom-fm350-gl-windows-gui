# Script scope: Pester shares BeforeAll variables with the It blocks, which the analyzer can't see.
BeforeAll {
    $script:manifestPath = "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1"
    $script:manifest = Import-PowerShellDataFile -Path $script:manifestPath
    $script:module = Import-Module $script:manifestPath -Force -PassThru
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'FibocomFm350 module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:manifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    # PowerShell silently skips a FunctionsToExport entry with no matching function,
    # so a typo or a forgotten dot-source would otherwise ship a module without it.
    It 'exports every function its manifest lists' {
        $missing = $script:manifest.FunctionsToExport | Where-Object { $_ -notin $script:module.ExportedFunctions.Keys }
        $missing | Should -BeNullOrEmpty
    }

    It 'gives every exported function a synopsis' {
        $undocumented = $script:module.ExportedFunctions.Keys | Where-Object {
            -not (Get-Help $_).Synopsis -or (Get-Help $_).Synopsis -match "^\s*$_\s"
        }
        $undocumented | Should -BeNullOrEmpty
    }
}

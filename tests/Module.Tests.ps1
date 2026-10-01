# Both modules - the core and the tray app - have a valid manifest and export exactly what it lists.

BeforeDiscovery {
    $script:manifests = @(
        @{ Name = 'FibocomFm350'; Path = "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" }
        @{ Name = 'FibocomFm350.App'; Path = "$PSScriptRoot/../src/App/FibocomFm350.App.psd1" }
    )
}

AfterAll {
    Remove-Module FibocomFm350.App, FibocomFm350 -ErrorAction SilentlyContinue
}

Describe '<Name> module' -ForEach $script:manifests {
    # Script scope: Pester shares BeforeAll variables with the It blocks, which the analyzer can't see.
    BeforeAll {
        $script:manifestPath = $Path
        $script:manifest = Import-PowerShellDataFile -Path $Path
        $script:module = Import-Module $Path -Force -PassThru
    }

    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:manifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    # PowerShell silently skips a FunctionsToExport entry with no matching function,
    # so a typo or a forgotten dot-source would otherwise ship a module without it.
    It 'exports every function its manifest lists, and no other' {
        $missing = $script:manifest.FunctionsToExport | Where-Object { $_ -notin $script:module.ExportedFunctions.Keys }
        $missing | Should -BeNullOrEmpty
        $script:module.ExportedFunctions.Count | Should -Be $script:manifest.FunctionsToExport.Count
    }

    It 'gives every exported function a synopsis' {
        $undocumented = $script:module.ExportedFunctions.Keys | Where-Object {
            -not (Get-Help $_).Synopsis -or (Get-Help $_).Synopsis -match "^\s*$_\s"
        }
        $undocumented | Should -BeNullOrEmpty
    }
}
